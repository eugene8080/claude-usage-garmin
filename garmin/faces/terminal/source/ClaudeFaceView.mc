import Toybox.Application;
import Toybox.Complications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.Weather;
import Toybox.WatchUi;

//! The Claude terminal watch face.
//!
//! Layout comes straight from the HTML layout editor: a prompt line, the big time, the date, then
//! three CLI-style rows (5H / 1W / model) each with a bar, percentage and reset time, a segmented
//! battery bar, and a blinking cursor. Night Owl colours on black, in IBM Plex Mono. In always-on
//! the time drops to a thin outline HH:MM and the grey tracks go; the mesh / scanlines stay (see _lowPower).
//!
//! The values come from the published complications. We can't construct a custom complication's Id
//! directly (its identity is an internal UUID), so onShow ENUMERATES the available complications,
//! keeps the ones whose label marks them as ours, subscribes, and caches value + reset epoch;
//! onComplicationChange refreshes the cache. The reset time is carried in the complication's `unit`
//! field as raw epoch-seconds and formatted here.
//!
//! Touch-and-hold on a meter row or the weather line launches the app behind it
//! (launchComplicationAt, called from ClaudeFaceDelegate.onPress).
class ClaudeFaceView extends WatchUi.WatchFace {

    // Colour theme (the "Theme" setting; see applyTheme). Night Owl by default. The VFD time's
    // face + glow colours are baked into a digit set per theme by tools/build_glow_time.py, so
    // VALUE and ACCENT here must stay in step with its THEMES table.
    private var ACCENT as Number = 0x82AAFF;      // prompt, bar fill, cursor, weather icon
    private var VALUE as Number = 0xD6DEEB;       // time + percentage + temperature
    private var TRACK as Number = 0x333333;       // empty bar background
    private var DIM as Number = 0x7F9C9C;         // date, labels, reset times
    private var NEAR_CAP as Number = 0xEF5350;    // bar fill at 80%+
    private var BG as Number = 0x000000;          // high-power background (always-on is black)
    private const DEFAULT_PROMPT = "fenix@tactix ~ $";
    private const THEME_RETRO = 1;

    // --- layout (fractions of the screen), from the editor ---
    // Prompt, time and date are centred on their x; every line is top-aligned at its y.
    private const PROMPT_X = 0.434;  private const PROMPT_Y = 0.187;
    private const TIME_X = 0.500;    private const TIME_Y = 0.234;
    private const DATE_X = 0.313;    private const DATE_Y = 0.423;
    private const ROWS_Y = 0.508;    private const ROWS_GAP = 0.113;
    private const LABEL_X = 0.148;   private const BAR_X = 0.242;   private const BAR_W = 0.287;
    private const BAR_H = 0.030;     private const BAR_DY = 0.018;
    private const PCT_X = 0.639;     private const RESET_X = 0.858;
    // The editor parks the cursor at y=2.0, below the screen: it is not shown. Kept (not deleted)
    // so moving it back on-screen in the editor is a one-constant change.
    private const CURSOR_X = 0.526;  private const CURSOR_Y = 2.000;
    private const CURSOR_W = 0.030;  private const CURSOR_H = 0.028;
    // Battery bar: the straight counterpart of Claude Grid's top battery arc, at the same scale
    // (16 segments of 10 x 15 px, 5 px apart on the 454 px screen = 235 px long). Centred on
    // BATT_X, top at BATT_Y, just below the meter rows. Sizes are fractions of the WIDTH, like
    // the meter bars, so the bar keeps its proportions on every screen size.
    // BATT_Y puts the bar the same 37 px below the last Claude bar as the Claude bars are apart
    // (bars at y 239 / 290 / 341, 14 px tall -> battery top 392; was 0.845 = 384, a 29 px gap).
    private const BATT_X = 0.500;    private const BATT_Y = 0.863;
    private const BATT_SEGS = 16;
    private const BATT_SEG_W = 0.022; private const BATT_GAP = 0.011; private const BATT_H = 0.033;
    private const BATT_LOW = 20;     // at or below this %, the lit segments turn NEAR_CAP red
    // Always-on meter bars are hollow, with the same 2 px stroke as the outline time.
    private const AOD_STROKE = 2;
    // Weather line (icon + current temperature), centred on WX_X, top at WX_Y - above the prompt,
    // like Rad Lad's top line.
    private const WX_X = 0.500;      private const WX_Y = 0.095;
    private const WX_GAP = 6;        // px between the icon and the temperature
    private const WX_FL = "FL";      // marks the feels-like reading after the temperature
    // Hold-to-launch hit bands, in px around the drawn text. Rows are top-aligned at their y, so a
    // row's band runs from just above its text to just above the next row: the three bands tile
    // the meter block without gaps and without reaching the date above or the battery bar below.
    private const HOLD_PAD = 4;      // band starts this far above a line's top
    private const WX_HOLD_H = 36;    // weather line band height (the 25 px text's line box + pad)

