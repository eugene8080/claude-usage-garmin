import Toybox.Application;
import Toybox.Application.WatchFaceConfig;
import Toybox.Complications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.WatchUi;
import Toybox.Weather;

//! "Claude Grid" - a data face in Roboto Mono built to the HTML layout editor's finalized design.
//! Big stacked time (solid white hour over a Gradient 1->2 minute), a brand line, a battery arc
//! on the bezel, a live 60-tick seconds sub-dial, a second time zone (New York, via LocalMoment
//! so DST is automatic), the date flanking the dial, a curved weekday strip, and eight
//! user-editable complication slots (Data 01-08; 07 and 08 are the dial and the time zone).
//!
//! All eight fields (Data 01-08) are complication slots configured with Garmin's native on-device
//! editor; the assigned complication's icon + value are drawn at the slot, and the two ring slots
//! (04/05) also gauge it. Data 07 is the bottom dial: the live seconds until a complication is
//! picked for it (or when forced by the SecondsAlways setting), then the same tick ring gauges the
//! picked field. Data 08 likewise shows a second time zone until a complication is picked for it
//! (or when forced by AltTzAlways); its city is a setting (on-watch menu or Garmin Connect).
//! Accent and data colours are editable natively; the rest of the palette is baked from the editor.
//! Any slot can instead show a face-computed field (humidity, wind, chance of rain, battery in days:
//! the DataNField settings) - data Garmin's editor can't offer because there is no complication.
//! On the live face, touch-and-hold on a slot launches its complication's app; the battery arc and
//! the date / weekday strip launch too (launchComplicationAt).
class ClaudeGridView extends WatchUi.WatchFace {

    // --- palette (from the layout editor) ---------------------------------------------------
    // Synthwave palette from the layout editor (2026-09-25). Earlier palettes are the editor's
    // themes: "Claude Grid teal" (TEXT2 7FE8C8, TEXT3 13916B, accent A4F5E1, data 1EC693) and
    // "Claude" (TEXT2 FFFFFF, TEXT3 9A9A9A, accent FF531A, data FF9C75).
    private const TEXT2 = 0xFFFFFF;               // ring values + date
    private const TEXT3 = 0x848BBD;               // icons, labels, weekday strip, brand, SEC
    private const HOUR_COL = 0xFFFFFF;            // hour digits (solid)
    private const _DEFAULT_ACCENT = 0xFEDE5D;    // today's weekday + seconds value
    private const _DEFAULT_DATA = 0x36F9F6;      // chip values (Text 1)

    private const TIME_GAP = 59;                 // HH / MM digit centres each this far from TIME_Y
    private const TIME_Y = 0.477;                // time block centre (fraction of height), = editor
    private const TIME_HALF_H = 64;              // minute gradient half-height: 0.42 x the 153 px time
                                                 // (= build_glow_digits.GRAD_HALF_H and the editor)
    private const DIAL_R = 50;                   // seconds-dial tick outer radius (= tick font R_OUT)
    private const DIAL_CLEAR_R = 55;             // knockout disc: DIAL_R + a 5 px black gap
    private const DATE_GAP = 90;                 // month / day each this far either side of the dial

    private var _fTime as Graphics.FontType?;    // 153px digits  - the clock
    private var _fTimeO as Graphics.FontType?;   // 153px outline - always-on clock
    private var _fBig as Graphics.FontType?;     // 36px          - ring values, brand, date
    private var _fMed as Graphics.FontType?;     // 30px          - chip values, alt-tz, seconds
    private var _fWeek as Graphics.FontType?;    // 27px          - weekday letters
    private var _fSmall as Graphics.FontType?;   // 24px          - battery %, SEC, text labels
    private var _fTiny as Graphics.FontType?;    // 20px          - last-resort value font (corners)
    private var _fIcon as Graphics.FontType?;    // 24px          - Tabler per-field icons
    private var _fArc as Graphics.FontType?;     // battery-arc dashes (pre-rasterised, cg_arc, 454 px)
    private var _fTicks as Graphics.FontType?;   // seconds-dial ticks (pre-rasterised, cg_ticks)
    private var _fWeekVec as Graphics.VectorFont?; // vector font  - weekday strip (rotatable)

    private var _editMode as Boolean = false;
    private var _lowPower as Boolean = false;    // always-on / ambient mode
    private var _accentColor as Number = _DEFAULT_ACCENT;
    private var _dataColor as Number = _DEFAULT_DATA;

    private var _altIndex as Number = 0;         // Data 08 time-zone city (AltTz index)
    private var _altAlways as Boolean = false;   // Data 08 shows the clock even if a comp is picked
    private var _secAlways as Boolean = false;   // Data 07 shows the seconds even if a comp is picked
    //! Per-slot face-computed field (GridField), index = slot uid; EDITOR = the editor's pick.
    private var _fields as Array<Number> = [0, 0, 0, 0, 0, 0, 0, 0, 0];

    private var _alarmChar as String = "";       // Tabler alarm glyph

    //! 0..1 multiplier that sweeps the ring gauges + seconds in on wake. Public so WatchUi.animate()
    //! can drive it by symbol. Defaults to 1.0 so nothing is stuck empty if animation is unavailable.
    public var ringSweep as Float = 1.0;

    private var _slots as Array<ClaudeGridSlot> = [];
    private var _slotIds as Dictionary = {};     // uid (Number) -> Complications.Id

    // edit-mode preview state
    private var _editingSlot as Boolean = false;
    private var _selectedUid as Number? = null;

    public function initialize(editMode as Boolean) {
        WatchFace.initialize();
        _editMode = editMode;
        _alarmChar = (0xea04).toChar().toString();
    }

    public function onLayout(dc as Dc) as Void {
        _fTime  = WatchUi.loadResource(Rez.Fonts.CGTime) as Graphics.FontType;
        _fTimeO = WatchUi.loadResource(Rez.Fonts.CGTimeOutline) as Graphics.FontType;
        _fBig   = WatchUi.loadResource(Rez.Fonts.CGBig) as Graphics.FontType;
        _fMed   = WatchUi.loadResource(Rez.Fonts.CGMed) as Graphics.FontType;
        _fWeek  = WatchUi.loadResource(Rez.Fonts.CGWeek) as Graphics.FontType;
        _fSmall = WatchUi.loadResource(Rez.Fonts.CGSmall) as Graphics.FontType;
        _fTiny  = WatchUi.loadResource(Rez.Fonts.CGTiny) as Graphics.FontType;
        _fIcon  = WatchUi.loadResource(Rez.Fonts.TablerIcon) as Graphics.FontType;
        _fTicks = WatchUi.loadResource(Rez.Fonts.CGTicks) as Graphics.FontType;
        _fArc   = WatchUi.loadResource(Rez.Fonts.CGArc) as Graphics.FontType;

        // A vector font for the weekday strip - the only way to draw ROTATED (curved) text on
        // CIQ; bitmap fonts can't rotate. Guarded so older devices fall back to upright letters.
        if (Graphics has :getVectorFont) {
            _fWeekVec = Graphics.getVectorFont({
                :face => ["RobotoCondensedBold", "RobotoCondensed"], :size => 26
            });
        }

        buildSlots(dc.getWidth(), dc.getHeight());
        readSettings();

        for (var i = 0; i < _slots.size(); i++) {
            updateSlotText(_slots[i].uid);
        }

        var settings = WatchFaceConfig.getSettings(null);
        if (settings != null) {
            seedConfig(settings);
            updateConfiguration(settings, null);
        }

        if (!_editMode) {
            for (var i = 0; i < _slots.size(); i++) {
                var id = _slotIds[_slots[i].uid] as Complications.Id;
                if (id != null) {
                    try { Complications.subscribeToUpdates(id); } catch (e) {}
                }
            }
            Complications.registerComplicationChangeCallback(method(:onComplicationChange));
        }
    }

