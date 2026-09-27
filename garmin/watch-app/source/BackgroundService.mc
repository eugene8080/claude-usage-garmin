import Toybox.Background;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;

//! Background entry point. A device app may only publish complications from here - doing it
//! from the foreground faults - so the three meters reach the complication framework from
//! two background events the main app registers:
//!
//!  - onPhoneAppMessage: the phone just pushed a snapshot. Store it and publish at once, so a
//!    watch face shows the new numbers within seconds of the push, whether or not the glance
//!    or the app is open.
//!  - onTemporalEvent: every 5 minutes (Connect IQ's floor), republish whatever is stored.
//!    A safety net for a missed message, and what keeps the model slot's "reset" countdown
//!    and a no-data state current.
//!
//! Before the message event existed, a push only reached Storage through the FOREGROUND
//! registerForPhoneAppMessages callback, so it waited in the message queue until the glance
//! or app was opened - the glance then looked current while Claude Grid's complications
//! still showed old numbers (and only caught up on the next 5-minute tick after that).
//!
//! Everything it touches is annotated (:background) so it is compiled into the background
//! memory image.
(:background)
class ClaudeUsageServiceDelegate extends System.ServiceDelegate {

    public function initialize() {
        ServiceDelegate.initialize();
    }

    public function onTemporalEvent() as Void {
        Publisher.publish();
        Background.exit(null);
    }

    //! A phone push that arrived while the foreground app was not running. The background
    //! process may write Application.Storage, so this does exactly what the foreground
    //! onPhone() does - validate + store - and then publishes, which only the background
    //! may do. A malformed message is dropped without touching storage or complications.
    public function onPhoneAppMessage(msg as Communications.PhoneAppMessage) as Void {
        if (Snapshot.store(msg.data)) {
            Publisher.publish();
        }
        // Always exit: a background process that does not call exit() is killed by the
        // system at its time limit and counts against the app.
        Background.exit(null);
    }
}
