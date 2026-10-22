import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! The full-screen provider pages - Claude, Codex, Cursor - shared by both watch apps.
//!
//! Reached by opening an app from the glance or the app list, or by holding one of its meters
//! on a watch face (the faces' hold-to-launch, which calls Complications.exitTo on our
//! complication and opens the page that complication belongs to). The pages are a ViewLoop, so
//! swipe up/down or the up/down buttons move between them and the system draws the page dots.
//!
//! The page ids (UsageApp.CLAUDE / CODEX / CURSOR) and the launch-page choice live in UsageApp,
//! which the background image also needs; this module is foreground-only.
module UsagePages {

    //! The initial view for an app whose pages are [pages] (page ids, in order), opened on the
    //! index [start]. Wraps around, so the last page leads back to the first.
    function initialView(pages as Array<Number>, start as Number) as [WatchUi.Views, WatchUi.InputDelegates] {
        var loop = new WatchUi.ViewLoop(new UsagePageFactory(pages), {:page => start, :wrap => true});
        return [loop, new WatchUi.ViewLoopDelegate(loop)];
    }
}

//! Hands the ViewLoop one provider page per index.
class UsagePageFactory extends WatchUi.ViewLoopFactory {

    private var _pages as Array<Number>;

    public function initialize(pages as Array<Number>) {
        ViewLoopFactory.initialize();
        _pages = pages;
    }

    public function getSize() as Number {
        return _pages.size();
    }

    // The return type must be the base class's typedefs exactly; an equivalent spelled-out
    // type is refused as "a different return type".
    public function getView(page as Number) as
        [WatchUi.ViewLoopFactory.Views] or [WatchUi.ViewLoopFactory.Views, WatchUi.ViewLoopFactory.Delegates] {
        // Always a pair. The docs allow a bare [view], but ViewLoop reads index 1 regardless:
        // a one-element array fails the app start with "Array Out Of Bounds Error" and no stack
        // (simulator, SDK 9.2.0, 2026-10-22). A plain BehaviorDelegate handles nothing, so
        // up/down still reach the ViewLoopDelegate that turns the pages.
        return [new UsagePageView(_pages[page]), new WatchUi.BehaviorDelegate()];
    }
}

//! One provider's meters: a title, then one row per window the phone sent - label, % used and
//! when it resets, over a bar - then how old the numbers are and the app version.
//!
//! Round display, so everything is centre-justified and the rows are inset from the edges -
//! text flush to the left edge of a circle is clipped by the bezel.
class UsagePageView extends WatchUi.View {

    private const TRACK = 0x333333;
    private const STALE = 0xFFC233;

    private var _page as Number;

    public function initialize(page as Number) {
        View.initialize();
        _page = page;
    }

