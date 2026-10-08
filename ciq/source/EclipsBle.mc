import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

// Canyon ECLIPS ("Canyon Power Supply") over Nordic UART Service.
// Commands are single bytes written to NUS RX; status comes back as ASCII
// "Key: value\n" lines over NUS TX notifications (see ../PROTOCOL.md).
module Eclips {
    const DEVICE_NAME = "Canyon Power Supply";

    const CMD_FRONT_ON = 0x03;
    const CMD_FRONT_OFF = 0x04;
    const CMD_REAR_ON = 0x05;
    const CMD_REAR_OFF = 0x06;
    const CMD_GET_INFO = 0x0E;

    enum State {
        STATE_SCANNING,
        STATE_CONNECTING,
        STATE_CONNECTED,
        STATE_READY,
    }
}

class EclipsBle extends BluetoothLowEnergy.BleDelegate {
    private var _nusService as BluetoothLowEnergy.Uuid;
    private var _nusRx as BluetoothLowEnergy.Uuid;
    private var _nusTx as BluetoothLowEnergy.Uuid;

    private var _device as BluetoothLowEnergy.Device?;
    private var _rx as BluetoothLowEnergy.Characteristic?;

    // CIQ allows only one outstanding GATT operation: queue command bytes.
    private var _queue as Array<Number> = [];
    private var _busy as Boolean = false;
    private var _lineBuf as String = "";

    public var state as Eclips.State = Eclips.STATE_SCANNING;
    public var info as Dictionary<String, String> = {};
    public var lastError as String? = null;
    public var attempt as Number = 0;
    public var secure as Boolean = false;
    public var lastEvent as String = "start";
    public var events as Array<String> = [];

    private var _watchdog as Timer.Timer = new Timer.Timer();
    private var _stateSince as Number = 0;

    public function initialize() {
        BleDelegate.initialize();
        _nusService = BluetoothLowEnergy.stringToUuid("6e400001-b5a3-f393-e0a9-e50e24dcca9e");
        _nusRx = BluetoothLowEnergy.stringToUuid("6e400002-b5a3-f393-e0a9-e50e24dcca9e");
        _nusTx = BluetoothLowEnergy.stringToUuid("6e400003-b5a3-f393-e0a9-e50e24dcca9e");
    }

    public function start() as Void {
        BluetoothLowEnergy.setDelegate(self);
        BluetoothLowEnergy.registerProfile({
            :uuid => _nusService,
            :characteristics => [
                { :uuid => _nusRx },
                { :uuid => _nusTx, :descriptors => [BluetoothLowEnergy.cccdUuid()] },
            ],
        });
    }

    public function stop() as Void {
        _watchdog.stop();
        BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
        if (_device != null) {
            BluetoothLowEnergy.unpairDevice(_device);
        }
    }

    // --- public commands ---------------------------------------------------

    public function setFront(on as Boolean) as Void {
        send(on ? Eclips.CMD_FRONT_ON : Eclips.CMD_FRONT_OFF);
        send(Eclips.CMD_GET_INFO);
    }

    public function setRear(on as Boolean) as Void {
        send(on ? Eclips.CMD_REAR_ON : Eclips.CMD_REAR_OFF);
        send(Eclips.CMD_GET_INFO);
    }

    public function requestInfo() as Void {
        if (_queue.indexOf(Eclips.CMD_GET_INFO) < 0) {
            send(Eclips.CMD_GET_INFO);
        }
    }

    public function isOn(key as String) as Boolean {
        return "1".equals(info[key]);
    }

    // --- BleDelegate -------------------------------------------------------

    public function onProfileRegister(uuid as BluetoothLowEnergy.Uuid, status as BluetoothLowEnergy.Status) as Void {
        if (status != BluetoothLowEnergy.STATUS_SUCCESS) {
            fail("profile register " + status);
            return;
        }
        event("profile ok");
        _watchdog.start(method(:onWatchdog), 1000, true);
        startScan();
    }

    // Recover from stalls: CONNECTING too long -> retry with the other
    // connection strategy; CONNECTED without encryption -> try NUS anyway.
    public function onWatchdog() as Void {
        var elapsed = System.getTimer() - _stateSince;
        if (state == Eclips.STATE_CONNECTING && elapsed > 15000) {
            event("connect timeout");
            if (_device != null) {
                BluetoothLowEnergy.unpairDevice(_device);
                _device = null;
            }
            // CONNECTION_STRATEGY_SECURE_PAIR_BOND freezes Edge MTB (fw bug:
            // passkey entry never prompted), so only ever retry the default.
            startScan();
        } else if (state == Eclips.STATE_CONNECTED && _rx == null && elapsed > 6000) {
            event("no encryption, trying plain");
            setupNus();
        }
    }

