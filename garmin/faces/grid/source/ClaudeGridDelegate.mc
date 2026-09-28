import Toybox.Application.WatchFaceConfig;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! Input for the Claude Grid face, in both of its modes:
//!
//!  - In the native watch face editor: maps taps to editable slots, provides a drawable the
//!    editor can pulse, and re-reads the configuration whenever the user changes a slot, colour
//!    or accent.
//!  - On the live face: touch-and-hold on a slot launches the app behind its complication
//!    (Garmin's "hold to launch"). The Claude meters open the Claude Usage app; a native field
//!    such as weather opens the watch's own app for it.
class ClaudeGridDelegate extends WatchUi.WatchFaceDelegate {

    private var _view as ClaudeGridView;
    private var _editMode as Boolean;

    public function initialize(view as ClaudeGridView, editMode as Boolean) {
        WatchFaceDelegate.initialize();
        _view = view;
        _editMode = editMode;
    }

    //! The user changed something in the editor - re-read the config and refresh the preview.
    public function onWatchFaceConfigEdited(options as Dictionary) as Void {
        var id = options[:configId];
        var type = options[:type];
        if (id != null) {
            var settings = WatchFaceConfig.getSettings(id);
            if (settings != null) {
                _view.updateConfiguration(settings, type);
            }
        }
    }

    //! The editor is asking for a drawable to illustrate the complication it wants to highlight.
    public function getComplicationDrawable(complication as ComplicationRef) as Drawable or ComplicationDrawableRef or Null {
        return _view.getComplication(complication);
    }

    //! Map a screen tap to an editable slot; tell the system which one was hit. The platform only
    //! delivers taps to a watch face in editor mode; the guard keeps it that way if that changes.
    public function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        if (!_editMode) { return false; }
        var coords = clickEvent.getCoordinates();
        var slotUid = _view.getTappedComplication(coords[0], coords[1]);
        if (slotUid != null) {
            setSelectedComplication(slotUid);
            return true;
        }
        return false;
    }

    //! Touch-and-hold on the live face: exit to the app that owns the complication under the
    //! finger. A hold anywhere else (the time, the seconds dial, the date) returns false, so the
    //! system's own hold action still runs there. Ignored in the editor, where a hold must not
    //! leave the configuration screen.
    public function onPress(clickEvent as WatchUi.ClickEvent) as Boolean {
        if (_editMode) { return false; }
        var coords = clickEvent.getCoordinates();
        return _view.launchComplicationAt(coords[0], coords[1]);
    }
}
