import Toybox.Application;
import Toybox.Background;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;

//! The HKO (Hong Kong Observatory) fetch: each face's background service, woken every 10 minutes
//! (Hko.schedule). Like every Connect IQ web request it goes through Garmin Connect on the phone;
//! with the phone away the requests fail at once (-104) and the face falls back to Garmin weather.
//!
//! One run makes five requests, one after another (a background run has 30 s and ~64 KB, so they
//! are chained, never in flight together), for the station the HkoStation setting names:
//!
//!   1  latest_1min_temperature.csv   the station's temperature          -> t  (tt = reading time)
//!   2  latest_1min_humidity.csv      its (or the nearest) humidity      -> h  (ht)
//!   3  latest_10min_wind.csv         its (or the nearest) mean wind     -> ws km/h, wd deg, wg (wt)
//!   4  rhrread (JSON, hourly)        HKO's weather icon                 -> i  (it); and the
//!                                    temperature again if request 1 failed (hourly, by name)
//!   5  warnsum (JSON)                warnings in force                  -> w  (codes), wf (fetch time)
//!
//! A failed request just leaves its keys out: Hko.merge keeps the previous values, each with its
//! own timestamp, and the face ignores whatever has aged out. Response codes that were not 200 are
//! reported as e1..e5 (for the on-watch settings row, which shows the last fetch's outcome).
//!
//! The CSVs are read as text: they are ~1 KB each ("YYYYMMDDhhmm,Station,value[,value...]" per
//! line, HKT timestamps, no BOM, "\n" line ends), and only the one line wanted is copied out.
(:background)
class HkoService extends System.ServiceDelegate {

    private const CSV_BASE = "https://data.weather.gov.hk/weatherAPI/hko_data/regional-weather/";
    private const API_BASE = "https://data.weather.gov.hk/weatherAPI/opendata/weather.php";
    //! HKO publishes every time in Hong Kong Time, UTC+8 (no daylight saving).
    private const HKT_OFFSET = 28800;

    private var _id as Number = 0;
    private var _step as Number = 0;
    private var _out as Dictionary<String, Application.PropertyValueType> = {};

    public function initialize() {
        ServiceDelegate.initialize();
    }

    public function onTemporalEvent() as Void {
        _id = HkoStations.selected();
        if (_id <= 0) {
            Background.exit(null);   // HKO switched off since the event was registered
            return;
        }
        _out = { "st" => _id, "ts" => Time.now().value() };
        _step = 0;
        next();
    }

    //! Issue the next request of the chain, or hand the results to the face after the last one.
    private function next() as Void {
        _step += 1;
        if (_step == 1) {
            request(CSV_BASE + "latest_1min_temperature.csv", null, false, method(:onTemperature));
        } else if (_step == 2) {
            request(CSV_BASE + "latest_1min_humidity.csv", null, false, method(:onHumidity));
        } else if (_step == 3) {
            request(CSV_BASE + "latest_10min_wind.csv", null, false, method(:onWind));
        } else if (_step == 4) {
            request(API_BASE, { "dataType" => "rhrread", "lang" => "en" }, true, method(:onReport));
        } else if (_step == 5) {
            request(API_BASE, { "dataType" => "warnsum", "lang" => "en" }, true, method(:onWarnings));
        } else {
            Background.exit(_out);
        }
    }

