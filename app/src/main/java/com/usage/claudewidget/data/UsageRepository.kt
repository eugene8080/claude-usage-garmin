package com.usage.claudewidget.data

import android.content.Context
import android.util.Log
import com.usage.claudewidget.orca.OrcaCallResult
import com.usage.claudewidget.orca.OrcaClient
import org.json.JSONObject

sealed interface FetchResult {
    data class Success(
        /** Merged: a provider with no fresh numbers keeps its last ones (see keepLastMeters). */
        val usage: Map<Provider, ProviderUsage>,
    ) : FetchResult {
        /** What the Garmin watch apps get, cut from the merged [usage]. */
        val watch: WatchSnapshot get() = WatchSnapshot.from(usage)
    }

    /** Not paired, or desktop Orca refused this device: the user must pair (again). */
    data class NeedsPairing(val reason: String) : FetchResult

    /**
     * The fetch failed but the pairing is fine; the last numbers stay on the widgets.
     * [retry] is whether trying again soon could help (a timeout mid-call) as opposed to
     * waiting for the next 15-minute run (the computer is off).
     */
    data class Soft(val reason: String, val retry: Boolean) : FetchResult
}

/**
 * Fetches every provider's usage from desktop Orca in one `accounts.list` call and records
 * the outcome in [Storage] for the widgets and the app's status screen.
 */
class UsageRepository(
    context: Context,
    private val client: OrcaClient = OrcaClient(),
) {
    private val storage = Storage.get(context)

    suspend fun refresh(): FetchResult {
        val pairing = storage.pairing
        if (pairing == null) {
            record(LinkState.NEEDS_PAIRING, "not paired with Orca")
            return FetchResult.NeedsPairing("not paired with Orca")
        }
        storage.linkAttemptAt = System.currentTimeMillis()

        // refreshUsage: desktop Orca pauses its own polling while its window is unfocused, so
        // without this the snapshot could be stale; Orca debounces repeated refreshes itself.
        val params = JSONObject().put("refreshUsage", true)
        return when (val result = client.call(pairing, METHOD_ACCOUNTS_LIST, params)) {
            is OrcaCallResult.Ok -> {
                val parsed = try {
                    OrcaAccountsParser.parse(result.result)
                } catch (e: IllegalArgumentException) {
                    Log.w(TAG, "unreadable accounts snapshot: ${e.message}")
                    record(LinkState.FAILED, "unexpected reply from Orca (${e.message})")
                    return FetchResult.Soft("unexpected reply from Orca", retry = false)
                }
                val merged = parsed.usage.mapValues { (provider, fresh) -> keepLastMeters(provider, fresh) }
                storage.saveUsage(merged.values)
                storage.linkSuccessAt = System.currentTimeMillis()
                record(LinkState.OK, "")
                FetchResult.Success(merged)
            }
            is OrcaCallResult.Unauthorized -> {
                record(LinkState.NEEDS_PAIRING, result.reason)
                FetchResult.NeedsPairing(result.reason)
            }
            is OrcaCallResult.Unreachable -> {
                record(LinkState.UNREACHABLE, result.reason)
                FetchResult.Soft(result.reason, retry = false)
            }
            is OrcaCallResult.Failed -> {
                record(LinkState.FAILED, result.reason)
                FetchResult.Soft(result.reason, retry = true)
            }
            is OrcaCallResult.RpcError -> {
                val reason = "Orca error ${result.code}" + if (result.message.isBlank()) "" else ": ${result.message}"
                record(LinkState.FAILED, reason)
                FetchResult.Soft(reason, retry = true)
            }
        }
    }

    /**
     * A provider Orca has no numbers for this time (its fetch failed, or Orca dropped data
     * older than 30 minutes) keeps the last numbers the widget had, with the new status.
     * Their own `updatedAt` stays, so the widget's stale dot shows how old they are - the
     * same "keep the last snapshot" behaviour the widget always had.
     */
    private fun keepLastMeters(provider: Provider, fresh: ProviderUsage): ProviderUsage {
        if (fresh.hasData) return fresh
        val last = storage.usage(provider) ?: return fresh
        if (!last.hasData) return fresh
        return last.copy(status = fresh.status, error = fresh.error)
    }

    private fun record(state: LinkState, detail: String) {
        storage.linkState = state
        storage.linkDetail = detail
    }

    private companion object {
        const val TAG = "UsageRepository"
        const val METHOD_ACCOUNTS_LIST = "accounts.list"
    }
}
