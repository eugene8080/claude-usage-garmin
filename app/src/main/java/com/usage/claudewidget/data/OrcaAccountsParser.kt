package com.usage.claudewidget.data

import org.json.JSONObject
import kotlin.math.roundToInt

/**
 * Reads the result of desktop Orca's `accounts.list` RPC (Orca's `AccountsSnapshot`, from
 * `RuntimeAccountController.getSnapshot()`) into what the widgets and the watch draw.
 *
 * The part used is `rateLimits`, Orca's `RateLimitState`: one `ProviderRateLimits` block (or
 * null) per provider, for the account active in Orca -
 *
 * ```
 * { provider, status: 'idle'|'fetching'|'ok'|'error'|'unavailable', error, updatedAt,
 *   session?, weekly?, fableWeekly?, monthly?, buckets?: [{name, ...window}] }
 * window = { usedPercent: 0..100, windowMinutes, resetsAt: epoch ms | null, resetDescription }
 * ```
 *
 * Which windows a provider fills: Claude `session` (5 h) + `weekly` + `fableWeekly`; Codex
 * `session` + `weekly`; Cursor `monthly` (the plan) + `buckets` ("Cursor Models",
 * "Other Models", "On-demand", all on the billing cycle).
 */
object OrcaAccountsParser {

    class Parsed(
        val usage: Map<Provider, ProviderUsage>,
        /** Claude's numbers for the watch; null when Orca has no Claude 5H or 1W window. */
        val claudeWatch: UsageSnapshot?,
    )

    /**
     * @throws IllegalArgumentException when [result] is not an accounts snapshot, so the
     *   caller can treat it as a failed fetch and keep the last good numbers.
     */
    fun parse(result: Any?): Parsed {
        require(result is JSONObject) { "accounts.list returned no object" }
        val rateLimits = result.optJSONObject("rateLimits")
        requireNotNull(rateLimits) { "accounts.list result has no rateLimits" }
        val usage = Provider.entries.associateWith { provider ->
            providerUsage(provider, rateLimits.optJSONObject(provider.orcaKey))
        }
        return Parsed(usage, claudeWatchSnapshot(rateLimits.optJSONObject(Provider.CLAUDE.orcaKey)))
    }

    private fun providerUsage(provider: Provider, block: JSONObject?): ProviderUsage {
        if (block == null) {
            return ProviderUsage(provider, emptyList(), ProviderStatus.NOT_SET_UP, null, 0L)
        }
        return ProviderUsage(
            provider = provider,
            meters = meters(provider, block).take(ProviderUsage.MAX_METERS),
            status = when (block.optString("status")) {
                "ok" -> ProviderStatus.OK
                "error" -> ProviderStatus.ERROR
                "unavailable" -> ProviderStatus.UNAVAILABLE
                else -> ProviderStatus.PENDING // 'idle' / 'fetching', or a status this build doesn't know
            },
            error = if (block.isNull("error")) null else block.optString("error").ifBlank { null },
            updatedAtEpochMs = block.optLong("updatedAt", 0L),
        )
    }

    /** Every window the block carries, in the order the widget lists them. */
    private fun meters(provider: Provider, block: JSONObject): List<Meter> {
        val meters = mutableListOf<Meter>()
        val session = window(block.optJSONObject("session"))
        val weekly = window(block.optJSONObject("weekly"))
        val fable = window(block.optJSONObject("fableWeekly"))
        val monthly = window(block.optJSONObject("monthly"))

        session?.let { meters += it.toMeter(it.label() ?: "5H") }
        weekly?.let { meters += it.toMeter(it.label() ?: "1W") }
        fable?.let {
            // A per-model window is a sub-cap on the weekly pool, and its reset can be null
            // until that model is used in the period: borrow the pooled reset so the row
            // does not show a blank time.
            val resetsAt = if (it.resetsAtEpochMs != 0L) it.resetsAtEpochMs else weekly?.resetsAtEpochMs ?: 0L
            meters += Meter("${weekly?.label() ?: "1W"} Fable", it.utilization, resetsAt)
        }
        monthly?.let {
            // Cursor's monthly window is its plan's overall pool; elsewhere label it by length.
            meters += it.toMeter(if (provider == Provider.CURSOR) "Plan" else it.label() ?: "1M")
        }
        block.optJSONArray("buckets")?.let { buckets ->
            for (i in 0 until buckets.length()) {
                val bucket = buckets.optJSONObject(i) ?: continue
                val parsed = window(bucket) ?: continue
                meters += parsed.toMeter(bucketLabel(bucket.optString("name")))
            }
        }
        return meters
    }