    // One cache slot per meter. pct is -1 until a value arrives; resetEpoch 0 means none.
    private var _labels as Array<String> = ["5H", "1W", "--"];
    private var _pcts as Array<Number> = [-1, -1, -1];
    private var _resets as Array<Number> = [0, 0, 0];
    private var _ids as Array<Complications.Id?> = [null, null, null];
    private var _subscribed as Boolean = false;
    private var _showSeconds as Boolean = true;
    private var _prompt as String = DEFAULT_PROMPT;   // PromptText setting (Garmin Connect / editor)
    private var _theme as Number = 1;                 // Theme setting: 0 Night Owl, 1 Retro tube (default)
    private var _scanlines as Boolean = true;         // Scanlines setting: CRT lines instead of mesh (default on)
    private var _fontIcon as Graphics.FontType?;      // weather icons (stm_icon, from Claude Grid)
    // Halo twins of the prompt / date+rows / icon fonts (Retro tube: everything glows).
    private var _glowText as Graphics.FontType?;
    private var _glowSmall as Graphics.FontType?;
    private var _glowIcon as Graphics.FontType?;
    private var _ink as Number = 0xFFFFFF;           // current text colour (see ink())
    // Halo colour = the text colour blended this far from the background: the halo font's full-
    // coverage core then shows at 50 %, its 2/3 and 1/3 steps at ~33 % and ~17 % (CIQ's 4 levels).
    private const GLOW_MIX = 0.5;

    // IBM Plex Mono, loaded from resources - the terminal typeface for every element, at the
    // editor's sizes: prompt 26px, date + rows 25px, time 70px.
    private var _fontText as Graphics.FontType?;
    private var _fontSmall as Graphics.FontType?;
    private var _fontTime as Graphics.FontType?;
    private var _fontTimeO as Graphics.FontType?;   // 2 px hollow outline time - always-on

    // Always-on (low power), the same scheme as Claude Grid: onEnterSleep / onExitSleep flip it.
    // The AMOLED burn-in budget wants few, thin lit pixels, so while it is set the face draws
    // the time as HH:MM in the hollow outline font (no glow bitmaps, no seconds, no per-second
    // repaint) left where the high-power HH:MM sits, keeps the mesh / scanlines, drops every grey
    // track (meter bar backgrounds, unlit battery segments), draws the meter bars' filled part as
    // a 2 px hollow outline, and keeps the text and the lit battery segments.
    private var _lowPower as Boolean = false;

    public function initialize() {
        WatchFace.initialize();
    }

    public function onLayout(dc as Dc) as Void {
        _fontText = WatchUi.loadResource(Rez.Fonts.STMono) as Graphics.FontType;
        _fontSmall = WatchUi.loadResource(Rez.Fonts.STMonoSmall) as Graphics.FontType;
        _fontTime = WatchUi.loadResource(Rez.Fonts.STMonoTime) as Graphics.FontType;
        _fontTimeO = WatchUi.loadResource(Rez.Fonts.STMonoTimeOutline) as Graphics.FontType;
        _fontIcon = WatchUi.loadResource(Rez.Fonts.STIcon) as Graphics.FontType;
        _glowText = WatchUi.loadResource(Rez.Fonts.STMonoGlow) as Graphics.FontType;
        _glowSmall = WatchUi.loadResource(Rez.Fonts.STMonoSmallGlow) as Graphics.FontType;
        _glowIcon = WatchUi.loadResource(Rez.Fonts.STIconGlow) as Graphics.FontType;
    }

    //! The prompt font (26px), falling back to the system font if the resource ever fails.
    private function ft() as Graphics.FontType {
        return (_fontText != null) ? _fontText : Graphics.FONT_TINY;
    }

    //! The date + meter-row font (25px), same fallback.
    private function fs() as Graphics.FontType {
        return (_fontSmall != null) ? _fontSmall : Graphics.FONT_TINY;
    }

    public function onShow() as Void {
        _lowPower = false;
        readSettings();
        if (!(Toybox has :Complications)) {
            return;
        }
        try {
            findAndSubscribe();
        } catch (e) {
            System.println("complication subscribe failed: " + e.getErrorMessage());
        }
    }

    //! Show seconds, prompt text, colour theme and scanlines, from the watch/app settings.
    public function readSettings() as Void {
        var v = Application.Properties.getValue("ShowSeconds");
        _showSeconds = (v instanceof Boolean) ? v : true;
        var p = Application.Properties.getValue("PromptText");
        _prompt = (p instanceof String) ? p as String : DEFAULT_PROMPT;
        var t = Application.Properties.getValue("Theme");
        _theme = (t instanceof Number) ? t : THEME_RETRO;
        var s = Application.Properties.getValue("Scanlines");
        _scanlines = (s instanceof Boolean) ? s : true;
        applyTheme(_theme);
    }

    //! Set the palette for a theme (layout editor values) and switch the glow digit set to match.
    //! Retro tube (the default): green phosphor on a near-black green background; 80 %+ bars in
    //! the brightest pure green (#11FF00), so a near-cap meter flares rather than changing hue -
    //! a monochrome tube has no red (the editor design, 2026-09-25; was amber).
    private function applyTheme(theme as Number) as Void {
        if (theme == THEME_RETRO) {
            ACCENT = 0x2BDC63; VALUE = 0x66FF8F; DIM = 0x1E9A48;
            TRACK = 0x0C3318; NEAR_CAP = 0x11FF00; BG = 0x020F06;
        } else {
            ACCENT = 0x82AAFF; VALUE = 0xD6DEEB; DIM = 0x7F9C9C;
            TRACK = 0x333333; NEAR_CAP = 0xEF5350; BG = 0x000000;
        }
        setGlowTheme(theme);
    }

    (:glow_time)
    private function setGlowTheme(theme as Number) as Void {
        GlowTime.setTheme(theme);
    }

    (:font_time)
    private function setGlowTheme(theme as Number) as Void {
    }

