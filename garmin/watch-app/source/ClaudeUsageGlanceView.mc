import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! The glance: two rows of up to three meters. Top row Claude (5H, 1W, model cap); bottom row
//! Codex (5H, 1W) and Cursor (plan). Each cell is "label  %" over a bar. The phone's one-row
//! widget has a taller band; a glance is a short, fixed-height strip, and five or six columns
//! across it overlapped, so the layout is a grid. Reset times are on the full pages instead.
//!
//! Glance code runs in its own small memory budget, hence (:glance) here and on everything
//! it touches. Keep this view allocation-free on the draw path.
(:glance)
class ClaudeUsageGlanceView extends WatchUi.GlanceView {

    // Bar colours: Claude's matches @color/accent on the phone; Codex and Cursor use the
    // colours of their full pages (UsagePages.accentOf), so a bar reads as the same provider
    // in both places. Glances are always drawn on the system's dark background.
    private const CLAUDE = 0xE8896B;
    private const CODEX = 0x8CA0FF;
    private const CURSOR = 0xEDEDED;
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

        // Version at the top-centre: the one part of the top strip the round screen does not
        // clip. Dim, so it never competes with the numbers. Shown even in the empty state.
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, 0, Graphics.FONT_XTINY, "v" + Version.APP,
            Graphics.TEXT_JUSTIFY_CENTER);

        // A provider the phone sent nothing for (not set up in desktop Orca, or no model cap
        // on this Claude account) simply has no cell; the cells after it move up. Codex's
        // 5-hour window is missing at times (Orca sent none on 2026-10-19), so each Codex
        // window is checked on its own.
        var claude = Snapshot.hasData();
        var model = claude && Snapshot.hasModelWeekly();
        var codexOk = Snapshot.hasNumbers(Snapshot.K_X_FETCHED);
        var codexFive = codexOk && Snapshot.percent(Snapshot.K_X_FIVE) >= 0;
        var codexWeek = codexOk && Snapshot.percent(Snapshot.K_X_WEEK) >= 0;
        var cursor = Snapshot.hasNumbers(Snapshot.K_U_FETCHED) && Snapshot.percent(Snapshot.K_U_PLAN) >= 0;

        if (!claude && !codexFive && !codexWeek && !cursor) {
            drawCentered(dc, w, h, "Open on phone");
            return;
        }

        // A round display clips the corners of the glance band, and the band sits high on the
        // screen, so the columns are inset and the first row starts below the version text.
        var inset = w * 0.09;
        var gap = w * 0.025;
        // The right-hand inset is larger than the left: the glance's top-right corner is rounder
        // than the top-left and clipped the third column's percentage.
        var colW = ((w * 0.78) - (2 * gap)) / 3;
        var step = colW + gap;
        // The top row sits where the round glance is narrowest, so its cells are narrower still.
        var colW1 = colW * 0.86;
        var step1 = colW1 + gap;
        var rowH = h * 0.38;
        var y1 = h * 0.20;
        var y2 = y1 + rowH + (h * 0.04);

        var font = cellFont(h);
        var i = 0;
        if (claude) {
            drawCell(dc, inset, y1, colW1, rowH, font, "5H", Snapshot.percent(Snapshot.K_FIVE), CLAUDE);
            drawCell(dc, inset + step1, y1, colW1, rowH, font, "1W", Snapshot.percent(Snapshot.K_WEEK), CLAUDE);
            if (model) {
                drawCell(dc, inset + (step1 * 2), y1, colW1, rowH, font, Snapshot.modelName(),
                    Snapshot.percent(Snapshot.K_MODEL), CLAUDE);
            }
        }
        if (codexFive) {
            drawCell(dc, inset + (step * i), y2, colW, rowH, font, "Codex 5H",
                Snapshot.percent(Snapshot.K_X_FIVE), CODEX);
            i++;
        }
        if (codexWeek) {
            drawCell(dc, inset + (step * i), y2, colW, rowH, font, "Codex 1W",
                Snapshot.percent(Snapshot.K_X_WEEK), CODEX);
            i++;
        }
        if (cursor) {
            drawCell(dc, inset + (step * i), y2, colW, rowH, font, "Cursor",
                Snapshot.percent(Snapshot.K_U_PLAN), CURSOR);
        }

        if (Snapshot.isStale(Snapshot.K_FETCHED)) {
            // A small dot rather than text: the numbers are still worth showing, they just
            // should not be trusted to the minute. Kept inside the inset so the round bezel
            // does not eat it. It follows Claude's fetch time; each provider has its own.
            dc.setColor(STALE, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(w - inset, h * 0.08, 4);
        }
    }

    //! One cell: the label at the left and the percentage at the right of one line, over a bar.
    //! The percentage is right-aligned so a long label ("Codex 5H") and "100%" share the cell
    //! width without a fixed split.
    private function drawCell(
        dc as Dc,
        x as Numeric,
        y as Numeric,
        colW as Numeric,
        rowH as Numeric,
        font as Graphics.FontType,
        label as String,
        pct as Number,
        accent as Number
    ) as Void {
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, font, label, Graphics.TEXT_JUSTIFY_LEFT);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + colW, y, font, pct.toString() + "%",
            Graphics.TEXT_JUSTIFY_RIGHT);

        var barY = y + (rowH * 0.70);
        var barH = rowH * 0.16;
        dc.setColor(TRACK, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(x, barY, colW, barH);

        var filled = colW * clampPct(pct) / 100.0;
        if (filled > 0) {
            dc.setColor(accent, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(x, barY, filled, barH);
        }
    }

    //! A condensed vector font, so "Codex 5H" and "100%" fit one 90 px cell. The system's
    //! smallest bitmap font (FONT_XTINY) is too wide for that; the vector font is sized off
    //! the glance height, so another screen needs no change. Falls back to FONT_XTINY on a
    //! device without vector fonts.
    private function cellFont(h as Numeric) as Graphics.FontType {
        if (Graphics has :getVectorFont) {
            var vf = Graphics.getVectorFont({:face => ["RobotoCondensedBold", "RobotoCondensedRegular"],
                :size => (h * 0.13).toNumber()});
            if (vf != null) {
                return vf;
            }
        }
        return Graphics.FONT_XTINY;
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
