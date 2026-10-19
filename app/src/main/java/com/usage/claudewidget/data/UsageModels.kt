package com.usage.claudewidget.data

import org.json.JSONArray
import org.json.JSONObject

/** One usage window. */
data class Window(
    val utilization: Float,      // percent, 0..100
    val resetsAtEpochMs: Long,   // absolute reset time; 0 when none is reported
)

/**
 * A per-model weekly sub-cap - Fable today. The label travels with the window instead of
 * being hardcoded where it is drawn.
 */
data class ModelWindow(
    val modelName: String,
    val window: Window,
)

/**
 * Claude's three meters in the shape the Garmin watch expects (garmin/CONTRACT.md, built by
 * WatchBridge.payloadOf). The watch stays Claude-only; this is cut from the Claude
 * [ProviderUsage] by [OrcaAccountsParser.claudeWatchSnapshot].
 */
data class UsageSnapshot(
    val fiveHour: Window,
    val sevenDay: Window,
    val modelWeekly: ModelWindow?,
    /** When these numbers were fetched from the provider (by desktop Orca), epoch ms. */
    val fetchedAtEpochMs: Long,
)

/** The providers the widget can show, each as its own home-screen widget. */
enum class Provider(
    /** The key of this provider's block in Orca's `rateLimits` snapshot. */
    val orcaKey: String,
    val displayName: String,
) {
    CLAUDE("claude", "Claude"),
    CODEX("codex", "Codex"),
    CURSOR("cursor", "Cursor"),
}

/** One meter row: a label ("5H", "1W", "1W Fable", "Plan"), % used, and when it resets. */
data class Meter(
    val label: String,
    val utilization: Float,
    val resetsAtEpochMs: Long,
    /**
     * Which of Orca's windows this is, independent of the display label: "session",
     * "weekly", "fableWeekly", "monthly", or "bucket:<Orca bucket name>". The usage grid
     * finds its fixed rows by it. Empty in snapshots stored before it existed.
     */
    val key: String = "",
) {
    companion object {
        const val SESSION = "session"
        const val WEEKLY = "weekly"
        const val FABLE_WEEKLY = "fableWeekly"
        const val MONTHLY = "monthly"
        fun bucket(name: String) = "bucket:$name"
    }
}

/**
 * How desktop Orca last fared fetching this provider - Orca's `ProviderRateLimitStatus`,
 * plus [NOT_SET_UP] for a provider Orca reports nothing for.
 */
enum class ProviderStatus {
    OK,
    /** Orca's last fetch failed; any meters are from an earlier success. */
    ERROR,
    /** Orca cannot fetch it (not signed in, no subscription). */
    UNAVAILABLE,
    /** Orca has not finished its first fetch yet. */
    PENDING,
    /** Orca's snapshot has no block for this provider at all. */
    NOT_SET_UP,
}

/** One provider's usage as the widget draws it. */
data class ProviderUsage(
    val provider: Provider,
    /** In display order, at most [MAX_METERS]. Empty when Orca has no numbers. */
    val meters: List<Meter>,
    val status: ProviderStatus,
    /** Orca's error text for the last failed fetch, if any. */
    val error: String?,
    /** When Orca last fetched these numbers successfully, epoch ms; 0 when never. */
    val updatedAtEpochMs: Long,
) {
    val hasData: Boolean get() = meters.isNotEmpty()

    fun toJson(): String = JSONObject()
        .put("provider", provider.name)
        .put("status", status.name)
        .put("error", error ?: JSONObject.NULL)
        .put("updatedAt", updatedAtEpochMs)
        .put(
            "meters",
            JSONArray().apply {
                meters.forEach { meter ->
                    put(
                        JSONObject()
                            .put("label", meter.label)
                            .put("pct", meter.utilization.toDouble())
                            .put("resetsAt", meter.resetsAtEpochMs)
                            .put("key", meter.key),
                    )
                }
            },
        )
        .toString()

    companion object {
        /** The widget layouts have room for three meter rows. */
        const val MAX_METERS = 3

        /** Reads what [toJson] wrote; null for anything unreadable (then the widget shows no data). */
        fun fromJson(json: String): ProviderUsage? = runCatching {
            val root = JSONObject(json)
            val meters = root.getJSONArray("meters")
            ProviderUsage(
                provider = Provider.valueOf(root.getString("provider")),
                meters = (0 until meters.length()).map { i ->
                    val meter = meters.getJSONObject(i)
                    Meter(
                        label = meter.getString("label"),
                        utilization = meter.getDouble("pct").toFloat(),
                        resetsAtEpochMs = meter.getLong("resetsAt"),
                        key = meter.optString("key", ""),
                    )
                },
                status = ProviderStatus.valueOf(root.getString("status")),
                error = if (root.isNull("error")) null else root.getString("error"),
                updatedAtEpochMs = root.getLong("updatedAt"),
            )
        }.getOrNull()
    }
}
