import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;

//! Shared drawing helpers + the gradient palette for the Claude Grid face. Used by both the
//! view (top battery arc, bottom seconds dial) and the editable ring slots so the gauge look
//! is identical everywhere. Colours mirror the HTML layout editor's Gradient 1 / Gradient 2.
module GridDraw {

    const TRACK = 0x333333;   // ring/arc/tick background: neutral dark grey, so it suits any theme
    const GRAD_A = 0xFF7EDB;  // Gradient 1 (synthwave pink)  - top of the fill   (teal: B4EEDE, Claude: FF9255)
    const GRAD_B = 0xF97E72;  // Gradient 2 (synthwave coral) - end of the fill   (teal: 1EC693, Claude: FF3C3B)

    //! Linear interpolate between two 0xRRGGBB colours.
    function lerp(a as Number, b as Number, t as Float) as Number {
        var ar = (a >> 16) & 0xFF; var ag = (a >> 8) & 0xFF; var ab = a & 0xFF;
        var br = (b >> 16) & 0xFF; var bg = (b >> 8) & 0xFF; var bb = b & 0xFF;
        var r = (ar + ((br - ar) * t)).toNumber();
        var g = (ag + ((bg - ag) * t)).toNumber();
        var bl = (ab + ((bb - ab) * t)).toNumber();
        return (r << 16) | (g << 8) | bl;
    }

    //! Round any Numeric to the nearest whole pixel.
    function px(v as Numeric) as Number {
        return Math.round(v.toFloat()).toNumber();
    }

    //! Pixel-snapped drawText. Resolves the justification ourselves - integer centring against the
    //! measured width, integer VCENTER against the font height - and hands CIQ an integer top-left
    //! with LEFT justification, so no glyph is ever placed on a half pixel. With setAntiAlias(true)
    //! a fractional origin risks the glyph bitmap being resampled across two pixel columns/rows,
    //! which softens every edge.
    //!
    //! `just` takes the usual Graphics.TEXT_JUSTIFY_* flags. RIGHT is 0 in the API, so it is the
    //! fall-through when neither the CENTER nor the LEFT bit is set.
    function text(dc as Dc, x as Numeric, y as Numeric, font as Graphics.FontType, s as String,
                  just as Number) as Void {
        var left = px(x);
        if ((just & Graphics.TEXT_JUSTIFY_CENTER) != 0) {
            left -= dc.getTextWidthInPixels(s, font) / 2;
        } else if ((just & Graphics.TEXT_JUSTIFY_LEFT) == 0) {
            left -= dc.getTextWidthInPixels(s, font);
        }
        var top = px(y);
        if ((just & Graphics.TEXT_JUSTIFY_VCENTER) != 0) {
            top -= dc.getFontHeight(font) / 2;
        }
        dc.drawText(left, top, font, s, Graphics.TEXT_JUSTIFY_LEFT);
    }

    //! Ring gauge: a dim full track, then a gradient arc from the top clockwise for `frac`.
    function gradientRing(dc as Dc, cx as Numeric, cy as Numeric, r as Numeric,
                          penW as Number, frac as Float) as Void {
        dc.setPenWidth(penW);
        dc.setColor(TRACK, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(cx, cy, r);
        var steps = 36;
        var lit = (steps * frac).toNumber();
        for (var i = 0; i < lit; i++) {
            dc.setColor(lerp(GRAD_A, GRAD_B, i.toFloat() / steps), Graphics.COLOR_TRANSPARENT);
            var s = 90.0 - (i * 360.0 / steps);
            var e = 90.0 - ((i + 1) * 360.0 / steps);
            dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE, s, e);
        }
        dc.setPenWidth(1);
    }

    // Tick font geometry - must match tools/build_tick_font.py (HALF, FIRST_CODE; R_OUT = 50).
    const TICK_HALF = 52;        // cell half-size: the dial centre is the cell's pixel corner
    const TICK_FIRST = 0xE100;   // glyph code of tick 0 (12 o'clock), +1 per tick clockwise
    var _tickChars as Array<String>? = null;   // the 60 one-glyph strings, built once

