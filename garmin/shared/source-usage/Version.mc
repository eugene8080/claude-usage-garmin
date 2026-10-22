import Toybox.Lang;

//! The watch apps' own version, shown on the glance and the provider pages so a sideload can
//! be confirmed to have taken. Shared, so Claude Usage and the Codex + Cursor app always carry
//! the same number and a mismatched pair is visible.
//!
//! Unlike the phone (whose version CI stamps from the git tag), the watch .prg files are built
//! locally, so this is a manual constant. BUMP IT whenever the .prg files are rebuilt for a
//! release - it is the one thing to remember when cutting a release that ships a new watch
//! binary. Annotated (:glance) because the glance reads it.
(:glance :background)
module Version {
    const APP = "1.12";
}
