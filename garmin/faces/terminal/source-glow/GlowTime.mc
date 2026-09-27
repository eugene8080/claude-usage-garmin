import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! VFD-style time for Claude Terminal: "HH:MM" (or "HH:MM:SS") drawn from pre-rendered RGBA glow
//! bitmaps (tools/build_glow_time.py) instead of the stm_time font. Only compiled into the VFD
//! build (monkey.jungle adds source-glow/ + resources-glow/ and excludes `font_time`).
//!
//! Placement reuses the time font's own metrics (advance, string width), exactly what the font
//! path uses, so each bitmap lands where the font glyph would, offset by GlowTimeMetrics.X0/Y0.
module GlowTime {

    var _bmps as Array = new [11];   // 0-9 = digits, 10 = colon; loaded on first use
    var _theme as Number = 0;        // 0 = Night Owl (GT*), 1 = Retro tube (RT*)

    //! Switch digit sets (the "Theme" setting). Drops the cached bitmaps so only the active
    //! set is ever held in the graphics pool.
    function setTheme(theme as Number) as Void {
        if (theme != _theme) {
            _theme = theme;
            _bmps = new [11];
        }
    }

    function resId(i as Number) as ResourceId {
        return (_theme == 1) ? retroId(i) : nightOwlId(i);
    }

    function retroId(i as Number) as ResourceId {
        switch (i) {
            case 0: return Rez.Drawables.RT0;
            case 1: return Rez.Drawables.RT1;
            case 2: return Rez.Drawables.RT2;
            case 3: return Rez.Drawables.RT3;
            case 4: return Rez.Drawables.RT4;
            case 5: return Rez.Drawables.RT5;
            case 6: return Rez.Drawables.RT6;
            case 7: return Rez.Drawables.RT7;
            case 8: return Rez.Drawables.RT8;
            case 9: return Rez.Drawables.RT9;
            default: return Rez.Drawables.RTC;
        }
    }

    function nightOwlId(i as Number) as ResourceId {
        switch (i) {
            case 0: return Rez.Drawables.GT0;
            case 1: return Rez.Drawables.GT1;
            case 2: return Rez.Drawables.GT2;
            case 3: return Rez.Drawables.GT3;
            case 4: return Rez.Drawables.GT4;
            case 5: return Rez.Drawables.GT5;
            case 6: return Rez.Drawables.GT6;
            case 7: return Rez.Drawables.GT7;
            case 8: return Rez.Drawables.GT8;
            case 9: return Rez.Drawables.GT9;
            default: return Rez.Drawables.GTC;
        }
    }

    function bitmap(i as Number) {
        if (_bmps[i] == null) { _bmps[i] = WatchUi.loadResource(resId(i)); }
        return _bmps[i];
    }

    //! Draw `t` centred on cx with its line top at `top` (the terminal's top-aligned convention).
    function draw(dc as Dc, cx as Number, top as Number, font as Graphics.FontType, t as String) as Void {
        var adv = dc.getTextWidthInPixels("0", font);
        var pen = cx - (dc.getTextWidthInPixels(t, font) / 2);
        var chars = t.toCharArray();
        for (var i = 0; i < chars.size(); i++) {
            var c = chars[i];
            var idx = (c == ':') ? 10 : (c.toNumber() - 48);
            if (idx < 0 || idx > 10) { continue; }
            dc.drawBitmap(pen + i * adv + GlowTimeMetrics.X0, top + GlowTimeMetrics.Y0, bitmap(idx));
        }
    }
}
