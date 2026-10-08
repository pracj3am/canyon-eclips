import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class EclipsBridgeApp extends Application.AppBase {
    private var _ble as BridgeBle;

    public function initialize() {
        AppBase.initialize();
        _ble = new BridgeBle();
    }

    public function onStart(state as Dictionary?) as Void {
        _ble.start();
    }

    public function onStop(state as Dictionary?) as Void {
        _ble.stop();
    }

    public function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        return [new BridgeView(_ble), new BridgeInput(_ble)];
    }
}