    /**
     * Claude for the watch: 5H and 1W are always sent (garmin/CONTRACT.md), so a missing one
     * goes as 0 % with no reset, as the claude.ai reader did; with neither there is nothing
     * worth sending.
     */
    private fun claudeWatchSnapshot(block: JSONObject?): UsageSnapshot? {
        if (block == null) return null
        val session = window(block.optJSONObject("session"))
        val weekly = window(block.optJSONObject("weekly"))
        if (session == null && weekly == null) return null
        val fable = window(block.optJSONObject("fableWeekly"))?.let {
            val resetsAt = if (it.resetsAtEpochMs != 0L) it.resetsAtEpochMs else weekly?.resetsAtEpochMs ?: 0L
            ModelWindow("Fable", Window(it.utilization, resetsAt))
        }
        return UsageSnapshot(
            fiveHour = session?.toWindow() ?: Window(0f, 0L),
            sevenDay = weekly?.toWindow() ?: Window(0f, 0L),
            modelWeekly = fable,
            fetchedAtEpochMs = block.optLong("updatedAt", 0L),
        )
    }

    private class ParsedWindow(val utilization: Float, val windowMinutes: Int, val resetsAtEpochMs: Long) {
        fun toMeter(label: String) = Meter(label, utilization, resetsAtEpochMs)
        fun toWindow() = Window(utilization, resetsAtEpochMs)

        /** "5H" / "1W" / "1M" / "3D" from the window's length; null when Orca gave none. */
        fun label(): String? = when {
            windowMinutes <= 0 -> null
            windowMinutes == WEEK_MINUTES -> "1W"
            // Cursor's billing cycle is the real month (28-31 days), not a flat 30.
            windowMinutes in 28 * DAY_MINUTES..31 * DAY_MINUTES -> "1M"
            windowMinutes % DAY_MINUTES == 0 -> "${windowMinutes / DAY_MINUTES}D"
            windowMinutes % 60 == 0 -> "${windowMinutes / 60}H"
            else -> "${windowMinutes}m"
        }
    }

    /** Null for a missing or unreadable window (no `usedPercent`), so it is left out rather than drawn as 0 %. */
    private fun window(json: JSONObject?): ParsedWindow? {
        if (json == null) return null
        val used = json.opt("usedPercent")
        if (used !is Number || !used.toDouble().isFinite()) return null
        return ParsedWindow(
            utilization = used.toFloat().coerceIn(0f, 100f),
            windowMinutes = json.optInt("windowMinutes", 0),
            resetsAtEpochMs = if (json.isNull("resetsAt")) 0L else json.optLong("resetsAt", 0L),
        )
    }

    /**
     * Short labels for Cursor's pools - the widget's label column fits about 8 characters.
     * "Cursor Models" is the Auto/Composer pool and "Other Models" the API pool
     * (Orca's cursor-usage-mapping.ts: autoPercentUsed / apiPercentUsed).
     */
    private fun bucketLabel(name: String): String = when (name) {
        "Cursor Models" -> "Auto"
        "Other Models" -> "API"
        "On-demand" -> "On-dem"
        else -> name.take(8).ifBlank { "Pool" }
    }

    private const val DAY_MINUTES = 24 * 60
    private const val WEEK_MINUTES = 7 * DAY_MINUTES

    /** For the app's status screen: one line per provider, e.g. "Claude: 5H 12% · 1W 40%". */
    fun summarize(usage: ProviderUsage): String = buildString {
        append(usage.provider.displayName).append(": ")
        when {
            // Rounded like the widget's own figures, so the app and the widget agree.
            usage.hasData -> append(usage.meters.joinToString(" · ") { "${it.label} ${it.utilization.roundToInt()}%" })
            usage.status == ProviderStatus.NOT_SET_UP -> append("not set up in Orca")
            usage.status == ProviderStatus.UNAVAILABLE -> append("unavailable in Orca")
            usage.status == ProviderStatus.PENDING -> append("waiting for Orca's first fetch")
            else -> append("no data")
        }
        if (usage.status == ProviderStatus.ERROR || usage.status == ProviderStatus.UNAVAILABLE) {
            usage.error?.let { append(" (").append(it.take(80)).append(")") }
        }
    }
}