    private function startScan() as Void {
        attempt++;
        BluetoothLowEnergy.setConnectionStrategy(secure
            ? BluetoothLowEnergy.CONNECTION_STRATEGY_SECURE_PAIR_BOND
            : BluetoothLowEnergy.CONNECTION_STRATEGY_DEFAULT);
        BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_SCANNING);
        setState(Eclips.STATE_SCANNING);
    }

    public function onScanResults(scanResults as BluetoothLowEnergy.Iterator) as Void {
        for (var r = scanResults.next() as BluetoothLowEnergy.ScanResult?; r != null; r = scanResults.next() as BluetoothLowEnergy.ScanResult?) {
            if (Eclips.DEVICE_NAME.equals(r.getDeviceName())) {
                BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
                event("found rssi " + r.getRssi());
                setState(Eclips.STATE_CONNECTING);
                try {
                    _device = BluetoothLowEnergy.pairDevice(r);
                } catch (e) {
                    fail("pair: " + e.getErrorMessage());
                }
                return;
            }
        }
    }

    public function onConnectedStateChanged(device as BluetoothLowEnergy.Device, cs as BluetoothLowEnergy.ConnectionState) as Void {
        event("conn state " + cs + (device.isBonded() ? " bonded" : ""));
        if (cs == BluetoothLowEnergy.CONNECTION_STATE_CONNECTED) {
            _device = device;
            setState(Eclips.STATE_CONNECTED);
            if (device.isBonded()) {
                setupNus();
            } else {
                // ECLIPS rejects unencrypted links; passkey = last 6 digits of serial
                device.requestBond();
            }
        } else {
            _device = null;
            _rx = null;
            _queue = [];
            _busy = false;
            _lineBuf = "";
            startScan();
        }
    }

    public function onEncryptionStatus(device as BluetoothLowEnergy.Device, status as BluetoothLowEnergy.Status) as Void {
        event("encryption " + status);
        if (status == BluetoothLowEnergy.STATUS_SUCCESS) {
            setupNus();
        } else {
            fail("encryption " + status);
        }
    }

    public function onDescriptorWrite(descriptor as BluetoothLowEnergy.Descriptor, status as BluetoothLowEnergy.Status) as Void {
        _busy = false;
        if (status != BluetoothLowEnergy.STATUS_SUCCESS) {
            fail("cccd write " + status);
            return;
        }
        setState(Eclips.STATE_READY);
        requestInfo();
    }

    public function onCharacteristicWrite(characteristic as BluetoothLowEnergy.Characteristic, status as BluetoothLowEnergy.Status) as Void {
        _busy = false;
        if (status != BluetoothLowEnergy.STATUS_SUCCESS) {
            lastError = "write " + status;
        }
        pump();
    }

    public function onCharacteristicChanged(characteristic as BluetoothLowEnergy.Characteristic, value as ByteArray) as Void {
        for (var i = 0; i < value.size(); i++) {
            var c = value[i];
            if (c == 0x0A) {
                parseLine(_lineBuf);
                _lineBuf = "";
            } else if (c != 0x0D) {
                _lineBuf += c.toChar();
            }
        }
        WatchUi.requestUpdate();
    }

    // --- internals ---------------------------------------------------------

    private function setupNus() as Void {
        if (_device == null || _rx != null) {
            return;
        }
        var service = _device.getService(_nusService);
        if (service == null) {
            fail("NUS service missing");
            return;
        }
        _rx = service.getCharacteristic(_nusRx);
        var tx = service.getCharacteristic(_nusTx);
        var cccd = tx != null ? tx.getDescriptor(BluetoothLowEnergy.cccdUuid()) : null;
        if (_rx == null || cccd == null) {
            fail("NUS characteristics missing");
            return;
        }
        _busy = true;
        cccd.requestWrite([0x01, 0x00]b);
    }

    private function send(cmd as Number) as Void {
        _queue.add(cmd);
        pump();
    }

    private function pump() as Void {
        if (_busy || _rx == null || state != Eclips.STATE_READY || _queue.size() == 0) {
            return;
        }
        var cmd = _queue[0];
        _queue = _queue.slice(1, null);
        _busy = true;
        try {
            _rx.requestWrite([cmd]b, { :writeType => BluetoothLowEnergy.WRITE_TYPE_WITH_RESPONSE });
        } catch (e) {
            _busy = false;
            lastError = "write: " + e.getErrorMessage();
        }
    }

    private function parseLine(line as String) as Void {
        var sep = line.find(":");
        if (sep == null) {
            return;
        }
        var key = line.substring(0, sep);
        var chars = line.toCharArray();
        var start = sep + 1;
        while (start < chars.size() && chars[start] == ' ') {
            start++;
        }
        var val = line.substring(start, line.length());
        if (key != null && val != null) {
            info[key] = val;
        }
    }

    private function event(msg as String) as Void {
        lastEvent = msg;
        var t = (System.getTimer() / 1000) % 1000;
        events.add(t + "s #" + attempt + (secure ? "S " : "D ") + msg);
        if (events.size() > 9) {
            events = events.slice(-9, null);
        }
        System.println("ECLIPS " + System.getTimer() + " #" + attempt + (secure ? " secure: " : " default: ") + msg);
        WatchUi.requestUpdate();
    }

    private function setState(s as Eclips.State) as Void {
        state = s;
        _stateSince = System.getTimer();
        WatchUi.requestUpdate();
    }

    private function fail(msg as String) as Void {
        lastError = msg;
        System.println("ECLIPS: " + msg);
        WatchUi.requestUpdate();
    }
}