    //! Seconds sub-dial: 60 short radial ticks from the top clockwise, the elapsed ones lit in
    //! the gradient, the rest on the dim track. Matches the editor's tick-ring look.
    //!
    //! With `tickFont` (cg_ticks) every tick is a pre-rasterised, exactly square-ended glyph, and
    //! all 60 share one cell whose corner is the dial centre - so each is drawn from the same
    //! integer origin and none is re-rasterised at a sub-pixel phase (the old drawLine ticks came
    //! out uneven with soft round caps). `r` must be the generator's R_OUT (50) on that path.
    //! The -1 on y offsets CIQ drawing font glyphs one row below their .fnt yoffset (measured).
    function tickRing(dc as Dc, cx as Numeric, cy as Numeric, r as Numeric, frac as Float,
                      tickFont as Graphics.FontType?) as Void {
        var n = 60;
        var lit = (n * frac).toNumber();
        if (tickFont != null) {
            if (_tickChars == null) {
                var arr = new Array<String>[n];
                for (var i = 0; i < n; i++) { arr[i] = (TICK_FIRST + i).toChar().toString(); }
                _tickChars = arr;
            }
            var chars = _tickChars as Array<String>;
            var ox = px(cx) - TICK_HALF;
            var oy = px(cy) - TICK_HALF - 1;
            for (var i = 0; i < n; i++) {
                dc.setColor(i < lit ? lerp(GRAD_A, GRAD_B, i.toFloat() / n) : TRACK,
                    Graphics.COLOR_TRANSPARENT);
                dc.drawText(ox, oy, tickFont, chars[i], Graphics.TEXT_JUSTIFY_LEFT);
            }
            return;
        }
        // Fallback (font missing): the original anti-aliased line ticks.
        var innerLen = 9;
        dc.setPenWidth(2);
        for (var i = 0; i < n; i++) {
            var a = (90.0 - i * 360.0 / n) * Math.PI / 180.0;
            var ca = Math.cos(a);
            var sa = Math.sin(a);
            dc.setColor(i < lit ? lerp(GRAD_A, GRAD_B, i.toFloat() / n) : TRACK,
                Graphics.COLOR_TRANSPARENT);
            dc.drawLine(cx + r * ca, cy - r * sa, cx + (r - innerLen) * ca, cy - (r - innerLen) * sa);
        }
        dc.setPenWidth(1);
    }

    //! Segmented arc between two math-degree angles (the battery indicator across the top bezel).
    //! `penW` is the dash thickness, `dashLen` how far each dash reaches inward from `r`.
    //!
    //! Each dash is a FILLED rectangle (fillPolygon), not a thick drawLine: CIQ renders wide short
    //! lines with rounded/chunky caps, which read as blobs at this size. Building the quad from the
    //! radial and its perpendicular keeps every dash a crisp rectangle at any angle.
    //!
    //! With `arcFont` (cg_arc, tools/build_arc_font.py) on a 454 px screen, each dash is instead a
    //! pre-rasterised glyph drawn at its generated screen position (ArcMetrics): exact, identical coverage for all 16
    //! (the polygons land on the pixel grid at different sub-pixel phases and look uneven/soft).
    //! The glyph geometry is fixed (R 224, 122.5 -> 57.5 deg, 16 dashes, 10 x 15), matching the
    //! only call site; -1 on y cancels CIQ drawing font glyphs one row low (measured).
    const ARC_FIRST = 0xE140;
    var _arcChars as Array<String>? = null;

    function segmentArc(dc as Dc, cx as Numeric, cy as Numeric, r as Numeric,
                        startDeg as Float, endDeg as Float, n as Number, frac as Float,
                        penW as Number, dashLen as Number, arcFont as Graphics.FontType?) as Void {
        var lit = (n * frac).toNumber();
        if (arcFont != null && dc.getWidth() == 454 && n == 16) {
            if (_arcChars == null) {
                var arr = new Array<String>[n];
                for (var i = 0; i < n; i++) { arr[i] = (ARC_FIRST + i).toChar().toString(); }
                _arcChars = arr;
            }
            var chars = _arcChars as Array<String>;
            for (var i = 0; i < n; i++) {
                dc.setColor(i < lit ? lerp(GRAD_A, GRAD_B, i.toFloat() / n) : TRACK,
                    Graphics.COLOR_TRANSPARENT);
                dc.drawText(ArcMetrics.X[i], ArcMetrics.Y[i] - 1, arcFont, chars[i], Graphics.TEXT_JUSTIFY_LEFT);
            }
            return;
        }
        var hw = penW / 2.0;
        for (var i = 0; i < n; i++) {
            var a = (startDeg + (endDeg - startDeg) * i / (n - 1)) * Math.PI / 180.0;
            var ca = Math.cos(a);
            var sa = Math.sin(a);
            // outer (r) and inner (r-dashLen) points on this radial; y is screen-down (cy - r*sa)
            var ox = cx + r * ca;              var oy = cy - r * sa;
            var ix = cx + (r - dashLen) * ca;  var iy = cy - (r - dashLen) * sa;
            // unit perpendicular to the radial, scaled to half the dash width
            var qx = sa * hw;                  var qy = ca * hw;
            dc.setColor(i < lit ? lerp(GRAD_A, GRAD_B, i.toFloat() / n) : TRACK,
                Graphics.COLOR_TRANSPARENT);
            dc.fillPolygon([
                [ox + qx, oy + qy],
                [ox - qx, oy - qy],
                [ix - qx, iy - qy],
                [ix + qx, iy + qy]
            ]);
        }
    }
}