    //! Create the six editable slots at their editor grid positions and record each one's default
    //! complication type. Claude usage meters (Fable / 5-hour / weekly) are custom complications
    //! the user assigns on-watch, so those slots seed a sensible standard default here.
    private function buildSlots(w as Number, h as Number) as Void {
        var ringR = (w * 0.123).toNumber();      // editor ring = 56px @ 454
        // uid, kind, fx, fy, ringR, pen, horizontal, defaultType
        var specs = [
            [1, SlotKind.CHIP, 0.500, 0.092, 0,     0, true,  Complications.COMPLICATION_TYPE_BATTERY],
            [2, SlotKind.CHIP, 0.175, 0.299, 0,     0, false, Complications.COMPLICATION_TYPE_HIGH_LOW_TEMPERATURE],
            [3, SlotKind.CHIP, 0.825, 0.299, 0,     0, false, Complications.COMPLICATION_TYPE_STEPS],
            [4, SlotKind.RING, 0.139, 0.500, ringR, 6, false, Complications.COMPLICATION_TYPE_HEART_RATE],
            [5, SlotKind.RING, 0.861, 0.500, ringR, 6, false, Complications.COMPLICATION_TYPE_BODY_BATTERY],
            [6, SlotKind.CHIP, 0.177, 0.722, 0,     0, false, Complications.COMPLICATION_TYPE_CURRENT_WEATHER],
            // Data 07: the bottom dial. NO seeded default - while nothing is picked it is the live
            // seconds dial, exactly as before it was editable.
            [7, SlotKind.DIAL, 0.500, 0.832, DIAL_R, 0, false, null],
            // Data 08: NO seeded default - while nothing is picked it shows the time-zone clock
            // (see refreshAltTz). Same centre the fixed alt-tz field used, so the look is unchanged.
            [8, SlotKind.CHIP, 0.823, 0.722, 0,     0, false, null]
        ];

        _slots = [];
        _slotIds = {};
        var cxf = w / 2.0;
        var cyf = h / 2.0;
        var R = w / 2.0;
        for (var i = 0; i < specs.size(); i++) {
            var s = specs[i];
            var uid = s[0] as Number;
            var isRing = (s[1] == SlotKind.RING);
            var isDial = (s[1] == SlotKind.DIAL);
            var isHoriz = s[6] as Boolean;
            var slotX = (s[2] as Float) * w;
            // Width budget that respects the round bezel: half-chord to the near edge.
            var dyy = ((s[3] as Float) * h) - cyf;
            var chordArg = (R * R) - (dyy * dyy);
            var chordHalf = (chordArg > 0) ? Math.sqrt(chordArg) : 0.0;
            var near = (slotX <= cxf) ? (slotX - (cxf - chordHalf)) : ((cxf + chordHalf) - slotX);
            var maxW = isRing ? ((s[4] as Number) * 1.6).toNumber() : (2.0 * (near - 8)).toNumber();
            if (maxW < 40) { maxW = 40; }
            // Data 01 sits INSIDE the battery arc, whose dashes (inner radius ~209 px) close in
            // to ~180 px wide at the text's top edge - narrower than the bezel chord above.
            if (isHoriz && maxW > 180) { maxW = 180; }
            // Data 07's text sits inside the tick ring; the slot also fits each row to that circle.
            if (isDial) { maxW = 2 * ((s[4] as Number) - 10); }

            // Largest -> smallest; the slot picks the first that fits the row (ClaudeGridSlot).
            // (Data 07's first font is also the seconds font, the 30 px one it always used.)
            var valueFonts = isRing ? [_fBig, _fMed, _fSmall]
                                    : (isHoriz ? [_fSmall, _fTiny] : [_fMed, _fSmall, _fTiny]);
            var slot = new ClaudeGridSlot({
                :uid => uid,
                :kind => s[1],
                :cx => slotX.toNumber(),
                :cy => ((s[3] as Float) * h).toNumber(),
                :ringR => s[4],
                :ringPen => s[5],
                :striped => false,
                :horizontal => isHoriz,
                :fLabel => _fSmall,
                :fIcon => _fIcon,
                :valueFonts => valueFonts,
                :fStacked => _fSmall,
                :valueMaxW => maxW,
                // lets the slot fit each text row to the round screen at that row's height
                :screen => [w / 2, h / 2, w / 2],
                // Data 07 only: the tick-ring font, a smaller label font for names like "FABLE",
                // and the knockout disc it clears into the minute digits
                :fTicks => _fTicks,
                :fLabelSmall => _fTiny,
                :clearR => DIAL_CLEAR_R
            });
            slot.labelColor = TEXT3;
            // rings = white, chips = Text 1, the dial = the accent (as the seconds always were)
            slot.valueColor = isRing ? TEXT2 : (isDial ? _accentColor : _dataColor);
            _slots.add(slot);
            if (s[7] != null) {
                _slotIds[uid] = new Complications.Id(s[7] as Complications.Type);
            }
        }
    }

    //! Write the face's per-slot defaults into the SAVED watch-face config, for slots that are still
    //! unset. Garmin's on-watch editor only knows the saved config: a fresh one has every slot
    //! empty, which the editor shows - and saves - as Battery, so the first edit turned all the
    //! fields into Battery (reproduced in the simulator's Watch Face Editor). Seeding makes the
    //! editor open on exactly what the face was showing. Slots the user has set are never touched,
    //! and Data 08 has no default (its unset state IS the time-zone clock), so it isn't seeded.
    private function seedConfig(settings as WatchFaceConfig.Settings) as Void {
        var comps = settings.complicationSettings;
        if (comps == null) { return; }
        var changed = false;
        for (var i = 0; i < comps.size(); i++) {
            var entry = comps[i];
            var uid = entry.uniqueIdentifier;
            if (uid == null || entry.complicationId != null) { continue; }
            var seed = _slotIds[uid];
            if (seed != null) {
                entry.complicationId = seed as Complications.Id;
                changed = true;
            }
        }
        if (changed) {
            try {
                WatchFaceConfig.setSettings(null, settings);
            } catch (e) {
                System.println("seedConfig: setSettings failed");
            }
        }
    }

    private function slotFor(uid as Number) as ClaudeGridSlot? {
        for (var i = 0; i < _slots.size(); i++) {
            if (_slots[i].uid == uid) { return _slots[i]; }
        }
        return null;
    }

