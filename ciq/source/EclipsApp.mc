import Toybox.Application;
import Toybox.Lang;
import Toybox.Timer;
import Toybox.WatchUi;

class EclipsApp extends Application.AppBase {
    private var _ble as EclipsBle;
    private var _pollTimer as Timer.Timer;

    public function initialize() {
        AppBase.initialize();
        _ble = new EclipsBle();
        _pollTimer = new Timer.Timer();
    }

    public function onStart(state as Dictionary?) as Void {
        _ble.start();
        _pollTimer.start(method(:onPoll), 5000, true);
    }

    public function onStop(state as Dictionary?) as Void {
        _pollTimer.stop();
        _ble.stop();
    }

    public function onPoll() as Void {
        if (_ble.state == Eclips.STATE_READY) {
            _ble.requestInfo();
        }
    }

    public function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        return [new EclipsView(_ble), new EclipsInput(_ble)];
    }
}
