// ECLIPS BLE bridge for ESP32-C6 (native ESP-IDF + esp-nimble-cpp).
//
//   Canyon unit  <--BLE central, PIN-->  ESP32-C6  <--BLE peripheral, no PIN-->  Garmin Edge
//
// Central side: bonds to the Canyon "Power Supply" with the fixed passkey and
// speaks its Nordic UART protocol (1-byte commands, ASCII status).
// Peripheral side: exposes a tiny no-encryption service the Connect IQ app
// connects to with no pairing.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "esp_timer.h"
#include "nvs_flash.h"
#include "sdkconfig.h"

#include "NimBLEDevice.h"

// ---- bike (central) side -------------------------------------------------
// Set in menuconfig ("ECLIPS bridge") or sdkconfig.secrets, see README.
static const char*    BIKE_ADDR    = CONFIG_ECLIPS_BIKE_ADDR;    // static random addr
static const uint32_t BIKE_PASSKEY = CONFIG_ECLIPS_BIKE_PASSKEY; // last 6 digits of serial

static NimBLEUUID NUS_SVC("6e400001-b5a3-f393-e0a9-e50e24dcca9e");
static NimBLEUUID NUS_RX ("6e400002-b5a3-f393-e0a9-e50e24dcca9e"); // write -> bike
static NimBLEUUID NUS_TX ("6e400003-b5a3-f393-e0a9-e50e24dcca9e"); // notify <- bike

static const uint8_t CMD_GET_INFO = 0x0E;

// ---- bridge (peripheral) side --------------------------------------------
static const char* BRIDGE_NAME = "ECLIPS Bridge";
static NimBLEUUID BR_SVC   ("e51c0000-9b4e-4f21-8d7a-2c6f1a3b5d70");
static NimBLEUUID BR_CTRL  ("e51c0000-9b4e-4f21-8d7a-2c6f1a3b5d71"); // write
static NimBLEUUID BR_STATUS("e51c0000-9b4e-4f21-8d7a-2c6f1a3b5d72"); // notify, live
static NimBLEUUID BR_DIAG  ("e51c0000-9b4e-4f21-8d7a-2c6f1a3b5d73"); // read, diagnostics

// ---- shared state --------------------------------------------------------
static NimBLEClient*               bikeClient = nullptr;
static NimBLERemoteCharacteristic* bikeRx     = nullptr; // NUS RX (write)
static NimBLECharacteristic*       statusChar = nullptr;
static NimBLECharacteristic*       diagChar   = nullptr;
static volatile bool bikeReady = false;

// Latest values from the bike's ASCII status report (see PROTOCOL.md).
struct BikeState {
    uint8_t  fl = 0, rl = 0, bl = 0, usb = 0;
    uint8_t  chgState = 0, chgInput = 0; // "Chg: a, b": charger state, input power present
    uint8_t  soc = 0xFF;            // %, 0xFF = unknown
    uint8_t  powerState = 0;
    uint16_t vbat = 0;              // mV
    int16_t  ibat = 0;              // mA, negative = discharging
    uint16_t speed10 = 0xFFFF;      // 0.1 km/h, 0xFFFF = unknown
    uint16_t vac1 = 0, vac2 = 0;    // charger inputs, mV: VAC1 USB-C in?, VAC2 dynamo
    uint8_t  fw[3] = {0, 0, 0};
    uint16_t eeprom = 0, tpsFail = 0;
    uint32_t count = 0;
    uint8_t  paired = 0;
};
static BikeState st;
static std::string lineBuf;
static std::string reportBuf; // raw report, printed once complete (debug/decoding)

// Edge commands are queued and sent from the main task: a blocking GATT write
// to the bike from inside a NimBLE callback would deadlock the host task.
static QueueHandle_t cmdQueue;

static inline uint32_t millis32() {
    return (uint32_t)(esp_timer_get_time() / 1000);
}

static void put16(uint8_t* b, uint16_t v) { b[0] = v & 0xFF; b[1] = v >> 8; }

