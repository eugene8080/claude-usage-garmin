import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

//! On-watch settings for Claude Grid (returned from ClaudeGridApp.getSettingsView): the Data 08
//! time-zone city, its "always the clock" switch, Data 07's "always seconds" switch, and the
//! per-slot face-computed fields (humidity, wind, chance of rain, battery in days). Writes the
//! same Application.Properties the Garmin Connect settings (resources/settings/settings.xml)
//! write, so either route works.
class ClaudeGridSettingsMenu extends WatchUi.Menu2 {

    public function initialize() {
        Menu2.initialize({ :title => Rez.Strings.settingsTitle });
        addItem(new WatchUi.MenuItem(Rez.Strings.altTzCityTitle, GridSettings.cityName(), :city, null));
        addItem(new WatchUi.ToggleMenuItem(Rez.Strings.altTzAlwaysTitle, Rez.Strings.altTzAlwaysSub,
            :always, GridSettings.readAlways(), null));
        addItem(new WatchUi.ToggleMenuItem(Rez.Strings.secAlwaysTitle, Rez.Strings.secAlwaysSub,
            :secAlways, GridSettings.readSecondsAlways(), null));
        addItem(new WatchUi.MenuItem(Rez.Strings.fieldsTitle, Rez.Strings.fieldsSub, :fields, null));
    }
}

//! Face-computed fields a slot can show instead of the editor's pick. Garmin's editor lists only
//! complications, and there is no complication for these, so the face reads them itself
//! (WeatherNow in garmin/shared/source-weather / System.getSystemStats). The values are the DataNField property
//! values and the settings.xml listEntry values - keep all three in the same order.
module GridField {
    enum {
        EDITOR = 0,      // the watch face editor's pick (default)
        HUMIDITY = 1,
        WIND = 2,
        PRECIP = 3,      // chance of rain
        BATT_DAYS = 4    // battery life in days
    }
    const COUNT = 5;

    function names() as Array<ResourceId> {
        return [Rez.Strings.fieldEditor, Rez.Strings.fieldHumidity, Rez.Strings.fieldWind,
                Rez.Strings.fieldPrecip, Rez.Strings.fieldBattDays];
    }

    //! The "Data 0N (where)" titles, index = slot uid - 1.
    function slotTitles() as Array<ResourceId> {
        return [Rez.Strings.slot1Title, Rez.Strings.slot2Title, Rez.Strings.slot3Title,
                Rez.Strings.slot4Title, Rez.Strings.slot5Title, Rez.Strings.slot6Title,
                Rez.Strings.slot7Title, Rez.Strings.slot8Title];
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

    function readSecondsAlways() as Boolean {
        var v = Application.Properties.getValue("SecondsAlways");
        return (v instanceof Lang.Boolean) ? (v as Boolean) : false;
    }

    //! Slot `uid`'s face-computed field (GridField), clamped: a stale or hand-edited value can't
    //! crash the face - it falls back to the editor's pick.
    function fieldFor(uid as Number) as Number {
        var v = Application.Properties.getValue("Data" + uid.toString() + "Field");
        if (v instanceof Lang.Number && (v as Number) >= 0 && (v as Number) < GridField.COUNT) {
            return v as Number;
        }
        return GridField.EDITOR;
    }

    function fieldName(uid as Number) as String {
        return WatchUi.loadResource(GridField.names()[fieldFor(uid)]) as String;
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
        } else if (id == :secAlways) {
            Application.Properties.setValue("SecondsAlways", (item as WatchUi.ToggleMenuItem).isEnabled());
        } else if (id == :fields) {
            var slots = new ClaudeGridFieldsMenu();
            WatchUi.pushView(slots, new ClaudeGridFieldsDelegate(slots), WatchUi.SLIDE_LEFT);
        }
    }
}

//! Data 01-08, each showing its current field; selecting one opens the field list.
class ClaudeGridFieldsMenu extends WatchUi.Menu2 {

    public function initialize() {
        Menu2.initialize({ :title => Rez.Strings.fieldsTitle });
        var titles = GridField.slotTitles();
        for (var i = 0; i < titles.size(); i++) {
            addItem(new WatchUi.MenuItem(titles[i], GridSettings.fieldName(i + 1), i + 1, null));
        }
    }
}

class ClaudeGridFieldsDelegate extends WatchUi.Menu2InputDelegate {

    private var _menu as ClaudeGridFieldsMenu;

    public function initialize(menu as ClaudeGridFieldsMenu) {
        Menu2InputDelegate.initialize();
        _menu = menu;
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var uid = item.getId() as Number;
        var picker = new ClaudeGridFieldPicker(uid);
        WatchUi.pushView(picker, new ClaudeGridFieldPickerDelegate(uid, _menu), WatchUi.SLIDE_LEFT);
    }
}

//! The field list for one slot, the current field focused.
class ClaudeGridFieldPicker extends WatchUi.Menu2 {

    public function initialize(uid as Number) {
        Menu2.initialize({ :title => GridField.slotTitles()[uid - 1], :focus => GridSettings.fieldFor(uid) });
        var names = GridField.names();
        for (var i = 0; i < names.size(); i++) {
            addItem(new WatchUi.MenuItem(names[i], null, i, null));
        }
    }
}

class ClaudeGridFieldPickerDelegate extends WatchUi.Menu2InputDelegate {

    private var _uid as Number;
    private var _parent as ClaudeGridFieldsMenu;

    public function initialize(uid as Number, parent as ClaudeGridFieldsMenu) {
        Menu2InputDelegate.initialize();
        _uid = uid;
        _parent = parent;
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        Application.Properties.setValue("Data" + _uid.toString() + "Field", item.getId() as Number);
        // Refresh the slot row's sub-label so the new field shows when we slide back.
        var pos = _parent.findItemById(_uid);
        if (pos >= 0) {
            var row = _parent.getItem(pos);
            if (row != null) { row.setSubLabel(GridSettings.fieldName(_uid)); }
        }
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
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
