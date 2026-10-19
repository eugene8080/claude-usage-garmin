package com.usage.claudewidget.widget

import android.content.Intent
import android.graphics.Paint
import android.graphics.Typeface
import android.util.TypedValue
import android.widget.RemoteViews
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalContext
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.AndroidRemoteViews
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontFamily
import androidx.glance.text.Text
import androidx.glance.text.TextAlign
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.usage.claudewidget.R
import com.usage.claudewidget.ui.MainActivity
import kotlin.math.ceil
import kotlin.math.min
import kotlin.math.pow

/**
 * The usage grid's design, exactly as Eugene set it in docs/widget-editor/usage-grid-editor.html
 * (2026-10-19, second round emailed the same day; the block is kept in
 * docs/widget-editor/usage-grid-design.jsonc). Lengths
 * and text sizes are dp at the design size [W] x [H]; the widget scales all of them by one factor
 * to the real 2x1 cell, so the proportions survive any launcher grid.
 *
 * Everything here is drawn natively by Glance - no picture of the widget: boxes are Box views
 * with background colours and corner radii, the halo is a translucent outer Box, the gloss and
 * bevel are one fixed vector drawable (grid_box_overlay), and the font is Android's built-in
 * `monospace` family (Droid Sans Mono).
 *
 * Text sizes are dp, like every other length (see [GridText]): the design is a fixed picture of
 * boxes and text, so the phone's font-size setting must not change one without the other.
 */
internal object GridDesign {
    const val W = 182f
    const val H = 114f
    const val R_WIDGET = 19f
    const val PAD_X = 9f
    const val LABEL_W = 12f
    const val LABEL_GAP = 3f
    const val BOX = 10.4f
    const val R_BOX = 3.8f
    const val GAP_X = 1.8f
    const val GAP_Y = 4.3f
    const val S_LABEL = 9.4f
    const val S_NUM = 8.7f
    /** Weekday and date resets (WED, NOV06). */
    const val S_RESET = 8.2f
    /** The time reset (1445) - sized on its own. */
    const val S_RESET_TIME = 9.3f

    /** Halo ring: 1 dp asked, capped at half the smaller gap (it lives in the gap) = 0.9 dp. */
    val HALO = min(1f, min(GAP_X, GAP_Y) / 2f)
    const val HALO_ALPHA = 0.25f

    /*
     * The width each text may take, in design dp; [GridTextFit] steps a size down only when the
     * text would not fit. Laid out as in GridRow and GridCell.
     */
    /** Label: its column plus the gap up to the first box's halo, less 0.3 dp for pixel rounding. */
    val LABEL_ROOM = LABEL_W + (LABEL_GAP - HALO).coerceAtLeast(0f) - 0.3f

    /**
     * Number: the box plus half the halo ring on each side. A digit's ink is narrower than its
     * advance (Droid Sans Mono, measured with fontTools: "45" at 8.7 is 10.44 dp of advance and
     * 9.44 dp of ink; "100", stepped down to 6.28, is 10.16 dp of ink), so this keeps the ink
     * inside the 10.4 dp box while letting two digits use the full design size.
     */
    val NUM_ROOM = BOX + HALO

    /** Reset: from the last box's halo to the right padding edge, less 1 dp. */
    val RESET_ROOM = W - 2 * PAD_X - LABEL_W - LABEL_GAP - (10 * BOX + 9 * GAP_X) - HALO - 1f

    const val BG = 0xFF000000.toInt()
    const val DIM = 0xFF1E1E1E.toInt()
    const val LABEL = 0xFF94EDFF.toInt()
    const val RESET = 0xFF94EDFF.toInt()
    const val INK_DARK = 0xFFD4D4D4.toInt()
    const val INK_LIGHT = 0xFFC4C4C4.toInt()

    /**
     * Advance of every glyph in Android's `monospace` (Droid Sans Mono: 1229/2048 em). Only a
     * fallback: [GridTextFit] measures the phone's own font, and uses this where it can't.
     */
    const val MONO_ADVANCE = 0.6f
    const val INK_ZERO = 0xFF2F6B78.toInt()