// Live status, 14 bytes little-endian (fits the 20-byte payload of the
// default MTU, which is all Connect IQ gets):
//  0 bikeLink  1 flags(b0 FL, b1 RL, b2 BL, b3 USB, b4-6 charger state, b7 input)  2 soc%
//  3 vbat mV   5 ibat mA (signed)   7 speed 0.1km/h   9 vac1   11 vac2   13 powerState
// Bytes 0-2 are unchanged from the original 3-byte packet.
static void pushStatus() {
    uint8_t b[14];
    b[0] = bikeReady ? 1 : 0;
    b[1] = (st.fl ? 0x01 : 0) | (st.rl ? 0x02 : 0) | (st.bl ? 0x04 : 0) |
           (st.usb ? 0x08 : 0) | ((st.chgState & 0x07) << 4) | (st.chgInput ? 0x80 : 0);
    b[2] = st.soc;
    put16(b + 3, st.vbat);
    put16(b + 5, (uint16_t)st.ibat);
    put16(b + 7, st.speed10);
    put16(b + 9, st.vac1);
    put16(b + 11, st.vac2);
    b[13] = st.powerState;
    if (statusChar != nullptr) {
        statusChar->setValue(b, sizeof(b));
        statusChar->notify();
    }
    // Diagnostics, 12 bytes: fw[3], eeprom, count(u32), tpsFail, paired
    uint8_t d[12];
    d[0] = st.fw[0]; d[1] = st.fw[1]; d[2] = st.fw[2];
    put16(d + 3, st.eeprom);
    d[5] = st.count & 0xFF; d[6] = (st.count >> 8) & 0xFF;
    d[7] = (st.count >> 16) & 0xFF; d[8] = st.count >> 24;
    put16(d + 9, st.tpsFail);
    d[11] = st.paired;
    if (diagChar != nullptr) {
        diagChar->setValue(d, sizeof(d));
    }
}

static bool key(const std::string& line, const char* k) {
    return line.rfind(k, 0) == 0;
}

static const char* val(const std::string& line) {
    size_t p = line.find(':');
    return p == std::string::npos ? "" : line.c_str() + p + 1;
}

// parse one "Key: value" status line; returns true on the last line (VAC2)
static bool parseLine(const std::string& line) {
    const char* v = val(line);
    if      (key(line, "FL:"))            st.fl = atoi(v) != 0;
    else if (key(line, "RL:"))            st.rl = atoi(v) != 0;
    else if (key(line, "BL:"))            st.bl = atoi(v) != 0;
    else if (key(line, "USB:"))           st.usb = atoi(v) != 0;
    else if (key(line, "SOC:")) {
        int x = atoi(v);                  // "SOC: 50%" -> 50
        if (x >= 0 && x <= 100) st.soc = (uint8_t)x;
    }
    else if (key(line, "VBat:"))          st.vbat = (uint16_t)atoi(v);
    else if (key(line, "iBat:"))          st.ibat = (int16_t)atoi(v);
    else if (key(line, "Speed:"))         st.speed10 = (uint16_t)(strtof(v, nullptr) * 10.0f + 0.5f);
    else if (key(line, "VAC1:"))          st.vac1 = (uint16_t)atoi(v);
    else if (key(line, "VAC2:"))        { st.vac2 = (uint16_t)atoi(v); return true; }
    else if (key(line, "Power State:"))   st.powerState = (uint8_t)atoi(v);
    else if (key(line, "Chg:")) {
        int a = 0, b = 0;                 // "Chg: 0, 0"
        sscanf(v, "%d , %d", &a, &b);
        st.chgState = (uint8_t)(a & 0x07); st.chgInput = b != 0;
    }
    else if (key(line, "FW:")) {
        int a = 0, b = 0, c = 0;          // "FW: 0.1.2"
        sscanf(v, "%d.%d.%d", &a, &b, &c);
        st.fw[0] = a; st.fw[1] = b; st.fw[2] = c;
    }
    else if (key(line, "EEPROM_Ver:"))    st.eeprom = (uint16_t)atoi(v);
    else if (key(line, "Count:"))         st.count = (uint32_t)strtoul(v, nullptr, 10);
    else if (key(line, "TPS_COMM_Fail:")) st.tpsFail = (uint16_t)atoi(v);
    else if (key(line, "Paired_Conn:"))   st.paired = (uint8_t)atoi(v);
    return false;
}

