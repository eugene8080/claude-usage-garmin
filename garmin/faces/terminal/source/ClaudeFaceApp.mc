import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//! A terminal/CLI-styled watch face that shows the time plus the three Claude usage meters.
//! The meters are read by subscribing to the complications the companion "Claude Usage"
//! watch-app publishes - a watch face cannot receive phone pushes or read another app's
//! storage, so complications are the only channel for this data.
//!
//! (:background) because the HKO weather service (garmin/shared/source-weather/HkoService.mc)
//! runs in this app's background process, which starts from this class.
(:background)
class ClaudeFaceApp extends Application.AppBase {

    public function initialize() {
        AppBase.initialize();
    }

    public function onStart(state as Dictionary?) as Void {
    }

    public function onStop(state as Dictionary?) as Void {
    }

    private var _view as ClaudeFaceView? = null;

    //! The delegate handles touch-and-hold on a meter row or the weather line (hold-to-launch).
    public function getInitialView() as [Views] or [Views, InputDelegates] {
        Hko.schedule();   // the 10-minute HKO fetch, on or off per the HkoStation setting
        var view = new $.ClaudeFaceView();
        _view = view;
        return [view, new $.ClaudeFaceDelegate(view)];
    }

    //! On-watch settings (hold the face > Settings): prompt text, theme, scanlines, show seconds.
    //! The only way to change them on a sideloaded face - see ClaudeFaceSettings.mc.
    public function getSettingsView() as [Views] or [Views, InputDelegates] or Null {
        var menu = new $.ClaudeFaceSettingsMenu();
        return [menu, new $.ClaudeFaceSettingsDelegate(menu)];
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

    //! Garmin Connect settings saved (show seconds, prompt text, theme, scanlines, HKO station):
    //! re-read, reschedule the HKO fetch, redraw.
    public function onSettingsChanged() as Void {
        Hko.schedule();
        if (_view != null) { (_view as ClaudeFaceView).readSettings(); }
        WatchUi.requestUpdate();
    }
}