    //! Pull the current icon / value / fill for the complication assigned to a slot.
    public function updateSlotText(uid as Number) as Void {
        var slot = slotFor(uid);
        if (slot == null) { return; }
        if (_fields[uid] != GridField.EDITOR) {
            fillField(slot, _fields[uid]);
            return;
        }
        var id = _slotIds[uid];
        if (id == null) { return; }
        var cid = id as Complications.Id;
        var t = cid.getType();
        slot.iconChar = iconCharFor(t);
        try {
            var c = Complications.getComplication(cid);
            var lbl = c.shortLabel;
            if (lbl == null) { lbl = c.longLabel; }
            if (lbl == null) { lbl = defaultLabel(uid); }
            slot.label = (lbl as String).toUpper();
            var raw = c.value;
            // Sea-level pressure arrives in Pa (~101000); show hPa/mb to match and fit.
            if ((t == Complications.COMPLICATION_TYPE_SEA_LEVEL_PRESSURE) && (raw != null)
                && (raw instanceof Lang.Number || raw instanceof Lang.Float || raw instanceof Lang.Double)
                && (raw > 2000)) {
                raw = (raw / 100.0 + 0.5).toNumber();
            }
            // The bitmap fonts carry UPPERCASE only - a lowercase value ("Fri", "Sep 25") drew
            // tofu boxes - so every value is upper-cased before it reaches a font.
            var vs = valStr(raw).toUpper();
            if ((c.value != null) && (isPercentUsage(t, c.longLabel)
                    || (t == Complications.COMPLICATION_TYPE_BATTERY))) {
                vs = vs + "%";
            }
            slot.valueTop = "";
            slot.valueBot = "";
            var feels = "";   // current weather's feels-like reading ("40°"), "" when unknown

            if (t == Complications.COMPLICATION_TYPE_WEEKDAY_MONTHDAY
                    || t == Complications.COMPLICATION_TYPE_DATE) {
                // Self-explanatory text: no icon, no label, just the value.
                slot.iconChar = "";
                slot.label = "";
            } else if (t == Complications.COMPLICATION_TYPE_SUNRISE
                    || t == Complications.COMPLICATION_TYPE_SUNSET) {
                // Arrives as seconds since local midnight (e.g. 65889 = 18:18:09).
                vs = clockFromSeconds(raw, vs);
            } else if (t == Complications.COMPLICATION_TYPE_CURRENT_WEATHER) {
                // The complication's value is the CONDITION code (1 = partly cloudy), not the
                // temperature. Draw the live temperature with an icon for the actual condition.
                var w = currentWeather();
                slot.iconChar = w[0];
                vs = w[1];
                feels = w[2];
            } else if (t == Complications.COMPLICATION_TYPE_CURRENT_TEMPERATURE) {
                vs = withDegree(vs);
            } else if (t == Complications.COMPLICATION_TYPE_TRAINING_STATUS) {
                vs = trainingCode(vs);
            } else if (t == Complications.COMPLICATION_TYPE_BATTERY) {
                slot.iconChar = batteryGlyph(c.value).toChar().toString();
            }

            if (t == Complications.COMPLICATION_TYPE_HIGH_LOW_TEMPERATURE) {
                var parts = splitTwo(vs);
                if (parts != null && slot.kind == SlotKind.CHIP && !slot.horizontal) {
                    slot.valueTop = withDegree(parts[0]);
                    slot.valueBot = withDegree(parts[1]);
                    slot.value = "";
                } else if (parts != null) {
                    // A ring, the dial or Data 01 draws one line: "H30°/L28°", auto-fitted.
                    slot.value = withDegree(parts[0]) + "/" + withDegree(parts[1]);
                } else {
                    slot.value = withDegree(vs);
                }
            } else if (!feels.equals("") && !vs.equals("--")
                    && slot.kind == SlotKind.CHIP && !slot.horizontal) {
                // Current weather: the actual temperature over the feels-like one (wind chill or
                // heat index), stacked like the high/low chip. "FL" marks the second reading, as
                // "H" / "L" do there. Garmin has no feels-like complication type, so this is the
                // only way onto the face - read through WeatherNow (currentWeather). Only a plain
                // chip draws two lines; in a ring or the one-row Data 01 the current reading stays.
                slot.valueTop = vs;
                slot.valueBot = "FL" + feels;
                slot.value = "";
            } else {
                slot.value = vs;
            }
            if (slot.kind == SlotKind.RING || slot.kind == SlotKind.DIAL) {
                slot.frac = ringFrac(cid, c.value, c.longLabel);
            }
        } catch (e) {
            slot.label = defaultLabel(uid);
            slot.value = "--";
            slot.valueTop = "";
            slot.valueBot = "";
            slot.frac = 0.0;
        }
    }

    //! Apply an edited (or freshly read) configuration: accent colour, data colour, and each
    //! slot's assigned complication. Ring values stay white (Text 2); only chips take the data colour.
    public function updateConfiguration(config as WatchFaceConfig.Settings, editedType as WatchFaceConfigType?) as Void {
        var accent = config.accentColor;
        _accentColor = ((accent != null) && (accent.color != null)) ? accent.color as Number : _DEFAULT_ACCENT;

        var data = config.complicationColor;
        _dataColor = ((data != null) && (data.color != null)) ? data.color as Number : _DEFAULT_DATA;
        for (var i = 0; i < _slots.size(); i++) {
            if (_slots[i].kind == SlotKind.CHIP) { _slots[i].valueColor = _dataColor; }
            else if (_slots[i].kind == SlotKind.DIAL) { _slots[i].valueColor = _accentColor; }
        }

        var comps = config.complicationSettings;
        if (comps != null) {
            for (var i = 0; i < comps.size(); i++) {
                var entry = comps[i];
                var uid = entry.uniqueIdentifier;
                if (uid == null) { continue; }
                var id = entry.complicationId;
                if (id == null) { continue; }  // unset -> keep the seeded default
                _slotIds[uid] = id;
                updateSlotText(uid);
            }
        }

        _editingSlot = (editedType == WatchUi.WATCH_FACE_CONFIG_TYPE_COMPLICATION);
        WatchUi.requestUpdate();
    }

    public function onComplicationChange(id as Complications.Id) as Void {
        for (var i = 0; i < _slots.size(); i++) {
            var slotId = _slotIds[_slots[i].uid] as Complications.Id;
            if (slotId != null && id.equals(slotId)) {
                updateSlotText(_slots[i].uid);
            }
        }
        WatchUi.requestUpdate();
    }

    // ---- editor interaction ----

    public function getTappedComplication(x as Number, y as Number) as Number? {
        for (var i = 0; i < _slots.size(); i++) {
            if (_slots[i].containsPoint(x, y)) { return _slots[i].uid; }
        }
        return null;
    }

    public function getComplication(complication as ComplicationRef) as ComplicationDrawableRef or Null {
        var slot = slotFor(complication.uniqueIdentifier);
        if (slot == null) { return null; }
        _editingSlot = true;
        _selectedUid = slot.uid;
        WatchUi.requestUpdate();
        return new WatchUi.ComplicationDrawableRef({
            :drawable => slot,
            :boundingBox => slot.getBoundingBox()
        });
    }

    // ---- hold-to-launch (live face) ----

    //! Touch-and-hold (ClaudeGridDelegate.onPress): exit to the app behind whatever is under (x, y).
    //!  - a slot: the app that owns its complication - Claude Usage for a Claude meter, the watch's
    //!    own screen for a native field (weather, heart rate, stress, Body Battery...);
    //!  - the battery arc: whatever it is gauging - Data 01's field, or the system battery;
    //!  - the date or the weekday strip: the calendar (the native calendar-events complication).
    //! Returns false, leaving the hold to the system, anywhere else (the time, the brand), on a slot
    //! with no complication, and while Data 07 shows the seconds or Data 08 the time-zone clock:
    //! those are drawn by this face, so launching a complication hidden behind them would surprise.
    public function launchComplicationAt(x as Number, y as Number) as Boolean {
        var id = null;
        var uid = getTappedComplication(x, y);
        if (uid != null) {
            if ((uid == 8 && altTzActive()) || (uid == 7 && dialSecondsActive())) { return false; }
            id = (_fields[uid] != GridField.EDITOR) ? fieldLaunchId(_fields[uid]) : _slotIds[uid];
        } else if (inBatteryArc(x, y)) {
            id = arcComplicationId();
        } else if (inDateArea(x, y)) {
            id = new Complications.Id(Complications.COMPLICATION_TYPE_CALENDAR_EVENTS);
        }
        if (id == null) { return false; }
        try {
            Complications.exitTo(id as Complications.Id);
            return true;
        } catch (e) {
            // InvalidValueException: the id is not from a launchable app (e.g. its publisher was
            // uninstalled since the slot was set). Nothing to open, so let the system handle it.
            System.println("hold-to-launch: exitTo failed");
            return false;
        }
    }

    //! On the bezel battery arc: 16 dashes between 122.5 and 57.5 degrees (math angle, 90 = top),
    //! outer radius = the screen radius, 15 px long (onUpdate's segmentArc call). The band is
    //! widened to a finger's width, and to 50-130 degrees.
    private function inBatteryArc(x as Number, y as Number) as Boolean {
        var ds = System.getDeviceSettings();
        var cx = ds.screenWidth / 2.0;
        var cy = ds.screenHeight / 2.0;
        var dx = x - cx;
        var dy = cy - y;
        var dist = Math.sqrt(dx * dx + dy * dy);
        if (dist < cx - 40 || dist > cx + 4) { return false; }
        var deg = Math.toDegrees(Math.atan2(dy, dx));
        return deg >= 50.0 && deg <= 130.0;
    }

    //! The complication the battery arc is showing: Data 01's when the arc gauges it (battArcFrac),
    //! otherwise the system battery.
    private function arcComplicationId() as Complications.Id {
        if (_fields[1] != GridField.EDITOR) { return fieldLaunchId(_fields[1]); }
        var id = _slotIds[1];
        if (id != null) {
            var cid = id as Complications.Id;
            try {
                var comp = Complications.getComplication(cid);
                if (isPercentMetric(cid.getType(), comp.longLabel)) { return cid; }
            } catch (e) {
            }
        }
        return new Complications.Id(Complications.COMPLICATION_TYPE_BATTERY);
    }

