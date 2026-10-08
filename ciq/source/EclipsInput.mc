import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Touch: tap top half = front, bottom half = rear.
// Buttons: Enter toggles both, Up = front, Down = rear.
class EclipsInput extends WatchUi.BehaviorDelegate {
    private var _ble as EclipsBle;

    public function initialize(ble as EclipsBle) {
        BehaviorDelegate.initialize();
        _ble = ble;
    }

    public function onTap(evt as WatchUi.ClickEvent) as Boolean {
        var xy = evt.getCoordinates();
        var h = System.getDeviceSettings().screenHeight;
        if (xy[1] < (h - 44) / 2) {
            toggleFront();
        } else if (xy[1] < h - 44) {
            toggleRear();
        }
        return true;
    }

    public function onSelect() as Boolean {
        var on = !(_ble.isOn("FL") && _ble.isOn("RL"));
        _ble.setFront(on);
        _ble.setRear(on);
        return true;
    }

    public function onPreviousPage() as Boolean {
        toggleFront();
        return true;
    }

    public function onNextPage() as Boolean {
        toggleRear();
        return true;
    }

    private function toggleFront() as Void {
        _ble.setFront(!_ble.isOn("FL"));
    }

    private function toggleRear() as Void {
        _ble.setRear(!_ble.isOn("RL"));
    }
}
