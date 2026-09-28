import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

//! "Claude Grid" - an Iron Grit-style data face in Chakra Petch with seven user-editable
//! complication slots (Data 01-06, 08) plus a fixed seconds dial (Data 07), configured with
//! Garmin's native on-device watch face editor. The view always comes with a WatchFaceDelegate:
//! in the editor it maps taps to slots so the editor can preview them, and on the live face it
//! handles touch-and-hold on a slot (hold-to-launch the complication's app).
class ClaudeGridApp extends Application.AppBase {

    //! Whether the app was launched by the native watch face settings editor.
    private var _editMode as Boolean = false;

    public function initialize() {
        AppBase.initialize();
    }

    public function onStart(state as Dictionary?) as Void {
        if (state != null) {
            var editing = state[:launchedFromWatchFaceSettingsEditor] as Boolean?;
            if (editing != null && editing) {
                _editMode = true;
            }
        }
    }

    public function onStop(state as Dictionary?) as Void {
    }

    public function getInitialView() as [Views] or [Views, InputDelegates] {
        var view = new $.ClaudeGridView(_editMode);
        _view = view;
        return [view, new $.ClaudeGridDelegate(view, _editMode)];
    }

    //! Kept so a settings change (phone or watch) can reach the running face.
    private var _view as ClaudeGridView? = null;

    //! On-watch settings: the Data 08 time-zone city and the "always the clock" switch.
    public function getSettingsView() as [Views] or [Views, InputDelegates] or Null {
        var menu = new $.ClaudeGridSettingsMenu();
        return [menu, new $.ClaudeGridSettingsDelegate(menu)];
    }

    //! Garmin Connect (phone) settings were saved - re-read them and redraw.
    public function onSettingsChanged() as Void {
        if (_view != null) {
            (_view as ClaudeGridView).readSettings();
        }
        WatchUi.requestUpdate();
    }
}