    //! On the month / day flanking the dial (drawDate: each DATE_GAP from centre on the dial's row),
    //! or on the curved weekday strip along the bottom bezel (drawWeekCurved).
    private function inDateArea(x as Number, y as Number) as Boolean {
        var ds = System.getDeviceSettings();
        var cx = ds.screenWidth / 2;
        var h = ds.screenHeight;
        var dialY = (h * 0.832).toNumber();
        var off = (x > cx) ? (x - cx) : (cx - x);
        var dateRow = (y >= dialY - 26 && y <= dialY + 26) && off >= DIAL_CLEAR_R && off <= DATE_GAP + 44;
        var weekStrip = (y >= (h * 0.915).toNumber()) && off <= 120;
        return dateRow || weekStrip;
    }

    //! Re-read the slots whose drawing depends on more than their complication's value: current
    //! weather (its VALUE is the condition code, so the callback need not fire when only the
    //! temperatures move), battery (the icon also shows the charger, which has no callback) and
    //! the face-computed fields (no callback at all). Refreshing on wake keeps them current
    //! whenever the watch is looked at, for one system read per such slot.
    private function refreshLiveSlots() as Void {
        for (var i = 0; i < _slots.size(); i++) {
            var uid = _slots[i].uid;
            var id = _slotIds[uid];
            var t = (id != null) ? (id as Complications.Id).getType() : null;
            if (_fields[uid] != GridField.EDITOR
                    || t == Complications.COMPLICATION_TYPE_CURRENT_WEATHER
                    || t == Complications.COMPLICATION_TYPE_BATTERY) {
                updateSlotText(uid);
            }
        }
    }

    // ---- face-computed fields (GridField) ----

    //! Fill a slot with a face-computed field. Each gets an icon (the chips draw it; the text label
    //! is the no-icon fallback) and a 0..1 fill for the rings, the dial and the battery arc.
    //! Missing data (no weather synced yet) shows "--" with an empty gauge.
    private function fillField(slot as ClaudeGridSlot, field as Number) as Void {
        slot.valueTop = "";
        slot.valueBot = "";
        slot.forceFont = null;
        var icon = 0;
        var label = "";
        var value = "--";
        var frac = 0.0;
        if (field == GridField.BATT_DAYS) {
            label = "BAT";
            var st = System.getSystemStats();
            icon = batteryGlyph(st.battery);
            frac = st.battery / 100.0;
            if ((st has :batteryInDays) && st.batteryInDays != null) {
                value = Math.round(st.batteryInDays).toNumber().format("%d") + "D";
            }
        } else {
            // The weather fields read WeatherNow, like the current-weather slot: the observation,
            // or with the phone away the stored forecast hour, whose values get the "~" mark.
            var r = null;
            try { r = WeatherNow.get(); } catch (e) {}
            if (field == GridField.HUMIDITY) {
                icon = humidityGlyph(null);   // an empty droplet until there is a reading
                label = "HUM";
                if (r != null && r.humidity != null) {
                    var hum = r.humidity as Number;
                    value = wxMark(r, hum.format("%d") + "%");
                    frac = hum / 100.0;
                    icon = humidityGlyph(hum);
                }
            } else if (field == GridField.PRECIP) {
                icon = rainGlyph(null);   // a dry umbrella until there is a reading
                label = "RAIN";
                if (r != null && r.precipChance != null) {
                    var pc = r.precipChance as Number;
                    value = wxMark(r, pc.format("%d") + "%");
                    frac = pc / 100.0;
                    icon = rainGlyph(pc);
                }
            } else if (field == GridField.WIND) {
                icon = 0xec34;   // wind, until a bearing is known
                label = "WIND";
                if (r != null && r.windSpeed != null) {
                    var sp = windSpeed(r.windSpeed as Float);
                    // "SW 19 KM/H", as Garmin's weather glance writes it (plus the unit). A narrow
                    // slot's auto-fit drops the words without digits first - the unit, then the
                    // direction - so the speed always survives (ClaudeGridSlot.fitText). The "~"
                    // forecast mark rides on the speed ("SW ~19 KM/H") so it survives with it.
                    var statute = System.getDeviceSettings().distanceUnits == System.UNIT_STATUTE;
                    value = wxMark(r, sp.format("%d")) + (statute ? " MPH" : " KM/H");
                    frac = sp / 60.0;   // a 60 km/h (or mph) gale fills the gauge
                    if (r.windBearing != null) {
                        icon = windArrow(r.windBearing as Number);
                        value = windCompass(r.windBearing as Number) + " " + value;
                    }
                }
            }
        }
        slot.iconChar = (icon != 0) ? icon.toChar().toString() : "";
        slot.label = label;
        slot.value = value;
        slot.frac = (frac < 0.0) ? 0.0 : ((frac > 1.0) ? 1.0 : frac);
    }

    //! The humidity droplet filled to the reading: a flat water line in 20 % steps, rounded to the
    //! nearest (50% -> 60%, 49% -> 40%). 0xE010 is the empty droplet, 0xE015 the full one
    //! (garmin/shared/tools/solid_icons.py humidity). No reading -> empty.
    private function humidityGlyph(pct as Number or Null) as Number {
        if (pct == null) { return 0xE010; }
        var step = ((pct as Number) + 10) / 20;
        if (step < 0) { step = 0; }
        if (step > 5) { step = 5; }
        return 0xE010 + step;
    }

    //! The chance-of-rain umbrella with more drops the likelier the rain, in quarter steps: 0-12%
    //! dry, 13-37% one drop, 38-62% two, 63%+ three. 0xE020-0xE023 (solid_icons.rain_chance).
    private function rainGlyph(pct as Number or Null) as Number {
        if (pct == null) { return 0xE020; }
        var step = ((pct as Number) + 12) / 25;
        if (step < 0) { step = 0; }
        if (step > 3) { step = 3; }
        return 0xE020 + step;
    }

    //! The battery icon at its charge level, as Garmin draws its own: empty, 1-4 bars, or the
    //! charging glyph while on the charger. Quarter steps, rounded (12% empty, 13% one bar).
    //! A non-numeric value falls back to the system battery.
    private function batteryGlyph(pct as Complications.Value or Null) as Number {
        var st = System.getSystemStats();
        if ((st has :charging) && st.charging) { return 0xea33; }
        var p = st.battery.toFloat();
        if (pct instanceof Lang.Number || pct instanceof Lang.Float
                || pct instanceof Lang.Double || pct instanceof Lang.Long) {
            p = pct.toFloat();
        }
        if (p >= 87.5) { return 0xea32; }
        if (p >= 62.5) { return 0xea31; }
        if (p >= 37.5) { return 0xea30; }
        if (p >= 12.5) { return 0xea2f; }
        return 0xea34;
    }

    //! m/s from the Weather API -> whole km/h, or mph on a watch set to statute distances.
    private function windSpeed(ms as Float) as Number {
        var f = (System.getDeviceSettings().distanceUnits == System.UNIT_STATUTE) ? 2.23694 : 3.6;
        return Math.round(ms * f).toNumber();
    }

    //! The arrow glyph for the way the air is moving: windBearing is where the wind comes FROM, so
    //! the arrow points the opposite way (a south-west wind -> up-right), as Garmin's weather glance
    //! draws it. Eight directions, N first, clockwise.
    private function windArrow(bearing as Number) as Number {
        var arrows = [0xea25, 0xea24, 0xea1f, 0xea15, 0xea16, 0xea13, 0xea19, 0xea22];
        var toward = (bearing + 180) % 360;
        var idx = ((toward + 22) / 45) % 8;
        return arrows[idx] as Number;
    }

