import Toybox.Application;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//! Codex + Cursor: publishes four more complications than Claude Usage has room for, from the
//! same phone push, and shows the Codex and Cursor pages when opened.
//!
//! It has no glance on purpose - Claude Usage's glance and pages already cover the numbers;
//! this app is what lets a watch face hold Codex and Cursor meters. It does need to run once
//! after install, so onStart can register the background events that publish.
class CodexCursorApp extends Application.AppBase {

    //! The pages, in order (UsageApp page ids).
    private const PAGES = [UsageApp.CODEX, UsageApp.CURSOR];

    //! The page each of this app's complications belongs to, by complication id
    //! (resources/complications.xml): 0-1 Codex, 2-3 Cursor.
    private const PAGE_FOR_COMPLICATION = [UsageApp.CODEX, UsageApp.CODEX, UsageApp.CURSOR,
        UsageApp.CURSOR];

    //! Held in a field because registerForPhoneAppMessages keeps a weak reference to the
    //! callback; a Method built inline would be collected and messages would stop arriving.
    private var _phoneMethod as Method(msg as PhoneAppMessage) as Void;

    //! The page to open on, from how the app was launched (onStart runs before getInitialView).
    private var _startPage as Number = 0;

    public function initialize() {
        AppBase.initialize();
        _phoneMethod = method(:onPhone);
        // A push that lands while the app is open is stored here; one that lands while it is
        // closed wakes the background service instead (UsageServiceDelegate).
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

    //! The background service that publishes the complications.
    public function getServiceDelegate() as [System.ServiceDelegate] {
        return [new $.UsageServiceDelegate()];
    }

    public function getInitialView() as [Views] or [Views, InputDelegates] {
        return UsagePages.initialView(PAGES, _startPage);
    }

    //! A message from the companion app; a malformed one is dropped without touching storage.
    public function onPhone(msg as PhoneAppMessage) as Void {
        if (Snapshot.store(msg.data)) {
            WatchUi.requestUpdate();
        }
    }
}
