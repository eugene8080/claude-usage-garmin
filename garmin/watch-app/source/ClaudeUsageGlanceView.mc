import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! The glance: three lines of plain text, one per provider, no bars and no version.
//!
//!   CLA 5H1% 1W15% FA0%
//!   CDX 1W 0%
//!   CUR P14% A14% api 0%
//!
//! Labels are light grey; each number takes its provider's colour (Claude orange, Codex blue,
//! Cursor white). The design comes from docs/watch-glance-editor/glance-editor.html (Eugene's
//! settings, 2026-11-13): Roboto Condensed Regular at 29/142 of the glance height, 4 px side
//! padding and 19 px top padding at the editor's 347 x 142 glance, 105 % line spacing. Sizes
//! are fractions of the glance's own width and height, so they follow the real glance size.
//!
//! A meter the phone sent nothing for is left out, and a line with nothing on it is left out;
//! the lines below move up. Codex shows only its weekly window: Orca sends no Codex 5-hour
//! window for this account.
//!
//! Glance code runs in its own small memory budget, hence (:glance) here and on everything
//! it touches. Keep this view allocation-light on the draw path.
(:glance)
class ClaudeUsageGlanceView extends WatchUi.GlanceView {

    // Provider colours match the full pages (UsagePages.accentOf) and the phone widget.
    private const CLAUDE = 0xE8896B;
    private const CODEX = 0x8CA0FF;
    private const CURSOR = 0xEDEDED;
    private const LABEL = 0xB9B9B9;
    private const STALE = 0xFFC233;

    // The editor's 347 x 142 glance: the fractions below are its pixel values divided by those.
    private const FONT_FRAC = 0.204;   // 29 / 142
    private const PAD_FRAC = 0.0115;   // 4 / 347
    private const TOP_FRAC = 0.134;    // 19 / 142
    private const LINE_GAP = 1.05;

    public function initialize() {
        GlanceView.initialize();
    }

    public function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_BLACK);
        dc.clear();

        var w = dc.getWidth();
        var h = dc.getHeight();

        var claude = Snapshot.hasData();
        var model = claude && Snapshot.hasModelWeekly();
        var codex = Snapshot.hasNumbers(Snapshot.K_X_FETCHED) && Snapshot.percent(Snapshot.K_X_WEEK) >= 0;
        var cursor = Snapshot.hasNumbers(Snapshot.K_U_FETCHED);

        var font = textFont(h);
        if (!claude && !codex && !cursor) {
            dc.setColor(LABEL, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h / 2, font, "Open on phone",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            return;
        }

        var x = w * PAD_FRAC;
        var fontPx = h * FONT_FRAC;
        var y = h * TOP_FRAC;
        var step = fontPx * LINE_GAP;

        if (claude) {
            var cx = run(dc, x, y, font, "CLA 5H", LABEL);
            cx = run(dc, cx, y, font, pct(Snapshot.percent(Snapshot.K_FIVE)), CLAUDE);
            cx = run(dc, cx, y, font, " 1W", LABEL);
            cx = run(dc, cx, y, font, pct(Snapshot.percent(Snapshot.K_WEEK)), CLAUDE);
            if (model) {
                // "FA" is the editor's short form of the model cap ("Fable"): the name is
                // whatever the API called it, so a different capped model keeps this layout.
                cx = run(dc, cx, y, font, " FA", LABEL);
                run(dc, cx, y, font, pct(Snapshot.percent(Snapshot.K_MODEL)), CLAUDE);
            }
            y += step;
        }
        if (codex) {
            var xx = run(dc, x, y, font, "CDX 1W ", LABEL);
            run(dc, xx, y, font, pct(Snapshot.percent(Snapshot.K_X_WEEK)), CODEX);
            y += step;
        }
        if (cursor) {
            var ux = run(dc, x, y, font, "CUR P", LABEL);
            ux = run(dc, ux, y, font, pct(Snapshot.percent(Snapshot.K_U_PLAN)), CURSOR);
            ux = run(dc, ux, y, font, " A", LABEL);
            ux = run(dc, ux, y, font, pct(Snapshot.percent(Snapshot.K_U_AUTO)), CURSOR);
            ux = run(dc, ux, y, font, " api ", LABEL);
            run(dc, ux, y, font, pct(Snapshot.percent(Snapshot.K_U_API)), CURSOR);
        }

        if (Snapshot.isStale(Snapshot.K_FETCHED)) {
            // A small dot rather than text: the numbers are still worth showing, they just
            // should not be trusted to the minute. It follows Claude's fetch time.
            dc.setColor(STALE, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(w - (w * 0.05), h * 0.08, 4);
        }
    }

    //! Draws [text] at ([x], [y]) in [colour] and returns where the next run starts.
    private function run(
        dc as Dc,
        x as Numeric,
        y as Numeric,
        font as Graphics.FontType,
        text as String,
        colour as Number
    ) as Numeric {
        dc.setColor(colour, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, font, text, Graphics.TEXT_JUSTIFY_LEFT);
        return x + dc.getTextWidthInPixels(text, font);
    }

    //! "14%", or a dash when the phone sent no number for the window (percent() gives -1).
    private function pct(value as Number) as String {
        return (value < 0) ? "-" : value.toString() + "%";
    }

    //! Roboto Condensed Regular, a vector font built into the watch, sized from the glance
    //! height. Falls back to FONT_XTINY on a device without vector fonts.
    private function textFont(h as Numeric) as Graphics.FontType {
        if (Graphics has :getVectorFont) {
            var vf = Graphics.getVectorFont({:face => ["RobotoCondensedRegular", "RobotoCondensedBold"],
                :size => (h * FONT_FRAC).toNumber()});
            if (vf != null) {
                return vf;
            }
        }
        return Graphics.FONT_XTINY;
    }
}
