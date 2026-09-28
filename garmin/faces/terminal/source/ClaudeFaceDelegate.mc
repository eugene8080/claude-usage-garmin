import Toybox.Lang;
import Toybox.WatchUi;

//! Touch-and-hold on the Claude Terminal face launches the app behind what is under the finger
//! (Garmin's "hold to launch"): a meter row opens the Claude Usage app that publishes it, the
//! weather line opens the watch's weather app. The hit-testing lives in the view, which owns the
//! layout (ClaudeFaceView.launchComplicationAt).
class ClaudeFaceDelegate extends WatchUi.WatchFaceDelegate {

    private var _view as ClaudeFaceView;

    public function initialize(view as ClaudeFaceView) {
        WatchFaceDelegate.initialize();
        _view = view;
    }

    //! A hold anywhere else (the prompt, the time, the date, the battery bar) returns false, so
    //! the system's own hold action still runs there.
    public function onPress(clickEvent as WatchUi.ClickEvent) as Boolean {
        var coords = clickEvent.getCoordinates();
        return _view.launchComplicationAt(coords[0], coords[1]);
    }
}
