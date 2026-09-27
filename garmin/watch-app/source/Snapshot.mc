import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;

//! The last usage snapshot pushed from the phone, and the only state this app holds.
//!
//! The watch never fetches anything: Cloudflare's cf_clearance can only be minted by a real
//! browser engine, and a Claude sessionKey does not belong in unencrypted watch storage. The
//! phone authenticates, fetches, and pushes these numbers over BLE; everything here is a
//! read of whatever arrived last.
//!
//! Annotated (:glance) because the glance view reads it, and glance code is compiled into its
//! own tightly budgeted memory space - anything it touches has to be declared part of it.
//! Also (:background) because the complication publisher reads it from the background service.
(:glance :background)
module Snapshot {

    // Storage keys are deliberately terse: they are also the keys of the BLE payload, and a
    // Connect IQ phone message is small. "fh" five-hour, "wk" weekly pool, "mw" model weekly.
    // The phone's WatchBridge.payloadOf() sends exactly these - garmin/CONTRACT.md, enforced by
    // garmin/tools/check_contract.py. Change a key there and here in the same commit.
    const K_FIVE = "fh";
    const K_FIVE_RESET = "fhr";
    const K_WEEK = "wk";
    const K_WEEK_RESET = "wkr";
    const K_MODEL = "mw";
    const K_MODEL_RESET = "mwr";
    const K_MODEL_NAME = "mwn";
    const K_FETCHED = "ts";

    //! The phone refreshes every 15 minutes. An hour of silence means the link is down, the
    //! companion app was killed, or the session expired - the numbers on screen are no longer
    //! something to act on, so they get marked rather than quietly aging.
    const STALE_AFTER_SEC = 3600;

    //! A percentage that was actually delivered, or -1 when the key has never been written.
    //! -1 rather than 0 because "no data yet" and "0% used" must not render identically.
    function percent(key as String) as Number {
        var v = Storage.getValue(key);
        return (v instanceof Number) ? v : -1;
    }

    //! Absolute epoch seconds at which a window resets, or 0 when the phone sent none. A
    //! per-model window has no reset of its own until that model is used in the period, so
    //! the phone substitutes the pooled weekly reset before sending.
    function resetAt(key as String) as Number {
        var v = Storage.getValue(key);
        return (v instanceof Number) ? v : 0;
    }

    //! The model the weekly sub-cap is scoped to, as the API named it (e.g. "Fable"), or ""
    //! when this account has no per-model cap. Never hardcoded - Anthropic changes which
    //! model is metered.
    function modelName() as String {
        var v = Storage.getValue(K_MODEL_NAME);
        return (v instanceof String) ? v : "";
    }

    //! True once any snapshot has arrived. Drives the "open the phone app" empty state.
    function hasData() as Boolean {
        return percent(K_FIVE) >= 0;
    }

    function hasModelWeekly() as Boolean {
        return percent(K_MODEL) >= 0 && !modelName().equals("");
    }

    //! True when the last push is old enough that the numbers should be visibly doubted.
    function isStale() as Boolean {
        var fetched = resetAt(K_FETCHED);
        if (fetched == 0) {
            return false; // never pushed at all - that is the empty state, not staleness
        }
        return (nowSec() - fetched) > STALE_AFTER_SEC;
    }

    //! How old the numbers are, measured from the phone's fetch time: "updated 4m ago",
    //! "updated 1h 20m ago", "updated 2d ago". Empty before the first push. A fetch time in
    //! the future (phone clock ahead of the watch) reads as "just now" rather than negative.
    //!
    //! A bare "not updated recently" only said THAT the watch was stale; the age says how
    //! stale, which tells one missed refresh (minutes) apart from a broken link (hours).
    function ageText() as String {
        var fetched = resetAt(K_FETCHED);
        if (fetched == 0) {
            return "";
        }
        var mins = (nowSec() - fetched) / 60;
        if (mins < 1) {
            return "updated just now";
        }
        if (mins < 60) {
            return "updated " + mins.format("%d") + "m ago";
        }
        var hours = mins / 60;
        if (hours < 24) {
            // Minutes still matter for the first few hours ("1h 20m" vs "1h 55m"); past
            // ten hours they are noise.
            var rem = mins % 60;
            var tail = (rem > 0 && hours < 10) ? " " + rem.format("%d") + "m" : "";
            return "updated " + hours.format("%d") + "h" + tail + " ago";
        }
        return "updated " + (hours / 24).format("%d") + "d ago";
    }

