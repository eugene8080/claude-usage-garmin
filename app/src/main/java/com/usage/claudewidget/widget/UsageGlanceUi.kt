package com.usage.claudewidget.widget

import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.runtime.Composable
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.LinearProgressIndicator
import androidx.glance.appwidget.cornerRadius
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import androidx.glance.LocalContext
import android.content.Intent
import com.usage.claudewidget.R
import com.usage.claudewidget.data.Provider
import com.usage.claudewidget.ui.MainActivity

/** One meter as drawn: label, rounded %, and the formatted reset time. */
data class MeterState(
    /** Full label for the stacked layout, e.g. "5H", "1W Fable", "Plan". */
    val label: String,
    /** The side-by-side and narrow layouts drop a window prefix: "1W Fable" -> "Fable". */
    val shortLabel: String,
    val pct: Int,
    val resets: String,
)

/** A message shown in place of the meters (not paired, provider not set up in Orca...). */
data class Notice(
    val text: String,
    /** For a widget too narrow for [text]. */
    val compactText: String,
    /** Tapping opens the app (to pair) instead of refreshing. */
    val opensApp: Boolean,
)

/** Immutable view state handed to the composable; assembled from Storage on each render. */
data class WidgetState(
    val provider: Provider,
    /** Shown instead of the meters when set. */
    val notice: Notice?,
    /** Up to three; empty (with no notice) means "waiting for the first fetch". */
    val meters: List<MeterState>,
    val stale: Boolean,
    /** App version (release tag), shown so an update can be confirmed at a glance. */
    val version: String,
) {
    val hasData: Boolean get() = meters.isNotEmpty()
}

private val COMPACT_MAX_WIDTH = 130.dp
/**
 * Below this height even the dense stacked layout can't fit three meters, so the widget sets
 * them side by side instead of clipping the last one off the bottom. (One home-screen row is a
 * little under 110 dp on a Pixel - tall enough for the dense stacked layout below.)
 */
private val SHORT_MAX_HEIGHT = 70.dp
/** Below this height the stacked layout switches to its dense sizing (one-row widgets). */
private val DENSE_MAX_HEIGHT = 130.dp
/**
 * The stacked layout with its "<Provider> usage" header needs about this much height at its densest
 * (measured on the emulator: 77 dp of content + 12 dp padding). It keeps the header down to here.
 */
private val DENSE_MARK_MIN_HEIGHT = 89.dp
private val COMPACT_MARK_MIN_HEIGHT = 100.dp
/** Below this width the "resets" prefix is dropped and only the reset time is shown. */
private val RESET_PREFIX_MIN_WIDTH = 220.dp

// Colors come from resources so they auto-adapt to light/dark via values-night.
private fun accentFor(provider: Provider) = ColorProvider(
    when (provider) {
        Provider.CLAUDE -> R.color.accent
        Provider.CODEX -> R.color.accent_codex
        Provider.CURSOR -> R.color.accent_cursor
    },
)
private fun barTrack() = ColorProvider(R.color.bar_track)

private fun markFor(provider: Provider) = when (provider) {
    Provider.CLAUDE -> R.drawable.ic_claude
    Provider.CODEX -> R.drawable.ic_codex
    Provider.CURSOR -> R.drawable.ic_cursor
}

@Composable
fun UsageWidgetContent(state: WidgetState) {
    val size = LocalSize.current
    val compact = size.width < COMPACT_MAX_WIDTH
    val short = !compact && size.height < SHORT_MAX_HEIGHT
    val dense = size.height < DENSE_MAX_HEIGHT
    val context = LocalContext.current

    val tap = if (state.notice?.opensApp == true) {
        actionStartActivity(Intent(context, MainActivity::class.java))
    } else {
        actionRunCallback<RefreshAction>()
    }

    Box(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(GlanceTheme.colors.widgetBackground)
            .cornerRadius(20.dp)
            .padding(if (short || dense) 6.dp else if (compact) 8.dp else 10.dp)
            .clickable(tap),
    ) {
        when {
            state.notice != null -> NoticeView(state.provider, state.notice, compact)
            !state.hasData -> Loading(compact)
            short -> ShortLayout(state)
            compact -> CompactLayout(state, showMark = size.height >= COMPACT_MARK_MIN_HEIGHT)
            else -> FullLayout(
                state,
                showMark = !dense || size.height >= DENSE_MARK_MIN_HEIGHT,
                showResetPrefix = size.width >= RESET_PREFIX_MIN_WIDTH,
                d = stackDims(size.height),
            )
        }
        if (state.hasData && state.stale) StaleDot()
    }
}

