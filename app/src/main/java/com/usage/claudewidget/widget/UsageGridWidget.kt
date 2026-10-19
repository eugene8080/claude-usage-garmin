package com.usage.claudewidget.widget

import android.content.Context
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.glance.GlanceId
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.provideContent
import com.usage.claudewidget.data.LinkState
import com.usage.claudewidget.data.Meter
import com.usage.claudewidget.data.Provider
import com.usage.claudewidget.data.Storage
import kotlinx.coroutines.flow.runningFold
import kotlin.math.roundToInt

/**
 * The fourth widget: every provider at once as a 7 x 10 grid (Claude 5H / 1W / FA, Codex 1W,
 * Cursor PL / AU / AP), fixed at 2 x 1 cells. Same data and refresh as the per-provider widgets;
 * the design is GridDesign in UsageGridGlanceUi.kt.
 */
class UsageGridWidget : GlanceAppWidget() {

    // Exact: the grid scales one factor to the cell's real size (it is not resizable, but the
    // 2 x 1 cell differs between launchers and phones).
    override val sizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val changes = Storage.get(context).snapshotChanges()
            .runningFold(0) { count, _ -> count + 1 }
        provideContent {
            // Re-read Storage on every change, for the same reason as ProviderUsageWidget: an
            // update() inside Glance's ~45 s session window does not re-run this otherwise.
            val version by changes.collectAsState(initial = 0)
            val state = remember(version) { readState(context) }
            UsageGridContent(state)
        }
    }

    private fun readState(context: Context): GridState {
        val s = Storage.get(context)
        val usage = Provider.entries.associateWith { s.usage(it) }
        val now = System.currentTimeMillis()
        val is24h = android.text.format.DateFormat.is24HourFormat(context)
        val anyData = usage.values.any { it?.hasData == true }

        val notice = when {
            !s.isPaired || s.linkState == LinkState.NEEDS_PAIRING ->
                Notice("Tap to pair with Orca", "Pair", opensApp = true)
            !anyData && s.linkState == LinkState.UNREACHABLE ->
                Notice("Can't reach Orca", "Offline", opensApp = false)
            else -> null
        }
        val rows = ROWS.map { spec ->
            val meter = usage[spec.provider]?.meters?.firstOrNull { windowKey(it) == spec.key }
            GridRowState(
                label = spec.label,
                startColor = spec.start,
                endColor = spec.end,
                pct = meter?.utilization?.roundToInt()?.coerceIn(0, 100),
                resets = meter?.let { TimeFmt.resetsAt(it.resetsAtEpochMs, now, is24h) } ?: "",
            )
        }
        // The dot shows when the OLDEST numbers on the grid are past the stale threshold.
        val oldest = usage.values.filterNotNull().filter { it.hasData }.minOfOrNull { it.updatedAtEpochMs }
        return GridState(notice, rows, stale = oldest != null && TimeFmt.isStale(oldest, now))
    }

    private class RowSpec(val label: String, val provider: Provider, val key: String, val start: Int, val end: Int)

    private companion object {
        val ROWS = listOf(
            RowSpec("5H", Provider.CLAUDE, Meter.SESSION, GridDesign.CLAUDE_START, GridDesign.CLAUDE_END),
            RowSpec("1W", Provider.CLAUDE, Meter.WEEKLY, GridDesign.CLAUDE_START, GridDesign.CLAUDE_END),
            RowSpec("FA", Provider.CLAUDE, Meter.FABLE_WEEKLY, GridDesign.CLAUDE_START, GridDesign.CLAUDE_END),
            RowSpec("1W", Provider.CODEX, Meter.WEEKLY, GridDesign.CODEX_START, GridDesign.CODEX_END),
            RowSpec("PL", Provider.CURSOR, Meter.MONTHLY, GridDesign.CURSOR_START, GridDesign.CURSOR_END),
            RowSpec("AU", Provider.CURSOR, Meter.bucket("Cursor Models"), GridDesign.CURSOR_START, GridDesign.CURSOR_END),
            RowSpec("AP", Provider.CURSOR, Meter.bucket("Other Models"), GridDesign.CURSOR_START, GridDesign.CURSOR_END),
        )

        /**
         * A meter's window key. Snapshots stored before keys existed have none; read those
         * from their display label until the next refresh stores keys.
         */
        fun windowKey(meter: Meter): String = meter.key.ifEmpty {
            when (meter.label) {
                "5H" -> Meter.SESSION
                "1W" -> Meter.WEEKLY
                "1W Fable" -> Meter.FABLE_WEEKLY
                "Plan" -> Meter.MONTHLY
                "Auto" -> Meter.bucket("Cursor Models")
                "API" -> Meter.bucket("Other Models")
                else -> ""
            }
        }
    }
}
