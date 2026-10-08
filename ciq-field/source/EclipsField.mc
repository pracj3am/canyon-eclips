import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

// Ride-screen data field: net battery power of the ECLIPS unit.
//   label  "Charging 48%" (green) / "Draining 48%" (orange) / "Idle 48%"
//   value  watts as an absolute number. Garmin's number fonts have no "+",
//          so the direction is shown by the label and the colour.
// Data comes from the ESP32 bridge via the shared BridgeBle.
class EclipsField extends WatchUi.DataField {
    private var _ble as BridgeBle;

    public function initialize(ble as BridgeBle) {
        DataField.initialize();
        _ble = ble;
    }

    public function onUpdate(dc as Dc) as Void {
        var bg = getBackgroundColor();
        var dark = (bg == Graphics.COLOR_BLACK);
        var fg = dark ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
        dc.setColor(fg, bg);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();
        var ready = (_ble.state == Bridge.READY) && _ble.bikeLink && _ble.full;

        var label;
        var value = "--";
        var color = fg;
        if (!ready) {
            label = (_ble.state == Bridge.READY) ? "ECLIPS: no bike" : "ECLIPS: no bridge";
        } else {
            var watts = _ble.vbat.toFloat() * _ble.ibat / 1000000.0;
            value = watts.abs().format("%.1f");
            if (_ble.ibat > 20) {
                label = "Charging";
                color = dark ? Graphics.COLOR_GREEN : Graphics.COLOR_DK_GREEN;
            } else if (_ble.ibat < -20) {
                label = "Draining";
                color = Graphics.COLOR_ORANGE;
            } else {
                label = "Idle";
                value = "0.0";
            }
            if (_ble.soc >= 0) {
                label += " " + _ble.soc + "%";
            }
        }

        // label at the top
        var lf = Graphics.FONT_XTINY;
        var lh = dc.getFontHeight(lf);
        dc.setColor(ready ? color : fg, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, 1, lf, label, Graphics.TEXT_JUSTIFY_CENTER);

        // value: largest font that fits next to the "W" unit
        var unitW = dc.getTextWidthInPixels(" W", lf);
        var availH = h - lh - 2;
        var availW = w - unitW - 4;
        var fonts = [Graphics.FONT_NUMBER_THAI_HOT, Graphics.FONT_NUMBER_HOT, Graphics.FONT_NUMBER_MEDIUM,
                     Graphics.FONT_NUMBER_MILD, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL];
        var font = Graphics.FONT_SMALL;
        for (var i = 0; i < fonts.size(); i++) {
            if (dc.getFontHeight(fonts[i]) <= availH && dc.getTextWidthInPixels(value, fonts[i]) <= availW) {
                font = fonts[i];
                break;
            }
        }
        var vw = dc.getTextWidthInPixels(value, font);
        var vh = dc.getFontHeight(font);
        var x = (w - vw - unitW) / 2;
        var y = lh + 1 + (availH - vh) / 2;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, font, value, Graphics.TEXT_JUSTIFY_LEFT);
        if (ready) {
            dc.drawText(x + vw, y + vh - dc.getFontHeight(lf) - 2, lf, " W", Graphics.TEXT_JUSTIFY_LEFT);
        }
    }
}
