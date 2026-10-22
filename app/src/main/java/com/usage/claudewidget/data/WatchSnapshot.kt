package com.usage.claudewidget.data

/**
 * Codex's two windows for the watch. A null window is one Orca did not report (on 2026-10-19
 * Orca sent `session: null` for Codex), and the watch leaves that row out.
 */
data class CodexWatch(
    val fiveHour: Window?,
    val weekly: Window?,
    /** When Orca last fetched these numbers, epoch ms. */
    val fetchedAtEpochMs: Long,
)

/** Cursor's plan and its Auto and API pools for the watch; a null window is left out there. */
data class CursorWatch(
    val plan: Window?,
    val auto: Window?,
    val api: Window?,
    /** When Orca last fetched these numbers, epoch ms. */
    val fetchedAtEpochMs: Long,
)

/**
 * Everything the Garmin watch apps get, one optional block per provider. WatchBridge.payloadOf
 * turns each block into one group of message keys (garmin/CONTRACT.md). A null block means the
 * phone has no numbers for that provider at all; the watch then clears that page instead of
 * keeping old numbers, the same rule the per-model meter has always had.
 */
data class WatchSnapshot(
    val claude: UsageSnapshot?,
    val codex: CodexWatch?,
    val cursor: CursorWatch?,
) {
    /** Nothing to send: the push is skipped, so the watch keeps what it has. */
    val isEmpty: Boolean get() = claude == null && codex == null && cursor == null

    companion object {

        /** The capped model the Claude `fableWeekly` window belongs to. */
        private const val CLAUDE_MODEL = "Fable"

        /**
         * Cut the watch's numbers from what the widgets draw.
         *
         * [usage] should be the repository's merged map: a provider whose fetch failed this
         * time keeps its last numbers there, with their own (older) fetch time, so the watch
         * shows them as stale rather than losing them.
         *
         * Meters are found by [Meter.key], not by label. A meter stored before keys existed
         * has an empty key and is treated as missing; every fetch since PR #54 writes keys.
         */
        fun from(usage: Map<Provider, ProviderUsage>): WatchSnapshot = WatchSnapshot(
            claude = usage[Provider.CLAUDE]?.let(::claude),
            codex = usage[Provider.CODEX]?.let(::codex),
            cursor = usage[Provider.CURSOR]?.let(::cursor),
        )

        /**
         * Claude's 5H and 1W go as a pair (garmin/CONTRACT.md): a watch app older than the
         * provider pages rejects a message without both. So a missing one goes as 0 % with no
         * reset, as before, and with neither there is no Claude block at all.
         */
        private fun claude(usage: ProviderUsage): UsageSnapshot? {
            val session = usage.window(Meter.SESSION)
            val weekly = usage.window(Meter.WEEKLY)
            if (session == null && weekly == null) return null
            return UsageSnapshot(
                fiveHour = session ?: Window(0f, 0L),
                sevenDay = weekly ?: Window(0f, 0L),
                // The parser already gave this window the pooled weekly reset when Orca had
                // none for it, so it can be passed on as it is.
                modelWeekly = usage.window(Meter.FABLE_WEEKLY)?.let { ModelWindow(CLAUDE_MODEL, it) },
                fetchedAtEpochMs = usage.updatedAtEpochMs,
            )
        }

        private fun codex(usage: ProviderUsage): CodexWatch? {
            val fiveHour = usage.window(Meter.SESSION)
            val weekly = usage.window(Meter.WEEKLY)
            if (fiveHour == null && weekly == null) return null
            return CodexWatch(fiveHour, weekly, usage.updatedAtEpochMs)
        }

        private fun cursor(usage: ProviderUsage): CursorWatch? {
            val plan = usage.window(Meter.MONTHLY)
            val auto = usage.window(Meter.bucket(Meter.CURSOR_AUTO_POOL))
            val api = usage.window(Meter.bucket(Meter.CURSOR_API_POOL))
            if (plan == null && auto == null && api == null) return null
            return CursorWatch(plan, auto, api, usage.updatedAtEpochMs)
        }

        private fun ProviderUsage.window(key: String): Window? =
            meters.firstOrNull { it.key == key }?.let { Window(it.utilization, it.resetsAtEpochMs) }
    }
}
