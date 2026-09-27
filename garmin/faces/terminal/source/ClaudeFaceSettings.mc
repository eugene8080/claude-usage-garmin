import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

//! On-watch settings for Claude Terminal (returned from ClaudeFaceApp.getSettingsView; hold the
//! face > Settings). They write the same Application.Properties as the Garmin Connect settings
//! (resources/settings/settings.xml), so either route works - and for a SIDELOADED face this is
//! the only route: Garmin Connect only edits the settings of faces installed from the store.
//!
//! The prompt text is edited with the watch's own text entry (WatchUi.TextPicker - supported on
//! the fenix 8 family, and allowed in watch faces), so it can be changed without a phone too.
class ClaudeFaceSettingsMenu extends WatchUi.Menu2 {

    public function initialize() {
        Menu2.initialize({ :title => Rez.Strings.settingsTitle });
        addItem(new WatchUi.MenuItem(Rez.Strings.promptTextTitle, FaceSettings.readPrompt(), :prompt, null));
        addItem(new WatchUi.ToggleMenuItem(Rez.Strings.themeRetroToggle, Rez.Strings.themeRetroSub,
            :retro, FaceSettings.readNumber("Theme", 1) == 1, null));
        addItem(new WatchUi.ToggleMenuItem(Rez.Strings.scanlinesTitle, null,
            :scan, FaceSettings.readBool("Scanlines", true), null));
        addItem(new WatchUi.ToggleMenuItem(Rez.Strings.showSecondsTitle, null,
            :secs, FaceSettings.readBool("ShowSeconds", true), null));
    }
}

//! Typed property readers with defaults (a property can be missing or the wrong type after an
//! update that added it).
module FaceSettings {

    function readBool(key as String, dflt as Boolean) as Boolean {
        var v = Application.Properties.getValue(key);
        return (v instanceof Lang.Boolean) ? (v as Boolean) : dflt;
    }

    function readNumber(key as String, dflt as Number) as Number {
        var v = Application.Properties.getValue(key);
        return (v instanceof Lang.Number) ? (v as Number) : dflt;
    }

    //! The prompt line's text (same default as properties.xml / the view).
    function readPrompt() as String {
        var v = Application.Properties.getValue("PromptText");
        return (v instanceof Lang.String) ? (v as String) : "fenix@tactix ~ $";
    }

    //! Same 24-character cap as the Garmin Connect setting (settings.xml maxLength), so a long
    //! entry can't run past the round screen's edge.
    const PROMPT_MAX = 24;
}

//! Each toggle writes its property as it flips; the face re-reads everything in onShow when the
//! menu closes (ClaudeFaceView.readSettings), so the change shows on return.
class ClaudeFaceSettingsDelegate extends WatchUi.Menu2InputDelegate {

    private var _menu as ClaudeFaceSettingsMenu;

    public function initialize(menu as ClaudeFaceSettingsMenu) {
        Menu2InputDelegate.initialize();
        _menu = menu;
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :prompt) {
            // The watch's text entry, prefilled with the current prompt.
            WatchUi.pushView(new WatchUi.TextPicker(FaceSettings.readPrompt()),
                new ClaudeFacePromptDelegate(_menu), WatchUi.SLIDE_LEFT);
            return;
        }
        var on = (item as WatchUi.ToggleMenuItem).isEnabled();
        if (id == :retro) {
            Application.Properties.setValue("Theme", on ? 1 : 0);
        } else if (id == :scan) {
            Application.Properties.setValue("Scanlines", on);
        } else if (id == :secs) {
            Application.Properties.setValue("ShowSeconds", on);
        }
    }
}

//! Saves the text entered for the prompt (trimmed to PROMPT_MAX) and updates the menu row's
//! sub-label so the new text shows on return. An empty entry keeps the old prompt.
class ClaudeFacePromptDelegate extends WatchUi.TextPickerDelegate {

    private var _menu as ClaudeFaceSettingsMenu;

    public function initialize(menu as ClaudeFaceSettingsMenu) {
        TextPickerDelegate.initialize();
        _menu = menu;
    }

    public function onTextEntered(text as String, changed as Boolean) as Boolean {
        if (text.length() > 0) {
            var t = (text.length() > FaceSettings.PROMPT_MAX)
                ? text.substring(0, FaceSettings.PROMPT_MAX) as String : text;
            Application.Properties.setValue("PromptText", t);
            var pos = _menu.findItemById(:prompt);
            if (pos >= 0) {
                var row = _menu.getItem(pos);
                if (row != null) { row.setSubLabel(t); }
            }
        }
        return true;   // close the picker, back to the menu
    }

    public function onCancel() as Boolean {
        return true;
    }
}
