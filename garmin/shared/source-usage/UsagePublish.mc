import Toybox.Complications;
import Toybox.Lang;

//! Writes one meter to one of the app's complications. Each app's `Publisher` module decides
//! which meter goes to which of its complication ids; this is the part they share.
//!
//! (:background) because it runs inside the background service, not the foreground app.
(:background)
module UsagePublish {

    // Threshold zones a watchface can colour a gauge by: 0-50 low, 50-80 mid, 80-100 near cap.
    const RANGE = [0, 50, 80, 100];

    //! A percentage < 0 means "no data" and is published as null, which a watchface renders
    //! as an empty complication instead of "0%".
    //!
    //! The reset time rides in the `unit` field as the raw epoch-seconds string. That keeps
    //! the background publish free of any date formatting (which may not be available in the
    //! background context) - the Claude faces parse and format it in the foreground, where
    //! the 12/24-hour setting is readable. A real "%" unit is unnecessary because our faces
    //! draw the percent sign themselves.
    function one(id as Number, pct as Number, label as String, resetEpoch as Number) as Void {
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
