import Toybox.Application;
import Toybox.Application.Storage;
import Toybox.Background;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.Weather;
import Toybox.WatchUi;

//! HKO (Hong Kong Observatory) weather for the faces: the foreground half of HkoService.
//!
//! The background service hands each run's results to the face (AppBase.onBackgroundData), which
//! passes them to merge(); they are kept in Storage under "hko" so they survive the face being
//! swapped out. WeatherNow.get() asks reading() first and falls back to Garmin's weather when it
//! returns null - HKO switched off, no reading for the chosen station yet, or the reading too old
//! (phone away, or out of Hong Kong with no data coming).
//!
//! What HKO supplies, and how old each part may be before it is ignored:
//!   temperature, humidity, wind   the station's minute readings           READING_MAX_AGE (75 min)
//!                                 (on a watch the minute CSVs fail, so the temperature and
//!                                 humidity come from the hourly report; see HkoService)
//!   condition icon                the hourly report's icon                ICON_MAX_AGE (3 h)
//!   warnings                      the warnings in force                   WARN_MAX_AGE (2 h)
//! The chance of rain has no HKO equivalent (HKO forecasts it per day, in words), so it stays
//! Garmin's. The feels-like temperature is computed from HKO's own temperature, humidity and wind
//! (heat index / wind chill, the same quantities Garmin's feels-like is), so the pair on the face
//! always comes from one source. HKO readings are observations: never marked "~".
module Hko {

    //! Fetch interval. HKO's minute feeds would allow less, but each run costs a phone round-trip
    //! and ~5 requests; 10 minutes keeps the reading well inside READING_MAX_AGE.
    const PERIOD_SEC = 600;
    //! A temperature / humidity / wind reading older than this is ignored. Covers several missed
    //! runs, and the hourly rhrread temperature used when the minute feed can't be read.
    const READING_MAX_AGE = 4500;     // 75 min
    const ICON_MAX_AGE = 10800;       // 3 h: the icon is updated about hourly
    //! Warnings not re-read for this long are not shown: a signal may have been lowered since.
    const WARN_MAX_AGE = 7200;        // 2 h

    var _data as Dictionary or Null = null;
    var _loaded as Boolean = false;

    //! The stored results (lazily read from Storage once per face run).
    function data() as Dictionary or Null {
        if (!_loaded) {
            _loaded = true;
            var v = Storage.getValue("hko");
            _data = (v instanceof Dictionary) ? v as Dictionary : null;
        }
        return _data;
    }

    //! Fold one background run's results into the store. A run for a different station than the
    //! stored one starts afresh; otherwise its keys overwrite the stored ones, and keys a failed
    //! request left out keep their previous (timestamped) values. Error codes are per run: the
    //! previous run's e1..e5 are dropped.
    function merge(incoming) as Void {
        if (!(incoming instanceof Dictionary)) {
            return;
        }
        var inc = incoming as Dictionary;
        var cur = data();
        var same = cur != null && inc["st"] instanceof Number && cur["st"] instanceof Number
                   && (inc["st"] as Number) == (cur["st"] as Number);
        if (!same) {
            cur = {};
        }
        for (var k = 1; k <= 5; k++) {
            cur.remove("e" + k.toString());
        }
        var keys = inc.keys();
        for (var k = 0; k < keys.size(); k++) {
            cur[keys[k]] = inc[keys[k]];
        }
        _data = cur;
        Storage.setValue("hko", cur);
    }

    //! Register (or cancel) the 10-minute background fetch to match the HkoStation setting. Called
    //! when the face starts and whenever the setting changes.
    function schedule() as Void {
        if (!(Toybox has :Background)) {
            return;
        }
        try {
            if (HkoStations.selected() > 0) {
                Background.registerForTemporalEvent(new Time.Duration(PERIOD_SEC));
            } else {
                Background.deleteTemporalEvent();
            }
        } catch (e) {
            System.println("hko: schedule failed");
        }
    }

    //! The stored data if it is for the selected station, else null.
    function current() as Dictionary or Null {
        var id = HkoStations.selected();
        if (id <= 0) {
            return null;
        }
        var d = data();
        if (d == null || !(d["st"] instanceof Number) || (d["st"] as Number) != id) {
            return null;
        }
        return d;
    }

    //! The value under `key` if its timestamp (under `tkey`) is within `maxAge` of `now`.
    function fresh(d as Dictionary, key as String, tkey as String, now as Number, maxAge as Number) {
        var t = d[tkey];
        if (!(t instanceof Number) || now - (t as Number) > maxAge) {
            return null;
        }
        return d[key];
    }

