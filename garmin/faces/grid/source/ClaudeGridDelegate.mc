import Toybox.Application.WatchFaceConfig;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! Handles the native watch face editor's interaction with the Claude Grid face while it runs
//! in edit mode: mapping taps to editable slots, providing a drawable the editor can pulse, and
//! re-reading the configuration whenever the user changes a slot, colour or accent.
class ClaudeGridDelegate extends WatchUi.WatchFaceDelegate {

    private var _view as ClaudeGridView;

    public function initialize(view as ClaudeGridView) {
        WatchFaceDelegate.initialize();
        _view = view;
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

    //! Map a screen tap to an editable slot; tell the system which one was hit.
    public function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        var coords = clickEvent.getCoordinates();
        var slotUid = _view.getTappedComplication(coords[0], coords[1]);
        if (slotUid != null) {
            setSelectedComplication(slotUid);
            return true;
        }
        return false;
    }
}
