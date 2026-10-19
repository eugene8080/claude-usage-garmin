package com.usage.claudewidget.widget

import android.content.Intent
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
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontFamily
import androidx.glance.text.FontWeight
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
 * (2026-10-19; the pasted block is kept in docs/widget-editor/usage-grid-design.jsonc). Lengths
 * are dp and text sp at the design size [W] x [H]; the widget scales all of them by one factor
 * to the real 2x1 cell, so the proportions survive any launcher grid.
 *
 * Everything here is drawn natively by Glance - no picture of the widget: boxes are Box views
 * with background colours and corner radii, the halo is a translucent outer Box, the gloss and
 * bevel are one fixed vector drawable (grid_box_overlay), and the font is Android's built-in
 * `monospace` family.
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
    const val S_LABEL = 7.5f
    const val S_NUM = 7f
    const val S_RESET = 5.3f

    /** Halo ring: 1 dp asked, capped at half the smaller gap (it lives in the gap) = 0.9 dp. */
    val HALO = min(1f, min(GAP_X, GAP_Y) / 2f)
    const val HALO_ALPHA = 0.25f

    const val BG = 0xFF000000.toInt()
    const val DIM = 0xFF1E1E1E.toInt()
    const val LABEL = 0xFF94EDFF.toInt()
    const val RESET = 0xFF94EDFF.toInt()
    const val INK_DARK = 0xFFA9F0FE.toInt()
    const val INK_LIGHT = 0xFF94EDFF.toInt()
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
    val resets: String,
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
    // One factor for every length, from the real cell to the design size. Text is divided by
    // the user's font scale too: the numbers must fit their boxes, which do not grow with it.
    val k = min(size.width.value / GridDesign.W, size.height.value / GridDesign.H).coerceAtLeast(0.3f)
    val fontScale = context.resources.configuration.fontScale.takeIf { it > 0f } ?: 1f
    val dims = Dims(k, fontScale)

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

/** dp / sp at the design size, scaled to the real widget. */
private class Dims(val k: Float, val fontScale: Float) {
    fun dp(v: Float): Dp = (v * k).dp
    fun sp(v: Float): TextUnit = (v * k / fontScale).sp

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
        Text(
            row.label,
            style = TextStyle(
                color = ColorProvider(Color(GridDesign.LABEL)),
                fontSize = d.sp(GridDesign.S_LABEL),
                fontFamily = GridDesign.FONT,
                fontWeight = FontWeight.Normal,
            ),
            maxLines = 1,
            modifier = GlanceModifier.width(d.dp(GridDesign.LABEL_W)),
        )
        // The design's label gap runs to the box edge; the halo ring takes the first part of it.
        Spacer(GlanceModifier.width(d.dp((GridDesign.LABEL_GAP - GridDesign.HALO).coerceAtLeast(0f))))
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
        // The reset time is right-aligned to the padding edge; the spare width goes here.
        Spacer(GlanceModifier.defaultWeight())
        Text(
            row.resets,
            style = TextStyle(
                color = ColorProvider(Color(GridDesign.RESET)),
                fontSize = d.sp(GridDesign.S_RESET),
                fontFamily = GridDesign.FONT,
                fontWeight = FontWeight.Normal,
                textAlign = TextAlign.End,
            ),
            maxLines = 1,
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
            if (landing && pct != null) {
                val text = pct.toString()
                Text(
                    text,
                    style = TextStyle(
                        color = ColorProvider(Color(GridColor.ink(pct, fill))),
                        // Three digits ("100") would overflow the box at the two-digit size.
                        fontSize = d.sp(if (text.length >= 3) GridDesign.S_NUM * 0.78f else GridDesign.S_NUM),
                        fontFamily = GridDesign.FONT,
                        fontWeight = FontWeight.Normal,
                        textAlign = TextAlign.Center,
                    ),
                    maxLines = 1,
                )
            }
        }
    }
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
