import Toybox.Lang;

//! The watch app's own version, shown on the glance and the full view so a sideload can be
//! confirmed to have taken.
//!
//! Unlike the phone (whose version CI stamps from the git tag), the watch .prg is built
//! locally, so this is a manual constant. BUMP IT to the release version whenever the .prg
//! is rebuilt for a release - it is the one thing to remember when cutting a release that
//! ships a new watch binary. Annotated (:glance) because the glance reads it.
(:glance :background)
module Version {
    const APP = "1.11";
}
