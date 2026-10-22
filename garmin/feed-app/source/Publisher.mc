import Toybox.Lang;
import Toybox.System;

//! Publishes the Codex + Cursor app's four meters as watchface complications, from whatever
//! snapshot the phone last pushed: Codex 5H and 1W, Cursor plan and Auto. (Cursor's API pool is
//! Claude Usage's fourth complication - Connect IQ caps each app at four.)
//!
//! A meter the phone sent no numbers for is published as null, so a face shows it empty
//! rather than as 0 %. (:background) because it runs inside the background service.
(:background)
module Publisher {

    // Complication ids - these MUST match resources/complications.xml and stay stable across
    // versions, or a watchface already configured for one silently loses it on update.
    // Part of the watch app <-> face contract (garmin/CONTRACT.md, checked in CI).
    const ID_CODEX_FIVE = 0;
    const ID_CODEX_WEEK = 1;
    const ID_CURSOR_PLAN = 2;
    const ID_CURSOR_AUTO = 3;

    //! Publish the current snapshot to the four complications. No-op without the
    //! Complications API, and caught, for the same reasons as Claude Usage's Publisher: the
    //! simulator throws with no live subscriber, and a failed publish must not take the app down.
    function publish() as Void {
        if (!(Toybox has :Complications)) {
            return;
        }
        try {
            UsagePublish.one(ID_CODEX_FIVE, Snapshot.percent(Snapshot.K_X_FIVE), "5H",
                Snapshot.resetAt(Snapshot.K_X_FIVE_RESET));
            UsagePublish.one(ID_CODEX_WEEK, Snapshot.percent(Snapshot.K_X_WEEK), "1W",
                Snapshot.resetAt(Snapshot.K_X_WEEK_RESET));
            UsagePublish.one(ID_CURSOR_PLAN, Snapshot.percent(Snapshot.K_U_PLAN), "Plan",
                Snapshot.resetAt(Snapshot.K_U_PLAN_RESET));
            UsagePublish.one(ID_CURSOR_AUTO, Snapshot.percent(Snapshot.K_U_AUTO), "Auto",
                Snapshot.resetAt(Snapshot.K_U_AUTO_RESET));
        } catch (e) {
            System.println("complication publish failed: " + e.getErrorMessage());
        }
    }
}
