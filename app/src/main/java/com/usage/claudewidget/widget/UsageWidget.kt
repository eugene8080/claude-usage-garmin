package com.usage.claudewidget.widget

import android.content.Context
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.glance.GlanceId
import androidx.glance.GlanceTheme
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import com.usage.claudewidget.data.LinkState
import com.usage.claudewidget.data.Provider
import com.usage.claudewidget.data.ProviderStatus
import com.usage.claudewidget.data.Storage
import kotlinx.coroutines.flow.runningFold
import kotlin.math.roundToInt

/**
 * One home-screen widget per provider. Each provider is its own widget class and receiver,
 * so it is picked straight from the launcher's widget list ("Claude usage", "Codex usage",
 * "Cursor usage") with no configuration screen, and all of them render from the snapshot one
 * background refresh stores.
 */
abstract class ProviderUsageWidget(private val provider: Provider) : GlanceAppWidget() {

    // Exact: the layout decides from the widget's REAL size. The previous Responsive buckets
    // made one home-screen row (a little under 110 dp) fall back to the 140x50 bucket, so a
    // 3x1 widget could only ever get the side-by-side layout - never the stacked one with the
    // header, even though the dense stacked layout fits a single row.
    override val sizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val changes = Storage.get(context).snapshotChanges()
            .runningFold(0) { count, _ -> count + 1 }
        provideContent {
            // Glance keeps a widget's composition alive for ~45 s after each render, and an
            // update() that lands in that window does NOT re-run content that reads from
            // outside Glance's own state - it was seen leaving "Tap to pair with Orca" on
            // the home screen after a successful pairing. Re-reading Storage on every change
            // to it makes any write show up, whether or not a session is still running.
            val version by changes.collectAsState(initial = 0)
            val state = remember(version) { readState(context) }
            GlanceTheme {
                UsageWidgetContent(state)
            }
        }
    }

    private fun readState(context: Context): WidgetState {
        val s = Storage.get(context)
        val usage = s.usage(provider)
        val now = System.currentTimeMillis()
        // The device clock setting decides 12/24-hour reset times, matching how every other
        // time on the phone is shown.
        val is24h = android.text.format.DateFormat.is24HourFormat(context)
        val name = provider.displayName
        val notice = when {
            // Unpaired, or Orca refused this device: the numbers can't refresh, so ask to pair.
            !s.isPaired || s.linkState == LinkState.NEEDS_PAIRING ->
                Notice("Tap to pair with Orca", "Pair", opensApp = true)
            usage?.hasData == true -> null
            usage?.status == ProviderStatus.NOT_SET_UP ->
                Notice("$name isn't set up in Orca", "Not set up", opensApp = false)
            usage?.status == ProviderStatus.UNAVAILABLE ->
                Notice("$name unavailable in Orca", "N/A", opensApp = false)
            s.linkState == LinkState.UNREACHABLE ->
                Notice("Can't reach Orca", "Offline", opensApp = false)
            else -> null // nothing yet: the "…" placeholder until the first fetch lands
        }
        return WidgetState(
            provider = provider,
            notice = notice,
            meters = usage?.meters.orEmpty().map { meter ->
                MeterState(
                    label = meter.label,
                    shortLabel = meter.label.substringAfter(' '),
                    pct = meter.utilization.coerceAtLeast(0f).roundToInt(),
                    resets = TimeFmt.resetsAt(meter.resetsAtEpochMs, now, is24h),
                )
            },
            // How old the numbers are at their source (Orca's last successful fetch), not when
            // the phone last talked to Orca - the dot means "these numbers are old".
            stale = TimeFmt.isStale(usage?.updatedAtEpochMs ?: 0L, now),
            version = com.usage.claudewidget.BuildConfig.VERSION_NAME,
        )
    }

    companion object {
        /** Re-renders every placed widget: the three providers and the usage grid. */
        suspend fun updateAll(context: Context) {
            UsageWidget().updateAll(context)
            CodexUsageWidget().updateAll(context)
            CursorUsageWidget().updateAll(context)
            UsageGridWidget().updateAll(context)
        }
    }
}

/**
 * The Claude widget. The class keeps its pre-Orca name, as does its receiver, so widgets
 * already on a home screen stay bound to it across the update.
 */
class UsageWidget : ProviderUsageWidget(Provider.CLAUDE)

class CodexUsageWidget : ProviderUsageWidget(Provider.CODEX)

class CursorUsageWidget : ProviderUsageWidget(Provider.CURSOR)
