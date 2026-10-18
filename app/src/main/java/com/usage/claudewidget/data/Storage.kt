package com.usage.claudewidget.data

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.usage.claudewidget.orca.OrcaPairing
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

/**
 * Two-tier storage:
 *  - [secure]   EncryptedSharedPreferences for the desktop Orca pairing (device token, pinned key).
 *  - [snapshot] Plain prefs for the non-secret usage snapshots the widgets render on every frame.
 */
class Storage private constructor(
    private val secure: SharedPreferences,
    private val snapshot: SharedPreferences,
) {
    /**
     * Emits whenever the plain snapshot prefs change (usage, link state, watch status) -
     * which every refresh, pairing and unpairing writes. The widgets recompose from it.
     *
     * The listener is held by this flow's closure until the collector goes away:
     * SharedPreferences keeps only a weak reference to it.
     */
    fun snapshotChanges(): Flow<Unit> = callbackFlow {
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ -> trySend(Unit) }
        snapshot.registerOnSharedPreferenceChangeListener(listener)
        awaitClose { snapshot.unregisterOnSharedPreferenceChangeListener(listener) }
    }

    // ---- desktop Orca pairing (encrypted) ----
    //
    // The device token is a bearer credential for this phone's entry in desktop Orca: anyone
    // holding it (and able to reach the computer) can read what the Orca phone app can. It
    // never leaves the encrypted tier.

    var pairing: OrcaPairing?
        get() {
            val endpoint = secure.getString(KEY_ENDPOINT, null) ?: return null
            val token = secure.getString(KEY_DEVICE_TOKEN, null) ?: return null
            val publicKey = secure.getString(KEY_PUBLIC_KEY, null) ?: return null
            return OrcaPairing(endpoint, token, publicKey, secure.getString(KEY_PAIRED_DEVICE_ID, null))
        }
        set(value) {
            val edit = secure.edit()
            if (value == null) {
                edit.remove(KEY_ENDPOINT).remove(KEY_DEVICE_TOKEN).remove(KEY_PUBLIC_KEY).remove(KEY_PAIRED_DEVICE_ID)
            } else {
                edit.putString(KEY_ENDPOINT, value.endpoint)
                    .putString(KEY_DEVICE_TOKEN, value.deviceToken)
                    .putString(KEY_PUBLIC_KEY, value.publicKeyB64)
                    .putString(KEY_PAIRED_DEVICE_ID, value.pairedDeviceId)
            }
            // commit, not apply: the next step (a test fetch, a background refresh) reads it back.
            edit.commit()
        }

    val isPaired: Boolean get() = pairing != null

    // ---- per-provider usage (plain, read by the widgets) ----

    fun usage(provider: Provider): ProviderUsage? =
        snapshot.getString(usageKey(provider), null)?.let(ProviderUsage::fromJson)

    fun saveUsage(usage: Collection<ProviderUsage>) {
        val edit = snapshot.edit()
        usage.forEach { edit.putString(usageKey(it.provider), it.toJson()) }
        edit.apply()
    }

    fun clearUsage() {
        val edit = snapshot.edit()
        Provider.entries.forEach { edit.remove(usageKey(it)) }
        edit.apply()
    }

    private fun usageKey(provider: Provider) = "usage_${provider.orcaKey}"

    // ---- the link to desktop Orca (plain, for the widgets' prompts and the app's status line) ----

    /** How the last attempt to reach desktop Orca ended; widgets prompt for pairing on NEEDS_PAIRING. */
    var linkState: LinkState
        get() = LinkState.entries.getOrElse(snapshot.getInt("link_state", 0)) { LinkState.OK }
        set(v) = snapshot.edit().putInt("link_state", v.ordinal).apply()

    /** Human-readable reason for the last failed attempt, e.g. "can't reach ws://100.x:6768 ...". */
    var linkDetail: String
        get() = snapshot.getString("link_detail", "").orEmpty()
        set(v) = snapshot.edit().putString("link_detail", v).apply()

    /** When the phone last tried / last succeeded to reach desktop Orca, epoch ms; 0 when never. */
    var linkAttemptAt: Long
        get() = snapshot.getLong("link_attempt_at", 0L)
        set(v) = snapshot.edit().putLong("link_attempt_at", v).apply()

    var linkSuccessAt: Long
        get() = snapshot.getLong("link_success_at", 0L)
        set(v) = snapshot.edit().putLong("link_success_at", v).apply()

    // ---- last watch push (plain, diagnostics for the phone app's status line) ----
    //
    // The push to the Garmin watch fails silently by design (it must never fail a widget
    // refresh), which made "why is the watch stale?" unanswerable without a USB cable and
    // logcat. Recording the last outcome lets the app itself answer it.

    /** When the last push attempt finished, epoch ms; 0 when none has run. */
    val watchPushAt: Long get() = snapshot.getLong("watch_push_at", 0L)

    /** Whether that attempt reached a watch. */
    val watchPushOk: Boolean get() = snapshot.getBoolean("watch_push_ok", false)

    /** Human-readable outcome, e.g. "sent to tactix 8" or "failed (timeout)". */
    val watchPushDetail: String get() = snapshot.getString("watch_push_detail", "").orEmpty()

    /** When a push last actually reached a watch, epoch ms; 0 when never. */
    val watchLastSentAt: Long get() = snapshot.getLong("watch_last_sent_at", 0L)

    /**
     * Whether the last push was cut off by the phone's own background management (the job
     * was stopped mid-send) - the one failure that a phone setting, not the watch, fixes.
     */
    val watchPushStoppedBySystem: Boolean
        get() = snapshot.getBoolean("watch_push_stopped_by_system", false)

    fun saveWatchPush(atEpochMs: Long, ok: Boolean, detail: String, stoppedBySystem: Boolean = false) {
        val edit = snapshot.edit()
            .putLong("watch_push_at", atEpochMs)
            .putBoolean("watch_push_ok", ok)
            .putString("watch_push_detail", detail)
            .putBoolean("watch_push_stopped_by_system", stoppedBySystem)
        if (ok) {
            edit.putLong("watch_last_sent_at", atEpochMs)
        }
        edit.apply()
    }

    /**
     * When the user confirmed they allowed background activity in the "Keep it running in
     * the background" prompt, epoch ms; 0 when never. The prompt stays away after that
     * unless a later watch push is stopped by the system again.
     */
    var backgroundHelpAckAt: Long
        get() = snapshot.getLong("background_help_ack_at", 0L)
        set(v) = snapshot.edit().putLong("background_help_ack_at", v).apply()

    companion object {
        private const val KEY_ENDPOINT = "orca_endpoint"
        private const val KEY_DEVICE_TOKEN = "orca_device_token"
        private const val KEY_PUBLIC_KEY = "orca_public_key"
        private const val KEY_PAIRED_DEVICE_ID = "orca_paired_device_id"

        @Volatile private var instance: Storage? = null

        fun get(context: Context): Storage = instance ?: synchronized(this) {
            instance ?: build(context.applicationContext).also { instance = it }
        }

        private fun build(app: Context): Storage {
            val masterKey = MasterKey.Builder(app)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            val secure = EncryptedSharedPreferences.create(
                app,
                "claude_secure",
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
            val snapshot = app.getSharedPreferences("claude_usage", Context.MODE_PRIVATE)
            dropClaudeAiData(secure, snapshot)
            return Storage(secure, snapshot)
        }

        /**
         * Builds before the Orca source signed in to claude.ai in a WebView and kept the
         * session cookie, which is as sensitive as the account password. Nothing reads it
         * any more, so an upgraded install deletes it - and the old single-provider snapshot
         * - once, instead of keeping a live credential around for nothing.
         */
        private fun dropClaudeAiData(secure: SharedPreferences, snapshot: SharedPreferences) {
            if (snapshot.getBoolean("claude_ai_data_dropped", false)) return
            secure.edit()
                .remove("sessionKey").remove("cf_clearance").remove("user_agent").remove("org_id")
                .commit()
            snapshot.edit()
                .remove("fh_util").remove("fh_reset").remove("wk_util").remove("wk_reset")
                .remove("mw_util").remove("mw_reset").remove("mw_name")
                .remove("fetched_at").remove("auth_state")
                .putBoolean("claude_ai_data_dropped", true)
                .commit()
        }
    }
}

/** How the last attempt to reach desktop Orca ended. */
enum class LinkState {
    OK,
    /** No pairing, or Orca refused this device (revoked / re-keyed): the user must pair. */
    NEEDS_PAIRING,
    /** Desktop Orca could not be reached (computer off, Orca closed, no Tailscale). */
    UNREACHABLE,
    /** Reached Orca but the call failed (timeout, protocol, RPC error). */
    FAILED,
}
