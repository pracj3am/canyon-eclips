# Canyon ECLIPS: alternative control (no Canyon app, no internet)

Reverse-engineered Bluetooth control of the Canyon Grizl **ECLIPS** light and
power unit, which advertises as **"Canyon Power Supply"**. The official Canyon
app needs an internet connection. Everything here works fully offline: from a
laptop, or from a **Garmin Edge** through a small ESP32-C6 bridge.

> **Unofficial.** Not affiliated with or endorsed by Canyon or Garmin. The
> protocol was worked out for interoperability with hardware you own. Use at
> your own risk.

- Full BLE protocol: [PROTOCOL.md](PROTOCOL.md)
- Read-only firmware-update service probe: [smp_probe.txt](smp_probe.txt)

Tested with: Canyon Grizl ECLIPS unit (FW 0.1.2), Garmin Edge MTB (FW 32.20,
Connect IQ 6.0), ESP32-C6-DevKitC, Linux with BlueZ.

---

## TL;DR: what you need

| Thing | Value |
|---|---|
| Device name | **Canyon Power Supply** |
| Address | your unit's static random address (`D9:…`). It is in the ECLIPS QR code, and any BLE scanner shows it |
| Pairing PIN | **last 6 digits of your ECLIPS serial number** (Quick Start Guide / frame) |
| Service UUID | `6e400001-b5a3-f393-e0a9-e50e24dcca9e` (Nordic UART) |
| **Write commands here** | `6e400002-b5a3-f393-e0a9-e50e24dcca9e` |
| **Read status here** (notify) | `6e400003-b5a3-f393-e0a9-e50e24dcca9e` |

### Commands: one hex byte, written to `…0002`
| Hex | Action |
|-----|--------|
| `03` | front light ON |
| `04` | front light OFF |
| `05` | rear light ON |
| `06` | rear light OFF |
| `0E` | request status (reply arrives on `…0003`) |

Mnemonic: **`…0002` = you write to the bike**, **`…0003` = the bike answers**.

### Status reply (ASCII text on `…0003`)
```
UID: cps_02      Chg: 0, 0       iBat: -99 mA    VBat: 7778 mV
SOC: 50%         USB: 0          FL: 0 (front)   RL: 1 (rear)
BL: 1            Speed: 0 km/h   FW: 0.1.2       Paired_Conn: 2
```
All fields are decoded in [PROTOCOL.md](PROTOCOL.md).

### Important limits
- **Pairing with the PIN is mandatory.** Commands sent over an unpaired link are
  received but ignored.
- The unit keeps only **3 bonds** (`Paired_Conn` shows the count). A phone, a
  laptop and the ESP32 bridge fill them all. What happens when a fourth device
  pairs is untested.
- **Only one central at a time** holds the link. The unit stops advertising
  while connected, so whoever connects first blocks the others.

---

## Option A: Laptop (Linux, BlueZ)

```sh
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python pair.py <PIN>          # bond once
.venv/bin/python eclips.py status
.venv/bin/python eclips.py front on|off
.venv/bin/python eclips.py rear on|off
.venv/bin/python eclips.py all on|off
```
The scripts find the unit by name. If it is already connected (and therefore
not advertising), set `ECLIPS_ADDR=<address>`.

`pair.py` marks the unit *trusted*, which makes BlueZ auto-reconnect and hold
the link. To let another device (e.g. the bridge) connect, free it:
```sh
bluetoothctl untrust <address>
bluetoothctl disconnect <address>
```

---

## Option B: Garmin Edge via an ESP32-C6 bridge

```
Canyon unit  <--BLE, PIN-->  ESP32-C6  <--BLE, no PIN-->  Edge (Connect IQ app + data field)
```
The ESP32 does the PIN pairing that Connect IQ can't, then offers the Edge a
simple unencrypted service. Status: the Edge MTB app has sent light commands
through the bridge; the full chain (commands and decoded status) was verified
with `bridge_test.py`; the data field is built but not yet tested on a device.

### Bridge service (ESP32 → Edge)
| | UUID | |
|---|---|---|
| Service | `e51c0000-9b4e-4f21-8d7a-2c6f1a3b5d70` | advertised as **ECLIPS Bridge** |
| Control (write) | `e51c0000-9b4e-4f21-8d7a-2c6f1a3b5d71` | 1 byte, same as the bike: `03`/`04`/`05`/`06` |
| Status (notify/read) | `e51c0000-9b4e-4f21-8d7a-2c6f1a3b5d72` | 14 bytes LE, sent ~1 s: `link, flags, soc%, vbat mV u16, ibat mA s16, speed 0.1km/h u16, vac1 u16, vac2 u16, powerState`; flags b0 front, b1 rear, b2 BL, b3 USB out, b4-6 charger state, b7 charger input present; vac2 = dynamo mV, vac1 = USB-C in mV; 0xFF/0xFFFF = unknown |
| Diagnostics (read) | `e51c0000-9b4e-4f21-8d7a-2c6f1a3b5d73` | 12 bytes: `fw major.minor.patch, EEPROM u16, Count u32, TPS_COMM_Fail u16, bonds` |

Packets are at most 20 bytes, because Connect IQ can't raise the MTU above the
default 23. The bridge accepts **two clients at once** (data field + app, or
Edge + laptop): three BLE connections in total, counting the one to the bike.

### Firmware (`esp32-idf/`, ESP-IDF + esp-nimble-cpp)
Tested with ESP-IDF v6.1.
```sh
cd esp32-idf
cp sdkconfig.secrets.example sdkconfig.secrets   # then fill in address + PIN
. <path-to-esp-idf>/export.sh
idf.py build
idf.py -p /dev/ttyACM0 flash monitor             # serial access needs the dialout group
```
`sdkconfig.secrets` is git-ignored and only read when `sdkconfig` is generated.
After changing it, delete `sdkconfig`, or set the values in
`idf.py menuconfig` → **ECLIPS bridge** instead.

