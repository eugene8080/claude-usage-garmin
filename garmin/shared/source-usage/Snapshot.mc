import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;

//! The last usage snapshot pushed from the phone, and the only state the watch apps hold.
//!
//! The watch never fetches anything: the phone reads every provider's usage from desktop
//! Orca and pushes these numbers over BLE; everything here is a read of whatever arrived
//! last. Shared by both watch apps (garmin/shared/README.md): Claude Usage and the Codex +
//! Cursor app get the same message and each keeps its own copy in its own Storage.
//!
//! Annotated (:glance) because the glance view reads it, and glance code is compiled into its
//! own tightly budgeted memory space - anything it touches has to be declared part of it.
//! Also (:background) because the complication publisher reads it from the background service.
(:glance :background)
module Snapshot {

    // Storage keys are deliberately terse: they are also the keys of the BLE payload, and a
    // Connect IQ phone message is small. The phone's WatchBridge.payloadOf() sends exactly
    // these - garmin/CONTRACT.md, enforced by garmin/tools/check_contract.py. Change a key
    // there and here in the same commit.

    // Claude: "fh" five-hour, "wk" weekly pool, "ts" Orca's fetch time.
    const K_FIVE = "fh";
    const K_FIVE_RESET = "fhr";
    const K_WEEK = "wk";
    const K_WEEK_RESET = "wkr";
    const K_FETCHED = "ts";
    // Claude's per-model weekly cap.
    const K_MODEL = "mw";
    const K_MODEL_RESET = "mwr";
    const K_MODEL_NAME = "mwn";
    // Codex ("x"): its five-hour and weekly windows, and its own fetch time.
    const K_X_FIVE = "xfh";
    const K_X_FIVE_RESET = "xfhr";
    const K_X_WEEK = "xwk";
    const K_X_WEEK_RESET = "xwkr";
    const K_X_FETCHED = "xts";
    // Cursor ("u"): the monthly plan, the Auto and API pools, and its own fetch time.
    const K_U_PLAN = "upl";
    const K_U_PLAN_RESET = "uplr";
    const K_U_AUTO = "uau";
    const K_U_AUTO_RESET = "uaur";
    const K_U_API = "uap";
    const K_U_API_RESET = "uapr";
    const K_U_FETCHED = "uts";

    // Key groups: each travels whole or not at all (garmin/CONTRACT.md). The phone builds
    // each from one `payload += mapOf(...)`; the checker compares the two sides.
    const G_CLAUDE = [K_FIVE, K_FIVE_RESET, K_WEEK, K_WEEK_RESET, K_FETCHED];
    const G_MODEL = [K_MODEL, K_MODEL_RESET, K_MODEL_NAME];
    const G_CODEX = [K_X_FIVE, K_X_FIVE_RESET, K_X_WEEK, K_X_WEEK_RESET, K_X_FETCHED];
    const G_CURSOR = [K_U_PLAN, K_U_PLAN_RESET, K_U_AUTO, K_U_AUTO_RESET, K_U_API, K_U_API_RESET,
        K_U_FETCHED];
    const GROUPS = [G_CLAUDE, G_MODEL, G_CODEX, G_CURSOR];

    //! The phone refreshes every 15 minutes. An hour of silence means the link is down, the
    //! companion app was killed, or Orca stopped answering - the numbers on screen are no
    //! longer something to act on, so they get marked rather than quietly aging.
    const STALE_AFTER_SEC = 3600;

    //! A percentage that was actually delivered, or -1 when the phone sent none (its group is
    //! absent, or the window was missing inside it). -1 rather than 0 because "no data" and
    //! "0% used" must not render identically.
    function percent(key as String) as Number {
        var v = Storage.getValue(key);
        return (v instanceof Number) ? v : -1;
    }

    //! Absolute epoch seconds for a reset or fetch-time key, or 0 when the phone sent none.
    //! A per-model window has no reset of its own until that model is used in the period, so
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

