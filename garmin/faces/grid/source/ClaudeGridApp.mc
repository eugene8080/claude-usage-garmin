import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//! "Claude Grid" - an Iron Grit-style data face in Chakra Petch with eight user-editable
//! complication slots (Data 01-08; 07 is the bottom dial, the live seconds until a field is
//! picked for it), configured with
//! Garmin's native on-device watch face editor. The view always comes with a WatchFaceDelegate:
//! in the editor it maps taps to slots so the editor can preview them, and on the live face it
//! handles touch-and-hold on a slot (hold-to-launch the complication's app).
//!
//! (:background) because the HKO weather service (garmin/shared/source-weather/HkoService.mc)
//! runs in this app's background process, which starts from this class; the view and everything
//! else stay out of the background's memory.
(:background)
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
        Hko.schedule();   // the 10-minute HKO fetch, on or off per the HkoStation setting
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

    //! The HKO weather service (background process).
    public function getServiceDelegate() as [System.ServiceDelegate] {
        return [new HkoService()];
    }

    //! A background HKO fetch finished: store its readings and redraw with them.
    public function onBackgroundData(data as Application.PersistableType) as Void {
        Hko.merge(data);
        WatchUi.requestUpdate();
    }

    //! Garmin Connect (phone) settings were saved - re-read them and redraw.
    public function onSettingsChanged() as Void {
        Hko.schedule();   // the HKO station may have been switched on or off
        if (_view != null) {
            (_view as ClaudeGridView).readSettings();
        }
        WatchUi.requestUpdate();
    }
}