Lessons built into the firmware (each one caused a failure during bring-up):
- **Range.** When idle the unit advertises only every ~5 s and weakly. A C6
  dev board's antenna misses it from across a room, so mount the bridge on the
  bike near the unit (it connects at about −50 dBm there). Scan window is 15 s.
- **Supervision timeout.** Right after connecting, the unit asks for a 420 ms
  supervision timeout, which drops the link. The bridge rejects that request
  and keeps NimBLE's 2.56 s.
- **No blocking GATT calls in NimBLE callbacks.** Edge commands go through a
  FreeRTOS queue to the main task; writing to the bike from inside `onWrite`
  deadlocked the host task.
- `advertiseOnDisconnect(true)`: the Edge reconnects on every app launch.

### Edge app (`ciq-bridge/`)
A plain Connect IQ client with no bonding, so it works on the Edge MTB.
Buttons: **Up** = front, **Down** = rear, **Enter** = both, **Menu** =
diagnostics page. The screen shows the light tiles, a big dynamo speed,
battery % and voltage, net power (green charging / orange draining), and
dynamo and USB state.

### Ride-screen data field (`ciq-field/`)
**ECLIPS Power**: net battery power in watts, shown as an absolute value. The
label says **Charging** (green), **Draining** (orange) or Idle, plus battery %.
Add it to a ride data screen.

Both Connect IQ projects share the bridge protocol code in
`ciq-common/BridgeBle.mc`.

### Building the Connect IQ apps
You need:
- the Connect IQ SDK (tested 9.2.0) with the **Edge MTB** device files, downloaded via
  Garmin's SDK Manager;
- Java 17+;
- a developer key:
  ```sh
  openssl genrsa -out developer_key.pem 4096
  openssl pkcs8 -topk8 -inform PEM -outform DER -in developer_key.pem -out developer_key.der -nocrypt
  ```

Then:
```sh
CIQ_SDK=/path/to/connectiq-sdk CIQ_KEY=/path/to/developer_key.der ciq-bridge/build.sh
CIQ_SDK=/path/to/connectiq-sdk CIQ_KEY=/path/to/developer_key.der ciq-field/build.sh
```
Copy `ciq-bridge/bin/EclipsBridge.prg` and `ciq-field/bin/EclipsPower.prg` to
the Edge's `GARMIN/APPS/` folder over USB.

### Test from the laptop (no Edge needed)
```sh
.venv/bin/python bridge_test.py watch        # status stream
.venv/bin/python bridge_test.py rear on      # front|rear on|off
```

---

## What does NOT work (so nobody retries it)

- **Garmin Edge talking to the unit directly.** Connect IQ BLE only supports
  "Just Works" pairing and has **no passkey/PIN entry API on any device**
  (a Garmin developer called adding it "highly doubtful"). ECLIPS requires
  Passkey Entry, so no Edge can pair with it from a Connect IQ app, not even
  the 540/840/1040/1050 that do support bonding. The Edge MTB has no bonding
  API at all (crash: "Symbol Not Found isBonded"). The non-working attempt is
  kept in `ciq/` for reference. Option B solves this.
- **Transferring a laptop's bond into a Garmin.** Connect IQ has no way to
  import keys or set the Bluetooth address.
- **Patching the unit's firmware.** The official app fetches the image from a
  private Firebase project, and it is an MCUboot-signed ZIP, so a modified
  image would be rejected unless signed with Canyon's key. A read-only probe
  (`scripts/smp_probe.py` → `smp_probe.txt`) found no settings or shell that
  could disable the PIN.
- **ANT+ from an ESP32-C6** (to appear in the Edge's built-in Lights menu). The
  pure-ESP32 ANT stack `RaemondBW/esp32-ant` explicitly doesn't support the C6,
  its transmit side is untested against real head units, and its radio works
  in one direction per session, while an ANT+ light must be bidirectional.

---

## How the protocol was found

The official Android app (`com.canyon.connected` 8.3.1) was decompiled with
jadx to find the command bytes and the status format. The fields were then
decoded by logging the unit while spinning the wheel, switching lights and
plugging in USB. The decompiled app is not included in this repository.

## Files
```
README.md               this file
LICENSE                 MIT
PROTOCOL.md             BLE protocol and decoded status fields
requirements.txt        Python dependencies for the laptop scripts
bike.py                 finds the unit (by name, or ECLIPS_ADDR)
eclips.py               laptop control CLI, direct to the unit
pair.py                 laptop bonding helper (bluetoothctl)
bridge_test.py          laptop client for the ESP32 bridge (Edge stand-in)
scripts/smp_probe.py    read-only probe of the firmware-update service
scripts/window_test.py  unpaired-link experiment (stalls pairing, tries writes)
smp_probe.txt           output of smp_probe.py
esp32-idf/              ESP32-C6 bridge firmware (ESP-IDF)
ciq-bridge/             Edge app: light control and status
ciq-field/              Edge data field: charging/draining watts
ciq-common/             bridge protocol code shared by the two Edge projects
ciq/                    failed direct-to-unit Connect IQ app (reference only)
```

## License

[MIT](LICENSE). The ESP32 firmware pulls in
[esp-nimble-cpp](https://github.com/h2zero/esp-nimble-cpp) (Apache-2.0) via the
ESP-IDF component manager; it is downloaded at build time, not included here.