    //! The reading to show, or null to use Garmin's. `cc` is Garmin's current conditions (for the
    //! chance of rain, and for any part HKO can't supply right now).
    function reading(cc as Weather.CurrentConditions or Null) as WeatherNow.Reading or Null {
        var d = current();
        if (d == null) {
            return null;
        }
        var now = Time.now().value();
        var t = fresh(d, "t", "tt", now, READING_MAX_AGE);
        if (!(t instanceof Float || t instanceof Number)) {
            return null;
        }
        var r = new WeatherNow.Reading();
        r.temperature = t.toFloat();

        var h = fresh(d, "h", "ht", now, READING_MAX_AGE);
        r.humidity = (h instanceof Number) ? h as Number : ((cc != null) ? cc.relativeHumidity : null);

        var ws = fresh(d, "ws", "wt", now, READING_MAX_AGE);
        var windKmh = null;
        if (ws instanceof Number) {
            windKmh = ws as Number;
            r.windSpeed = windKmh / 3.6;          // the Reading holds m/s, like the Weather API
            var wd = d["wd"];
            r.windBearing = (wd instanceof Number) ? wd as Number : null;
        } else if (cc != null) {
            r.windSpeed = cc.windSpeed;
            r.windBearing = cc.windBearing;
        }

        var icon = fresh(d, "i", "it", now, ICON_MAX_AGE);
        var cond = (icon instanceof Number) ? condition(icon as Number) : null;
        r.condition = (cond != null) ? cond : ((cc != null) ? cc.condition : null);

        r.precipChance = (cc != null) ? cc.precipitationChance : null;
        r.feelsLike = feelsLike(r.temperature as Float, (h instanceof Number) ? h as Number : null, windKmh);
        return r;
    }

    //! HKO weather icon (https://www.hko.gov.hk/textonly/v2/explain/wxicon_e.htm) -> the nearest
    //! Weather.CONDITION_*, which the faces turn into their own glyphs. The icons that describe no
    //! sky - Dry 81, Humid 82, Hot 90, Warm 91, Cool 92, Cold 93 - give null, so the face keeps
    //! Garmin's condition for the picture. The night-only icons (70-77) map to their daytime
    //! equivalent; the faces pick the moon themselves (WeatherNow.isNight).
    function condition(icon as Number) as Number or Null {
        if (icon == 50) { return Weather.CONDITION_CLEAR; }                 // Sunny
        if (icon == 51 || icon == 52) { return Weather.CONDITION_PARTLY_CLOUDY; } // Sunny Periods / Intervals
        if (icon == 53) { return Weather.CONDITION_SCATTERED_SHOWERS; }     // Sunny Periods with A Few Showers
        if (icon == 54) { return Weather.CONDITION_SHOWERS; }               // Sunny Intervals with Showers
        if (icon == 60 || icon == 61) { return Weather.CONDITION_CLOUDY; }  // Cloudy / Overcast
        if (icon == 62) { return Weather.CONDITION_LIGHT_RAIN; }
        if (icon == 63) { return Weather.CONDITION_RAIN; }
        if (icon == 64) { return Weather.CONDITION_HEAVY_RAIN; }
        if (icon == 65) { return Weather.CONDITION_THUNDERSTORMS; }
        if (icon >= 70 && icon <= 75) { return Weather.CONDITION_CLEAR; }   // Fine (moon phases)
        if (icon == 76) { return Weather.CONDITION_PARTLY_CLOUDY; }         // Mainly Cloudy (night)
        if (icon == 77) { return Weather.CONDITION_MOSTLY_CLEAR; }          // Mainly Fine (night)
        if (icon == 80) { return Weather.CONDITION_WINDY; }
        if (icon == 83) { return Weather.CONDITION_FOG; }
        if (icon == 84) { return Weather.CONDITION_MIST; }
        if (icon == 85) { return Weather.CONDITION_HAZE; }
        return null;
    }

    //! Feels-like, Celsius: the US NWS heat index (Rothfusz regression, with its low- and
    //! high-humidity adjustments) from 26.7 °C (80 °F) up, wind chill (Environment Canada / NWS
    //! 2001) at 10 °C and below in a wind over 4.8 km/h, otherwise the air temperature. The heat
    //! index needs the humidity: without it, null (no FL shown) rather than a guess.
    function feelsLike(tc as Float, rh as Number or Null, windKmh as Number or Null) as Float or Null {
        if (tc <= 10.0 && windKmh != null && windKmh > 4.8) {
            var v = Math.pow(windKmh.toFloat(), 0.16);
            return 13.12 + 0.6215 * tc - 11.37 * v + 0.3965 * tc * v;
        }
        if (tc < 26.7) {
            return tc;
        }
        if (rh == null) {
            return null;
        }
        var f = tc * 9.0 / 5.0 + 32.0;
        var r = rh.toFloat();
        var hi = -42.379 + 2.04901523 * f + 10.14333127 * r - 0.22475541 * f * r
                 - 0.00683783 * f * f - 0.05481717 * r * r + 0.00122874 * f * f * r
                 + 0.00085282 * f * r * r - 0.00000199 * f * f * r * r;
        if (r < 13.0 && f <= 112.0) {
            var dev = f - 95.0;
            if (dev < 0) { dev = -dev; }
            hi -= ((13.0 - r) / 4.0) * Math.sqrt((17.0 - dev) / 17.0);
        } else if (r > 85.0 && f <= 87.0) {
            hi += ((r - 85.0) / 10.0) * ((87.0 - f) / 5.0);
        }
        return ((hi - 32.0) * 5.0 / 9.0).toFloat();
    }