    function nowSec() as Number {
        return Time.now().value();
    }

    //! Persist a payload from the companion app.
    //!
    //! Returns false and writes nothing when the message is not a usage payload, so a stray
    //! or malformed message can never blank out a good snapshot. Partial payloads are
    //! rejected for the same reason: the three meters are read together and must not come
    //! from two different fetches.
    function store(data as Dictionary or Null) as Boolean {
        if (!(data instanceof Dictionary)) {
            return false;
        }
        var five = data.get(K_FIVE);
        var week = data.get(K_WEEK);
        if (!(five instanceof Number) || !(week instanceof Number)) {
            return false;
        }

        Storage.setValue(K_FIVE, five);
        Storage.setValue(K_WEEK, week);
        Storage.setValue(K_FIVE_RESET, numberOr(data.get(K_FIVE_RESET), 0));
        Storage.setValue(K_WEEK_RESET, numberOr(data.get(K_WEEK_RESET), 0));

        // Write -1 / "" when the account has no per-model cap, so a window that disappears
        // stops being drawn instead of leaving a stale third meter on screen.
        var model = data.get(K_MODEL);
        var name = data.get(K_MODEL_NAME);
        if (model instanceof Number && name instanceof String) {
            Storage.setValue(K_MODEL, model);
            Storage.setValue(K_MODEL_NAME, name);
            Storage.setValue(K_MODEL_RESET, numberOr(data.get(K_MODEL_RESET), 0));
        } else {
            Storage.setValue(K_MODEL, -1);
            Storage.setValue(K_MODEL_NAME, "");
            Storage.setValue(K_MODEL_RESET, 0);
        }

        // Trust the phone's clock for "when was this fetched": the watch clock can drift and
        // the freshness question is about the phone's last successful fetch, not this radio
        // message. Fall back to the watch only if the phone omitted it.
        Storage.setValue(K_FETCHED, numberOr(data.get(K_FETCHED), nowSec()));
        return true;
    }

    function numberOr(v as Object or Null, fallback as Number) as Number {
        return (v instanceof Number) ? v : fallback;
    }

    //! When a window resets, as an absolute wall-clock time - the way the Claude usage menu
    //! states it ("Resets 5:00 AM" / "Resets Sep 22") rather than a countdown, so a glance
    //! answers "when can I use it again" without arithmetic.
    //!
    //! The format follows the distance, which naturally matches the windows: the 5-hour
    //! session resets within a day, so it reads as a clock time; the weekly caps are days
    //! out, so they read as a weekday, or a month/day once past a week. Empty when the phone
    //! sent no reset time, "now" once the reset is due but a fresh snapshot has not arrived.
    function resetsAt(epochSec as Number) as String {
        if (epochSec == 0) {
            return "";
        }
        var secs = epochSec - nowSec();
        if (secs <= 0) {
            return "now";
        }
        var moment = new Time.Moment(epochSec);
        if (secs < 86400) {
            // Within a day: clock time, in the device's own 12/24-hour setting.
            var info = Gregorian.info(moment, Time.FORMAT_SHORT);
            return clock(info.hour, info.min);
        }
        // FORMAT_MEDIUM gives abbreviated names ("Mon", "Sep") rather than the numbers
        // FORMAT_SHORT would return.
        var info = Gregorian.info(moment, Time.FORMAT_MEDIUM);
        if (secs < 7 * 86400) {
            return info.day_of_week; // "Mon" - unambiguous within the coming week
        }
        return info.month + " " + info.day.format("%d"); // "Sep 22"
    }

    //! "5:00p" / "17:00" - the reset clock time, compressed to fit a glance column and
    //! honouring the watch's 12/24-hour setting.
    function clock(hour as Number, min as Number) as String {
        var mm = min.format("%02d");
        if (System.getDeviceSettings().is24Hour) {
            return hour.format("%d") + ":" + mm;
        }
        var h = hour % 12;
        if (h == 0) {
            h = 12;
        }
        return h.format("%d") + ":" + mm + (hour < 12 ? "a" : "p");
    }
}