    //! The background for the current mode: the theme's in high power, always black in always-on
    //! (AMOLED: an unlit pixel costs nothing and can't burn in).
    private function bg() as Number {
        return _lowPower ? Graphics.COLOR_BLACK : BG;
    }

    // ---- whole-pixel drawing -----------------------------------------------------------------
    // Every position here is a fraction of the screen, i.e. a Float. With anti-aliasing on, a
    // fractional origin risks a glyph or bar edge being spread across two pixel rows/columns
    // (soft text, blurry bar ends). These helpers resolve everything to integer pixels first.

    private function px(v as Numeric) as Number {
        return Math.round(v.toFloat()).toNumber();
    }

    //! Pixel-snapped drawText with top-aligned text (the terminal's convention): the
    //! justification is resolved to an integer left edge against the measured width.
    private function text(dc as Dc, x as Numeric, y as Numeric, font as Graphics.FontType,
                          s as String, just as Number) as Void {
        var left = px(x);
        if (just == Graphics.TEXT_JUSTIFY_CENTER) {
            left -= dc.getTextWidthInPixels(s, font) / 2;
        } else if (just == Graphics.TEXT_JUSTIFY_RIGHT) {
            left -= dc.getTextWidthInPixels(s, font);
        }
        glowText(dc, left, px(y), font, s);
        dc.drawText(left, px(y), font, s, Graphics.TEXT_JUSTIFY_LEFT);
    }

    // ---- tube glow (Retro tube theme) ----------------------------------------------------------
    // Everything lit glows, like a phosphor tube. CIQ can't blur, so text gets a pre-rendered halo
    // font drawn first in the same colour (its glyphs sit exactly under the sharp ones), and the
    // lit bars / battery segments get a two-step halo of rectangles blended from the background
    // towards their colour. High power only: always-on stays thin and unlit.

    private function glowOn() as Boolean {
        return _theme == THEME_RETRO && !_lowPower;
    }

    //! The halo font matching `font`, or null when there is none (the time uses glow bitmaps).
    private function glowFontFor(font as Graphics.FontType) as Graphics.FontType? {
        if (font == _fontText) { return _glowText; }
        if (font == _fontSmall) { return _glowSmall; }
        if (font == _fontIcon) { return _glowIcon; }
        return null;
    }

    //! Draw `s`'s halo at (left, top) in the current colour, when the tube glow is on.
    private function glowText(dc as Dc, left as Number, top as Number, font as Graphics.FontType,
                              s as String) as Void {
        if (!glowOn()) { return; }
        var g = glowFontFor(font);
        if (g != null) {
            dc.setColor(mix(BG, _ink, GLOW_MIX), Graphics.COLOR_TRANSPARENT);
            dc.drawText(left, top, g as Graphics.FontType, s, Graphics.TEXT_JUSTIFY_LEFT);
            dc.setColor(_ink, Graphics.COLOR_TRANSPARENT);
        }
    }

    //! Set the text colour and remember it, so glowText can draw the halo in a blend of it.
    private function ink(dc as Dc, color as Number) as Void {
        _ink = color;
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
    }

    //! Soft halo behind a lit rectangle: +4 px at 14 % and +2 px at 30 % of the way from the
    //! background to `color`. Pre-blended solid colours rather than alpha, so it looks the same on
    //! every device and costs two fills.
    private function haloRect(dc as Dc, x as Number, y as Number, w as Number, h as Number,
                              color as Number) as Void {
        if (!glowOn() || w <= 0 || h <= 0) { return; }
        dc.setColor(mix(BG, color, 0.14), Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x - 4, y - 4, w + 8, h + 8);
        dc.setColor(mix(BG, color, 0.30), Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x - 2, y - 2, w + 4, h + 4);
    }

    //! Linear blend of two 0xRRGGBB colours, t = 0 -> a, 1 -> b.
    private function mix(a as Number, b as Number, t as Float) as Number {
        var r = ((a >> 16) & 0xFF) + ((((b >> 16) & 0xFF) - ((a >> 16) & 0xFF)) * t);
        var g = ((a >> 8) & 0xFF) + ((((b >> 8) & 0xFF) - ((a >> 8) & 0xFF)) * t);
        var bl = (a & 0xFF) + (((b & 0xFF) - (a & 0xFF)) * t);
        return (r.toNumber() << 16) | (g.toNumber() << 8) | bl.toNumber();
    }

    //! Pixel-snapped filled rectangle: integer edges, so bar ends are hard.
    private function rect(dc as Dc, x as Numeric, y as Numeric, w as Numeric, h as Numeric) as Void {
        var x0 = px(x);
        var y0 = px(y);
        dc.fillRectangle(x0, y0, px(x + w) - x0, px(y + h) - y0);
    }

    private function findAndSubscribe() as Void {
        var iter = Complications.getComplications();
        var comp = iter.next();
        while (comp != null) {
            var long = comp.longLabel;
            if (long != null && (long as String).find("Claude") != null) {
                var slot = slotFor(long as String);
                if (slot >= 0) {
                    _ids[slot] = comp.complicationId;
                    cache(slot, comp);
                    Complications.subscribeToUpdates(comp.complicationId);
                }
            }
            comp = iter.next();
        }
        Complications.registerComplicationChangeCallback(method(:onComplicationChange));
        _subscribed = true;
    }

