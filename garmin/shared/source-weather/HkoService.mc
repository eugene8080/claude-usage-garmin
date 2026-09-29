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
//! Normally ONE request, to hko-proxy (garmin/hko-proxy/, a Cloudflare Worker), which returns
//! everything for the station the HkoStation setting names:
//!
//!   1  hko-proxy /hko?st=&hum=&wind=&rhr=    the station's minute temperature and humidity and
//!                                            the nearest 10-minute wind (t/tt, h/ht, ws/wd/wg/wt),
//!                                            HKO's icon (i/it) and the warnings in force (w/wf)
//!
//! Why a proxy: HKO serves its minute-level station feeds (latest_1min_*.csv, latest_10min_wind.csv)
//! as CSV with the Content-Type headers "application/octet-stream" and "text/csv". Garmin Connect
//! only relays a response whose Content-Type matches the request exactly ("text/plain" for
//! HTTP_RESPONSE_CONTENT_TYPE_TEXT_PLAIN), so on a watch those requests always failed; the
//! simulator makes its own HTTP requests without that check, which is why they worked there
//! (found on the first tactix 8 install, 2026-09-29). The Worker reads them and answers in plain
//! "application/json".
//!
//! If the proxy fails (any non-200, reported as e1), two direct HKO requests take over, both JSON
//! with a Content-Type Garmin Connect accepts:
//!
//!   2  rhrread (hourly report)   the icon; the station's temperature (hourly, by its rhrread
//!                                name); the Observatory's humidity (the report's only one)
//!   3  warnsum                   the warnings in force
//!
//! so the face still shows HKO, hourly and without HKO's wind. `tm` records which feed the
//! temperature came from (1 = the minute feed via the proxy, 0 = the hourly report) for the
//! settings row. A failed request just leaves its keys out: Hko.merge keeps the previous values,
//! each with its own timestamp, and the face ignores whatever has aged out.
(:background)
class HkoService extends System.ServiceDelegate {

    //! The deployed hko-proxy Worker (garmin/hko-proxy/README.md). Change here if it moves.
    private const PROXY_URL = "https://hko-proxy.ewong.workers.dev/hko";
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
    //! After a successful proxy response the chain ends at step 1.
    private function next() as Void {
        _step += 1;
        if (_step == 1) {
            var params = {
                "st" => HkoStations.TEMP[_id],
                "hum" => HkoStations.HUM[_id],
                "wind" => HkoStations.WIND[_id]
            };
            var rhr = HkoStations.RHR[_id];
            if (!rhr.equals("")) {
                params["rhr"] = rhr;
            }
            request(PROXY_URL, params, method(:onProxy));
        } else if (_step == 2) {
            request(API_BASE, { "dataType" => "rhrread", "lang" => "en" }, method(:onReport));
        } else if (_step == 3) {
            request(API_BASE, { "dataType" => "warnsum", "lang" => "en" }, method(:onWarnings));
        } else {
            Background.exit(_out);
        }
    }

    private function request(url as String, params as Dictionary, cb as Method) as Void {
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON
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

    // ---- 1: the proxy - everything at once ----

    //! Copies the proxy's keys (each group only when present, types checked) and ends the chain.
    //! On failure the direct requests 2 and 3 follow.
    public function onProxy(code as Number, data) as Void {
        if (!ok(code) || !(data instanceof Dictionary)) {
            next();
            return;
        }
        var d = data as Dictionary;
        if (isNum(d["t"]) && d["tt"] instanceof Number) {
            _out["t"] = d["t"].toFloat();
            _out["tt"] = d["tt"];
            var src = d["src"];
            _out["tm"] = (src instanceof Dictionary && "min".equals((src as Dictionary)["t"])) ? 1 : 0;
        }
        if (d["h"] instanceof Number && d["ht"] instanceof Number) {
            _out["h"] = d["h"];
            _out["ht"] = d["ht"];
        }
        if (d["ws"] instanceof Number && d["wt"] instanceof Number) {
            _out["ws"] = d["ws"];
            _out["wt"] = d["wt"];
            if (d["wd"] instanceof Number) { _out["wd"] = d["wd"]; }
            if (d["wg"] instanceof Number) { _out["wg"] = d["wg"]; }
        }
        if (d["i"] instanceof Number && d["it"] instanceof Number) {
            _out["i"] = d["i"];
            _out["it"] = d["it"];
        }
        if (d["w"] instanceof Array && d["wf"] instanceof Number) {
            var codes = [] as Array<String>;
            var w = d["w"] as Array;
            for (var k = 0; k < w.size(); k++) {
                if (w[k] instanceof String) { codes.add(w[k] as String); }
            }
            _out["w"] = codes;
            _out["wf"] = d["wf"];
        }
        Background.exit(_out);
    }

    // ---- 2: the hourly report (fallback) - icon, temperature, the Observatory's humidity ----

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
            if (!name.equals("")) {
                var temp = d["temperature"];
                if (temp instanceof Dictionary) {
                    var rows = (temp as Dictionary)["data"];
                    var when = isoEpoch((temp as Dictionary)["recordTime"]);
                    if (rows instanceof Array && when != null) {
                        for (var k = 0; k < (rows as Array).size(); k++) {
                            var r = (rows as Array)[k];
                            if (r instanceof Dictionary && name.equals((r as Dictionary)["place"])) {
                                var v = (r as Dictionary)["value"];
                                if (isNum(v)) {
                                    _out["t"] = v.toFloat();
                                    _out["tt"] = when;
                                    _out["tm"] = 0;
                                }
                                break;
                            }
                        }
                    }
                }
            }
            // rhrread reports humidity for the Observatory only, as one hourly figure. That still
            // gives the face a heat index, and it stays within HKO (Hko.mc never mixes Garmin's
            // humidity into the feels-like).
            var hum = d["humidity"];
            if (hum instanceof Dictionary) {
                var hrows = (hum as Dictionary)["data"];
                var hwhen = isoEpoch((hum as Dictionary)["recordTime"]);
                if (hrows instanceof Array && (hrows as Array).size() > 0 && hwhen != null
                        && (hrows as Array)[0] instanceof Dictionary) {
                    var hv = ((hrows as Array)[0] as Dictionary)["value"];
                    if (hv instanceof Number && (hv as Number) >= 0 && (hv as Number) <= 100) {
                        _out["h"] = hv as Number;
                        _out["ht"] = hwhen;
                    }
                }
            }
        }
        next();
    }

    // ---- 3: warnings in force (fallback) ----

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

    private function isNum(v) as Boolean {
        return v instanceof Number || v instanceof Float || v instanceof Double || v instanceof Long;
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
}
