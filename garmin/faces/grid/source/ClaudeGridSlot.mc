import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.WatchUi;

//! A data slot's visual style.
module SlotKind {
    enum {
        CHIP = 0,   // icon over value (Data 01/02/03/06)
        RING = 1    // gradient ring gauge with icon + value inside (Data 04/05)
    }
}

//! One user-editable data field. Draws itself (chip or ring) at a fixed centre using the shared
//! Roboto Mono bitmap fonts, and exposes a bounding box so the view can hit-test taps and the
//! native watch face editor can "pulse" the selected slot. The view feeds it a live icon, value
//! and (for rings) fill fraction as the assigned complication updates.
//!
//! The value auto-fits: it is drawn with the largest of `_valueFonts` (largest -> smallest) that
//! fits `_valueMaxW`, so wide readings shrink instead of overflowing. High/low temperature draws
//! stacked (two lines + divider). In always-on (`lowPower`) the ring circle is dropped, leaving
//! just the icon + value inside, matching the editor's low-power preview.
class ClaudeGridSlot extends WatchUi.Drawable {

    public var uid as Number;
    public var kind as Number;
    public var cx as Number;
    public var cy as Number;
    public var ringR as Number;
    public var ringPen as Number;
    public var striped as Boolean;
    public var horizontal as Boolean = false;  // battery: icon beside the value on one row
    public var lowPower as Boolean = false;     // always-on: drop the ring circle

    public var label as String = "";
    public var value as String = "--";     // single-line reading
    public var valueTop as String = "";    // stacked (hi/low temp): top line
    public var valueBot as String = "";    // stacked: bottom line
    public var iconChar as String = "";    // icon glyph for the assigned complication ("" = none)
    public var frac as Float = 0.0;
    public var sweep as Float = 1.0;       // 0..1 wake-in fill multiplier (rings only)
    public var valueColor as Number = 0xFF9C75;
    public var labelColor as Number = 0x9A9A9A;
    //! When set, a chip value always uses this font instead of auto-fitting (Data 08's time-zone
    //! clock keeps the 30px font it had as a fixed field, even though "HH:MM" is a hair wider
    //! than the slot's bezel budget).
    public var forceFont as Graphics.FontType? = null;

    private var _fLabel as Graphics.FontType;
    private var _fIcon as Graphics.FontType?;    // Tabler icon glyph (may be null)
    private var _fStacked as Graphics.FontType;  // compact font for the two stacked temp lines
    private var _valueFonts as Array;            // largest -> smallest, for auto-fit
    private var _valueMaxW as Number;            // width budget for the value
    private var _scx as Number = 0;              // screen centre + radius, for widthAt()
    private var _scy as Number = 0;
    private var _sr as Number = 0;               // 0 = unknown -> fall back to _valueMaxW

    // text offsets, in px (tied to the fixed bitmap-font heights; from the layout editor)
    private const _CHIP_ICON_DY = 28;    // icon lifted above the value
    private const _CHIP_LABEL_DY = 22;   // text label (no-icon fallback) lift
    private const _CHIP_STACK_DY = 12;   // hi/low temp: each line this far from centre (no divider)
    private const _RING_ICON_DY = 23;
    private const _RING_VALUE_DY = 10;

    //! @param opts :uid, :kind, :cx, :cy, :ringR, :ringPen, :striped, :horizontal, :fLabel,
    //!             :fIcon, :valueFonts (Array), :fStacked, :valueMaxW, :screen ([cx, cy, r])
    function initialize(opts as Dictionary) {
        Drawable.initialize({ :identifier => opts[:uid] });
        uid = opts[:uid];
        kind = opts[:kind];
        cx = opts[:cx];
        cy = opts[:cy];
        ringR = opts.hasKey(:ringR) ? opts[:ringR] : 0;
        ringPen = opts.hasKey(:ringPen) ? opts[:ringPen] : 6;
        striped = opts.hasKey(:striped) ? opts[:striped] : false;
        horizontal = opts.hasKey(:horizontal) ? opts[:horizontal] : false;
        _fLabel = opts[:fLabel];
        _fIcon = opts[:fIcon];
        _valueFonts = opts[:valueFonts];
        _fStacked = opts[:fStacked];
        _valueMaxW = opts[:valueMaxW];
        if (opts.hasKey(:screen)) {
            var sc = opts[:screen] as Array<Number>;
            _scx = sc[0];
            _scy = sc[1];
            _sr = sc[2];
        }
    }