    public function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var name = providerName();
        var fetchedKey = fetchedKeyOf();

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.10, Graphics.FONT_XTINY, name + " usage", Graphics.TEXT_JUSTIFY_CENTER);

        if (!Snapshot.hasNumbers(fetchedKey)) {
            // The phone sends a provider's numbers only when it has some from Orca, so an
            // empty page means that provider is not set up in desktop Orca (or the phone app
            // predates these pages). Not "yet": a page the phone stopped sending is blanked too.
            dc.drawText(cx, h / 2, Graphics.FONT_SMALL, "No " + name + " data",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText(cx, h * 0.60, Graphics.FONT_XTINY, "from the phone",
                Graphics.TEXT_JUSTIFY_CENTER);
            drawVersion(dc, cx, h);
            return;
        }

        // Rows are spaced off the display height rather than fixed pixels, because the
        // supported devices span 416x416 to 454x454. Only the windows the phone sent are
        // drawn, top-down, so a missing one (Codex's 5-hour window, say) leaves no hole.
        var rowH = h * 0.17;
        var y = h * 0.24;
        var barW = w * 0.54;
        var rows = rowsOf();
        for (var i = 0; i < rows.size(); i++) {
            var row = rows[i];
            var pct = Snapshot.percent(row[1]);
            var label = row[0];
            if (label.equals("")) {
                label = Snapshot.modelName(); // the capped model's own name ("Fable")
            }
            if (pct < 0 || label.equals("")) {
                continue;
            }
            drawRow(dc, cx, y, barW, rowH, label, pct, Snapshot.resetAt(row[2]));
            y += rowH;
        }

        // Always show the data's age - grey while fresh, amber once stale - so a watch that
        // stopped receiving pushes is visible before the stale threshold, and how long it has
        // been is readable without guessing. Each provider has its own fetch time.
        var age = Snapshot.ageText(fetchedKey);
        if (!age.equals("")) {
            dc.setColor(Snapshot.isStale(fetchedKey) ? STALE : Graphics.COLOR_LT_GRAY,
                Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h * 0.83, Graphics.FONT_XTINY, age, Graphics.TEXT_JUSTIFY_CENTER);
        }

        drawVersion(dc, cx, h);
    }

    private function providerName() as String {
        if (_page == UsageApp.CODEX) { return "Codex"; }
        if (_page == UsageApp.CURSOR) { return "Cursor"; }
        return "Claude";
    }

    //! The provider's fetch-time key: present means the phone sent this provider's group.
    private function fetchedKeyOf() as String {
        if (_page == UsageApp.CODEX) { return Snapshot.K_X_FETCHED; }
        if (_page == UsageApp.CURSOR) { return Snapshot.K_U_FETCHED; }
        return Snapshot.K_FETCHED;
    }

    //! The bar colour: the phone widget's dark-theme accent for the provider
    //! (app/src/main/res/values-night/colors.xml), so the two read as one product.
    private function accentOf() as Number {
        if (_page == UsageApp.CODEX) { return 0x8CA0FF; }
        if (_page == UsageApp.CURSOR) { return 0xEDEDED; }
        return 0xE8896B;
    }

    //! [label, % key, reset key] per row, in display order. An empty label is the model cap,
    //! labelled with the model's own name at draw time.
    private function rowsOf() as Array<[String, String, String]> {
        if (_page == UsageApp.CODEX) {
            return [
                ["5H", Snapshot.K_X_FIVE, Snapshot.K_X_FIVE_RESET],
                ["1W", Snapshot.K_X_WEEK, Snapshot.K_X_WEEK_RESET],
            ];
        }
        if (_page == UsageApp.CURSOR) {
            return [
                ["Plan", Snapshot.K_U_PLAN, Snapshot.K_U_PLAN_RESET],
                ["Auto", Snapshot.K_U_AUTO, Snapshot.K_U_AUTO_RESET],
                ["API", Snapshot.K_U_API, Snapshot.K_U_API_RESET],
            ];
        }
        return [
            ["5H", Snapshot.K_FIVE, Snapshot.K_FIVE_RESET],
            ["1W", Snapshot.K_WEEK, Snapshot.K_WEEK_RESET],
            ["", Snapshot.K_MODEL, Snapshot.K_MODEL_RESET],
        ];
    }

    //! One window: "5H  37%   3h" over a progress bar.
    private function drawRow(
        dc as Dc,
        cx as Numeric,
        y as Numeric,
        barW as Numeric,
        rowH as Numeric,
        label as String,
        pct as Number,
        resetEpoch as Number
    ) as Void {
        var left = cx - (barW / 2);
        var right = cx + (barW / 2);

        var font = Graphics.FONT_XTINY;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(left, y, font, label, Graphics.TEXT_JUSTIFY_LEFT);

        var resets = Snapshot.resetsAt(resetEpoch);
        var resetW = 0;
        if (!resets.equals("")) {
            dc.drawText(right, y, font, resets, Graphics.TEXT_JUSTIFY_RIGHT);
            resetW = dc.getTextWidthInPixels(resets, font);
        }

        // Centred, so the percentages line up down the page - unless that would run into the
        // reset text: Cursor's monthly resets read as a date ("Nov 30"), and next to "100%"
        // the two touched. Then it moves left, but never over the label.
        var text = pct.toString() + "%";
        var half = dc.getTextWidthInPixels(text, font) / 2;
        var gap = barW * 0.03;
        var x = cx;
        if (x + half > right - resetW - gap) {
            x = right - resetW - gap - half;
        }
        var minX = left + dc.getTextWidthInPixels(label, font) + gap + half;
        if (x < minX) {
            x = minX;
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, font, text, Graphics.TEXT_JUSTIFY_CENTER);

        var barY = y + (rowH * 0.62);
        var barH = rowH * 0.16;
        dc.setColor(TRACK, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(left, barY, barW, barH);

        var filled = barW * clampPct(pct) / 100.0;
        if (filled > 0) {
            dc.setColor(accentOf(), Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(left, barY, filled, barH);
        }
    }

    //! Version at the bottom, dim - the watch apps' own, so a sideload can be confirmed.
    private function drawVersion(dc as Dc, cx as Numeric, h as Numeric) as Void {
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.90, Graphics.FONT_XTINY, "v" + Version.APP,
            Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function clampPct(pct as Number) as Number {
        if (pct < 0) { return 0; }
        if (pct > 100) { return 100; }
        return pct;
    }
}
