package com.usage.claudewidget.widget

import android.content.Context
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import com.usage.claudewidget.work.RefreshScheduler

/**
 * Shared behaviour of the three widget receivers: the first widget placed starts the
 * background refresh, and every update re-asserts it.
 */
abstract class ProviderUsageWidgetReceiver : GlanceAppWidgetReceiver() {

    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        // First widget of this provider added: start the periodic refresh and fetch
        // immediately (refreshNow also (re)schedules the periodic work).
        RefreshScheduler.refreshNow(context)
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: android.appwidget.AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        super.onUpdate(context, appWidgetManager, appWidgetIds)
        RefreshScheduler.ensurePeriodic(context)
    }
}

/** Claude. Keeps its pre-Orca component name so placed widgets survive the update. */
class UsageWidgetReceiver : ProviderUsageWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = UsageWidget()
}

class CodexUsageWidgetReceiver : ProviderUsageWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = CodexUsageWidget()
}

class CursorUsageWidgetReceiver : ProviderUsageWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = CursorUsageWidget()
}