    //! Bounding box for tap hit-testing and the editor pulse animation.
    function getBoundingBox() as Graphics.BoundingBox {
        var bb = new Graphics.BoundingBox();
        if (kind == SlotKind.RING) {
            var r = ringR + ringPen + 2;
            bb.addRectangle(cx - r, cy - r, 2 * r, 2 * r);
        } else {
            var halfW = 52;
            bb.addRectangle(cx - halfW, cy - 36, 2 * halfW, 66);
        }
        return bb;
    }

    function containsPoint(x as Number, y as Number) as Boolean {
        return getBoundingBox().includesPoint(x, y);
    }

    //! Width (px) a line of `font` text centred on this slot's cx can use at screen row `y`
    //! without crossing the round bezel (8 px margin), capped by the slot's own budget.
    //!
    //! The screen narrows with distance from its centre row, so the binding row is the text's
    //! edge FARTHEST from centre: the top of the text for upper slots, the bottom for lower ones.
    //! (The old single budget was measured at the slot's centre line, so a label lifted 22 px
    //! above it - where the circle is narrower - could still run off the edge.)
    private function widthAt(dc as Dc, y as Numeric, font as Graphics.FontType) as Number {
        if (_sr <= 0 || kind == SlotKind.RING) { return _valueMaxW; }  // rings: interior budget
        var hh = (dc.getFontHeight(font) * 0.32).toNumber();         // ~half the cap height
        var yw = (y < _scy) ? (y - hh) : (y + hh);
        var dy = (yw - _scy).toFloat();
        var hw2 = (_sr * _sr).toFloat() - dy * dy;
        if (hw2 <= 0.0) { return 0; }
        var off = cx - _scx;
        if (off < 0) { off = -off; }
        var avail = (2.0 * (Math.sqrt(hw2) - off - 8.0)).toNumber();
        return (avail < _valueMaxW) ? avail : _valueMaxW;
    }

    //! Largest value font whose rendering of `text` fits at row `y`; the smallest otherwise (the
    //! caller then shortens the text with fitText).
    private function pickFont(dc as Dc, text as String, y as Numeric) as Graphics.FontType {
        for (var i = 0; i < _valueFonts.size(); i++) {
            var f = _valueFonts[i] as Graphics.FontType;
            if (dc.getTextWidthInPixels(text, f) <= widthAt(dc, y, f)) {
                return f;
            }
        }
        return _valueFonts[_valueFonts.size() - 1] as Graphics.FontType;
    }

    //! Shorten `s` until it fits `maxW` px: whole trailing TOKENS first, then characters. A token
    //! starts at a space, or at a +/- sign that follows a digit/space ("227.52 +0.45%" ->
    //! "227.52", "227.52+0.45%" -> "227.52"), so a quote keeps its price and a long label keeps
    //! its leading words ("1-DAY FORECAST" -> "1-DAY"). Returns "" if not one character fits.
    //!
    //! `chopNumbers` false (values): once only one token is left, text containing a digit is NEVER
    //! cut character by character - "227.52" -> "227.5" silently changes the number, so it is
    //! better to let it run a few px into the 8 px bezel margin.
    private function fitText(dc as Dc, s as String, font as Graphics.FontType, maxW as Number,
                             chopNumbers as Boolean) as String {
        var out = s;
        while (out.length() > 0 && dc.getTextWidthInPixels(out, font) > maxW) {
            var chars = out.toCharArray();
            var cut = null;
            for (var i = chars.size() - 1; i > 0; i--) {
                var ch = chars[i];
                var prev = chars[i - 1];
                if (ch == ' ') { cut = i; break; }
                if ((ch == '+' || ch == '-') && ((prev >= '0' && prev <= '9') || prev == ' ')) {
                    cut = i; break;
                }
            }
            if (cut == null && !chopNumbers && hasDigit(out)) { break; }
            var shorter = (cut != null) ? out.substring(0, cut) : out.substring(0, out.length() - 1);
            out = (shorter != null) ? noTrailingSpace(shorter) : "";
        }
        return out;
    }

    private function hasDigit(s as String) as Boolean {
        var chars = s.toCharArray();
        for (var i = 0; i < chars.size(); i++) {
            if (chars[i] >= '0' && chars[i] <= '9') { return true; }
        }
        return false;
    }

    private function noTrailingSpace(s as String) as String {
        var out = s;
        while (out.length() > 0 && out.substring(out.length() - 1, out.length()).equals(" ")) {
            var t = out.substring(0, out.length() - 1);
            out = (t != null) ? t : "";
        }
        return out;
    }

