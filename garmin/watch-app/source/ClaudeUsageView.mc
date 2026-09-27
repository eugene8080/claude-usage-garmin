import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! The full-screen app view, reached by opening the app from the glance or the app list.
//!
//! It shows what the glance cannot fit: the countdown to each window's reset. Round display,
//! so everything is centre-justified and the rows are inset from the edges - text flush to
//! the left edge of a circle is clipped by the bezel.
class ClaudeUsageView extends WatchUi.View {

    private const ACCENT = 0xE8896B;
    private const TRACK = 0x333333;
    private const STALE = 0xFFC233;

    public function initialize() {
        View.initialize();
    }

    public function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;

        if (!Snapshot.hasData()) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                cx,
                h / 2,
                Graphics.FONT_SMALL,
                "Sign in on phone",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
            return;
        }

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.10, Graphics.FONT_XTINY, "Claude usage",
            Graphics.TEXT_JUSTIFY_CENTER);

        // Rows are spaced off the display height rather than fixed pixels, because the
        // supported devices span 416x416 to 454x454.
        var rowH = h * 0.17;
        var firstY = h * 0.24;
        var barW = w * 0.54;

        drawRow(dc, cx, firstY, barW, rowH, "5H",
            Snapshot.percent(Snapshot.K_FIVE), Snapshot.resetAt(Snapshot.K_FIVE_RESET));
        drawRow(dc, cx, firstY + rowH, barW, rowH, "1W",
            Snapshot.percent(Snapshot.K_WEEK), Snapshot.resetAt(Snapshot.K_WEEK_RESET));
        if (Snapshot.hasModelWeekly()) {
            drawRow(dc, cx, firstY + (rowH * 2), barW, rowH, Snapshot.modelName(),
                Snapshot.percent(Snapshot.K_MODEL), Snapshot.resetAt(Snapshot.K_MODEL_RESET));
        }

        // Always show the data's age - grey while fresh, amber once stale - so a watch that
        // stopped receiving pushes is visible before the stale threshold, and how long it has
        // been is readable without guessing.
        var age = Snapshot.ageText();
        if (!age.equals("")) {
            dc.setColor(Snapshot.isStale() ? STALE : Graphics.COLOR_LT_GRAY,
                Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h * 0.83, Graphics.FONT_XTINY, age, Graphics.TEXT_JUSTIFY_CENTER);
        }

        // Version at the bottom, dim - the watch app's own, so a sideload can be confirmed.
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.90, Graphics.FONT_XTINY, "v" + Version.APP,
            Graphics.TEXT_JUSTIFY_CENTER);
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

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(left, y, Graphics.FONT_XTINY, label, Graphics.TEXT_JUSTIFY_LEFT);

        var resets = Snapshot.resetsAt(resetEpoch);
        if (!resets.equals("")) {
            dc.drawText(right, y, Graphics.FONT_XTINY, resets, Graphics.TEXT_JUSTIFY_RIGHT);
        }

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, Graphics.FONT_XTINY, pct.toString() + "%",
            Graphics.TEXT_JUSTIFY_CENTER);

        var barY = y + (rowH * 0.62);
        var barH = rowH * 0.16;
        dc.setColor(TRACK, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(left, barY, barW, barH);

        var filled = barW * clampPct(pct) / 100.0;
        if (filled > 0) {
            dc.setColor(ACCENT, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(left, barY, filled, barH);
        }
    }

    private function clampPct(pct as Number) as Number {
        if (pct < 0) { return 0; }
        if (pct > 100) { return 100; }
        return pct;
    }
}