// The report spans several notifications; notify the Edge once it is complete.
static void onBikeNotify(NimBLERemoteCharacteristic* c, uint8_t* data, size_t len, bool isNotify) {
    for (size_t i = 0; i < len; i++) {
        char ch = (char)data[i];
        if (ch == '\n') {
            if (!lineBuf.empty()) { reportBuf += lineBuf; reportBuf += '|'; }
            if (parseLine(lineBuf)) {
                pushStatus();
                printf("R %lu %s\n", (unsigned long)millis32(), reportBuf.c_str());
                reportBuf.clear();
            }
            lineBuf.clear();
        } else if (ch != '\r') {
            lineBuf += ch;
            if (lineBuf.length() > 64) { lineBuf.clear(); }
        }
    }
}

// ---- central: provide the passkey when the bike asks ---------------------
class BikeClientCB : public NimBLEClientCallbacks {
    void onConnect(NimBLEClient* c) override {
        printf("bike: connected, starting security\n");
    }
    void onConnectFail(NimBLEClient* c, int reason) override {
        printf("bike: connect FAIL reason=%d\n", reason);
    }
    void onPassKeyEntry(NimBLEConnInfo& connInfo) override {
        printf("bike: onPassKeyEntry -> injecting %lu\n", (unsigned long)BIKE_PASSKEY);
        NimBLEDevice::injectPassKey(connInfo, BIKE_PASSKEY);
    }
    void onConfirmPasskey(NimBLEConnInfo& connInfo, uint32_t pin) override {
        printf("bike: onConfirmPasskey pin=%lu (confirming)\n", (unsigned long)pin);
        NimBLEDevice::injectConfirmPasskey(connInfo, true);
    }
    void onAuthenticationComplete(NimBLEConnInfo& connInfo) override {
        printf("bike: auth complete encrypted=%d bonded=%d\n",
               connInfo.isEncrypted(), connInfo.isBonded());
    }
    // The bike asks for a 420 ms supervision timeout right after connecting,
    // which drops the link while we also advertise to the Edge. Reject it and
    // keep NimBLE's more relaxed initial parameters.
    bool onConnParamsUpdateRequest(NimBLEClient* c, const ble_gap_upd_params* p) override {
        printf("bike: param update req itvl %u-%u lat %u timeout %u -> rejected\n",
               p->itvl_min, p->itvl_max, p->latency, p->supervision_timeout);
        return false;
    }
    void onDisconnect(NimBLEClient* c, int reason) override {
        bikeReady = false;
        bikeRx = nullptr;
        pushStatus();
        printf("bike: disconnected reason=%d\n", reason);
    }
};
static BikeClientCB bikeCB;

static bool connectBike() {
    if (bikeClient == nullptr) {
        bikeClient = NimBLEDevice::createClient();
        bikeClient->setClientCallbacks(&bikeCB, false);
    }
    NimBLEAddress addr(BIKE_ADDR, BLE_ADDR_RANDOM);

    // Scan first and connect to the advert we actually saw: proves the radio
    // can hear the bike and uses the advertised address type.
    NimBLEScan* scan = NimBLEDevice::getScan();
    scan->setActiveScan(false);
    scan->setInterval(100); // 100% duty cycle: window == interval
    scan->setWindow(100);
    scan->clearResults();
    NimBLEScanResults res = scan->getResults(15000, false); // bike adverts only every ~5 s when idle
    const NimBLEAdvertisedDevice* adv = res.getDevice(addr);
    if (adv == nullptr) {
        printf("scan: %d devices, bike NOT seen:", res.getCount());
        for (int i = 0; i < res.getCount(); i++) {
            const NimBLEAdvertisedDevice* d = res.getDevice(i);
            printf(" %s/%d", d->getAddress().toString().c_str(), d->getRSSI());
        }
        printf("\n");
        return false;
    }
    printf("scan: bike seen rssi=%d connectable=%d\n", adv->getRSSI(), adv->isConnectable());

    printf("connecting to bike...\n");
    if (!bikeClient->connect(adv)) {
        printf("  connect failed\n");
        return false;
    }
    printf("  connected, calling secureConnection()...\n");
    if (!bikeClient->secureConnection()) { // triggers pairing + passkey
        printf("  secure/pair failed\n");
        bikeClient->disconnect();
        return false;
    }
    printf("  secured OK\n");
    NimBLERemoteService* svc = bikeClient->getService(NUS_SVC);
    if (svc == nullptr) { printf("  no NUS\n"); bikeClient->disconnect(); return false; }
    bikeRx = svc->getCharacteristic(NUS_RX);
    NimBLERemoteCharacteristic* tx = svc->getCharacteristic(NUS_TX);
    if (bikeRx == nullptr || tx == nullptr) { printf("  no NUS chars\n"); bikeClient->disconnect(); return false; }
    if (!tx->subscribe(true, onBikeNotify)) { printf("  subscribe failed\n"); bikeClient->disconnect(); return false; }
    bikeReady = true;
    printf("bike ready\n");
    pushStatus();
    return true;
}