    /** Row gradients, box 1 -> box 10. */
    const val CLAUDE_START = 0xFFF06000.toInt()
    const val CLAUDE_END = 0xFFFFD27A.toInt()
    const val CODEX_START = 0xFF0D6AD3.toInt()
    const val CODEX_END = 0xFF7FE3FF.toInt()
    const val CURSOR_START = 0xFF9FD8E6.toInt()
    const val CURSOR_END = 0xFFFFFFFF.toInt()

    /** Monospace in Normal weight for every text, as designed. */
    val FONT = FontFamily.Monospace
}

/** One grid row as drawn. [pct] null = no data for this window (all boxes dim, no number). */
data class GridRowState(
    val label: String,
    val startColor: Int,
    val endColor: Int,
    val pct: Int?,
    val reset: TimeFmt.GridReset,
)

data class GridState(
    val notice: Notice?,
    val rows: List<GridRowState>,
    val stale: Boolean,
)

@Composable
fun UsageGridContent(state: GridState) {
    val context = LocalContext.current
    val size = LocalSize.current
    // One factor for every length, text included, from the real cell to the design size.
    val k = min(size.width.value / GridDesign.W, size.height.value / GridDesign.H).coerceAtLeast(0.3f)
    val dims = Dims(k)

    val tap = if (state.notice?.opensApp == true) {
        actionStartActivity(Intent(context, MainActivity::class.java))
    } else {
        actionRunCallback<RefreshAction>()
    }

    Box(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(ColorProvider(Color(GridDesign.BG)))
            .cornerRadius(dims.dp(GridDesign.R_WIDGET))
            .clickable(tap),
        contentAlignment = Alignment.Center,
    ) {
        if (state.notice != null) {
            Text(
                state.notice.text,
                style = TextStyle(
                    color = ColorProvider(Color(GridDesign.LABEL)),
                    fontSize = dims.sp(GridDesign.S_LABEL),
                    fontFamily = GridDesign.FONT,
                    textAlign = TextAlign.Center,
                ),
                maxLines = 2,
            )
        } else {
            // Glance rows and columns take at most 10 children, so the rows are spaced with
            // padding (not Spacers) and each row's ten boxes sit in a row of their own.
            Column(
                modifier = GlanceModifier.fillMaxSize().padding(horizontal = dims.dp(GridDesign.PAD_X)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                state.rows.forEachIndexed { i, row -> GridRow(row, first = i == 0, dims) }
            }
        }
        if (state.stale && state.notice == null) GridStaleDot(dims)
    }
}

/** Lengths at the design size, scaled to the real widget. */
private class Dims(val k: Float) {
    fun dp(v: Float): Dp = (v * k).dp

    /** A grid text size, in dp, for [GridText]. */
    fun textDp(v: Float): Float = v * k

    /** Only the pairing notice uses Glance's own (sp) text: it wraps, and may grow with the phone's font size. */
    fun sp(v: Float): TextUnit = (v * k).sp

    /** The halo sits in the gap, so a cell is the box plus a ring on every side. */
    val cell: Dp get() = dp(GridDesign.BOX + 2 * GridDesign.HALO)
    val box: Dp get() = dp(GridDesign.BOX)
    val cellGapX: Dp get() = dp((GridDesign.GAP_X - 2 * GridDesign.HALO).coerceAtLeast(0f))
    val cellGapY: Dp get() = dp((GridDesign.GAP_Y - 2 * GridDesign.HALO).coerceAtLeast(0f))
}

@Composable
private fun GridRow(row: GridRowState, first: Boolean, d: Dims) {
    Row(
        modifier = GlanceModifier.fillMaxWidth().padding(top = if (first) 0.dp else d.cellGapY),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // The label's view spans its column AND the gap up to the first box's halo (the halo
        // ring takes the first part of the design's gap), so a label a hair wider than its
        // column still fits; it is left-aligned, so it sits where the design puts it.
        GridText(
            row.label,
            d.textDp(GridTextFit.fit(GridDesign.S_LABEL, GridDesign.LABEL_ROOM, GridTextFit.ems(row.label))),
            GridDesign.LABEL,
            GridTextAlign.START,
            GlanceModifier.width(d.dp(GridDesign.LABEL_W + (GridDesign.LABEL_GAP - GridDesign.HALO).coerceAtLeast(0f))),
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            for (j in 0 until 10) {
                // Exactly ten children: any gap left beside the halo is padding on a wrapper,
                // never a Spacer (which would make 19 children and break the row).
                if (j < 9 && d.cellGapX.value > 0f) {
                    Box(GlanceModifier.padding(end = d.cellGapX)) { GridCell(row, j, d) }
                } else {
                    GridCell(row, j, d)
                }
            }
        }
        // The reset view takes all the spare width and right-aligns its text to the padding
        // edge. (A weighted Spacer before a wrap-width AndroidRemoteViews got no width at all,
        // which left the reset against the boxes.)
        val resetSize = if (row.reset.isTime) GridDesign.S_RESET_TIME else GridDesign.S_RESET
        GridText(
            row.reset.text,
            d.textDp(GridTextFit.fit(resetSize, GridDesign.RESET_ROOM, GridTextFit.ems(row.reset.text))),
            GridDesign.RESET,
            GridTextAlign.END,
            GlanceModifier.defaultWeight(),
        )
    }
}

@Composable
private fun GridCell(row: GridRowState, j: Int, d: Dims) {
    val pct = row.pct
    // Box j covers (10j, 10j + 10] %: fully lit once passed; the box the percentage lands in is
    // shaded by how far into its band it is (61 % -> box 7 at 10 %).
    val f = if (pct == null) 0f else (pct / 10f - j).coerceIn(0f, 1f)
    val lit = GridColor.lerp(row.startColor, row.endColor, j / 9f)
    val fill = if (f > 0f) GridColor.lerp(GridDesign.DIM, lit, f) else GridDesign.DIM
    val landing = pct != null && j + 1 == ceil(pct / 10f).toInt().coerceIn(1, 10)

    var outer = GlanceModifier.size(d.cell)
    // Halo: the outer cell painted in the box's own colour at 25 % - scaled by a graded
    // box's fill - so a lit box carries a thin neon ring in the gap.
    if (f > 0f) {
        outer = outer
            .background(ColorProvider(Color(GridColor.withAlpha(lit, GridDesign.HALO_ALPHA * f))))
            .cornerRadius(d.dp(GridDesign.R_BOX + GridDesign.HALO))
    }
    Box(modifier = outer, contentAlignment = Alignment.Center) {
        Box(
            modifier = GlanceModifier
                .size(d.box)
                .background(ColorProvider(Color(fill)))
                .cornerRadius(d.dp(GridDesign.R_BOX)),
            contentAlignment = Alignment.Center,
        ) {
            if (f > 0f) {
                // Gloss (top highlight) + a faint bevel, one fixed drawable over every lit box.
                Image(
                    provider = ImageProvider(R.drawable.grid_box_overlay),
                    contentDescription = null,
                    modifier = GlanceModifier.fillMaxSize(),
                    contentScale = ContentScale.FillBounds,
                )
            }
        }
        if (landing && pct != null) {
            // On the whole cell, over the box: the number's view may then be wider than the box
            // (two digits' advance at full size is) while the digits' ink stays inside it. "100"
            // steps down until it fits NUM_ROOM.
            val text = pct.toString()
            GridText(
                text,
                d.textDp(GridTextFit.fit(GridDesign.S_NUM, GridDesign.NUM_ROOM, GridTextFit.ems(text))),
                GridColor.ink(pct, fill),
                GridTextAlign.CENTER,
                GlanceModifier.fillMaxSize(),
            )
        }
    }
}

private enum class GridTextAlign(val layout: Int) {
    START(R.layout.grid_text_start),
    CENTER(R.layout.grid_text_center),
    END(R.layout.grid_text_end),
}

/**
 * One line of grid text: a plain RemoteViews TextView (res/layout/grid_text_*.xml) sized in dp.
 *
 * Not Glance's Text, which only takes sp. The launcher converts sp with ITS font-size setting
 * when it lays the widget out, which need not be the one this process saw when it drew; on
 * Eugene's phone (2026-10-20) the text came out bigger than designed, so the labels showed as
 * "…" and two-digit numbers vanished. The emulator shows the same at 130 % font size until the
 * next redraw. dp is converted with the display density alone, like the boxes.
 */
@Composable
private fun GridText(
    text: String,
    sizeDp: Float,
    color: Int,
    align: GridTextAlign,
    modifier: GlanceModifier = GlanceModifier,
) {
    val views = RemoteViews(LocalContext.current.packageName, align.layout).apply {
        setTextViewText(R.id.grid_text, text)
        setTextColor(R.id.grid_text, color)
        setTextViewTextSize(R.id.grid_text, TypedValue.COMPLEX_UNIT_DIP, sizeDp)
    }
    AndroidRemoteViews(views, modifier)
}

/**
 * Fits grid text to its room in the font the launcher draws it with. The app and the launcher
 * load the same system font files, so a width measured here is the width there.
 */
internal object GridTextFit {
    // Paint is not thread-safe; widgets of the same app can compose on different threads.
    private val paint by lazy {
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Typeface.create("monospace", Typeface.NORMAL)
            textSize = MEASURE_PX
        }
    }
    private const val MEASURE_PX = 100f

    /**
     * [text]'s advance width in em in `monospace`. Where Paint can't measure (JVM unit tests,
     * where android.jar returns 0), Droid Sans Mono's fixed advance stands in.
     */
    fun ems(text: String): Float {
        if (text.isEmpty()) return 0f
        val measured = runCatching { synchronized(paint) { paint.measureText(text) } / MEASURE_PX }.getOrDefault(0f)
        return if (measured > 0f) measured else GridDesign.MONO_ADVANCE * text.length
    }

    /** The largest size up to [desired] at which text [ems] wide fits [room] (sizes and room in design dp). */
    fun fit(desired: Float, room: Float, ems: Float): Float =
        if (ems <= 0f || room <= 0f) desired else min(desired, room / ems)
}

