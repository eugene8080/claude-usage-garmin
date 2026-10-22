import Toybox.Lang;
import Toybox.System;

//! Publishes this app's four meters as watchface complications, from whatever snapshot the
//! phone last pushed: Claude's three, and Cursor's API pool. The watch still fetches nothing
//! itself - this only re-exposes stored numbers in the complication framework so any
//! watchface (public access) can show them.
//!
//! Connect IQ caps one app at four complications (the compiler refuses a fifth), so the other
//! Codex and Cursor meters are published by the Codex + Cursor app (garmin/feed-app/).
//!
//! The framework keeps the last published value, so a watchface shows it even when this app
//! is not open. It is only as fresh as the last publish, which the background service runs on
//! a ~5-min timer and on every phone push - the watch has no data source itself.
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
    const ID_CURSOR_API = 3;

    //! Publish the current snapshot to the four complications.
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
            UsagePublish.one(ID_FIVE, Snapshot.percent(Snapshot.K_FIVE), "5H",
                Snapshot.resetAt(Snapshot.K_FIVE_RESET));
            UsagePublish.one(ID_WEEK, Snapshot.percent(Snapshot.K_WEEK), "1W",
                Snapshot.resetAt(Snapshot.K_WEEK_RESET));
            if (Snapshot.hasModelWeekly()) {
                UsagePublish.one(ID_MODEL, Snapshot.percent(Snapshot.K_MODEL),
                    UsagePublish.short(Snapshot.modelName()), Snapshot.resetAt(Snapshot.K_MODEL_RESET));
            } else {
                // No per-model cap this period: publish an empty value so the slot reads
                // blank rather than a stale number.
                UsagePublish.one(ID_MODEL, -1, "1W", 0);
            }
            UsagePublish.one(ID_CURSOR_API, Snapshot.percent(Snapshot.K_U_API), "API",
                Snapshot.resetAt(Snapshot.K_U_API_RESET));
        } catch (e) {
            System.println("complication publish failed: " + e.getErrorMessage());
        }
    }
}