// send one command byte to the bike, then ask for fresh status
static void sendToBike(uint8_t cmd) {
    if (!bikeReady || bikeRx == nullptr) { return; }
    bikeRx->writeValue(&cmd, 1, true);
    uint8_t info = CMD_GET_INFO;
    bikeRx->writeValue(&info, 1, true);
}

// ---- peripheral: receive commands from the Edge --------------------------
class CtrlCB : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* c, NimBLEConnInfo& connInfo) override {
        NimBLEAttValue v = c->getValue();
        if (v.size() >= 1) {
            uint8_t cmd = v[0];
            xQueueSend(cmdQueue, &cmd, 0);
        }
    }
};
static CtrlCB ctrlCB;

// Allow two clients at once (Edge data field + Edge app, or Edge + laptop
// test client): keep advertising after the first one connects. 3 connections
// total = bike + 2 clients (CONFIG_BT_NIMBLE_MAX_CONNECTIONS).
static const int MAX_CLIENTS = 2;

class ServerCB : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer* s, NimBLEConnInfo& connInfo) override {
        printf("client connected (%d)\n", s->getConnectedCount());
        if (s->getConnectedCount() < MAX_CLIENTS) {
            NimBLEDevice::startAdvertising();
        }
    }
    void onDisconnect(NimBLEServer* s, NimBLEConnInfo& connInfo, int reason) override {
        printf("client disconnected (%d left)\n", s->getConnectedCount());
    }
};
static ServerCB serverCB;

static void startBridgePeripheral() {
    NimBLEServer* server = NimBLEDevice::createServer();
    server->advertiseOnDisconnect(true); // Edge reconnects every app launch
    server->setCallbacks(&serverCB);
    NimBLEService* svc = server->createService(BR_SVC);

    NimBLECharacteristic* ctrl = svc->createCharacteristic(
        BR_CTRL, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
    ctrl->setCallbacks(&ctrlCB);

    statusChar = svc->createCharacteristic(
        BR_STATUS, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
    diagChar = svc->createCharacteristic(BR_DIAG, NIMBLE_PROPERTY::READ);
    pushStatus(); // initial values (link down, unknowns)

    server->start();

    NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
    adv->setName(BRIDGE_NAME);
    adv->addServiceUUID(BR_SVC);
    adv->enableScanResponse(true);
    adv->start();
    printf("bridge advertising\n");
}

extern "C" void app_main(void) {
    nvs_flash_init();

    printf("\nECLIPS bridge starting\n");
    if (BIKE_ADDR[0] == '\0' || BIKE_PASSKEY == 0) {
        printf("ERROR: bike address/PIN not configured, see README (sdkconfig.secrets)\n");
        while (true) { vTaskDelay(pdMS_TO_TICKS(10000)); }
    }
    cmdQueue = xQueueCreate(8, sizeof(uint8_t));
    NimBLEDevice::init(BRIDGE_NAME);
    // central needs to input the bike's passkey -> keyboard-only, bond + MITM
    NimBLEDevice::setSecurityAuth(true, true, true);
    NimBLEDevice::setSecurityIOCap(BLE_HS_IO_KEYBOARD_ONLY);

    startBridgePeripheral();

    uint32_t lastPoll = 0;
    while (true) {
        if (!bikeReady) {
            connectBike();
            vTaskDelay(pdMS_TO_TICKS(2000));
            continue;
        }
        if (millis32() - lastPoll > 1000) { // 1 s: live speed
            lastPoll = millis32();
            if (bikeRx != nullptr) {
                uint8_t info = CMD_GET_INFO;
                bikeRx->writeValue(&info, 1, true);
            }
        }
        uint8_t cmd;
        if (xQueueReceive(cmdQueue, &cmd, pdMS_TO_TICKS(100)) == pdTRUE) {
            printf("edge cmd 0x%02x -> bike\n", cmd);
            sendToBike(cmd);
        }
    }
}