/**
 * Sizes for the stacked layout. REGULAR is the original roomy look (two rows and up); DENSE is
 * the same header + three meter rows with bars, tightened to fit a single home-screen row.
 * [stackDims] interpolates between them by the widget's real height, so a one-row widget fills
 * its row (a Pixel row is ~104 dp) instead of leaving a gap or clipping.
 */
private data class StackDims(
    val markDp: Float, val titleSp: Float, val versionSp: Float, val headerGap: Float,
    val labelSp: Float, val labelW: Float, val pctSp: Float, val resetSp: Float,
    val barGap: Float, val barDp: Float, val rowGap: Float,
)

private fun stackDims(height: androidx.compose.ui.unit.Dp): StackDims {
    // t = 0 at the densest height the header layout needs, 1 at the regular layout's height;
    // the dense layout grows roughly one-for-one with height between them, so it stays full.
    // (+6 dp keeps a little air under the last bar instead of packing the row edge to edge.)
    val t = ((height.value - DENSE_MARK_MIN_HEIGHT.value - 6f) /
        (DENSE_MAX_HEIGHT.value - DENSE_MARK_MIN_HEIGHT.value - 6f)).coerceIn(0f, 1f)
    fun mix(a: Float, b: Float) = a + (b - a) * t
    val a = DENSE
    val b = REGULAR
    return StackDims(
        mix(a.markDp, b.markDp), mix(a.titleSp, b.titleSp), mix(a.versionSp, b.versionSp),
        mix(a.headerGap, b.headerGap), mix(a.labelSp, b.labelSp), mix(a.labelW, b.labelW),
        mix(a.pctSp, b.pctSp), mix(a.resetSp, b.resetSp), mix(a.barGap, b.barGap),
        mix(a.barDp, b.barDp), mix(a.rowGap, b.rowGap),
    )
}

private val REGULAR = StackDims(
    markDp = 22f, titleSp = 14f, versionSp = 11f, headerGap = 8f,
    labelSp = 12f, labelW = 56f, pctSp = 13f, resetSp = 11f, barGap = 3f, barDp = 5f, rowGap = 6f,
)
private val DENSE = StackDims(
    markDp = 14f, titleSp = 11f, versionSp = 9f, headerGap = 2f,
    labelSp = 10f, labelW = 48f, pctSp = 11f, resetSp = 9f, barGap = 1f, barDp = 3f, rowGap = 2f,
)

@Composable
private fun FullLayout(s: WidgetState, showMark: Boolean, showResetPrefix: Boolean, d: StackDims) {
    Column(modifier = GlanceModifier.fillMaxSize()) {
        if (showMark) {
            Row(
                modifier = GlanceModifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ProviderMark(s.provider, d.markDp.dp)
                Spacer(GlanceModifier.width(6.dp))
                Text(
                    "${s.provider.displayName} usage",
                    style = TextStyle(
                        color = GlanceTheme.colors.onSurface,
                        fontWeight = FontWeight.Medium,
                        fontSize = d.titleSp.sp,
                    ),
                    maxLines = 1,
                )
                Spacer(GlanceModifier.defaultWeight())
                // Version at the right of the header, so an update is confirmable on the
                // widget itself without opening the app.
                Text(
                    "v${s.version}",
                    style = TextStyle(
                        color = GlanceTheme.colors.onSurfaceVariant,
                        fontSize = d.versionSp.sp,
                    ),
                    maxLines = 1,
                )
            }
            Spacer(GlanceModifier.height(d.headerGap.dp))
        }
        s.meters.forEachIndexed { i, meter ->
            if (i > 0) Spacer(GlanceModifier.height(d.rowGap.dp))
            MeterRow(meter, accentFor(s.provider), showResetPrefix, d)
        }
    }
}

/**
 * The meters across, for a widget one row tall. Label over value over bar keeps
 * each cell narrow enough that a long model name and "100%" never collide.
 */
@Composable
private fun ShortLayout(s: WidgetState) {
    Row(
        modifier = GlanceModifier.fillMaxSize(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        s.meters.forEachIndexed { i, meter ->
            if (i > 0) Spacer(GlanceModifier.width(10.dp))
            ShortMeter(meter, accentFor(s.provider), GlanceModifier.defaultWeight())
        }
    }
}

@Composable
private fun ShortMeter(meter: MeterState, accent: ColorProvider, modifier: GlanceModifier) {
    Column(modifier = modifier) {
        Text(
            meter.shortLabel,
            style = TextStyle(
                color = GlanceTheme.colors.onSurfaceVariant,
                fontWeight = FontWeight.Bold,
                fontSize = 10.sp,
            ),
            maxLines = 1,
        )
        Text(
            "${meter.pct}%",
            style = TextStyle(
                color = GlanceTheme.colors.onSurface,
                fontWeight = FontWeight.Bold,
                fontSize = 13.sp,
            ),
            maxLines = 1,
        )
        // The reset time, dimmed so the percentage stays the thing the eye lands on. This is
        // the one-row analogue of the watch glance's reset line.
        Text(
            meter.resets,
            style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 9.sp),
            maxLines = 1,
        )
        Spacer(GlanceModifier.height(2.dp))
        Bar(meter.pct, accent, height = 4.dp)
    }
}

