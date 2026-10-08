import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Talks to the ESP32-C6 "ECLIPS Bridge", NOT the bike directly. The bridge is
// an unencrypted (no-PIN) peripheral, so this is a plain Connect IQ client with
// no bonding — which is what works on the Edge MTB. The bridge handles the
// PIN-paired link to the Canyon unit on its other radio side.
module Bridge {
    const NAME = "ECLIPS Bridge";

    // command bytes written to the control characteristic
    const CMD_FRONT_ON = 0x03;
    const CMD_FRONT_OFF = 0x04;
    const CMD_REAR_ON = 0x05;
    const CMD_REAR_OFF = 0x06;

    enum State { SCANNING, CONNECTING, READY }
}

class BridgeBle extends BluetoothLowEnergy.BleDelegate {
    private var _service as BluetoothLowEnergy.Uuid;
    private var _ctrlUuid as BluetoothLowEnergy.Uuid;
    private var _statusUuid as BluetoothLowEnergy.Uuid;
    private var _diagUuid as BluetoothLowEnergy.Uuid;

    private var _device as BluetoothLowEnergy.Device?;
    private var _ctrl as BluetoothLowEnergy.Characteristic?;
    private var _diag as BluetoothLowEnergy.Characteristic?;
    private var _diagPending as Boolean = false;

    private var _queue as Array<Number> = [];
    private var _busy as Boolean = false;

    public var state as Bridge.State = Bridge.SCANNING;
    public var bikeLink as Boolean = false; // bridge <-> Canyon unit up?
    public var front as Boolean = false;
    public var rear as Boolean = false;
    public var soc as Number = -1;          // battery %, -1 = unknown
    public var vbat as Number = 0;          // mV
    public var ibat as Number = 0;          // mA, negative = discharging
    public var speed10 as Number = -1;      // 0.1 km/h, -1 = unknown
    public var usb as Boolean = false;
    public var bl as Boolean = false;
    public var chgState as Number = 0;      // 0 idle, 3 charging
    public var chgInput as Boolean = false; // charger input (dynamo) has power
    public var vac1 as Number = 0;          // mV, second charger input (USB-C in?)
    public var vac2 as Number = 0;          // mV, dynamo input (decays slowly after stopping)
    public var powerState as Number = 0;
    public var full as Boolean = false;     // bridge sent the 14-byte packet
    // diagnostics (read on demand)
    public var fw as String = "?";
    public var eeprom as Number = -1;
    public var count as Number = -1;
    public var tpsFail as Number = -1;
    public var bonds as Number = -1;
    public var lastError as String? = null;

    public function initialize() {
        BleDelegate.initialize();
        _service = BluetoothLowEnergy.stringToUuid("e51c0000-9b4e-4f21-8d7a-2c6f1a3b5d70");
        _ctrlUuid = BluetoothLowEnergy.stringToUuid("e51c0000-9b4e-4f21-8d7a-2c6f1a3b5d71");
        _statusUuid = BluetoothLowEnergy.stringToUuid("e51c0000-9b4e-4f21-8d7a-2c6f1a3b5d72");
        _diagUuid = BluetoothLowEnergy.stringToUuid("e51c0000-9b4e-4f21-8d7a-2c6f1a3b5d73");
    }

    public function start() as Void {
        BluetoothLowEnergy.setDelegate(self);
        BluetoothLowEnergy.registerProfile({
            :uuid => _service,
            :characteristics => [
                { :uuid => _ctrlUuid },
                { :uuid => _statusUuid, :descriptors => [BluetoothLowEnergy.cccdUuid()] },
                { :uuid => _diagUuid },
            ],
        });
    }

    public function stop() as Void {
        BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
        if (_device != null) {
            BluetoothLowEnergy.unpairDevice(_device);
        }
    }

    // --- commands ----------------------------------------------------------

    public function setFront(on as Boolean) as Void {
        send(on ? Bridge.CMD_FRONT_ON : Bridge.CMD_FRONT_OFF);
    }

    public function setRear(on as Boolean) as Void {
        send(on ? Bridge.CMD_REAR_ON : Bridge.CMD_REAR_OFF);
    }

    // VAC2 holds its value for minutes after the wheel stops, so judge
    // "generating" by speed and the charger's input-present flag instead.
    public function generating() as Boolean {
        return speed10 > 0 || chgInput;
    }

    public function requestDiag() as Void {
        _diagPending = true;
        pump();
    }

    public function toggleBoth() as Void {
        var on = !(front && rear);
        setFront(on);
        setRear(on);
    }

    // --- BleDelegate -------------------------------------------------------

    public function onProfileRegister(uuid as BluetoothLowEnergy.Uuid, status as BluetoothLowEnergy.Status) as Void {
        if (status != BluetoothLowEnergy.STATUS_SUCCESS) {
            fail("profile " + status);
            return;
        }
        scan();
    }

    public function onScanResults(scanResults as BluetoothLowEnergy.Iterator) as Void {
        for (var r = scanResults.next() as BluetoothLowEnergy.ScanResult?; r != null; r = scanResults.next() as BluetoothLowEnergy.ScanResult?) {
            if (matches(r)) {
                BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
                setState(Bridge.CONNECTING);
                try {
                    BluetoothLowEnergy.pairDevice(r);
                } catch (e) {
                    fail("connect: " + e.getErrorMessage());
                    scan();
                }
                return;
            }
        }
    }