    //! True when the group stamped with [fetchedKey] is stored - every group of a provider
    //! carries its fetch time, so this is "the phone sent numbers for that provider".
    function hasNumbers(fetchedKey as String) as Boolean {
        return Storage.getValue(fetchedKey) instanceof Number;
    }

    //! True once a Claude snapshot has arrived. Drives the glance's "open on phone" state.
    function hasData() as Boolean {
        return hasNumbers(K_FETCHED);
    }

    function hasModelWeekly() as Boolean {
        return percent(K_MODEL) >= 0 && !modelName().equals("");
    }

    //! True when the numbers stamped with [fetchedKey] are old enough to be visibly doubted.
    function isStale(fetchedKey as String) as Boolean {
        var fetched = resetAt(fetchedKey);
        if (fetched == 0) {
            return false; // never pushed at all - that is the empty state, not staleness
        }
        return (nowSec() - fetched) > STALE_AFTER_SEC;
    }

    //! How old the numbers stamped with [fetchedKey] are, measured from the phone's fetch
    //! time: "updated 4m ago", "updated 1h 20m ago", "updated 2d ago". Empty before the first
    //! push. A fetch time in the future (phone clock ahead of the watch) reads as "just now".
    //!
    //! A bare "not updated recently" only said THAT the watch was stale; the age says how
    //! stale, which tells one missed refresh (minutes) apart from a broken link (hours).
    function ageText(fetchedKey as String) as String {
        var fetched = resetAt(fetchedKey);
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
    //! Group by group: a group whose keys all arrived is written; a group that is absent is
    //! cleared, so a provider the phone has no numbers for stops being drawn instead of
    //! leaving stale numbers on screen. A group that arrived only in part counts as absent.
    //!
    //! Returns false and writes nothing when no group is complete, so a stray or malformed
    //! message can never blank out a good snapshot.
    function store(data as Dictionary or Null) as Boolean {
        if (!(data instanceof Dictionary)) {
            return false;
        }
        // Pass 1 decides, pass 2 writes: nothing may be cleared before we know the message
        // carries at least one group.
        var complete = new [GROUPS.size()];
        var any = false;
        for (var g = 0; g < GROUPS.size(); g++) {
            complete[g] = isComplete(data, GROUPS[g] as Array<String>);
            any = any || complete[g];
        }
        if (!any) {
            return false;
        }
        for (var g = 0; g < GROUPS.size(); g++) {
            var keys = GROUPS[g] as Array<String>;
            for (var i = 0; i < keys.size(); i++) {
                if (complete[g]) {
                    Storage.setValue(keys[i], data.get(keys[i]) as Number or String);
                } else {
                    // Deleted rather than written as -1: percent() / resetAt() / modelName()
                    // read a missing key as "no data", which is what absent means.
                    Storage.deleteValue(keys[i]);
                }
            }
        }
        return true;
    }

    //! Every key of [keys] is in [data] with the right type: the model name a String, every
    //! other key a Number (a percentage, or epoch seconds).
    function isComplete(data as Dictionary, keys as Array<String>) as Boolean {
        for (var i = 0; i < keys.size(); i++) {
            var v = data.get(keys[i]);
            var ok = keys[i].equals(K_MODEL_NAME) ? (v instanceof String) : (v instanceof Number);
            if (!ok) {
                return false;
            }
        }
        return true;
    }

    //! When a window resets, as an absolute wall-clock time - the way the Claude usage menu
    //! states it ("Resets 5:00 AM" / "Resets Sep 22") rather than a countdown, so a glance
    //! answers "when can I use it again" without arithmetic.
    //!
    //! The format follows the distance, which naturally matches the windows: the 5-hour
    //! session resets within a day, so it reads as a clock time; the weekly caps are days
    //! out, so they read as a weekday, or a month/day once past a week (Cursor's monthly
    //! plan). Empty when the phone sent no reset time, "now" once the reset is due but a
    //! fresh snapshot has not arrived.
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
