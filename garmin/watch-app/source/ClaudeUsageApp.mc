import Toybox.Application;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//! Claude, Codex and Cursor usage on the wrist, fed entirely by the Android companion app
//! over BLE.
//!
//! There is no network code here on purpose - see Snapshot.mc for why the watch must not
//! authenticate. The app's whole job is: receive a message, persist it, redraw. Its glance is
//! Claude's; opening it shows one page per provider.
class ClaudeUsageApp extends Application.AppBase {

    //! The pages, in order (UsageApp page ids).
    private const PAGES = [UsageApp.CLAUDE, UsageApp.CODEX, UsageApp.CURSOR];

    //! The page each of this app's complications belongs to, by complication id
    //! (resources/complications.xml): 0-2 Claude, 3 Cursor API.
    private const PAGE_FOR_COMPLICATION = [UsageApp.CLAUDE, UsageApp.CLAUDE, UsageApp.CLAUDE,
        UsageApp.CURSOR];

    //! Held in a field because registerForPhoneAppMessages keeps a weak reference to the
    //! callback; a Method built inline would be collected and messages would stop arriving.
    private var _phoneMethod as Method(msg as PhoneAppMessage) as Void;

    //! The page to open on, from how the app was launched (onStart runs before getInitialView).
    private var _startPage as Number = 0;

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
        UsageApp.registerPublishing();
        _startPage = UsageApp.startPage(state, PAGES, PAGE_FOR_COMPLICATION);
    }

    public function onStop(state as Dictionary?) as Void {
    }

    //! The background service that publishes the complications. Returning it here is what
    //! lets the system run onTemporalEvent() when the app is closed.
    public function getServiceDelegate() as [System.ServiceDelegate] {
        return [new $.UsageServiceDelegate()];
    }

    public function getInitialView() as [Views] or [Views, InputDelegates] {
        return UsagePages.initialView(PAGES, _startPage);
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