    //! Which row a Claude meter goes on, from words in its longLabel (the watch app's
    //! strings.xml). This matching is part of garmin/CONTRACT.md; garmin/tools/check_contract.py
    //! mirrors it (terminal_row) and fails CI if these literals or the labels drift apart.
    private function slotFor(longLabel as String) as Number {
        if (longLabel.find("5-hour") != null) { return 0; }
        if (longLabel.find("weekly") != null && longLabel.find("model") == null) { return 1; }
        if (longLabel.find("model") != null) { return 2; }
        return -1;
    }

    public function onComplicationChange(id as Complications.Id) as Void {
        for (var i = 0; i < 3; i++) {
            if (_ids[i] != null && (_ids[i] as Complications.Id).equals(id)) {
                cache(i, Complications.getComplication(id));
                WatchUi.requestUpdate();
                return;
            }
        }
    }

    private function cache(slot as Number, comp as Complications.Complication or Null) as Void {
        if (comp == null) {
            return;
        }
        var v = comp.value;
        _pcts[slot] = (v instanceof Number) ? v : -1;
        var sl = comp.shortLabel;
        if (sl != null) {
            // Keep labels to 2 chars, uppercased, so a long model name ("Fable") shows as "FA"
            // and never overruns into the bar. "5H"/"1W" are unchanged.
            var s = sl as String;
            if (s.length() > 2) {
                var sub = s.substring(0, 2);
                if (sub != null) { s = sub; }
            }
            _labels[slot] = s.toUpper();
        }
        // The reset epoch rides in `unit` as a numeric string.
        _resets[slot] = parseEpoch(comp.unit);
    }

    private function parseEpoch(unit as Object or Null) as Number {
        if (unit instanceof String) {
            var n = (unit as String).toNumber();
            if (n != null) { return n; }
        }
        return 0;
    }

    //! Touch-and-hold (ClaudeFaceDelegate.onPress): exit to the app behind the line under (x, y).
    //! A meter row opens the app that publishes its complication (the Claude Usage app); the
    //! weather line opens the watch's weather app through the native current-weather complication.
    //! Returns false, leaving the hold to the system, anywhere else, on a row whose complication
    //! was never found, or on the weather line while it is blank (no weather synced yet).
    public function launchComplicationAt(x as Number, y as Number) as Boolean {
        if (!(Toybox has :Complications)) { return false; }
        var ds = System.getDeviceSettings();
        var w = ds.screenWidth;
        var h = ds.screenHeight;
        var id = null;

        var wxTop = h * WX_Y - HOLD_PAD;
        if (y >= wxTop && y < wxTop + WX_HOLD_H && !(currentWeather()[1]).equals("")) {
            id = new Complications.Id(Complications.COMPLICATION_TYPE_CURRENT_WEATHER);
        } else if (x >= w * 0.10 && x <= w * 0.90) {
            for (var i = 0; i < 3; i++) {
                var top = h * (ROWS_Y + ROWS_GAP * i) - HOLD_PAD;
                if (y >= top && y < top + h * ROWS_GAP) {
                    id = _ids[i];
                    break;
                }
            }
        }
        if (id == null) { return false; }
        try {
            Complications.exitTo(id as Complications.Id);
            return true;
        } catch (e) {
            // InvalidValueException: not a launchable app (e.g. the publisher was uninstalled).
            System.println("hold-to-launch: exitTo failed");
            return false;
        }
    }

    public function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        if (dc has :setAntiAlias) { dc.setAntiAlias(true); }
        dc.setColor(Graphics.COLOR_WHITE, bg());
        dc.clear();

        drawWeather(dc, w, h);
        drawHeader(dc, w, h);

        // Three CLI rows.
        for (var i = 0; i < 3; i++) {
            drawRow(dc, i, w, h, ROWS_Y + ROWS_GAP * i);
        }

        drawBattery(dc, w, h);

        // Blinking cursor (a no-op while the layout parks it off-screen). Not in always-on: a
        // once-a-minute update can't blink it.
        if (!_lowPower && System.getClockTime().sec % 2 == 0) {
            ink(dc, ACCENT);
            rect(dc, w * CURSOR_X - w * CURSOR_W / 2.0, h * CURSOR_Y, w * CURSOR_W, h * CURSOR_H);
        }

