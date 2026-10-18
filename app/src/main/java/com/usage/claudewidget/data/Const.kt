package com.usage.claudewidget.data

object Const {
    const val REFRESH_INTERVAL_MIN = 15L

    // Unchanged from the claude.ai builds, so an upgraded install keeps (and UPDATEs) the
    // periodic work it already has instead of scheduling a second one beside it.
    const val WORK_NAME = "claude-usage-refresh"
}