    // ---- warnings ----

    //! Warnings in priority order (most serious first): [HKO code, label, severity]. Severity:
    //! 2 = red (danger to life - typhoon 8+, red / black rain, tsunami, landslip), 1 = amber,
    //! 0 = yellow (standby / advisory). Labels are upper case and at most 11 characters so they
    //! fit Claude Grid's brand line in its bitmap font (which has no lower case).
    const ALERTS = [
        ["TC10", "T10", 2], ["TC9", "T9", 2],
        ["TC8NE", "T8 NE", 2], ["TC8SE", "T8 SE", 2], ["TC8SW", "T8 SW", 2], ["TC8NW", "T8 NW", 2],
        ["WRAINB", "BLACK RAIN", 2], ["WRAINR", "RED RAIN", 2], ["WTMW", "TSUNAMI", 2], ["WL", "LANDSLIP", 2],
        ["TC3", "T3", 1], ["WRAINA", "AMBER RAIN", 1], ["WFNTSA", "NT FLOOD", 1], ["WTS", "THUNDER", 1],
        ["WMSGNL", "MONSOON", 1], ["WHOT", "VERY HOT", 1], ["WCOLD", "COLD", 1], ["WFIRER", "RED FIRE", 1],
        ["TC1", "T1", 0], ["WFROST", "FROST", 0], ["WFIREY", "YELLOW FIRE", 0]
    ] as Array<Array>;

    //! The most serious warning in force, as [label, severity, others], where `others` counts the
    //! further warnings in force (the faces add "+1"); or null when there is none, HKO is off, or
    //! the list is older than WARN_MAX_AGE. An unknown code (one HKO adds later) counts as
    //! `others` only.
    function alert() as Array or Null {
        var d = current();
        if (d == null) {
            return null;
        }
        var wf = d["wf"];
        var codes = d["w"];
        if (!(wf instanceof Number) || Time.now().value() - (wf as Number) > WARN_MAX_AGE
                || !(codes instanceof Array) || (codes as Array).size() == 0) {
            return null;
        }
        var list = codes as Array;
        for (var k = 0; k < ALERTS.size(); k++) {
            var a = ALERTS[k] as Array;
            for (var j = 0; j < list.size(); j++) {
                if ((a[0] as String).equals(list[j])) {
                    return [a[1], a[2], list.size() - 1];
                }
            }
        }
        return null;
    }

    //! "VERY HOT" or "VERY HOT +1".
    function alertText(a as Array) as String {
        var more = a[2] as Number;
        return (more > 0) ? (a[0] as String) + " +" + more.toString() : a[0] as String;
    }

    // ---- the station setting (on-watch menu) ----

    //! The selected station's name, for a settings row.
    function stationName() as String {
        var id = HkoStations.selected();
        var ids = HkoNames.IDS;
        for (var k = 0; k < ids.size(); k++) {
            if (ids[k] == id) {
                return WatchUi.loadResource(HkoNames.names()[k]) as String;
            }
        }
        return "";
    }

    //! The settings row's sub-label: the station, and how the last fetch went - the time of the
    //! temperature reading on the face, or the failing response code (e.g. -104: no phone).
    function menuSub() as String {
        var name = stationName();
        var d = current();
        if (d == null) {
            return name;
        }
        var e1 = d["e1"];
        if (e1 instanceof Number && d["t"] == null) {
            return name + " - err " + (e1 as Number).toString();
        }
        var tt = d["tt"];
        if (tt instanceof Number) {
            var info = Gregorian.info(new Time.Moment(tt as Number), Time.FORMAT_SHORT);
            return name + " - " + info.hour.format("%02d") + ":" + info.min.format("%02d");
        }
        return name;
    }
}

//! The station picker: "Off" then the stations A-Z, the current one focused. Selecting one saves
//! the setting, reschedules the fetch and refreshes the parent row (`rowId` in `parent`).
class HkoStationMenu extends WatchUi.Menu2 {

    public function initialize() {
        var cur = HkoStations.selected();
        var ids = HkoNames.IDS;
        var focus = 0;
        for (var k = 0; k < ids.size(); k++) {
            if (ids[k] == cur) { focus = k; }
        }
        Menu2.initialize({ :title => Rez.Strings.hkoStationTitle, :focus => focus });
        var names = HkoNames.names();
        for (var k = 0; k < ids.size(); k++) {
            addItem(new WatchUi.MenuItem(names[k], null, ids[k], null));
        }
    }
}

class HkoStationDelegate extends WatchUi.Menu2InputDelegate {

    private var _parent as WatchUi.Menu2;
    private var _rowId as Object;

    public function initialize(parent as WatchUi.Menu2, rowId as Object) {
        Menu2InputDelegate.initialize();
        _parent = parent;
        _rowId = rowId;
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        Application.Properties.setValue("HkoStation", item.getId() as Number);
        Hko.schedule();
        var pos = _parent.findItemById(_rowId);
        if (pos >= 0) {
            var row = _parent.getItem(pos);
            if (row != null) { row.setSubLabel(Hko.menuSub()); }
        }
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
