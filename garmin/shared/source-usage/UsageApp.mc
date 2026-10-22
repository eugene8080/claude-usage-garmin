import Toybox.Background;
import Toybox.Lang;
import Toybox.Time;

//! App start-up both watch apps need, so neither copy can drift from the other.
//!
//! (:background) because onStart() calls it, and onStart() also runs when the system starts
//! the app's background service: the compiler adds the App class to the background image
//! ("entry point ... implicitly added to the background process"), so everything onStart
//! touches must be there too. A foreground-only module here faults the background start with
//! an uncatchable "Illegal Access (Out of Bounds)" (seen in the simulator, 2026-10-22). The
//! page views stay in UsagePages, which only the foreground loads.
(:background)
module UsageApp {

    // Page ids for UsagePages - here, not there, because the App classes' constants and
    // startPage() use them in the background too.
    const CLAUDE = 0;
    const CODEX = 1;
    const CURSOR = 2;

    //! Register the two background events that keep the complications current:
    //!
    //!  - the phone-message event (API 3.2+), so a push wakes the background service,
    //!    which stores it and publishes immediately - see UsageServiceDelegate;
    //!  - the 5-minute temporal event (the platform minimum) as the periodic republish.
    //!
    //! Both registrations persist once made, but a sideload of a new .prg clears them, so
    //! the app (or its glance) must run once after install for this to take effect.
    //! Re-registering on every launch is harmless; the InvalidBackgroundTime case only
    //! happens if a prior event ran too recently and is safe to skip.
    function registerPublishing() as Void {
        if (!(Toybox has :Background)) {
            return;
        }
        if (Background has :registerForPhoneAppMessageEvent) {
            Background.registerForPhoneAppMessageEvent();
        }
        try {
            Background.registerForTemporalEvent(new Time.Duration(5 * 60));
        } catch (e instanceof Background.InvalidBackgroundTimeException) {
            // Too soon since the last event - it will fire on the already-scheduled slot.
        }
    }

    //! The index into [pages] to open on: the page of the complication a face's hold-to-launch
    //! came from, where [pageForComplication][N] is the page id of the app's complication N
    //! (garmin/CONTRACT.md). 0 (the first page) for anything else, including a glance launch.
    function startPage(state as Dictionary or Null, pages as Array<Number>,
            pageForComplication as Array<Number>) as Number {
        if (state == null) {
            return 0;
        }
        var id = state.get(:launchedFromComplication);
        if (!(id instanceof Number) || id < 0 || id >= pageForComplication.size()) {
            return 0;
        }
        var page = pages.indexOf(pageForComplication[id]);
        return (page >= 0) ? page : 0;
    }
}
