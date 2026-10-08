import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

// Top half = front light, bottom half = rear light; tap a half to toggle.
class EclipsView extends WatchUi.View {
    private var _ble as EclipsBle;

    public function initialize(ble as EclipsBle) {
        View.initialize();
        _ble = ble;
    }

    public function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var barH = 44;
        var half = (h - barH) / 2;

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        if (_ble.state == Eclips.STATE_READY) {
            drawLight(dc, 0, w, half, "FRONT", _ble.isOn("FL"));
            drawLight(dc, half, w, half, "REAR", _ble.isOn("RL"));
        } else {
            // not connected yet: show connection event history for debugging
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            var lh = dc.getFontHeight(Graphics.FONT_XTINY);
            for (var k = 0; k < _ble.events.size(); k++) {
                dc.drawText(4, 4 + k * lh, Graphics.FONT_XTINY, _ble.events[k], Graphics.TEXT_JUSTIFY_LEFT);
            }
        }

        // status bar
        var y = h - barH;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        var soc = _ble.info["SOC"];
        var line1 = statusText() + (soc != null ? "   Batt " + soc : "");
        dc.drawText(w / 2, y + 2, Graphics.FONT_SMALL, line1, Graphics.TEXT_JUSTIFY_CENTER);
        var line2 = _ble.lastError;
        if (line2 == null && _ble.state != Eclips.STATE_READY) {
            line2 = "#" + _ble.attempt + (_ble.secure ? " sec " : " def ") + _ble.lastEvent;
        } else if (line2 == null) {
            var v = _ble.info["VBat"];
            var i = _ble.info["iBat"];
            line2 = (v != null ? v : "") + (i != null ? "  " + i : "");
        }
        dc.setColor(_ble.lastError != null ? Graphics.COLOR_RED : Graphics.COLOR_LT_GRAY, Graphics.COLOR_BLACK);
        dc.drawText(w / 2, y + 24, Graphics.FONT_XTINY, line2, Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function drawLight(dc as Dc, y as Number, w as Number, h as Number, label as String, on as Boolean) as Void {
        var ready = _ble.state == Eclips.STATE_READY;
        var bg = !ready ? Graphics.COLOR_DK_GRAY : (on ? Graphics.COLOR_YELLOW : Graphics.COLOR_BLACK);
        var fg = on && ready ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;
        dc.setColor(bg, bg);
        dc.fillRoundedRectangle(6, y + 6, w - 12, h - 12, 12);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawRoundedRectangle(6, y + 6, w - 12, h - 12, 12);
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, y + h / 2 - 30, Graphics.FONT_MEDIUM, label, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(w / 2, y + h / 2 + 2, Graphics.FONT_LARGE, on ? "ON" : "OFF", Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function statusText() as String {
        switch (_ble.state) {
            case Eclips.STATE_SCANNING: return "Searching...";
            case Eclips.STATE_CONNECTING: return "Connecting...";
            case Eclips.STATE_CONNECTED: return "Pairing...";
            default: return "Connected";
        }
    }
}