@Composable
private fun GridStaleDot(d: Dims) {
    Box(
        modifier = GlanceModifier.fillMaxSize().padding(d.dp(7f)),
        contentAlignment = Alignment.TopEnd,
    ) {
        Box(
            modifier = GlanceModifier
                .size(d.dp(4f))
                .cornerRadius(d.dp(2f))
                .background(ColorProvider(Color(0xFFFFC233.toInt()))),
        ) {}
    }
}

/** Colour arithmetic for the grid, matching the editor's mix() / contrast(). */
internal object GridColor {
    fun lerp(a: Int, b: Int, t: Float): Int {
        fun ch(shift: Int): Int {
            val x = (a shr shift) and 0xFF
            val y = (b shr shift) and 0xFF
            return (x + (y - x) * t + 0.5f).toInt().coerceIn(0, 255)
        }
        return (0xFF shl 24) or (ch(16) shl 16) or (ch(8) shl 8) or ch(0)
    }

    fun withAlpha(color: Int, alpha: Float): Int =
        ((alpha.coerceIn(0f, 1f) * 255f + 0.5f).toInt() shl 24) or (color and 0x00FFFFFF)

    /** WCAG relative luminance. */
    fun luminance(color: Int): Double {
        fun ch(shift: Int): Double {
            val c = ((color shr shift) and 0xFF) / 255.0
            return if (c <= 0.03928) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)
        }
        return 0.2126 * ch(16) + 0.7152 * ch(8) + 0.0722 * ch(0)
    }

    fun contrast(a: Int, b: Int): Double {
        val x = luminance(a)
        val y = luminance(b)
        return (maxOf(x, y) + 0.05) / (minOf(x, y) + 0.05)
    }

    /** The number's colour: the zero colour for 0 %, else whichever ink contrasts more. */
    fun ink(pct: Int, fill: Int): Int = when {
        pct == 0 -> GridDesign.INK_ZERO
        contrast(fill, GridDesign.INK_DARK) >= contrast(fill, GridDesign.INK_LIGHT) -> GridDesign.INK_DARK
        else -> GridDesign.INK_LIGHT
    }
}
