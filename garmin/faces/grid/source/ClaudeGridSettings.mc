import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

//! On-watch settings for Claude Grid (returned from ClaudeGridApp.getSettingsView): the Data 08
//! time-zone city and the "always the clock" switch. Writes the same Application.Properties the
//! Garmin Connect settings (resources/settings/settings.xml) write, so either route works.
class ClaudeGridSettingsMenu extends WatchUi.Menu2 {

    public function initialize() {
        Menu2.initialize({ :title => Rez.Strings.settingsTitle });
        addItem(new WatchUi.MenuItem(Rez.Strings.altTzCityTitle, GridSettings.cityName(), :city, null));
        addItem(new WatchUi.ToggleMenuItem(Rez.Strings.altTzAlwaysTitle, Rez.Strings.altTzAlwaysSub,
            :always, GridSettings.readAlways(), null));
    }
}

//! Property readers shared by the menus and the view.
module GridSettings {

    function cityIndex() as Number {
        return AltTz.clampIndex(Application.Properties.getValue("AltTzCity"));
    }

    //! Current city's display name (loaded, because the sub-label is refreshed as a String).
    function cityName() as String {
        return WatchUi.loadResource(AltTz.names()[cityIndex()]) as String;
    }

    function readAlways() as Boolean {
        var v = Application.Properties.getValue("AltTzAlways");
        return (v instanceof Lang.Boolean) ? (v as Boolean) : false;
    }
}

class ClaudeGridSettingsDelegate extends WatchUi.Menu2InputDelegate {

    private var _menu as ClaudeGridSettingsMenu;

    public function initialize(menu as ClaudeGridSettingsMenu) {
        Menu2InputDelegate.initialize();
        _menu = menu;
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :city) {
            var picker = new ClaudeGridCityMenu();
            WatchUi.pushView(picker, new ClaudeGridCityDelegate(_menu), WatchUi.SLIDE_LEFT);
        } else if (id == :always) {
            Application.Properties.setValue("AltTzAlways", (item as WatchUi.ToggleMenuItem).isEnabled());
        }
    }
}

//! The city list: one item per AltTz index, the current one focused.
class ClaudeGridCityMenu extends WatchUi.Menu2 {

    public function initialize() {
        var cur = GridSettings.cityIndex();
        Menu2.initialize({ :title => Rez.Strings.altTzCityTitle, :focus => cur });
        var names = AltTz.names();
        for (var i = 0; i < names.size(); i++) {
            addItem(new WatchUi.MenuItem(names[i], null, i, null));
        }
    }
}

class ClaudeGridCityDelegate extends WatchUi.Menu2InputDelegate {

    private var _parent as ClaudeGridSettingsMenu;

    public function initialize(parent as ClaudeGridSettingsMenu) {
        Menu2InputDelegate.initialize();
        _parent = parent;
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var idx = AltTz.clampIndex(item.getId());
        Application.Properties.setValue("AltTzCity", idx);
        // Refresh the parent's sub-label so the new city shows when we slide back.
        var pos = _parent.findItemById(:city);
        if (pos >= 0) {
            var row = _parent.getItem(pos);
            if (row != null) { row.setSubLabel(GridSettings.cityName()); }
        }
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