    public function onConnectedStateChanged(device as BluetoothLowEnergy.Device, cs as BluetoothLowEnergy.ConnectionState) as Void {
        if (cs == BluetoothLowEnergy.CONNECTION_STATE_CONNECTED) {
            _device = device;
            setupChars();
        } else {
            _device = null;
            _ctrl = null;
            _queue = [];
            _busy = false;
            bikeLink = false;
            scan();
        }
    }

    public function onDescriptorWrite(descriptor as BluetoothLowEnergy.Descriptor, status as BluetoothLowEnergy.Status) as Void {
        _busy = false;
        setState(Bridge.READY);
        pump();
    }

    public function onCharacteristicWrite(characteristic as BluetoothLowEnergy.Characteristic, status as BluetoothLowEnergy.Status) as Void {
        _busy = false;
        if (status != BluetoothLowEnergy.STATUS_SUCCESS) {
            lastError = "write " + status;
        }
        pump();
    }

    public function onCharacteristicChanged(characteristic as BluetoothLowEnergy.Characteristic, value as ByteArray) as Void {
        parseStatus(value);
    }

    public function onCharacteristicRead(characteristic as BluetoothLowEnergy.Characteristic, status as BluetoothLowEnergy.Status, value as ByteArray) as Void {
        _busy = false;
        if (status == BluetoothLowEnergy.STATUS_SUCCESS) {
            parseDiag(value);
        }
        pump();
    }

    // --- internals ---------------------------------------------------------

    private function matches(r as BluetoothLowEnergy.ScanResult) as Boolean {
        if (Bridge.NAME.equals(r.getDeviceName())) {
            return true;
        }
        var it = r.getServiceUuids();
        for (var u = it.next() as BluetoothLowEnergy.Uuid?; u != null; u = it.next() as BluetoothLowEnergy.Uuid?) {
            if (u.equals(_service)) {
                return true;
            }
        }
        return false;
    }

    private function scan() as Void {
        setState(Bridge.SCANNING);
        BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_SCANNING);
    }

    private function setupChars() as Void {
        if (_device == null) {
            return;
        }
        var service = _device.getService(_service);
        if (service == null) {
            fail("no service");
            return;
        }
        _ctrl = service.getCharacteristic(_ctrlUuid);
        _diag = service.getCharacteristic(_diagUuid); // null with older bridge firmware
        var st = service.getCharacteristic(_statusUuid);
        var cccd = st != null ? st.getDescriptor(BluetoothLowEnergy.cccdUuid()) : null;
        if (_ctrl == null || cccd == null) {
            fail("no chars");
            return;
        }
        _busy = true;
        cccd.requestWrite([0x01, 0x00]b); // enable notifications
    }

    private function send(cmd as Number) as Void {
        _queue.add(cmd);
        pump();
    }

    private function pump() as Void {
        if (_busy || _ctrl == null || state != Bridge.READY) {
            return;
        }
        if (_queue.size() == 0) {
            if (_diagPending && _diag != null) {
                _diagPending = false;
                _busy = true;
                _diag.requestRead();
            }
            return;
        }
        var cmd = _queue[0];
        _queue = _queue.slice(1, null);
        _busy = true;
        try {
            _ctrl.requestWrite([cmd]b, { :writeType => BluetoothLowEnergy.WRITE_TYPE_WITH_RESPONSE });
        } catch (e) {
            _busy = false;
            lastError = "write: " + e.getErrorMessage();
        }
    }

    // [link, flags, soc] + (14-byte firmware) vbat u16, ibat s16, speed u16,
    // vac1 u16, vac2 u16, powerState, all little-endian
    private function parseStatus(v as ByteArray) as Void {
        if (v.size() < 3) {
            return;
        }
        bikeLink = (v[0] != 0);
        var f = v[1];
        front = (f & 0x01) != 0;
        rear = (f & 0x02) != 0;
        soc = (v[2] == 0xFF) ? -1 : v[2];
        full = v.size() >= 14;
        if (full) {
            bl = (f & 0x04) != 0;
            usb = (f & 0x08) != 0;
            chgState = (f >> 4) & 0x07;
            chgInput = (f & 0x80) != 0;
            vbat = u16(v, 3);
            ibat = v.decodeNumber(Lang.NUMBER_FORMAT_SINT16, { :offset => 5, :endianness => Lang.ENDIAN_LITTLE }) as Number;
            var s = u16(v, 7);
            speed10 = (s == 0xFFFF) ? -1 : s;
            vac1 = u16(v, 9);
            vac2 = u16(v, 11);
            powerState = v[13];
        }
        lastError = null;
        WatchUi.requestUpdate();
    }

    // fw[3], eeprom u16, count u32, tpsFail u16, bonds
    private function parseDiag(v as ByteArray) as Void {
        if (v.size() < 12) {
            return;
        }
        fw = v[0] + "." + v[1] + "." + v[2];
        eeprom = u16(v, 3);
        count = v.decodeNumber(Lang.NUMBER_FORMAT_SINT32, { :offset => 5, :endianness => Lang.ENDIAN_LITTLE }) as Number;
        tpsFail = u16(v, 9);
        bonds = v[11];
        WatchUi.requestUpdate();
    }

    private function u16(v as ByteArray, off as Number) as Number {
        return v.decodeNumber(Lang.NUMBER_FORMAT_UINT16, { :offset => off, :endianness => Lang.ENDIAN_LITTLE }) as Number;
    }

    private function setState(s as Bridge.State) as Void {
        state = s;
        WatchUi.requestUpdate();
    }

    private function fail(msg as String) as Void {
        lastError = msg;
        System.println("Bridge: " + msg);
        WatchUi.requestUpdate();
    }
}