@Composable
private fun MeterRow(meter: MeterState, accent: ColorProvider, showResetPrefix: Boolean, d: StackDims) {
    Column(modifier = GlanceModifier.fillMaxWidth()) {
        Row(
            modifier = GlanceModifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                meter.label,
                style = TextStyle(
                    color = GlanceTheme.colors.onSurfaceVariant,
                    fontWeight = FontWeight.Bold,
                    fontSize = d.labelSp.sp,
                ),
                maxLines = 1,
                // Wide enough for the longest label ("1W Fable") so the bars stay aligned.
                modifier = GlanceModifier.width(d.labelW.dp),
            )
            Text(
                "${meter.pct}%",
                style = TextStyle(
                    color = GlanceTheme.colors.onSurface,
                    fontWeight = FontWeight.Bold,
                    fontSize = d.pctSp.sp,
                ),
                maxLines = 1,
            )
            Spacer(GlanceModifier.defaultWeight())
            Text(
                if (showResetPrefix) "resets ${meter.resets}" else meter.resets,
                style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = d.resetSp.sp),
                maxLines = 1,
            )
        }
        Spacer(GlanceModifier.height(d.barGap.dp))
        Bar(meter.pct, accent, height = d.barDp.dp)
    }
}

@Composable
private fun CompactLayout(s: WidgetState, showMark: Boolean) {
    Column(modifier = GlanceModifier.fillMaxSize()) {
        if (showMark) {
            ProviderMark(s.provider, 14.dp)
            Spacer(GlanceModifier.height(4.dp))
        }
        s.meters.forEachIndexed { i, meter ->
            if (i > 0) Spacer(GlanceModifier.height(4.dp))
            CompactMeter(meter, accentFor(s.provider))
        }
    }
}

@Composable
private fun CompactMeter(meter: MeterState, accent: ColorProvider) {
    Column(modifier = GlanceModifier.fillMaxWidth()) {
        Row(modifier = GlanceModifier.fillMaxWidth()) {
            Text(
                meter.shortLabel,
                style = TextStyle(
                    color = GlanceTheme.colors.onSurfaceVariant,
                    fontWeight = FontWeight.Bold,
                    fontSize = 11.sp,
                ),
                maxLines = 1,
            )
            Spacer(GlanceModifier.defaultWeight())
            Text(
                "${meter.pct}%",
                style = TextStyle(
                    color = GlanceTheme.colors.onSurface,
                    fontWeight = FontWeight.Bold,
                    fontSize = 11.sp,
                ),
                maxLines = 1,
            )
        }
        Spacer(GlanceModifier.height(2.dp))
        Bar(meter.pct, accent)
    }
}

@Composable
private fun Bar(pct: Int, accent: ColorProvider, height: androidx.compose.ui.unit.Dp = 5.dp) {
    LinearProgressIndicator(
        progress = (pct.coerceIn(0, 100)) / 100f,
        modifier = GlanceModifier.fillMaxWidth().height(height).cornerRadius(height / 2),
        color = accent,
        backgroundColor = barTrack(),
    )
}

@Composable
private fun ProviderMark(provider: Provider, s: androidx.compose.ui.unit.Dp) {
    Image(
        provider = ImageProvider(markFor(provider)),
        contentDescription = provider.displayName,
        modifier = GlanceModifier.size(s),
    )
}

/** The provider's mark over a short message: "Tap to pair with Orca", "Can't reach Orca"... */
@Composable
private fun NoticeView(provider: Provider, notice: Notice, compact: Boolean) {
    Column(
        modifier = GlanceModifier.fillMaxSize(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        ProviderMark(provider, if (compact) 18.dp else 24.dp)
        Spacer(GlanceModifier.height(6.dp))
        Text(
            if (compact) notice.compactText else notice.text,
            style = TextStyle(color = GlanceTheme.colors.onSurface, fontWeight = FontWeight.Medium),
            maxLines = 2,
        )
    }
}

@Composable
private fun Loading(compact: Boolean) {
    Column(
        modifier = GlanceModifier.fillMaxSize(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("…", style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant))
    }
}

@Composable
private fun StaleDot() {
    Box(
        modifier = GlanceModifier.fillMaxSize().padding(2.dp),
        contentAlignment = Alignment.TopEnd,
    ) {
        Box(
            modifier = GlanceModifier
                .size(8.dp)
                .cornerRadius(4.dp)
                .background(ColorProvider(R.color.stale)),
        ) {}
    }
}