    //! Draw `value` centred at (cx, y), in the largest font that fits that row, shortened if even
    //! the smallest doesn't.
    private function drawValue(dc as Dc, y as Numeric, text as String) as Void {
        var f = pickFont(dc, text, y);
        GridDraw.text(dc, cx, y, f, fitText(dc, text, f, widthAt(dc, y, f), false),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! Draw the field marker (icon if we have one + the icon font, else the text label, fitted to
    //! the slot's width budget).
    private function drawMarker(dc as Dc, x as Numeric, y as Numeric) as Void {
        dc.setColor(labelColor, Graphics.COLOR_TRANSPARENT);
        if (!iconChar.equals("") && _fIcon != null) {
            GridDraw.text(dc, x, y, _fIcon, iconChar,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        } else if (!label.equals("")) {
            GridDraw.text(dc, x, y, _fLabel, fitText(dc, label, _fLabel, widthAt(dc, y, _fLabel), true),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    function draw(dc as Dc) as Void {
        if (!isVisible) { return; }
        var hasIcon = (!iconChar.equals("") && _fIcon != null);
        var stacked = !valueTop.equals("");

        if (kind == SlotKind.RING) {
            if (!lowPower) {
                GridDraw.gradientRing(dc, cx, cy, ringR, ringPen, frac * sweep);
            }
            drawMarker(dc, cx, cy - _RING_ICON_DY);
            dc.setColor(valueColor, Graphics.COLOR_TRANSPARENT);
            drawValue(dc, cy + _RING_VALUE_DY, value);
        } else if (horizontal) {
            // Battery-style: an icon - or the text LABEL when the complication has no icon (the
            // Claude usage meters are icon-less, so this is what shows "FABLE" beside "55%") -
            // beside the value on one row, the pair centred on cx.
            var vf = pickFont(dc, value, cy);
            var rowW = widthAt(dc, cy, vf);
            var val = fitText(dc, value, vf, rowW, false);
            var vw = dc.getTextWidthInPixels(val, vf);
            var mFont = hasIcon ? _fIcon : _fLabel;
            var marker = hasIcon ? iconChar : label;
            if (!hasIcon && !marker.equals("")) {
                // The label gets whatever width the value leaves; it's dropped if that's < 2 chars.
                marker = fitText(dc, marker, _fLabel, rowW - vw - 7, true);
                if (marker.length() < 2) { marker = ""; }
            }
            var mw = marker.equals("") ? 0 : dc.getTextWidthInPixels(marker, mFont);
            var gap = (mw > 0) ? 7 : 0;
            var sx = cx - (mw + gap + vw) / 2;
            if (mw > 0) {
                dc.setColor(labelColor, Graphics.COLOR_TRANSPARENT);
                GridDraw.text(dc, sx, cy, mFont, marker,
                    Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
            }
            dc.setColor(valueColor, Graphics.COLOR_TRANSPARENT);
            GridDraw.text(dc, sx + mw + gap, cy, vf, val,
                Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        } else if (stacked) {
            // hi/low temperature: the two readings directly on top of each other (Iron Grit look),
            // no divider. Both lines share ONE right edge - the centred block's right side - so
            // the digits and ° signs line up column-for-column even when the widths differ
            // (e.g. "9°" over "-2°"); centring each line separately staggered them.
            if (hasIcon) { drawMarker(dc, cx, cy - _CHIP_ICON_DY - 6); }
            dc.setColor(valueColor, Graphics.COLOR_TRANSPARENT);
            var wTop = dc.getTextWidthInPixels(valueTop, _fStacked);
            var wBot = dc.getTextWidthInPixels(valueBot, _fStacked);
            var right = cx + ((wTop > wBot ? wTop : wBot) / 2);
            GridDraw.text(dc, right, cy - _CHIP_STACK_DY, _fStacked, valueTop,
                Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
            GridDraw.text(dc, right, cy + _CHIP_STACK_DY, _fStacked, valueBot,
                Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        } else {
            drawMarker(dc, cx, cy - (hasIcon ? _CHIP_ICON_DY : _CHIP_LABEL_DY));
            dc.setColor(valueColor, Graphics.COLOR_TRANSPARENT);
            if (forceFont != null) {
                GridDraw.text(dc, cx, cy, forceFont as Graphics.FontType, value,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            } else {
                drawValue(dc, cy, value);
            }
        }
    }
}
