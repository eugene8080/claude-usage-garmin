import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

//! A terminal/CLI-styled watch face that shows the time plus the three Claude usage meters.
//! The meters are read by subscribing to the complications the companion "Claude Usage"
//! watch-app publishes - a watch face cannot receive phone pushes or read another app's
//! storage, so complications are the only channel for this data.
class ClaudeFaceApp extends Application.AppBase {

    public function initialize() {
        AppBase.initialize();
    }

    public function onStart(state as Dictionary?) as Void {
    }

    public function onStop(state as Dictionary?) as Void {
    }

    private var _view as ClaudeFaceView? = null;

    public function getInitialView() as [Views] or [Views, InputDelegates] {
        _view = new $.ClaudeFaceView();
        return [_view as ClaudeFaceView];
    }

    //! On-watch settings (hold the face > Settings): prompt text, theme, scanlines, show seconds.
    //! The only way to change them on a sideloaded face - see ClaudeFaceSettings.mc.
    public function getSettingsView() as [Views] or [Views, InputDelegates] or Null {
        var menu = new $.ClaudeFaceSettingsMenu();
        return [menu, new $.ClaudeFaceSettingsDelegate(menu)];
    }

    //! Garmin Connect settings saved (show seconds, prompt text, theme, scanlines): re-read, redraw.
    public function onSettingsChanged() as Void {
        if (_view != null) { (_view as ClaudeFaceView).readSettings(); }
        WatchUi.requestUpdate();
    }
}