    private function request(url as String, params as Dictionary?, json as Boolean, cb as Method) as Void {
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => json ? Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
                                  : Communications.HTTP_RESPONSE_CONTENT_TYPE_TEXT_PLAIN
        };
        try {
            Communications.makeWebRequest(url, params, options, cb);
        } catch (e) {
            // Should not happen (the arguments are fixed); skip this request rather than stall.
            _out["e" + _step.toString()] = -1;
            next();
        }
    }

    //! Record a non-200 response for step `_step`. Returns true when the response is usable.
    private function ok(code as Number) as Boolean {
        if (code == 200) {
            return true;
        }
        _out["e" + _step.toString()] = code;
        return false;
    }

    // ---- 1-3: the regional CSVs ----

    public function onTemperature(code as Number, data) as Void {
        if (ok(code)) {
            var row = csvRow(data, HkoStations.TEMP[_id]);
            if (row != null && row.size() >= 2) {
                var v = (row[1] as String).toFloat();
                if (v != null) {
                    _out["t"] = v;
                    _out["tt"] = row[0];
                }
            }
        }
        next();
    }

    public function onHumidity(code as Number, data) as Void {
        if (ok(code)) {
            var row = csvRow(data, HkoStations.HUM[_id]);
            if (row != null && row.size() >= 2) {
                var v = (row[1] as String).toNumber();
                if (v != null && v >= 0 && v <= 100) {
                    _out["h"] = v;
                    _out["ht"] = row[0];
                }
            }
        }
        next();
    }

    //! "YYYYMMDDhhmm,Station,<direction word>,<mean km/h>,<gust km/h>". A calm or variable wind has
    //! a speed but no bearing; "N/A" in the speed means the station isn't reporting.
    public function onWind(code as Number, data) as Void {
        if (ok(code)) {
            var row = csvRow(data, HkoStations.WIND[_id]);
            if (row != null && row.size() >= 3) {
                var speed = (row[2] as String).toNumber();
                if (speed != null) {
                    _out["ws"] = speed;
                    _out["wt"] = row[0];
                    var bearing = compass(row[1] as String);
                    if (bearing != null) {
                        _out["wd"] = bearing;
                    }
                    if (row.size() >= 4) {
                        var gust = (row[3] as String).toNumber();
                        if (gust != null) {
                            _out["wg"] = gust;
                        }
                    }
                }
            }
        }
        next();
    }

    // ---- 4: the hourly report - the icon, and the temperature if the minute feed failed ----

    public function onReport(code as Number, data) as Void {
        if (ok(code) && data instanceof Dictionary) {
            var d = data as Dictionary;
            var icons = d["icon"];
            if (icons instanceof Array && (icons as Array).size() > 0 && (icons as Array)[0] instanceof Number) {
                _out["i"] = (icons as Array)[0] as Number;
                var it = isoEpoch(d["iconUpdateTime"]);
                if (it != null) {
                    _out["it"] = it;
                }
            }
            var name = HkoStations.RHR[_id];
            if (_out["t"] == null && !name.equals("")) {
                var temp = d["temperature"];
                if (temp instanceof Dictionary) {
                    var rows = (temp as Dictionary)["data"];
                    var when = isoEpoch((temp as Dictionary)["recordTime"]);
                    if (rows instanceof Array && when != null) {
                        for (var k = 0; k < (rows as Array).size(); k++) {
                            var r = (rows as Array)[k];
                            if (r instanceof Dictionary && name.equals((r as Dictionary)["place"])) {
                                var v = (r as Dictionary)["value"];
                                if (v instanceof Number || v instanceof Float) {
                                    _out["t"] = v.toFloat();
                                    _out["tt"] = when;
                                }
                                break;
                            }
                        }
                    }
                }
            }
        }
        next();
    }

    // ---- 5: warnings in force ----

    //! warnsum is one entry per warning type in force, e.g. {"WHOT":{"code":"WHOT","actionCode":
    //! "REISSUE",...}, "WTCSGNL":{"code":"TC8NE",...}}. A just-cancelled warning can still be listed
    //! with actionCode (or, for the typhoon signal, code) "CANCEL" - those are dropped. An empty
    //! object means no warnings; it is still stored, so the face knows the list is current.
    public function onWarnings(code as Number, data) as Void {
        if (ok(code) && data instanceof Dictionary) {
            var d = data as Dictionary;
            var codes = [] as Array<String>;
            var keys = d.keys();
            for (var k = 0; k < keys.size(); k++) {
                var w = d[keys[k]];
                if (!(w instanceof Dictionary)) {
                    continue;
                }
                var c = (w as Dictionary)["code"];
                var action = (w as Dictionary)["actionCode"];
                if (c instanceof String && !(c as String).equals("CANCEL")
                        && !("CANCEL".equals(action))) {
                    codes.add(c as String);
                }
            }
            _out["w"] = codes;
            _out["wf"] = Time.now().value();
        }
        next();
    }

    // ---- parsing ----

    //! The fields of `station`'s line in an HKO regional CSV, as [readingEpoch, field1, field2, ...]
    //! (fields as Strings, the station name itself left out), or null if it isn't there.
    //! Lines are "YYYYMMDDhhmm,<station>,<fields...>"; the name is matched between commas, so
    //! "Kai Tak" never matches "Kai Tak Runway Park".
    private function csvRow(data, station as String) as Array or Null {
        if (!(data instanceof String) || station.equals("")) {
            return null;
        }
        var s = data as String;
        var key = "," + station + ",";
        var i = s.find(key);
        if (i == null || i < 12) {
            return null;
        }
        var when = stampEpoch(s.substring(i - 12, i) as String);
        if (when == null) {
            return null;
        }
        var rest = s.substring(i + key.length(), s.length()) as String;
        var nl = rest.find("\n");
        if (nl != null) {
            rest = rest.substring(0, nl) as String;
        }
        var out = [when] as Array;
        while (true) {
            var c = rest.find(",");
            if (c == null) {
                out.add(trimCr(rest));
                break;
            }
            out.add(rest.substring(0, c) as String);
            rest = rest.substring(c + 1, rest.length()) as String;
        }
        return out;
    }

    private function trimCr(s as String) as String {
        var n = s.length();
        if (n > 0 && s.substring(n - 1, n).equals("\r")) {
            return s.substring(0, n - 1) as String;
        }
        return s;
    }

    //! "202609291450" (HKT) -> epoch seconds.
    private function stampEpoch(t as String) as Number or Null {
        if (t.length() != 12) {
            return null;
        }
        return hktEpoch(t.substring(0, 4), t.substring(4, 6), t.substring(6, 8),
                        t.substring(8, 10), t.substring(10, 12));
    }

    //! "2026-09-29T13:30:00+08:00" -> epoch seconds. HKO always writes +08:00.
    private function isoEpoch(v) as Number or Null {
        if (!(v instanceof String) || (v as String).length() < 16) {
            return null;
        }
        var t = v as String;
        return hktEpoch(t.substring(0, 4), t.substring(5, 7), t.substring(8, 10),
                        t.substring(11, 13), t.substring(14, 16));
    }

    //! Gregorian.moment reads its fields as UTC, so an HKT wall-clock time is 8 h later than the
    //! moment it builds: subtract the offset.
    private function hktEpoch(y, mo, d, h, mi) as Number or Null {
        var yy = (y != null) ? (y as String).toNumber() : null;
        var mm = (mo != null) ? (mo as String).toNumber() : null;
        var dd = (d != null) ? (d as String).toNumber() : null;
        var hh = (h != null) ? (h as String).toNumber() : null;
        var nn = (mi != null) ? (mi as String).toNumber() : null;
        if (yy == null || mm == null || dd == null || hh == null || nn == null) {
            return null;
        }
        var m = Gregorian.moment({ :year => yy, :month => mm, :day => dd, :hour => hh,
                                   :minute => nn, :second => 0 });
        return m.value() - HKT_OFFSET;
    }

    //! The wind CSV's direction word -> the bearing it blows FROM, in degrees (the Weather API's
    //! convention). "Variable", "Calm" and "N/A" have none.
    private function compass(word as String) as Number or Null {
        var names = ["North", "Northeast", "East", "Southeast", "South", "Southwest", "West", "Northwest"];
        for (var k = 0; k < names.size(); k++) {
            if (word.equals(names[k])) {
                return k * 45;
            }
        }
        return null;
    }
}