        // VFD build: one screen-aligned mesh (or the CRT scanlines, per setting) over everything,
        // drawn last (no-op otherwise). Kept in always-on too, so the face keeps its VFD / CRT
        // character when the wrist is down: the overlay only DARKENS what is lit (black at partial
        // alpha over a black background changes nothing), so it adds no lit pixels - it slightly
        // lowers the burn-in load of the outline time and bars.
        drawMeshOverlay(dc, w, h, 0, 0, w, h);
    }

    //! Always-on on: repaint once in the low-power style (see _lowPower).
    public function onEnterSleep() as Void {
        _lowPower = true;
        WatchUi.requestUpdate();
    }

    //! Back to high power: full style, and seconds resume with the next partial update.
    public function onExitSleep() as Void {
        _lowPower = false;
        WatchUi.requestUpdate();
    }

    //! Seconds tick here when the device allows partial updates; onUpdate handles the rest.
    //!
    //! Only the time's band is repainted, clipped. The band is the time's real extent (the glow
    //! bitmaps' cell in the VFD build, the font's line height otherwise), which at this layout
    //! reaches into the prompt's descenders above and the date's line box below. So inside the
    //! clip the band is blanked and the prompt, time and date are all redrawn in onUpdate's order:
    //! every pixel in the band is then painted from black exactly once, as in a full update (text
    //! drawn over its own anti-aliased edges without a blank would darken them each second).
    public function onPartialUpdate(dc as Dc) as Void {
        // No seconds in always-on (the outline time is HH:MM), so nothing to tick.
        if (!_showSeconds || _lowPower) {
            return;
        }
        var w = dc.getWidth();
        var h = dc.getHeight();
        if (dc has :setAntiAlias) { dc.setAntiAlias(true); }
        var band = timeBand(h);          // [top, height] in whole pixels
        // Never reach the meter rows, which are not redrawn here. On the small (260/280 px) screens
        // the time font's line box runs past the first row's top; the digit ink itself stops short.
        var rowsTop = px(h * ROWS_Y);
        if (band[0] + band[1] > rowsTop) {
            band[1] = rowsTop - band[0];
        }
        dc.setClip(0, band[0], w, band[1]);
        dc.setColor(bg(), bg());          // the theme background (Retro tube is not black)
        dc.fillRectangle(0, band[0], w, band[1]);
        drawHeader(dc, w, h);
        dc.clearClip();
        // re-mesh just the repainted band (same lattice, so it lines up with the rest)
        drawMeshOverlay(dc, w, h, 0, band[0], w, band[1]);
    }

    //! Prompt line, time and date - the three lines the seconds repaint may touch.
    private function drawHeader(dc as Dc, w as Numeric, h as Numeric) as Void {
        // Prompt line (the PromptText setting), accent colour.
        ink(dc, ACCENT);
        text(dc, w * PROMPT_X, h * PROMPT_Y, ft(), _prompt, Graphics.TEXT_JUSTIFY_CENTER);

        drawTime(dc, w, h);

        // Date.
        var info = Gregorian.info(Time.now(), Time.FORMAT_MEDIUM);
        var dateStr = info.day_of_week + " " + info.month + " " + info.day.format("%d");
        ink(dc, DIM);
        text(dc, w * DATE_X, h * DATE_Y, fs(), dateStr, Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function timeFont() as Graphics.FontType {
        return (_fontTime != null) ? _fontTime : Graphics.FONT_NUMBER_MEDIUM;
    }

    //! Draws the time; the caller has already painted the background under it (the full clear in
    //! onUpdate, the clipped band blank in onPartialUpdate).
    private function drawTime(dc as Dc, w as Numeric, h as Numeric) as Void {
        var clock = System.getClockTime();
        var hour = clock.hour;
        if (!System.getDeviceSettings().is24Hour) {
            hour = hour % 12;
            if (hour == 0) { hour = 12; }
        }
        var t = hour.format("%02d") + ":" + clock.min.format("%02d");
        var ty = px(h * TIME_Y);
        if (_lowPower) {
            // Always-on: HH:MM in the hollow outline font, never the glow bitmaps (a lit bloom
            // would blow the AMOLED burn-in budget). HH:MM must not MOVE on entering sleep -
            // only the seconds disappear - so it keeps the left edge the high-power time has:
            // centred on the width of the whole HH:MM:SS (both paths centre on that, see
            // GlowTime.draw / text()). The outline font shares the solid font's line metrics
            // and advance (monospace), so each digit lands exactly on its solid twin.
            var solid = timeFont();
            var full = _showSeconds ? t + ":00" : t;   // same width as any HH:MM:SS (monospace)
            var left = px(w * TIME_X) - dc.getTextWidthInPixels(full, solid) / 2;
            ink(dc, VALUE);
            dc.drawText(left, ty, (_fontTimeO != null) ? _fontTimeO : solid, t,
                Graphics.TEXT_JUSTIFY_LEFT);
            return;
        }
        if (_showSeconds) {
            t += ":" + clock.sec.format("%02d");
        }
        var font = timeFont();
        if (_fontTime != null && drawGlowTime(dc, px(w * TIME_X), ty, font, t)) {
            return;
        }
        ink(dc, VALUE);
        text(dc, w * TIME_X, ty, font, t, Graphics.TEXT_JUSTIFY_CENTER);
    }

    // ---- VFD style (optional build, selected in monkey.jungle) ---------------------------------
    // Same scheme as Claude Grid: the time drawn from pre-rendered glow bitmaps (source-glow/ +
    // resources-glow/, tools/build_glow_time.py) and one overlay tile tiled over the whole face:
    // the mesh shared with Claude Grid (garmin/shared/resources-mesh/) or, with Scanlines on, this
    // face's scanline tile (resources-scanlines/). The annotations pick the implementation compiled in.

    (:glow_time)
    private function drawGlowTime(dc as Dc, cx as Number, top as Number, font as Graphics.FontType,
                                  t as String) as Boolean {
        GlowTime.draw(dc, cx, top, font, t);
        return true;
    }

    (:font_time)
    private function drawGlowTime(dc as Dc, cx as Number, top as Number, font as Graphics.FontType,
                                  t as String) as Boolean {
        return false;
    }

    //! The rows the time occupies, as [top, height] in pixels. VFD build: the glow bitmaps' cell
    //! (glyph ink + bloom, generated into GlowTimeMetrics), unless the time font failed to load and
    //! drawTime fell back to the system font.
    (:glow_time)
    private function timeBand(h as Numeric) as Array<Number> {
        var ty = px(h * TIME_Y);
        if (_fontTime != null) {
            return [ty + GlowTimeMetrics.Y0, GlowTimeMetrics.H];
        }
        return [ty, Graphics.getFontHeight(timeFont())];
    }

    //! Plain build: the time font's line box (+1 for CIQ drawing glyphs one row low).
    (:font_time)
    private function timeBand(h as Numeric) as Array<Number> {
        return [px(h * TIME_Y), Graphics.getFontHeight(timeFont()) + 1];
    }

    (:mesh_overlay)
    private var _meshTile = null;
    (:mesh_overlay)
    private var _meshIsScan as Boolean = false;   // which tile _meshTile currently holds

    //! Tile the overlay over the given screen rectangle (clipped to it), tiles anchored at the
    //! screen origin so every call hits the same lattice. The overlay is the VFD mesh (rows AND
    //! columns), or with the Scanlines setting the CRT scanline tile (rows only); only the one in
    //! use is loaded, and switching the setting swaps it.
    (:mesh_overlay)
    private function drawMeshOverlay(dc as Dc, w as Number, h as Number, x as Number, y as Number,
                                     cw as Number, ch as Number) as Void {
        if (_meshTile == null || _meshIsScan != _scanlines) {
            _meshTile = WatchUi.loadResource(_scanlines ? Rez.Drawables.ScanTile : Rez.Drawables.MeshTile);
            _meshIsScan = _scanlines;
        }
        var s = (_meshTile as Graphics.BitmapReference).getWidth();
        if (s <= 0) { return; }
        dc.setClip(x, y, cw, ch);
        for (var ty = (y / s) * s; ty < y + ch; ty += s) {
            for (var tx = (x / s) * s; tx < x + cw; tx += s) {
                dc.drawBitmap(tx, ty, _meshTile);
            }
        }
        dc.clearClip();
    }

    (:plain_overlay)
    private function drawMeshOverlay(dc as Dc, w as Number, h as Number, x as Number, y as Number,
                                     cw as Number, ch as Number) as Void {
    }

    //! One row: label, bar, percentage, reset time. Columns are fixed fractions of the width so the
    //! three rows align and stay within the round bezel's safe band. Everything is snapped to whole
    //! pixels - the bars especially, whose fractional edges used to render soft.
    private function drawRow(dc as Dc, slot as Number, w as Numeric, h as Numeric, yf as Float) as Void {
        var y = h * yf;
        var pct = _pcts[slot];

        ink(dc, DIM);
        text(dc, w * LABEL_X, y, fs(), _labels[slot], Graphics.TEXT_JUSTIFY_LEFT);

        // Bar: integer track, and an integer-width fill measured from the same left edge.
        var bx = px(w * BAR_X);
        var bw = px(w * BAR_W);
        var by = px(y + w * BAR_DY);
        var bh = px(w * BAR_H);
        // Tube glow: the lit fill's halo goes down first, so the track and fill draw over its
        // inside and only the soft edge shows around the lit part.
        if (pct > 0) {
            var gfw = px(bw * ((pct > 100) ? 100 : pct) / 100.0);
            haloRect(dc, bx, by, gfw, bh, pct >= 80 ? NEAR_CAP : ACCENT);
        }
        if (!_lowPower) {   // always-on keeps only the filled part (see _lowPower)
            dc.setColor(TRACK, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(bx, by, bw, bh);
        }
        if (pct >= 0) {
            var clamped = (pct > 100) ? 100 : pct;
            var fw = px(bw * clamped / 100.0);
            if (fw > 0) {
                dc.setColor(pct >= 80 ? NEAR_CAP : ACCENT, Graphics.COLOR_TRANSPARENT);
                if (_lowPower) {
                    outlineRect(dc, bx, by, fw, bh, AOD_STROKE);   // always-on: hollow bar
                } else {
                    dc.fillRectangle(bx, by, fw, bh);
                }
            }
        }

        // Percentage.
        ink(dc, VALUE);
        var pctTxt = (pct >= 0) ? (pct.toString() + "%") : "--";
        text(dc, w * PCT_X, y, fs(), pctTxt, Graphics.TEXT_JUSTIFY_RIGHT);

        // Reset time.
        var reset = resetsAt(_resets[slot]);
        if (!reset.equals("")) {
            ink(dc, DIM);
            text(dc, w * RESET_X, y, fs(), reset, Graphics.TEXT_JUSTIFY_RIGHT);
        }
    }
    //! Weather line at the top, like Rad Lad's: condition icon + current temperature + feels-like,
    //! "<icon> 32° FL40°", centred as a whole on WX_X. Icon in the accent colour, readings in VALUE,
    //! the "FL" marker in DIM (the colour of the meter-row labels). Nothing is drawn when the watch
    //! has no weather yet (no phone sync) rather than a lone "--"; the feels-like part is left off
    //! when the weather service doesn't report one.
    private function drawWeather(dc as Dc, w as Numeric, h as Numeric) as Void {
        var wx = currentWeather();
        var icon = wx[0];
        var temp = wx[1];
        var feels = wx[2];
        if (temp.equals("")) { return; }
        var font = fs();
        var tempW = dc.getTextWidthInPixels(temp, font);
        // " FL" then the reading: the leading space is part of the marker, so the monospace
        // advance keeps the gap exactly one character wide.
        var flMark = " " + WX_FL;
        var flMarkW = feels.equals("") ? 0 : dc.getTextWidthInPixels(flMark, font);
        var feelsW = feels.equals("") ? 0 : dc.getTextWidthInPixels(feels, font);
        var iconW = (!icon.equals("") && _fontIcon != null)
            ? dc.getTextWidthInPixels(icon, _fontIcon) + WX_GAP : 0;
        var left = px(w * WX_X) - (iconW + tempW + flMarkW + feelsW) / 2;
        var top = px(h * WX_Y);
        if (iconW > 0) {
            // The 24 px icon is centred on the 25 px text line: icon line box is ~29 px tall vs
            // the text's 33, so it sits 2 px lower to line up with the digits.
            ink(dc, ACCENT);
            glowText(dc, left, top + 2, _fontIcon as Graphics.FontType, icon);
            dc.drawText(left, top + 2, _fontIcon as Graphics.FontType, icon, Graphics.TEXT_JUSTIFY_LEFT);
        }
        ink(dc, VALUE);
        glowText(dc, left + iconW, top, font, temp);
        dc.drawText(left + iconW, top, font, temp, Graphics.TEXT_JUSTIFY_LEFT);
        if (feelsW > 0) {
            var fx = left + iconW + tempW;
            ink(dc, DIM);
            glowText(dc, fx, top, font, flMark);
            dc.drawText(fx, top, font, flMark, Graphics.TEXT_JUSTIFY_LEFT);
            ink(dc, VALUE);
            glowText(dc, fx + flMarkW, top, font, feels);
            dc.drawText(fx + flMarkW, top, font, feels, Graphics.TEXT_JUSTIFY_LEFT);
        }
    }

    //! [icon, temperature, feels] from Weather.getCurrentConditions() - the same logic as Claude
    //! Grid: live and feels-like (wind chill / heat index) temperatures in the watch's unit, and a
    //! condition icon with the sun / moon variant by whether it's between sunrise and sunset.
    //! ["", "", ""] when there is no weather data; feels is "" when it alone is not reported.
    private function currentWeather() as Array<String> {
        if (!(Toybox has :Weather)) { return ["", "", ""]; }
        try {
            var cc = Weather.getCurrentConditions();
            if (cc == null) { return ["", "", ""]; }
            var temp = "";
            var tc = cc.temperature;
            if (tc != null) {
                temp = tempStr(tc);
            }
            var feels = "";
            var fc = cc.feelsLikeTemperature;
            if (fc != null) {
                feels = tempStr(fc);
            }
            var icon = "";
            if (cc.condition != null) {
                icon = weatherGlyph(cc.condition as Number, isNight(cc)).toChar().toString();
            }
            return [icon, temp, feels];
        } catch (ex) {
            return ["", "", ""];
        }
    }

    //! A Celsius reading from the Weather API -> "32°" in the watch's temperature unit, rounded.
    private function tempStr(celsius as Numeric) as String {
        var tv = celsius.toFloat();
        if (System.getDeviceSettings().temperatureUnits == System.UNIT_STATUTE) {
            tv = tv * 9.0 / 5.0 + 32.0;
        }
        return Math.round(tv).toNumber().format("%d") + "°";
    }

    //! True between local sunset and the next sunrise at the observation location; daytime when
    //! the location or sun times are unknown.
    private function isNight(cc as Weather.CurrentConditions) as Boolean {
        var loc = cc.observationLocationPosition;
        if (loc == null) { return false; }
        var now = Time.now();
        var rise = Weather.getSunrise(loc, now);
        var set = Weather.getSunset(loc, now);
        if (rise == null || set == null) { return false; }
        return now.lessThan(rise) || now.greaterThan(set);
    }

    //! Weather condition -> glyph in stm_icon (Claude Grid's cg_icon; keep the two in step).
    //! 0xE001 / 0xE002 are the composited cloud+sun / cloud+moon.
    private function weatherGlyph(c as Number, night as Boolean) as Number {
        if (c == Weather.CONDITION_CLEAR || c == Weather.CONDITION_FAIR
         || c == Weather.CONDITION_MOSTLY_CLEAR) {
            return night ? 0xeaf8 : 0xeb30;                      // moon / sun
        }
        if (c == Weather.CONDITION_PARTLY_CLOUDY || c == Weather.CONDITION_PARTLY_CLEAR
         || c == Weather.CONDITION_THIN_CLOUDS) {
            return night ? 0xE002 : 0xE001;                      // cloud+moon / cloud+sun
        }
        if (c == Weather.CONDITION_THUNDERSTORMS || c == Weather.CONDITION_SCATTERED_THUNDERSTORMS
         || c == Weather.CONDITION_CHANCE_OF_THUNDERSTORMS || c == Weather.CONDITION_HURRICANE
         || c == Weather.CONDITION_TROPICAL_STORM || c == Weather.CONDITION_TORNADO) {
            return 0xea74;
        }
        if (c == Weather.CONDITION_SNOW || c == Weather.CONDITION_LIGHT_SNOW
         || c == Weather.CONDITION_HEAVY_SNOW || c == Weather.CONDITION_FLURRIES
         || c == Weather.CONDITION_CHANCE_OF_SNOW || c == Weather.CONDITION_CLOUDY_CHANCE_OF_SNOW
         || c == Weather.CONDITION_WINTRY_MIX || c == Weather.CONDITION_RAIN_SNOW
         || c == Weather.CONDITION_LIGHT_RAIN_SNOW || c == Weather.CONDITION_HEAVY_RAIN_SNOW
         || c == Weather.CONDITION_CHANCE_OF_RAIN_SNOW || c == Weather.CONDITION_CLOUDY_CHANCE_OF_RAIN_SNOW
         || c == Weather.CONDITION_SLEET || c == Weather.CONDITION_ICE
         || c == Weather.CONDITION_ICE_SNOW || c == Weather.CONDITION_HAIL
         || c == Weather.CONDITION_FREEZING_RAIN) {
            return 0xea73;
        }
        if (c == Weather.CONDITION_RAIN || c == Weather.CONDITION_LIGHT_RAIN
         || c == Weather.CONDITION_HEAVY_RAIN || c == Weather.CONDITION_SHOWERS
         || c == Weather.CONDITION_LIGHT_SHOWERS || c == Weather.CONDITION_HEAVY_SHOWERS
         || c == Weather.CONDITION_SCATTERED_SHOWERS || c == Weather.CONDITION_CHANCE_OF_SHOWERS
         || c == Weather.CONDITION_DRIZZLE || c == Weather.CONDITION_CLOUDY_CHANCE_OF_RAIN
         || c == Weather.CONDITION_UNKNOWN_PRECIPITATION) {
            return 0xea72;
        }
        if (c == Weather.CONDITION_FOG || c == Weather.CONDITION_HAZY || c == Weather.CONDITION_HAZE
         || c == Weather.CONDITION_MIST || c == Weather.CONDITION_SMOKE || c == Weather.CONDITION_DUST
         || c == Weather.CONDITION_SAND || c == Weather.CONDITION_SANDSTORM
         || c == Weather.CONDITION_VOLCANIC_ASH) {
            return 0xecd9;
        }
        if (c == Weather.CONDITION_WINDY || c == Weather.CONDITION_SQUALL) {
            return 0xec34;
        }
        return 0xea76; // cloud: MOSTLY_CLOUDY, CLOUDY (overcast) and anything unknown
    }

    //! A hollow rectangle: a `t`-px border drawn INSIDE (x, y, w, h), all edges on whole pixels.
    //! Four fills rather than drawRectangle so the stroke width is exact and nothing is
    //! anti-aliased. Too small to leave a hollow (e.g. a 1 % bar) -> filled solid instead.
    private function outlineRect(dc as Dc, x as Number, y as Number, w as Number, h as Number,
                                 t as Number) as Void {
        if (w <= 2 * t || h <= 2 * t) {
            dc.fillRectangle(x, y, w, h);
            return;
        }
        dc.fillRectangle(x, y, w, t);                   // top
        dc.fillRectangle(x, y + h - t, w, t);           // bottom
        dc.fillRectangle(x, y + t, t, h - 2 * t);       // left
        dc.fillRectangle(x + w - t, y + t, t, h - 2 * t); // right
    }

    //! The watch battery as a straight row of segments - every edge on a whole pixel (integer
    //! segment width, gap and origin), so the segments are as crisp as the meter bars. A segment
    //! lights as soon as its share has started (ceil), so any charge left shows at least one;
    //! at BATT_LOW or below the lit ones turn red. Redrawn once a minute with the full update,
    //! which is plenty for a battery level.
    private function drawBattery(dc as Dc, w as Numeric, h as Numeric) as Void {
        var sw = px(w * BATT_SEG_W);
        if (sw < 1) { sw = 1; }
        var gap = px(w * BATT_GAP);
        var bh = px(w * BATT_H);
        if (bh < 1) { bh = 1; }
        var total = BATT_SEGS * sw + (BATT_SEGS - 1) * gap;
        var x0 = px(w * BATT_X) - total / 2;
        var y0 = px(h * BATT_Y);

        var pct = System.getSystemStats().battery;               // Float 0-100
        var lit = Math.ceil(BATT_SEGS * pct / 100.0).toNumber();
        if (lit > BATT_SEGS) { lit = BATT_SEGS; }
        if (lit < 0) { lit = 0; }
        var on = (pct <= BATT_LOW) ? NEAR_CAP : ACCENT;

        // Tube glow: every lit segment's halo first, so neighbouring halos merge in the gaps and no
        // halo is drawn over a segment.
        for (var i = 0; i < lit; i++) {
            haloRect(dc, x0 + i * (sw + gap), y0, sw, bh, on);
        }
        for (var i = 0; i < BATT_SEGS; i++) {
            if (i >= lit && _lowPower) { break; }   // always-on: lit segments only
            dc.setColor(i < lit ? on : TRACK, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(x0 + i * (sw + gap), y0, sw, bh);
        }
    }

    //! Absolute reset time, the way the phone and glance state it: clock time within a day,
    //! weekday within the week, month/day beyond. Empty when no reset is known.
    private function resetsAt(epochSec as Number) as String {
        if (epochSec == 0) {
            return "";
        }
        var secs = epochSec - Time.now().value();
        if (secs <= 0) {
            return "now";
        }
        var moment = new Time.Moment(epochSec);
        if (secs < 86400) {
            var i = Gregorian.info(moment, Time.FORMAT_SHORT);
            var mm = i.min.format("%02d");
            if (System.getDeviceSettings().is24Hour) {
                return i.hour.format("%d") + ":" + mm;
            }
            var hr = i.hour % 12;
            if (hr == 0) { hr = 12; }
            return hr.format("%d") + ":" + mm + (i.hour < 12 ? "a" : "p");
        }
        var g = Gregorian.info(moment, Time.FORMAT_MEDIUM);
        if (secs < 7 * 86400) {
            return g.day_of_week;
        }
        return g.month + " " + g.day.format("%d");
    }

    public function onHide() as Void {
        if (_subscribed && Toybox has :Complications) {
            Complications.unsubscribeFromAllUpdates();
            _subscribed = false;
        }
    }
}
