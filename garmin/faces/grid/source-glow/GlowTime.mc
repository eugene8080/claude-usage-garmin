import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! Bitmap time digits (option 4): the hour and minute drawn from pre-rendered RGBA images with the
//! glow, gradient and bevel baked in (tools/build_glow_digits.py), instead of from the cg_time font.
//!
//! Only compiled into the glow variants: this folder (source-glow/) and one resources-glow*/
//! folder are added to the jungle paths by tools/build_sharpness_variants.py, and the view's
//! `(:glow_time)` drawGlowTime() is the only caller. The normal Claude Grid build excludes both.
//!
//! Placement reuses the cg_time font's own metrics at runtime (digit advance, string width, line
//! height) - exactly what drawText/GridDraw.text use - so each bitmap lands where the font glyph
//! would, offset by the constant cell origin GlowTimeMetrics.X0/Y0.
module GlowTime {

    // Loaded on first use and kept: with enhanced graphics these are BitmapReferences living in
    // the graphics pool (not the 128 KB watch-face heap), and the pool reloads them if it evicts.
    // Index 0-9 = hour digit, 10-19 = minute digit.
    var _bmps as Array = new [20];

    //! Resource id for a digit. A switch rather than a stored Array of ids: Rez ids are
    //! compile-time symbols, and this keeps no extra array in the heap.
    function resId(idx as Number) as ResourceId {
        switch (idx) {
            case 0:  return Rez.Drawables.GH0;
            case 1:  return Rez.Drawables.GH1;
            case 2:  return Rez.Drawables.GH2;
            case 3:  return Rez.Drawables.GH3;
            case 4:  return Rez.Drawables.GH4;
            case 5:  return Rez.Drawables.GH5;
            case 6:  return Rez.Drawables.GH6;
            case 7:  return Rez.Drawables.GH7;
            case 8:  return Rez.Drawables.GH8;
            case 9:  return Rez.Drawables.GH9;
            case 10: return Rez.Drawables.GM0;
            case 11: return Rez.Drawables.GM1;
            case 12: return Rez.Drawables.GM2;
            case 13: return Rez.Drawables.GM3;
            case 14: return Rez.Drawables.GM4;
            case 15: return Rez.Drawables.GM5;
            case 16: return Rez.Drawables.GM6;
            case 17: return Rez.Drawables.GM7;
            case 18: return Rez.Drawables.GM8;
            default: return Rez.Drawables.GM9;
        }
    }

    function bitmap(idx as Number) {
        if (_bmps[idx] == null) {
            _bmps[idx] = WatchUi.loadResource(resId(idx));
        }
        return _bmps[idx];
    }

    //! Draw one stacked row of digits (`text` is "00".."59") centred on tx, VCENTERed on yc.
    //! `base` selects the image set: 0 = hour, 10 = minute.
    function drawRow(dc as Dc, tx as Number, yc as Number, font as Graphics.FontType,
                     text as String, base as Number) as Void {
        var adv = dc.getTextWidthInPixels("0", font);
        var pen = tx - (dc.getTextWidthInPixels(text, font) / 2);
        var top = yc - (dc.getFontHeight(font) / 2);
        var chars = text.toCharArray();
        for (var i = 0; i < chars.size(); i++) {
            var d = chars[i].toNumber() - 48;   // '0' is code point 48
            if (d < 0 || d > 9) { continue; }   // defensive: never index outside the set
            dc.drawBitmap(pen + i * adv + GlowTimeMetrics.X0, top + GlowTimeMetrics.Y0,
                bitmap(base + d));
        }
    }
}
