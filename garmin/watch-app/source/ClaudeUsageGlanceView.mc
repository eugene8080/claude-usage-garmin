import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! The glance: three meters across a short horizontal band, laid out the same way as the
//! phone's one-row home-screen widget so the two read as one product.
//!
//! Glance code runs in its own small memory budget, hence (:glance) here and on everything
//! it touches. Keep this view allocation-free on the draw path.
(:glance)
class ClaudeUsageGlanceView extends WatchUi.GlanceView {

    // Claude's accent, matching @color/accent on the phone. Glances are always drawn on the
    // system's dark background, so the dark-theme variant is the right one.
    private const ACCENT = 0xE8896B;
    private const TRACK = 0x333333;
    private const STALE = 0xFFC233;

    public function initialize() {
        GlanceView.initialize();
    }

    public function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_BLACK);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();

        // Version at the top-centre. That strip is otherwise empty (the labels were pushed
        // down to clear the bezel) and the centre column is the one part of the top the round
        // screen does not clip, so it costs no layout room. Dim, so it never competes with
        // the numbers. Shown even in the empty state below.
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, 0, Graphics.FONT_XTINY, "v" + Version.APP,
            Graphics.TEXT_JUSTIFY_CENTER);

        if (!Snapshot.hasData()) {
            drawCentered(dc, w, h, "Open on phone");
            return;
        }

        // Two or three columns depending on whether this account has a per-model cap. The
        // divisor is the count, not a constant, so a missing third meter widens the other
        // two rather than leaving a hole.
        var count = Snapshot.hasModelWeekly() ? 3 : 2;

        // A round display clips the corners of the glance band, and the band sits high on the
        // screen so its top is the narrowest part - a full-width layout loses the ends of the
        // outer labels ("5H" -> "H", "Fable" -> "Fa"). Inset the columns and keep the top row
        // out of the very top so every label clears the bezel.
        var inset = w * 0.12;
        var avail = w - (2 * inset);
        var gap = w * 0.03;
        var colW = (avail - (gap * (count - 1))) / count;

        // resetAt() resolves the storage key to an epoch; resetsAt() formats that epoch as a
        // wall-clock time. Both steps here, same as the full view does.
        drawMeter(dc, inset, colW, h, "5H", Snapshot.percent(Snapshot.K_FIVE),
            Snapshot.resetsAt(Snapshot.resetAt(Snapshot.K_FIVE_RESET)));
        drawMeter(dc, inset + colW + gap, colW, h, "1W", Snapshot.percent(Snapshot.K_WEEK),
            Snapshot.resetsAt(Snapshot.resetAt(Snapshot.K_WEEK_RESET)));
        if (count == 3) {
            drawMeter(
                dc,
                inset + ((colW + gap) * 2),
                colW,
                h,
                Snapshot.modelName(),
                Snapshot.percent(Snapshot.K_MODEL),
                Snapshot.resetsAt(Snapshot.resetAt(Snapshot.K_MODEL_RESET))
            );
        }

        if (Snapshot.isStale()) {
            // A small dot rather than text: the numbers are still worth showing, they just
            // should not be trusted to the minute. Kept inside the inset so the round bezel
            // does not eat it.
            dc.setColor(STALE, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(w - inset, h * 0.14, 4);
        }
    }

    //! One meter: label, percentage, reset time, bar - stacked, so a long model name and
    //! "100%" never collide in a narrow column. The reset line is what makes the glance
    //! answer "when is it back", the way the Claude usage menu does; it is dimmed so the
    //! percentage stays the thing the eye lands on.
    private function drawMeter(
        dc as Dc,
        x as Numeric,
        colW as Numeric,
        h as Numeric,
        label as String,
        pct as Number,
        resets as String
    ) as Void {
        var labelY = h * 0.17;
        var valueY = h * 0.39;
        var resetY = h * 0.63;
        var barY = h * 0.87;
        var barH = h * 0.08;

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, labelY, Graphics.FONT_XTINY, label, Graphics.TEXT_JUSTIFY_LEFT);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            x,
            valueY,
            Graphics.FONT_TINY,
            pct.toString() + "%",
            Graphics.TEXT_JUSTIFY_LEFT
        );

        if (!resets.equals("")) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, resetY, Graphics.FONT_XTINY, resets, Graphics.TEXT_JUSTIFY_LEFT);
        }

        dc.setColor(TRACK, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x, barY, colW, barH);

        var filled = colW * clampPct(pct) / 100.0;
        if (filled > 0) {
            dc.setColor(ACCENT, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(x, barY, filled, barH);
        }
    }

    private function clampPct(pct as Number) as Number {
        if (pct < 0) { return 0; }
        if (pct > 100) { return 100; }
        return pct;
    }

    private function drawCentered(dc as Dc, w as Numeric, h as Numeric, text as String) as Void {
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            w / 2,
            h / 2,
            Graphics.FONT_XTINY,
            text,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }
}