    //! The compass point the wind blows FROM, as weather reports name it (a "south-west wind" comes
    //! from the SW; its arrow points NE). Eight points, matching the eight arrows.
    private function windCompass(bearing as Number) as String {
        var names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];
        var idx = (((bearing % 360) + 360 + 22) % 360) / 45;
        return names[idx] as String;
    }

    //! What a hold on a face-computed field opens: the weather screen for the weather fields, the
    //! battery screen for battery days.
    private function fieldLaunchId(field as Number) as Complications.Id {
        if (field == GridField.BATT_DAYS) {
            return new Complications.Id(Complications.COMPLICATION_TYPE_BATTERY);
        }
        return new Complications.Id(Complications.COMPLICATION_TYPE_CURRENT_WEATHER);
    }

    // ---- drawing ----

    public function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var cy = h / 2;
        // Smooth the vector work (rings, battery-arc dashes, seconds ticks, curved weekday text);
        // CIQ leaves anti-aliasing OFF by default, which is what makes diagonals look jagged/blobby.
        if (dc has :setAntiAlias) { dc.setAntiAlias(true); }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        // Arc on the bezel: gauges Data 01's percentage (e.g. Claude Fable 55%), falling back to
        // the system battery when Data 01 isn't a 0-100 metric. Sweeps in with the rings on wake.
        GridDraw.segmentArc(dc, cx, cy, cx, 122.5, 57.5, 16, battArcFrac() * ringSweep, 10, 15, _fArc);

        // The editable slots (skip the one the editor is currently pulsing). Data 08 is
        // re-filled with the time-zone clock first when that's what it should show.
        refreshAltTz();
        for (var i = 0; i < _slots.size(); i++) {
            var slot = _slots[i];
            slot.sweep = ringSweep;
            slot.lowPower = _lowPower;
            if (_editingSlot && _selectedUid != null && slot.uid == _selectedUid) { continue; }
            if (slot.kind == SlotKind.DIAL) { continue; }   // Data 07: after the time, below
            slot.draw(dc);
        }

        // Anchor the time by its digit INK (TimeInk.DY, generated with the fonts), so the digits are
        // centred on TIME_Y whatever the typeface - exactly as the layout editor draws them.
        drawTime(dc, cx, (h * TIME_Y).toNumber() - TimeInk.DY);
        drawBrand(dc, cx, (h * 0.169).toNumber());
        drawIndicators(dc, w, h);

        var dialY = (h * 0.832).toNumber();
        // Iron Grit knockout: clear a black disc around the seconds dial (and, in always-on, the
        // stacked date that replaces it) so it cuts into the bottom of the minute digits with a
        // clean gap, instead of the digits running under the ticks. Drawn after the time and
        // before the dial/date, so only what's already on screen (the digits) is cut.
        knockDial(dc, cx, dialY);
        if (_lowPower) {
            drawDateCollapsed(dc, cx, dialY);
        } else {
            drawDial(dc);
            drawDate(dc, cx, dialY);
        }
        drawWeekCurved(dc, cx, cy, (h * 0.971).toNumber() - cy);

        // Full-face VFD mesh, LAST so it lies over every lit pixel (time, text, icons, rings, arc).
        // Skipped in always-on: the thin outline time + collapsed date would break up under it.
        if (!_lowPower) { drawMeshOverlay(dc, w, h); }
    }

    //! VFD build: tile the generated mesh (black grid lines at partial alpha) over the whole face.
    //! Tiles start at the screen origin and the tile size is a multiple of the 3 px pitch, so the
    //! grid is one continuous screen-aligned lattice - same phase on every element. Kept in the
    //! graphics pool after the first load.
    (:mesh_overlay)
    private var _meshTile = null;

    (:mesh_overlay)
    private function drawMeshOverlay(dc as Dc, w as Number, h as Number) as Void {
        if (_meshTile == null) {
            _meshTile = WatchUi.loadResource(Rez.Drawables.MeshTile);
        }
        var t = (_meshTile as Graphics.BitmapReference).getWidth();
        if (t <= 0) { return; }
        for (var y = 0; y < h; y += t) {
            for (var x = 0; x < w; x += t) {
                dc.drawBitmap(x, y, _meshTile);
            }
        }
    }

    //! Normal build: no mesh.
    (:plain_overlay)
    private function drawMeshOverlay(dc as Dc, w as Number, h as Number) as Void {
    }

    //! Stacked hours over minutes (no colon). Hour is solid; minute is a vertical Gradient 1->2.
    //! In always-on the digits switch to the hollow outline font.
    private function drawTime(dc as Dc, tx as Numeric, cy as Numeric) as Void {
        var clock = System.getClockTime();
        var hour = clock.hour;
        if (!System.getDeviceSettings().is24Hour) {
            hour = hour % 12;
            if (hour == 0) { hour = 12; }
        }
        // Glow builds draw the high-power time from pre-rendered bitmaps; always-on keeps the thin
        // outline font below (a lit bloom would defeat the AMOLED burn-in budget).
        if (!_lowPower && _fTime != null
                && drawGlowTime(dc, tx, cy, hour.format("%02d"), clock.min.format("%02d"))) {
            return;
        }
        var tf = _lowPower ? ((_fTimeO != null) ? _fTimeO : _fTime) : _fTime;
        if (tf == null) { tf = Graphics.FONT_NUMBER_THAI_HOT; }
        dc.setColor(HOUR_COL, Graphics.COLOR_TRANSPARENT);
        GridDraw.text(dc, tx, cy - TIME_GAP, tf, hour.format("%02d"),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        drawGradientText(dc, tx, cy + TIME_GAP, tf, clock.min.format("%02d"),
            GridDraw.GRAD_A, GridDraw.GRAD_B);
    }

    //! Bitmap time (option 4 - glow digits). Only compiled into the glow variants, which add
    //! source-glow/ + a resources-glow*/ folder and exclude the `font_time` annotation instead.
    (:glow_time)
    private function drawGlowTime(dc as Dc, tx as Numeric, cy as Numeric, hh as String,
                                  mm as String) as Boolean {
        var f = _fTime as Graphics.FontType;
        GlowTime.drawRow(dc, GridDraw.px(tx), GridDraw.px(cy) - TIME_GAP, f, hh, 0);
        GlowTime.drawRow(dc, GridDraw.px(tx), GridDraw.px(cy) + TIME_GAP, f, mm, 10);
        return true;
    }

    //! Normal build: no bitmap digits, so the caller falls through to the font path.
    (:font_time)
    private function drawGlowTime(dc as Dc, tx as Numeric, cy as Numeric, hh as String,
                                  mm as String) as Boolean {
        return false;
    }

    //! Draw `text` centred at (x, yc) with a top->bottom colour gradient, by re-drawing it inside
    //! a stack of horizontal clip bands. `fade` (0.44) keeps the top solid Gradient 1 and the
    //! bottom solid Gradient 2 with a soft transition between.
    private function drawGradientText(dc as Dc, x as Numeric, yc as Numeric, font as Graphics.FontType,
                                      text as String, cTop as Number, cBot as Number) as Void {
        var halfW = (dc.getTextWidthInPixels(text, font) / 2) + 8;
        var halfH = TIME_HALF_H;
        var bands = 12;
        var lo = 0.5 - 0.44 / 2.0;
        var hi = 0.5 + 0.44 / 2.0;
        var bandH = (2.0 * halfH) / bands;
        for (var i = 0; i < bands; i++) {
            var topF = yc - halfH + i * bandH;
            var f = (i + 0.5) / bands.toFloat();
            var t = 0.0;
            if (f <= lo) { t = 0.0; }
            else if (f >= hi) { t = 1.0; }
            else { t = (f - lo) / (hi - lo); }
            dc.setClip(x - halfW, topF.toNumber(), 2 * halfW, (bandH + 2).toNumber());
            dc.setColor(GridDraw.lerp(cTop, cBot, t), Graphics.COLOR_TRANSPARENT);
            GridDraw.text(dc, x, yc, font, text,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
        dc.clearClip();
    }

    private function drawBrand(dc as Dc, cx as Numeric, y as Numeric) as Void {
        dc.setColor(TEXT3, Graphics.COLOR_TRANSPARENT);
        var f = (_fBig != null) ? _fBig : Graphics.FONT_TINY;
        GridDraw.text(dc, cx, y, f, "TACTIX",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! Top-corner status icons. Alarm shows when alarms are set (the platform exposes alarm count);
    //! the stopwatch has no public "running" state, so its corner is left empty.
    private function drawIndicators(dc as Dc, w as Numeric, h as Numeric) as Void {
        if (_fIcon == null) { return; }
        var ds = System.getDeviceSettings();
        if (ds.alarmCount != null && ds.alarmCount > 0) {
            dc.setColor(TEXT3, Graphics.COLOR_TRANSPARENT);
            GridDraw.text(dc, (w * 0.166).toNumber(), (h * 0.169).toNumber(), _fIcon, _alarmChar,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    // ---- Data 08: editable slot that defaults to a second time zone ----

    //! Re-read the Data 08 settings (city + "always the clock"). Called on layout, on show, and by
    //! ClaudeGridApp.onSettingsChanged after a Garmin Connect save.
    public function readSettings() as Void {
        _altIndex = GridSettings.cityIndex();
        _altAlways = GridSettings.readAlways();
        _secAlways = GridSettings.readSecondsAlways();
        for (var uid = 1; uid <= 8; uid++) {
            _fields[uid] = GridSettings.fieldFor(uid);
        }
        // Same for Data 07 leaving seconds mode.
        if (!dialSecondsActive() && _slotIds[7] != null) {
            updateSlotText(7);
        }
        // A field setting may have changed: repopulate every slot (a field slot, or one handed
        // back to the editor's pick).
        for (var i = 0; i < _slots.size(); i++) {
            updateSlotText(_slots[i].uid);
        }
        // Leaving clock mode with a complication already picked: repopulate its icon/value now,
        // rather than waiting for its next change callback.
        if (!altTzActive() && _slotIds[8] != null) {
            updateSlotText(8);
        }
    }

    //! The clock shows when forced by the setting, or while no complication is picked for Data 08.
    private function altTzActive() as Boolean {
        return _altAlways || (_slotIds[8] == null && _fields[8] == GridField.EDITOR);
    }

    //! Data 07 is the live seconds dial when forced by the setting, or while no complication is
    //! picked for it.
    private function dialSecondsActive() as Boolean {
        return _secAlways || (_slotIds[7] == null && _fields[7] == GridField.EDITOR);
    }

    //! Put the time-zone clock into the Data 08 slot (the city code, e.g. "LDN", over HH:MM in the
    //! 30px font), or hand the slot back to auto-fit when a picked complication owns it. The code
    //! is drawn as the slot's text label, in the same place and colour as any other field's label.
    //! Because the clock lives IN the slot, the editor can select, pulse and reassign Data 08 like
    //! any other field.
    private function refreshAltTz() as Void {
        var slot = slotFor(8);
        if (slot == null) { return; }
        if (altTzActive()) {
            slot.iconChar = "";
            slot.label = AltTz.code(_altIndex);
            slot.valueTop = "";
            slot.valueBot = "";
            slot.value = AltTz.timeStr(_altIndex);
            slot.forceFont = _fMed;
        } else {
            slot.forceFont = null;
        }
    }

    //! Clear the dial's knockout disc to black (see onUpdate). Anti-aliased, so the cut edge
    //! through the minute digits is a smooth arc.
    private function knockDial(dc as Dc, cx as Numeric, cy as Numeric) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.fillCircle(cx, cy, DIAL_CLEAR_R);
    }

    //! Data 07, the bottom dial (ClaudeGridSlot draws both modes, so the editor can pulse it like
    //! any other slot). Skipped while the editor is pulsing it, as the other slots are.
    private function drawDial(dc as Dc) as Void {
        var dial = slotFor(7);
        if (dial == null) { return; }
        if (_editingSlot && _selectedUid != null && _selectedUid == 7) { return; }
        dial.secondsMode = dialSecondsActive();
        dial.sweep = ringSweep;
        dial.draw(dc);
    }

    //! Month and day flanking the seconds dial (high-power).
    private function drawDate(dc as Dc, cx as Numeric, y as Numeric) as Void {
        var info = Gregorian.info(Time.now(), Time.FORMAT_MEDIUM);
        dc.setColor(TEXT2, Graphics.COLOR_TRANSPARENT);
        var f = (_fBig != null) ? _fBig : Graphics.FONT_TINY;
        GridDraw.text(dc, cx - DATE_GAP, y, f, (info.month as String).toUpper(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        GridDraw.text(dc, cx + DATE_GAP, y, f, info.day.format("%d"),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! Always-on: the date collapses to a stacked day / month at the centre where the dial was.
    private function drawDateCollapsed(dc as Dc, cx as Numeric, y as Numeric) as Void {
        var info = Gregorian.info(Time.now(), Time.FORMAT_MEDIUM);
        dc.setColor(TEXT2, Graphics.COLOR_TRANSPARENT);
        var f = (_fMed != null) ? _fMed : Graphics.FONT_TINY;
        GridDraw.text(dc, cx, y - 16, f, info.day.format("%d"),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        GridDraw.text(dc, cx, y + 16, f, (info.month as String).toUpper(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! Weekday letters curved along the bottom bezel (52 deg span centred on the bottom), today
    //! accent. Each letter is rotated tangent to the arc with drawAngledText (vector font); if no
    //! vector font is available the bitmap letters are drawn upright as a fallback.
    private function drawWeekCurved(dc as Dc, cx as Numeric, cy as Numeric, r as Numeric) as Void {
        var letters = ["S", "M", "T", "W", "T", "F", "S"];
        var today = Gregorian.info(Time.now(), Time.FORMAT_SHORT).day_of_week; // 1=Sun..7=Sat
        var wf = (_fWeek != null) ? _fWeek : Graphics.FONT_XTINY;
        for (var i = 0; i < 7; i++) {
            var aDeg = 244.0 + (52.0 / 6.0) * i;              // math degrees, 270 = bottom
            var a = aDeg * Math.PI / 180.0;
            var x = GridDraw.px(cx + r * Math.cos(a));   // whole-pixel anchor (see GridDraw.text)
            var y = GridDraw.px(cy - r * Math.sin(a));
            dc.setColor((i == today - 1) ? _accentColor : TEXT3, Graphics.COLOR_TRANSPARENT);
            if (_fWeekVec != null) {
                // NOTE: on the real tactix 8, drawAngledText rotates OPPOSITE to the simulator;
                // (aDeg - 270) is what points the letters INWARD on-device (verified on-wrist).
                dc.drawAngledText(x, y, _fWeekVec, letters[i],
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER, aDeg - 270.0);
            } else {
                GridDraw.text(dc, x, y, wf, letters[i],
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            }
        }
    }

    //! Always-on: redraw only the seconds dial each second, clipped so it doesn't smear. Skipped in
    //! ambient mode where the dial is hidden, and when Data 07 gauges a picked field instead (its
    //! value changes arrive through onComplicationChange).
    public function onPartialUpdate(dc as Dc) as Void {
        if (_lowPower || !dialSecondsActive()) { return; }
        var w = dc.getWidth();
        var h = dc.getHeight();
        if (dc has :setAntiAlias) { dc.setAntiAlias(true); }
        var scx = w / 2;
        var scy = (h * 0.832).toNumber();
        var pad = DIAL_CLEAR_R + 1;
        dc.setClip(scx - pad, scy - pad, 2 * pad, 2 * pad);
        // The dial clears only its knockout DISC, not the whole clip square: the square's corners
        // hold minute-digit pixels outside the disc, which must survive a seconds-only refresh.
        drawDial(dc);
        drawMeshOverlay(dc, w, h);   // clipped to the dial, so only its tiles' overlap is touched
        dc.clearClip();
    }

    // ---- ring fill animation (sweeps in on wake) ----

    public function startSweep() as Void {
        if (_editMode) { ringSweep = 1.0; return; }
        try {
            ringSweep = 0.0;
            WatchUi.animate(self, :ringSweep, WatchUi.ANIM_TYPE_EASE_OUT, 0.0, 1.0, 0.7,
                method(:onSweepDone));
        } catch (ex) {
            ringSweep = 1.0;
            WatchUi.requestUpdate();
        }
    }

    public function onSweepDone() as Void {
        ringSweep = 1.0;
        WatchUi.requestUpdate();
    }

    public function onShow() as Void {
        readSettings();   // an on-watch settings edit lands here when the face comes back
        refreshLiveSlots();
        _lowPower = false;
        startSweep();
    }

    public function onExitSleep() as Void {
        refreshLiveSlots();
        _lowPower = false;
        startSweep();
    }

    public function onEnterSleep() as Void {
        _lowPower = true;
        WatchUi.cancelAllAnimations();
        ringSweep = 1.0;
        WatchUi.requestUpdate();
    }

    // ---- value helpers ----

    //! Fill fraction for the top arc: Data 01's reading when it's a 0-100 percentage (battery, the
    //! Claude usage meters, body battery, etc.), otherwise the system battery. Read fresh so the
    //! arc tracks the live value and matches the numeric readout below it.
    private function battArcFrac() as Float {
        if (_fields[1] != GridField.EDITOR) {
            var s1 = slotFor(1);
            if (s1 != null) { return s1.frac; }
        }
        var id = _slotIds[1];
        if (id != null) {
            var cid = id as Complications.Id;
            var comp = null;
            try { comp = Complications.getComplication(cid); } catch (e) {}
            if (comp != null && isPercentMetric(cid.getType(), comp.longLabel)) {
                try {
                    var v = comp.value;
                    if (v instanceof Lang.Number || v instanceof Lang.Float
                        || v instanceof Lang.Double || v instanceof Lang.Long) {
                        var f = v.toFloat() / 100.0;
                        if (f < 0.0) { f = 0.0; }
                        if (f > 1.0) { f = 1.0; }
                        return f;
                    }
                } catch (e) {
                }
            }
        }
        return System.getSystemStats().battery / 100.0;
    }

    //! Our own Claude usage meters. They are Connect IQ complications (type INVALID), but so is
    //! every other third-party one (e.g. Quote Glance), so INVALID alone must NOT mean "a Claude
    //! percentage" - the long label is what identifies ours ("Claude 5-hour usage", ...).
    //! That label text is part of garmin/CONTRACT.md (checked in CI by garmin/tools/check_contract.py).
    private function isClaudeMeter(longLabel as String or Null) as Boolean {
        return (longLabel != null) && ((longLabel as String).find("Claude") != null);
    }

    //! Types whose value is a 0-100 percentage, so the arc can gauge them directly.
    private function isPercentMetric(t as Complications.Type or Null, longLabel as String or Null) as Boolean {
        return t == Complications.COMPLICATION_TYPE_BATTERY
            || t == Complications.COMPLICATION_TYPE_BODY_BATTERY
            || t == Complications.COMPLICATION_TYPE_PULSE_OX
            || t == Complications.COMPLICATION_TYPE_STRESS
            || t == Complications.COMPLICATION_TYPE_SLEEP_SCORE
            || (t == Complications.COMPLICATION_TYPE_INVALID && isClaudeMeter(longLabel));
    }

    private function ringFrac(id as Complications.Id, v as Complications.Value or Null,
                              longLabel as String or Null) as Float {
        var t = id.getType();
        if (v != null && isPercentMetric(t, longLabel)) {
            var f = 0.0;
            if (v instanceof Lang.Float || v instanceof Lang.Double) {
                f = v.toFloat() / 100.0;
            } else if (v instanceof Lang.Number || v instanceof Lang.Long) {
                f = v.toFloat() / 100.0;
            }
            if (f < 0.0) { f = 0.0; }
            if (f > 1.0) { f = 1.0; }
            return f;
        }
        return 0.66;
    }

    //! Claude usage meters get a "%" suffix (their value is a bare 0-100 number).
    private function isPercentUsage(t as Complications.Type or Null, longLabel as String or Null) as Boolean {
        return (t == Complications.COMPLICATION_TYPE_INVALID) && isClaudeMeter(longLabel);
    }

    //! Split "29°/27°" (or "29° / 27°", "29 27") into its two readings, with ALL spaces removed:
    //! a stray space left on either side of the "/" is what staggered the stacked high/low lines.
    private function splitTwo(s as String) as Array<String>? {
        var sep = s.find("/");
        if (sep == null) { sep = s.find(" "); }
        if (sep == null) { return null; }
        var a = s.substring(0, sep);
        var b = s.substring(sep + 1, s.length());
        if ((a == null) || (b == null)) { return null; }
        a = noSpaces(a);
        b = noSpaces(b);
        if ((a.length() == 0) || (b.length() == 0)) {
            return null;
        }
        return [a, b];
    }

    private function noSpaces(s as String) as String {
        var chars = s.toCharArray();
        var out = "";
        for (var i = 0; i < chars.size(); i++) {
            if (chars[i] != ' ') { out += chars[i].toString(); }
        }
        return out;
    }

    //! Seconds since local midnight -> "HH:MM" (24 h) or "H:MM" (12 h). `fallback` is returned
    //! unchanged when the value isn't numeric (e.g. a firmware that already sends a string).
    private function clockFromSeconds(v as Complications.Value or Null, fallback as String) as String {
        if (!(v instanceof Lang.Number || v instanceof Lang.Float
              || v instanceof Lang.Double || v instanceof Lang.Long)) {
            return fallback;
        }
        var secs = v.toNumber();
        if (secs < 0) { return fallback; }
        var h = (secs / 3600) % 24;
        var m = (secs % 3600) / 60;
        if (System.getDeviceSettings().is24Hour) {
            return h.format("%02d") + ":" + m.format("%02d");
        }
        var h12 = h % 12;
        if (h12 == 0) { h12 = 12; }
        return h12.format("%d") + ":" + m.format("%02d");
    }

    //! Training status as a fixed short code (a corner fits ~6 characters; the full words are
    //! 7-12). Matched by keyword on the upper-cased value, UNPRODUCTIVE before PRODUCTIVE since it
    //! contains it. Anything unrecognised passes through unchanged (the slot then fits it).
    private function trainingCode(s as String) as String {
        if (s.find("UNPROD") != null) { return "UNPROD"; }
        if (s.find("PRODUCT") != null) { return "PROD"; }
        if (s.find("MAINTAIN") != null) { return "MAINT"; }
        if (s.find("RECOVER") != null) { return "RECOV"; }
        if (s.find("DETRAIN") != null) { return "DETRN"; }
        if (s.find("OVERREACH") != null) { return "OVRRCH"; }
        if (s.find("PEAK") != null) { return "PEAK"; }
        if (s.find("STRAIN") != null) { return "STRAIN"; }
        if (s.find("NO STATUS") != null || s.find("NONE") != null) { return "--"; }
        return s;
    }

    //! Append the degree sign to a numeric reading (idempotent: an existing ° is not doubled).
    private function withDegree(s as String) as String {
        if (s.equals("") || s.equals("--") || s.find("°") != null) { return s; }
        return s + "°";
    }

    //! [icon, value, feels] for current weather, from WeatherNow (garmin/shared/source-weather):
    //! the live temperature and the feels-like temperature (wind chill / heat index), both
    //! converted to the watch's unit, and an icon for the actual condition, sun or moon variant by
    //! whether it's currently between sunrise and sunset at that location. `feels` is "" when not
    //! reported. Once the observation is stale (phone away) the reading is the stored forecast for
    //! the current hour: its temperature is marked "~31°" and it has no feels-like.
    private function currentWeather() as Array<String> {
        try {
            var r = WeatherNow.get();
            if (r == null) { return ["", "--", ""]; }
            var val = "--";
            if (r.temperature != null) {
                val = wxMark(r, tempStr(r.temperature as Numeric));
            }
            var feels = "";
            if (r.feelsLike != null) {
                feels = tempStr(r.feelsLike as Numeric);
            }
            var icon = "";
            if (r.condition != null) {
                icon = weatherGlyph(r.condition as Number, isNight(r.location)).toChar().toString();
            }
            return [icon, val, feels];
        } catch (ex) {
            return ["", "--", ""];
        }
    }

    //! A weather value as drawn: "~" in front when it comes from the hourly forecast rather than an
    //! observation (WeatherNow's offline fallback), so a forecast never passes for a measurement.
    private function wxMark(r as WeatherNow.Reading, s as String) as String {
        return r.forecast ? "~" + s : s;
    }

    //! A Celsius reading from the Weather API -> "32°" in the watch's temperature unit, rounded.
    private function tempStr(celsius as Numeric) as String {
        var tv = celsius.toFloat();
        if (System.getDeviceSettings().temperatureUnits == System.UNIT_STATUTE) {
            tv = tv * 9.0 / 5.0 + 32.0;
        }
        return Math.round(tv).toNumber().format("%d") + "°";
    }

    //! True between local sunset and the next sunrise at the observation location. Unknown
    //! location or sun times -> daytime (the sun icons are the safer default).
    private function isNight(loc as Position.Location or Null) as Boolean {
        if (loc == null) { return false; }
        var now = Time.now();
        var rise = Weather.getSunrise(loc, now);
        var set = Weather.getSunset(loc, now);
        if (rise == null || set == null) { return false; }
        return now.lessThan(rise) || now.greaterThan(set);
    }

    private function valStr(v as Complications.Value or Null) as String {
        if (v == null) { return "--"; }
        if (v instanceof Lang.Float || v instanceof Lang.Double) {
            return v.format("%.0f");
        }
        return v.toString();
    }

    private function defaultLabel(uid as Number) as String {
        if (uid == 1) { return "BAT"; }
        if (uid == 2) { return ""; }
        if (uid == 3) { return "ST"; }
        if (uid == 4) { return "HR"; }
        if (uid == 5) { return "BB"; }
        if (uid == 8) { return "TZ"; }
        return "WX";
    }

    private function iconCharFor(t as Complications.Type or Null) as String {
        var cp = iconCodeFor(t);
        if (cp == 0) { return ""; }
        return cp.toChar().toString();
    }

    //! Complication type -> Tabler codepoint (0 = no icon, falls back to a text label). Only glyphs
    //! present in cg_icon are returned; VO2 / pressure / temperature use their text label instead
    //! (matching the editor's "no icon" treatment).
    private function iconCodeFor(t as Complications.Type or Null) as Number {
        if (t == null) { return 0; }
        if (t == Complications.COMPLICATION_TYPE_BATTERY) { return 0xea34; }
        // footprints: re-filed from U+10265 to 0xE000 in cg_icon (CIQ glyph codes are 16-bit)
        if (t == Complications.COMPLICATION_TYPE_STEPS) { return 0xE000; }
        if (t == Complications.COMPLICATION_TYPE_HEART_RATE) { return 0xef92; }
        if (t == Complications.COMPLICATION_TYPE_BODY_BATTERY) { return 0xea38; }
        if (t == Complications.COMPLICATION_TYPE_CALORIES) { return 0xec2c; }
        if (t == Complications.COMPLICATION_TYPE_FLOORS_CLIMBED) { return 0xeca5; }
        if (t == Complications.COMPLICATION_TYPE_ALTITUDE) { return 0xef97; }
        if (t == Complications.COMPLICATION_TYPE_STRESS) { return 0xf0db; }
        if (t == Complications.COMPLICATION_TYPE_PULSE_OX) { return 0xea97; }
        if (t == Complications.COMPLICATION_TYPE_INTENSITY_MINUTES) { return 0xff9b; }
        if (t == Complications.COMPLICATION_TYPE_NOTIFICATION_COUNT) { return 0xea35; }
        if (t == Complications.COMPLICATION_TYPE_SUNRISE) { return 0xef1c; }
        if (t == Complications.COMPLICATION_TYPE_SUNSET) { return 0xec31; }
        if (t == Complications.COMPLICATION_TYPE_CURRENT_WEATHER
         || t == Complications.COMPLICATION_TYPE_FORECAST_WEATHER_1DAY
         || t == Complications.COMPLICATION_TYPE_FORECAST_WEATHER_2DAY
         || t == Complications.COMPLICATION_TYPE_FORECAST_WEATHER_3DAY) {
            // Current weather's icon is set live in updateSlotText. Forecasts get NO icon rather
            // than today's condition, which would mislabel a forecast; they show their own label.
            return 0;
        }
        if (t == Complications.COMPLICATION_TYPE_RESPIRATION_RATE) { return 0xef62; }  // lungs
        // Icons instead of long labels ("VO2 MAX RUN", "TRAINING STATUS") that can't fit a corner.
        if (t == Complications.COMPLICATION_TYPE_VO2MAX_RUN) { return 0xec82; }        // runner
        if (t == Complications.COMPLICATION_TYPE_VO2MAX_BIKE) { return 0xea36; }       // bike
        if (t == Complications.COMPLICATION_TYPE_TRAINING_STATUS) { return 0xeb43; }   // trending-up
        if (t == Complications.COMPLICATION_TYPE_CURRENT_TEMPERATURE) { return 0xeb38; } // thermometer
        if (t == Complications.COMPLICATION_TYPE_SLEEP_SCORE) { return 0xeaf8; }
        if (t == Complications.COMPLICATION_TYPE_RECOVERY_TIME) { return 0xf228; }
        if (t == Complications.COMPLICATION_TYPE_SOLAR_INPUT) { return 0xeb30; }
        return 0;
    }

    //! Weather condition -> icon glyph in cg_icon: the solid, Garmin-style weather set at
    //! 0xE001-0xE00A, built by garmin/shared/tools/weather_icons.py (codes = its CODES table).
    //! `night` swaps the sun for the moon on the clear and partly-cloudy icons.
    private function weatherGlyph(c as Number, night as Boolean) as Number {
        if (c == Weather.CONDITION_CLEAR || c == Weather.CONDITION_FAIR
         || c == Weather.CONDITION_MOSTLY_CLEAR) {
            return night ? 0xE004 : 0xE003;                      // moon / sun
        }
        if (c == Weather.CONDITION_PARTLY_CLOUDY || c == Weather.CONDITION_PARTLY_CLEAR
         || c == Weather.CONDITION_THIN_CLOUDS) {
            return night ? 0xE002 : 0xE001;                      // cloud+moon / cloud+sun
        }
        if (c == Weather.CONDITION_THUNDERSTORMS || c == Weather.CONDITION_SCATTERED_THUNDERSTORMS
         || c == Weather.CONDITION_CHANCE_OF_THUNDERSTORMS || c == Weather.CONDITION_HURRICANE
         || c == Weather.CONDITION_TROPICAL_STORM || c == Weather.CONDITION_TORNADO) {
            return 0xE008;
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
            return 0xE007;
        }
        if (c == Weather.CONDITION_RAIN || c == Weather.CONDITION_LIGHT_RAIN
         || c == Weather.CONDITION_HEAVY_RAIN || c == Weather.CONDITION_SHOWERS
         || c == Weather.CONDITION_LIGHT_SHOWERS || c == Weather.CONDITION_HEAVY_SHOWERS
         || c == Weather.CONDITION_SCATTERED_SHOWERS || c == Weather.CONDITION_CHANCE_OF_SHOWERS
         || c == Weather.CONDITION_DRIZZLE || c == Weather.CONDITION_CLOUDY_CHANCE_OF_RAIN
         || c == Weather.CONDITION_UNKNOWN_PRECIPITATION) {
            return 0xE006;
        }
        if (c == Weather.CONDITION_FOG || c == Weather.CONDITION_HAZY || c == Weather.CONDITION_HAZE
         || c == Weather.CONDITION_MIST || c == Weather.CONDITION_SMOKE || c == Weather.CONDITION_DUST
         || c == Weather.CONDITION_SAND || c == Weather.CONDITION_SANDSTORM
         || c == Weather.CONDITION_VOLCANIC_ASH) {
            return 0xE009;
        }
        if (c == Weather.CONDITION_WINDY || c == Weather.CONDITION_SQUALL) {
            return 0xE00A;
        }
        return 0xE005; // cloud: MOSTLY_CLOUDY, CLOUDY (overcast) and anything unknown
    }
}
