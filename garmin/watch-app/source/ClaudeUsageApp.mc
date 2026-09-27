import Toybox.Application;
import Toybox.Background;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

//! Claude usage on the wrist, fed entirely by the Android companion app over BLE.
//!
//! There is no network code here on purpose - see Snapshot.mc for why the watch must not
//! authenticate. The app's whole job is: receive a message, persist it, redraw.
class ClaudeUsageApp extends Application.AppBase {

    //! Held in a field because registerForPhoneAppMessages keeps a weak reference to the
    //! callback; a Method built inline would be collected and messages would stop arriving.
    private var _phoneMethod as Method(msg as PhoneAppMessage) as Void;

    public function initialize() {
        AppBase.initialize();
        _phoneMethod = method(:onPhone);

        // Registering in initialize() rather than onStart() matters: this runs for the
        // glance too, so a push that lands while the user is scrolling the glance carousel
        // is still captured, without the full app ever having been opened.
        if (Communications has :registerForPhoneAppMessages) {
            Communications.registerForPhoneAppMessages(_phoneMethod);
        }
    }

    public function onStart(state as Dictionary?) as Void {
        registerComplicationPublishing();
    }

    public function onStop(state as Dictionary?) as Void {
    }

    //! The background service that publishes the complications. Returning it here is what
    //! lets the system run onTemporalEvent() when the app is closed.
    public function getServiceDelegate() as [System.ServiceDelegate] {
        return [new $.ClaudeUsageServiceDelegate()];
    }

    //! Register the two background events that keep the complications current:
    //!
    //!  - the phone-message event (API 3.2+), so a push wakes the background service,
    //!    which stores it and publishes immediately - see ClaudeUsageServiceDelegate;
    //!  - the 5-minute temporal event (the platform minimum) as the periodic republish.
    //!
    //! Both registrations persist once made, but a sideload of a new .prg clears them, so
    //! the app (or its glance) must run once after install for this to take effect.
    //! Re-registering on every launch is harmless; the InvalidBackgroundTime case only
    //! happens if a prior event ran too recently and is safe to skip.
    private function registerComplicationPublishing() as Void {
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

    public function getInitialView() as [Views] or [Views, InputDelegates] {
        return [new $.ClaudeUsageView()];
    }

    //! The glance carousel entry. This is the screen that justifies the whole app - usage
    //! readable with a scroll, without launching anything.
    (:glance)
    public function getGlanceView() as
        [WatchUi.GlanceView] or [WatchUi.GlanceView, WatchUi.GlanceViewDelegate] or Null {
        return [new $.ClaudeUsageGlanceView()];
    }

    //! A message from the companion app. Anything that is not a well-formed usage payload is
    //! dropped without touching storage, so a stray message cannot blank the display.
    public function onPhone(msg as PhoneAppMessage) as Void {
        if (Snapshot.store(msg.data)) {
            WatchUi.requestUpdate();
        }
    }
}
