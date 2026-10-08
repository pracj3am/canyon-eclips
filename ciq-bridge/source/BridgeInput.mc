import Toybox.Lang;
import Toybox.WatchUi;

// Edge MTB buttons: Up = front toggle, Down = rear toggle, Enter = both,
// Menu = diagnostics page (Back returns).
class BridgeInput extends WatchUi.BehaviorDelegate {
    private var _ble as BridgeBle;

    public function initialize(ble as BridgeBle) {
        BehaviorDelegate.initialize();
        _ble = ble;
    }

    public function onSelect() as Boolean {
        _ble.toggleBoth();
        return true;
    }

    public function onPreviousPage() as Boolean {
        _ble.setFront(!_ble.front);
        return true;
    }

    public function onNextPage() as Boolean {
        _ble.setRear(!_ble.rear);
        return true;
    }

    public function onMenu() as Boolean {
        WatchUi.pushView(new DiagView(_ble), new WatchUi.BehaviorDelegate(), WatchUi.SLIDE_LEFT);
        return true;
    }
}
