import Toybox.Complications;
import Toybox.Lang;
import Toybox.System;

//! Publishes the three meters as watchface complications, from whatever snapshot the phone
//! last pushed. The watch still fetches nothing itself - this only re-exposes stored numbers
//! in the complication framework so any watchface (public access) can show them.
//!
//! The framework keeps the last published value, so a watchface shows it even when this app
//! is not open. It is only as fresh as the last publish, which the background service runs on
//! a ~5-min timer from whatever the phone last pushed - the watch has no data source itself.
//!
//! (:background) because it runs inside the background service, not the foreground app.
(:background)
module Publisher {

    // Complication ids - these MUST match resources/complications.xml and stay stable across
    // versions, or a watchface already configured for one silently loses it on update.
    // Part of the watch app <-> face contract (garmin/CONTRACT.md, checked in CI).
    const ID_FIVE = 0;
    const ID_WEEK = 1;
    const ID_MODEL = 2;

    // Threshold zones a watchface can colour a gauge by: 0-50 low, 50-80 mid, 80-100 near cap.
    const RANGE = [0, 50, 80, 100];

    //! Publish the current snapshot to the three complications.
    //!
    //! No-op where the Complications API is absent, and wrapped in a catch because publishing
    //! is a nice-to-have that must never take down the glance/app: the Connect IQ simulator
    //! throws when a device app publishes with no live subscriber, and a device could refuse
    //! for reasons of its own. A failure here just means the watchface complications don't
    //! update this cycle - the app carries on.
    function publish() as Void {
        if (!(Toybox has :Complications)) {
            return;
        }
        try {
            publishOne(ID_FIVE, Snapshot.percent(Snapshot.K_FIVE), "5H",
                Snapshot.resetAt(Snapshot.K_FIVE_RESET));
            publishOne(ID_WEEK, Snapshot.percent(Snapshot.K_WEEK), "1W",
                Snapshot.resetAt(Snapshot.K_WEEK_RESET));
            if (Snapshot.hasModelWeekly()) {
                publishOne(ID_MODEL, Snapshot.percent(Snapshot.K_MODEL),
                    short(Snapshot.modelName()), Snapshot.resetAt(Snapshot.K_MODEL_RESET));
            } else {
                // No per-model cap this period: publish an empty value so the slot reads
                // blank rather than a stale number.
                publishOne(ID_MODEL, -1, "1W", 0);
            }
        } catch (e) {
            System.println("complication publish failed: " + e.getErrorMessage());
        }
    }

    //! A percentage < 0 means "no data" and is published as null, which a watchface renders
    //! as an empty complication instead of "0%".
    //!
    //! The reset time rides in the `unit` field as the raw epoch-seconds string. That keeps
    //! the background publish free of any date formatting (which may not be available in the
    //! background context) - the Claude face parses and formats it in the foreground, where
    //! the 12/24-hour setting is readable. A real "%" unit is unnecessary because our face
    //! draws the percent sign itself, and no other watchface can show a custom complication.
    function publishOne(id as Number, pct as Number, label as String, resetEpoch as Number) as Void {
        Complications.updateComplication(
            id,
            {
                :value => (pct >= 0) ? pct : null,
                :shortLabel => label,
                :unit => resetEpoch.toString(),
                :ranges => RANGE,
            }
        );
    }

    //! shortLabel is capped at five characters for radial display.
    function short(name as String) as String {
        return (name.length() > 5) ? name.substring(0, 5) : name;
    }
}
