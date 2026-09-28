import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.WatchUi;

//! A data slot's visual style.
module SlotKind {
    enum {
        CHIP = 0,   // icon over value (Data 01/02/03/06/08)
        RING = 1,   // gradient ring gauge with icon + value inside (Data 04/05)
        DIAL = 2    // Data 07: 60-tick ring - the live seconds, or a picked field's gauge
    }
}

//! One user-editable data field. Draws itself (chip or ring) at a fixed centre using the shared
//! Roboto Mono bitmap fonts, and exposes a bounding box so the view can hit-test taps and the
//! native watch face editor can "pulse" the selected slot. The view feeds it a live icon, value
//! and (for rings) fill fraction as the assigned complication updates.
//!
//! The value auto-fits: it is drawn with the largest of `_valueFonts` (largest -> smallest) that
//! fits `_valueMaxW`, so wide readings shrink instead of overflowing. High/low temperature, and
//! current weather with a feels-like reading, draw stacked (two lines). In always-on (`lowPower`) the ring circle is dropped, leaving
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
    //! DIAL only: true = the live seconds dial (no field picked, or forced by the SecondsAlways
    //! setting); false = gauge the picked field. Set by the view before each draw.
    public var secondsMode as Boolean = true;

    private var _fLabel as Graphics.FontType;
    private var _fIcon as Graphics.FontType?;    // Tabler icon glyph (may be null)
    private var _fStacked as Graphics.FontType;  // compact font for the two stacked temp lines
    private var _valueFonts as Array;            // largest -> smallest, for auto-fit
    private var _valueMaxW as Number;            // width budget for the value
    private var _scx as Number = 0;              // screen centre + radius, for widthAt()
    private var _scy as Number = 0;
    private var _sr as Number = 0;               // 0 = unknown -> fall back to _valueMaxW
    private var _fTicks as Graphics.FontType?;   // DIAL: pre-rasterised 60-tick ring font
    private var _fLabelSmall as Graphics.FontType?;  // DIAL: fallback label font for long labels
    private var _clearR as Number = 0;           // DIAL: black knockout disc radius

    // text offsets, in px (tied to the fixed bitmap-font heights; from the layout editor)
    private const _CHIP_ICON_DY = 28;    // icon lifted above the value
    private const _CHIP_LABEL_DY = 22;   // text label (no-icon fallback) lift
    private const _CHIP_STACK_DY = 12;   // hi/low temp: each line this far from centre (no divider)
    private const _CHIP_STACK_ICON_SHIFT = 8;  // stacked pair under an icon: moved down this far
    private const _RING_ICON_DY = 23;
    private const _RING_VALUE_DY = 10;
    private const _DIAL_LABEL_DY = 24;   // "SEC", above the dial centre
    private const _DIAL_VALUE_DY = 11;   // the seconds, below it
    // A picked field's label and value sit closer to the centre, where the ring is wider: at
    // "SEC"'s row a 5-letter model name ("FABLE") would be clipped to 4 by the ticks.
    private const _DIAL_FIELD_LABEL_DY = 17;
    private const _DIAL_FIELD_VALUE_DY = 13;
    private const _DIAL_INSET = 10;      // text stays this far inside the tick ring's outer radius

    //! @param opts :uid, :kind, :cx, :cy, :ringR, :ringPen, :striped, :horizontal, :fLabel,
    //!             :fIcon, :valueFonts (Array), :fStacked, :valueMaxW, :screen ([cx, cy, r]),
    //!             and for DIAL :fTicks, :fLabelSmall, :clearR
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
        _fTicks = opts.hasKey(:fTicks) ? opts[:fTicks] : null;
        _fLabelSmall = opts.hasKey(:fLabelSmall) ? opts[:fLabelSmall] : null;
        _clearR = opts.hasKey(:clearR) ? opts[:clearR] : 0;
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
        } else if (kind == SlotKind.DIAL) {
            bb.addRectangle(cx - _clearR, cy - _clearR, 2 * _clearR, 2 * _clearR);
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
        if (kind == SlotKind.DIAL) { return dialWidthAt(dc, y, font); }
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

    //! DIAL: width inside the tick ring (radius ringR - _DIAL_INSET) at the text edge farther from
    //! the dial centre - the same round-screen rule as widthAt, applied to the dial's own circle.
    private function dialWidthAt(dc as Dc, y as Numeric, font as Graphics.FontType) as Number {
        var hh = (dc.getFontHeight(font) * 0.32).toNumber();
        var yw = (y < cy) ? (y - hh) : (y + hh);
        var dy = (yw - cy).toFloat();
        var r = (ringR - _DIAL_INSET).toFloat();
        var hw2 = r * r - dy * dy;
        if (hw2 <= 0.0) { return 0; }
        var avail = (2.0 * Math.sqrt(hw2)).toNumber();
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
        // Values: first drop whole words that carry no digit - a unit, a compass direction -
        // rightmost first, so the number itself survives: "SW 19 KM/H" -> "SW 19" -> "19".
        if (!chopNumbers) {
            out = dropWordsWithoutDigits(dc, out, font, maxW);
        }
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

    //! Remove digit-free words (space-separated), rightmost first, until `s` fits `maxW` or only
    //! words with digits are left. The caller's token trimming then handles the rest.
    private function dropWordsWithoutDigits(dc as Dc, s as String, font as Graphics.FontType,
                                            maxW as Number) as String {
        var words = splitSpaces(s);
        var text = joinSpaces(words);
        while (words.size() > 1 && dc.getTextWidthInPixels(text, font) > maxW) {
            var drop = -1;
            for (var i = words.size() - 1; i >= 0; i--) {
                if (!hasDigit(words[i] as String)) { drop = i; break; }
            }
            if (drop < 0) { break; }
            var kept = [] as Array<String>;
            for (var j = 0; j < words.size(); j++) {
                if (j != drop) { kept.add(words[j] as String); }
            }
            words = kept;
            text = joinSpaces(words);
        }
        return text;
    }

    private function splitSpaces(s as String) as Array<String> {
        var words = [] as Array<String>;
        var cur = "";
        var chars = s.toCharArray();
        for (var i = 0; i < chars.size(); i++) {
            if (chars[i] == ' ') {
                if (cur.length() > 0) { words.add(cur); }
                cur = "";
            } else {
                cur += chars[i].toString();
            }
        }
        if (cur.length() > 0) { words.add(cur); }
        return words;
    }

    private function joinSpaces(words as Array<String>) as String {
        var out = "";
        for (var i = 0; i < words.size(); i++) {
            out += (i > 0 ? " " : "") + words[i];
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

    //! Data 07. The black knockout disc goes down first, so the dial cuts cleanly into the minute
    //! digits (the view draws this slot AFTER the time for that reason). Seconds mode is the
    //! original live dial; with a field picked, the same tick ring gauges it and the field's
    //! icon or label and its value sit where "SEC" and the seconds were.
    private function drawDial(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.fillCircle(cx, cy, _clearR);
        if (secondsMode) {
            var sec = System.getClockTime().sec;
            GridDraw.tickRing(dc, cx, cy, ringR, (sec / 60.0) * sweep, _fTicks);
            dc.setColor(labelColor, Graphics.COLOR_TRANSPARENT);
            GridDraw.text(dc, cx, cy - _DIAL_LABEL_DY, _fLabel, "SEC",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.setColor(valueColor, Graphics.COLOR_TRANSPARENT);
            GridDraw.text(dc, cx, cy + _DIAL_VALUE_DY, _valueFonts[0] as Graphics.FontType,
                sec.format("%02d"), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            return;
        }
        GridDraw.tickRing(dc, cx, cy, ringR, frac * sweep, _fTicks);
        if (!iconChar.equals("") && _fIcon != null) {
            drawMarker(dc, cx, cy - _DIAL_FIELD_LABEL_DY);
        } else if (!label.equals("")) {
            // A model name such as "FABLE" is wider than "SEC": drop to the small label font when
            // the 24 px one would reach the ticks, and trim only if even that doesn't fit.
            var y = cy - _DIAL_FIELD_LABEL_DY;
            var f = _fLabel;
            if (_fLabelSmall != null && dc.getTextWidthInPixels(label, f) > widthAt(dc, y, f)) {
                f = _fLabelSmall as Graphics.FontType;
            }
            dc.setColor(labelColor, Graphics.COLOR_TRANSPARENT);
            GridDraw.text(dc, cx, y, f, fitText(dc, label, f, widthAt(dc, y, f), true),
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
        dc.setColor(valueColor, Graphics.COLOR_TRANSPARENT);
        drawValue(dc, cy + _DIAL_FIELD_VALUE_DY, value);
    }

    function draw(dc as Dc) as Void {
        if (!isVisible) { return; }
        if (kind == SlotKind.DIAL) {
            drawDial(dc);
            return;
        }
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
            // Two readings directly on top of each other (Iron Grit look), no divider: hi/low
            // temperature, or current weather's actual over feels-like. Both lines share ONE right
            // edge - the centred block's right side - so the digits and ° signs line up
            // column-for-column even when the widths differ (e.g. "9°" over "-2°"); centring each
            // line separately staggered them.
            // With an icon (current weather) the icon keeps its usual chip position and the pair
            // moves down instead: lifting the icon would push it into the ring slot above.
            var sy = cy;
            if (hasIcon) {
                drawMarker(dc, cx, cy - _CHIP_ICON_DY);
                sy = cy + _CHIP_STACK_ICON_SHIFT;
            }
            dc.setColor(valueColor, Graphics.COLOR_TRANSPARENT);
            var wTop = dc.getTextWidthInPixels(valueTop, _fStacked);
            var wBot = dc.getTextWidthInPixels(valueBot, _fStacked);
            var right = cx + ((wTop > wBot ? wTop : wBot) / 2);
            GridDraw.text(dc, right, sy - _CHIP_STACK_DY, _fStacked, valueTop,
                Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
            GridDraw.text(dc, right, sy + _CHIP_STACK_DY, _fStacked, valueBot,
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
