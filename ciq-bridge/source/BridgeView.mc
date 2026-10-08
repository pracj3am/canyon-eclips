import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

// Edge MTB: 240x320, buttons only.
//   light tiles (front | rear)
//   big dynamo speed
//   battery %, voltage / net power in-out / dynamo + USB
//   status line
class BridgeView extends WatchUi.View {
    private var _ble as BridgeBle;

    public function initialize(ble as BridgeBle) {
        View.initialize();
        _ble = ble;
    }

    public function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var ready = (_ble.state == Bridge.READY) && _ble.bikeLink;

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        // light tiles
        var tileH = h / 4;
        drawLight(dc, 0, 0, w / 2, tileH, "FRONT", _ble.front, ready);
        drawLight(dc, w / 2, 0, w - w / 2, tileH, "REAR", _ble.rear, ready);

        // bottom: status line + three info rows
        var hx = dc.getFontHeight(Graphics.FONT_XTINY);
        var hs = dc.getFontHeight(Graphics.FONT_SMALL);
        var statusY = h - hx - 2;
        var infoTop = statusY - 3 * hs - 4;
        drawInfo(dc, w, infoTop, hs, ready);

        dc.setColor(_ble.lastError != null ? Graphics.COLOR_RED : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        var status = _ble.lastError != null ? _ble.lastError : statusText();
        dc.drawText(w / 2, statusY, Graphics.FONT_XTINY, status, Graphics.TEXT_JUSTIFY_CENTER);

        // big speed between the tiles and the info rows
        drawSpeed(dc, w, tileH, infoTop, ready);
    }

    private function drawSpeed(dc as Dc, w as Number, top as Number, bottom as Number, ready as Boolean) as Void {
        var unitH = dc.getFontHeight(Graphics.FONT_XTINY);
        var avail = bottom - top - unitH;
        var fonts = [Graphics.FONT_NUMBER_THAI_HOT, Graphics.FONT_NUMBER_HOT, Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_LARGE];
        var font = Graphics.FONT_LARGE;
        for (var i = 0; i < fonts.size(); i++) {
            if (dc.getFontHeight(fonts[i]) <= avail) {
                font = fonts[i];
                break;
            }
        }
        var text = (ready && _ble.full && _ble.speed10 >= 0) ? ((_ble.speed10 + 5) / 10).toString() : "--";
        var fh = dc.getFontHeight(font);
        var y = top + (avail - fh) / 2;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, y, font, text, Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, y + fh, Graphics.FONT_XTINY, "km/h", Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function drawInfo(dc as Dc, w as Number, y as Number, hs as Number, ready as Boolean) as Void {
        var f = Graphics.FONT_SMALL;
        if (!ready || !_ble.full) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            var batt = _ble.soc >= 0 ? "Batt " + _ble.soc + "%" : "";
            dc.drawText(w / 2, y + hs, f, batt, Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        // battery % + voltage
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var batt = (_ble.soc >= 0 ? _ble.soc + "%" : "?%") + "  " + (_ble.vbat / 1000.0).format("%.2f") + " V";
        dc.drawText(w / 2, y, f, "Batt " + batt, Graphics.TEXT_JUSTIFY_CENTER);

        // net power: green when the dynamo charges, orange when draining
        var watts = _ble.vbat.toFloat() * _ble.ibat / 1000000.0;
        var label;
        if (_ble.ibat > 20) {
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            label = "+" + watts.format("%.1f") + " W charging";
        } else if (_ble.ibat < -20) {
            dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
            label = watts.format("%.1f") + " W draining";
        } else {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            label = "0.0 W idle";
        }
        dc.drawText(w / 2, y + hs, f, label, Graphics.TEXT_JUSTIFY_CENTER);

        // dynamo voltage while generating; USB-C output (bike powering a device)
        var dyn = _ble.generating() ? "Dynamo " + ((_ble.vac2 + 500) / 1000) + " V" : "Dynamo off";
        dc.setColor(_ble.generating() ? Graphics.COLOR_GREEN : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, y + 2 * hs, f, dyn + (_ble.usb ? "  USB out" : ""), Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function drawLight(dc as Dc, x as Number, y as Number, w as Number, h as Number, label as String, on as Boolean, ready as Boolean) as Void {
        var bg = !ready ? Graphics.COLOR_DK_GRAY : (on ? Graphics.COLOR_YELLOW : Graphics.COLOR_BLACK);
        var fg = on && ready ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;
        dc.setColor(bg, bg);
        dc.fillRoundedRectangle(x + 4, y + 4, w - 8, h - 8, 10);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawRoundedRectangle(x + 4, y + 4, w - 8, h - 8, 10);
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        var lh = dc.getFontHeight(Graphics.FONT_XTINY);
        var vh = dc.getFontHeight(Graphics.FONT_MEDIUM);
        var top = y + (h - lh - vh) / 2;
        dc.drawText(x + w / 2, top, Graphics.FONT_XTINY, label, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(x + w / 2, top + lh, Graphics.FONT_MEDIUM, on ? "ON" : "OFF", Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function statusText() as String {
        if (_ble.state == Bridge.SCANNING) {
            return "Searching bridge...";
        } else if (_ble.state == Bridge.CONNECTING) {
            return "Connecting...";
        } else if (!_ble.bikeLink) {
            return "Bridge up, waiting for bike...";
        }
        return "Connected  -  Menu: details";
    }
}

// Menu page: bike diagnostics and raw values of fields not decoded yet.
class DiagView extends WatchUi.View {
    private var _ble as BridgeBle;

    public function initialize(ble as BridgeBle) {
        View.initialize();
        _ble = ble;
    }

    public function onShow() as Void {
        _ble.requestDiag();
    }

    public function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var lines = [
            "ECLIPS details",
            "FW " + _ble.fw + "   EEPROM " + num(_ble.eeprom),
            "Bonds " + num(_ble.bonds) + "/3",
            "Count " + num(_ble.count),
            "TPS fails " + num(_ble.tpsFail),
            "Power state " + _ble.powerState,
            "iBat " + _ble.ibat + " mA",
            "Dynamo in " + (_ble.vac2 / 1000.0).format("%.1f") + " V",
            "USB-C in " + _ble.vac1 + " mV",
            "Charger " + _ble.chgState + "  input " + (_ble.chgInput ? 1 : 0),
            "USB out " + (_ble.usb ? 1 : 0) + "   BL " + (_ble.bl ? 1 : 0) + " (?)",
        ];
        var lh = dc.getFontHeight(Graphics.FONT_SMALL);
        for (var i = 0; i < lines.size(); i++) {
            dc.drawText(8, 6 + i * lh, Graphics.FONT_SMALL, lines[i], Graphics.TEXT_JUSTIFY_LEFT);
        }
    }

    private function num(n as Number) as String {
        return n >= 0 ? n.toString() : "?";
    }
}
