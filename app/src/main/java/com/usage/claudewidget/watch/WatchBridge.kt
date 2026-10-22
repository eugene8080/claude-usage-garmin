package com.usage.claudewidget.watch

import android.content.Context
import android.util.Log
import com.garmin.android.connectiq.ConnectIQ
import com.garmin.android.connectiq.IQApp
import com.garmin.android.connectiq.IQDevice
import com.usage.claudewidget.BuildConfig
import com.usage.claudewidget.data.Storage
import com.usage.claudewidget.data.WatchSnapshot
import com.usage.claudewidget.data.Window
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume

/**
 * Pushes the usage snapshot to the Garmin watch apps over BLE, via Garmin Connect Mobile.
 *
 * This is the only thing that ever reaches the watch. The watch apps hold no credentials and
 * make no web requests - see garmin/watch-app/README.md for why that is not negotiable - so
 * if this push does not happen, the watch goes stale.
 *
 * Two apps get the same message: the watch app (Claude Usage: the glance, the three provider
 * pages and four complications) and, after it, the Codex + Cursor app, which exists only to
 * publish four more complications - Connect IQ caps one app at four. The second is optional:
 * it is tried once, after the first push is settled, and never fails or retries it.
 *
 * The app ids and the message keys are one side of a contract with the watch apps, written
 * down in garmin/CONTRACT.md and checked in CI by garmin/tools/check_contract.py: change either
 * here and the watch side (and that file) must change in the same commit.
 *
 * Every failure here is swallowed and logged. A watch that is out of range, a Garmin Connect
 * Mobile that is not installed, a watch app that was never sideloaded: none of those are
 * reasons to fail a refresh whose real job is updating the home-screen widget. The outcome of
 * every push is recorded in [Storage] so the phone app can show it without a USB cable.
 */
object WatchBridge {

    /** Must match `id` in garmin/watch-app/manifest.xml; the watch app is addressed by this (garmin/CONTRACT.md). */
    private const val WATCH_APP_ID = "8a5bd20e02f34f58afb5f357a23a4a65"

    /**
     * Must match `id` in garmin/feed-app/manifest.xml: the Codex + Cursor app, which publishes
     * the Codex and Cursor complications the watch app has no room for (garmin/CONTRACT.md).
     */
    private const val FEED_APP_ID = "43bb7ac1ca954af9a00dfff271303aee"

    /** How the phone's status line names the Codex + Cursor app. */
    private const val FEED_APP_NAME = "Codex + Cursor app"

    private const val TAG = "ClaudeWatch"

    /**
     * Deadline for one attempt (SDK ready -> devices -> app info -> send). The handshake is
     * callback-driven with no timeout of its own: a watch that is paired but asleep simply
     * never calls back, so without this a background refresh would hang until WorkManager
     * kills it.
     */
    private const val ATTEMPT_TIMEOUT_MS = 15_000L

    /**
     * Deadline for the Codex + Cursor app's single attempt. Shorter than the watch app's: the
     * SDK is already bound by then, so only the device query and the send remain, and nothing
     * waits on this app.
     */
    private const val FEED_TIMEOUT_MS = 10_000L

    /**
     * A window the phone has no numbers for, inside a Codex or Cursor key group: the watch
     * leaves that row (and complication) empty instead of drawing 0 %.
     */
    private const val NO_WINDOW = -1

    /**
     * Pause before the single retry. Long enough for a BLE link that dropped for a moment
     * (phone in a pocket, a lift, a tunnel) to come back; short enough that the whole push
     * stays well inside WorkManager's 10-minute execution window and the "Test fetch now"
     * button does not feel hung.
     */
    private const val RETRY_DELAY_MS = 5_000L

    // Reason codes carried by NoTarget. The SDK prefix is followed by the SDK's own status
    // name (e.g. GCM_NOT_INSTALLED) so the phone's status line can show it verbatim.
    private const val REASON_APP_NOT_INSTALLED = "app-not-installed"
    private const val REASON_NO_DEVICE = "no-connected-device"
    private const val REASON_SDK_PREFIX = "garmin-connect:"
    private const val REASON_STOPPED_BY_SYSTEM = "stopped-by-system"

    sealed interface PushResult {
        /** The watch app took it. [feed] is how the Codex + Cursor app on the watch fared. */
        data class Sent(val deviceName: String, val feed: Feed = Feed.NOT_INSTALLED) : PushResult
        /** Nothing to talk to: no connected watch, SDK unavailable, or app not installed. */
        data class NoTarget(val reason: String) : PushResult
        data class Failed(val reason: String) : PushResult
    }

    /** The Codex + Cursor app's outcome. It is optional, so it only ever annotates [PushResult.Sent]. */
    enum class Feed { SENT, NOT_INSTALLED, FAILED }

    /**
     * Send [snapshot] to every connected watch that has the watch app installed, retrying
     * once after [RETRY_DELAY_MS] when the first attempt failed for a reason that can clear by
     * itself (link down, timeout, SDK hiccup); then, once, to the Codex + Cursor app. The final
     * outcome is persisted for the phone app's status line.
     *
     * Returns rather than throws; the caller is expected to log and carry on.
     */
    suspend fun push(context: Context, snapshot: WatchSnapshot): PushResult {
        val app = context.applicationContext
        val payload = payloadOf(snapshot)
        // The watch app's settled outcome, kept outside the try so a cancellation during the
        // feed step does not overwrite a push that already landed.
        var main: PushResult? = null
        try {
            var result = attempt(app, payload, WATCH_APP_ID, ATTEMPT_TIMEOUT_MS)
            if (isRetryable(result)) {
                Log.i(TAG, "push attempt 1 -> $result; retrying in ${RETRY_DELAY_MS}ms")
                delay(RETRY_DELAY_MS)
                result = attempt(app, payload, WATCH_APP_ID, ATTEMPT_TIMEOUT_MS)
            }
            main = result
            // Second, so it can neither delay nor fail the watch app's push; one try, no retry.
            // Only after a push that landed: otherwise the watch is unreachable or the SDK
            // is down, and a second attempt would just spend another timeout finding that out.
            if (result is PushResult.Sent) {
                val feed = when (val f = attempt(app, payload, FEED_APP_ID, FEED_TIMEOUT_MS)) {
                    is PushResult.Sent -> Feed.SENT
                    is PushResult.NoTarget -> Feed.NOT_INSTALLED
                    is PushResult.Failed -> Feed.FAILED.also { Log.i(TAG, "Codex + Cursor app push -> $f") }
                }
                result = result.copy(feed = feed)
            }
            record(app, result)
            return result
        } catch (e: CancellationException) {
            // The job was stopped from outside - on ColorOS (Oppo/OnePlus/realme) the OFreezer
            // re-freezes a background app ~5 s after waking it, and JobScheduler stops the
            // job with it (seen on-device 2026-09-25: fetch + widget done in ~1 s, push
            // cancelled at +5 s, every time). Record that distinctly - it is a phone setting
            // problem, not a watch or Bluetooth one - then let the cancellation propagate as
            // coroutines require. record() is synchronous, so it still runs here. If the watch
            // app already had its push, only the Codex + Cursor app missed out.
            val settled = main
            record(
                app,
                if (settled is PushResult.Sent) settled.copy(feed = Feed.FAILED)
                else PushResult.Failed(REASON_STOPPED_BY_SYSTEM),
            )
            throw e
        }
    }

    /** One user-facing phrase for [result], shared by the app's status line and debug text. */
    fun describe(result: PushResult): String = when (result) {
        is PushResult.Sent -> "sent to ${result.deviceName}" + when (result.feed) {
            Feed.SENT -> " + $FEED_APP_NAME"
            Feed.NOT_INSTALLED -> " ($FEED_APP_NAME not installed)"
            Feed.FAILED -> " ($FEED_APP_NAME missed it)"
        }
        is PushResult.NoTarget -> when {
            result.reason == REASON_NO_DEVICE ->
                "no watch connected (check Bluetooth and Garmin Connect)"
            result.reason == REASON_APP_NOT_INSTALLED ->
                "Claude Usage app is not installed on the watch"
            result.reason.startsWith(REASON_SDK_PREFIX) ->
                "Garmin Connect unavailable (${result.reason.removePrefix(REASON_SDK_PREFIX)})"
            else -> "not sent (${result.reason})"
        }
        is PushResult.Failed -> when (result.reason) {
            REASON_STOPPED_BY_SYSTEM ->
                "stopped by the phone before it finished (allow background activity)"
            else -> "failed (${result.reason})"
        }
    }

    private fun isRetryable(result: PushResult): Boolean = when (result) {
        is PushResult.Sent -> false
        // Not installed / Garmin Connect missing are setup states; 5 s will not change them.
        is PushResult.NoTarget -> result.reason == REASON_NO_DEVICE
        is PushResult.Failed -> true
    }

    private fun record(context: Context, result: PushResult) {
        try {
            Storage.get(context).saveWatchPush(
                atEpochMs = System.currentTimeMillis(),
                ok = result is PushResult.Sent,
                detail = describe(result),
                // Drives the app's "keep it running in the background" prompt.
                stoppedBySystem = result is PushResult.Failed &&
                    result.reason == REASON_STOPPED_BY_SYSTEM,
            )
        } catch (e: Exception) {
            // Storage is best-effort diagnostics; never let it turn a push into a crash.
            Log.w(TAG, "could not record push result: ${e.message}")
        }
    }

    /** One push of [payload] to the app [appId] on every connected watch, bounded by [timeoutMs]. */
    private suspend fun attempt(
        context: Context,
        payload: Map<String, Any>,
        appId: String,
        timeoutMs: Long,
    ): PushResult =
        withContext(Dispatchers.IO) {
            // Must NOT be the main thread. The tethered strategy does its own blocking TCP
            // inside getConnectedDevices()/sendMessage() - it talks to the simulator over an
            // adb-forwarded socket - so driving this from the main looper throws
            // NetworkOnMainThreadException. The SDK delivers its callbacks on the main
            // looper either way, which is all it actually needs the main thread for.
            try {
                withTimeout(timeoutMs) { attemptInternal(context, payload, appId) }
            } catch (e: TimeoutCancellationException) {
                // Must precede the CancellationException rethrow below: a timeout is OUR
                // deadline (a result), not the caller being cancelled.
                Log.w(TAG, "push to $appId timed out after ${timeoutMs}ms")
                // A wedged handshake may mean the SDK's service binding is stale; start the
                // next attempt from a clean initialise rather than reusing it.
                Sdk.reset(context)
                PushResult.Failed("timeout")
            } catch (e: CancellationException) {
                // The worker itself was stopped. Swallowing this (the old code logged it as
                // "push failed: JobCancellationException") would hide why; push() records it.
                throw e
            } catch (e: Exception) {
                // Includes InvalidStateException and ServiceUnavailableException, thrown when
                // Garmin Connect Mobile's service went away under us.
                Log.w(TAG, "push failed: ${e.javaClass.simpleName}: ${e.message}")
                Sdk.reset(context)
                PushResult.Failed(e.javaClass.simpleName)
            }
        }

    private suspend fun attemptInternal(context: Context, payload: Map<String, Any>, appId: String): PushResult {
        val connectIQ = when (val s = Sdk.acquire(context)) {
            is Sdk.Acquired.Ready -> s.connectIQ
            is Sdk.Acquired.Unavailable -> return PushResult.NoTarget(REASON_SDK_PREFIX + s.why)
        }

        val devices: List<IQDevice> = connectIQ.connectedDevices.orEmpty()
        if (devices.isEmpty()) {
            return PushResult.NoTarget(REASON_NO_DEVICE)
        }

        var result: PushResult = PushResult.NoTarget(REASON_APP_NOT_INSTALLED)

        for (device in devices) {
            // getApplicationInfo is what reports whether our app is sideloaded on THIS watch.
            // Sending to a device without it silently goes nowhere, so ask first.
            val app = awaitApplicationInfo(connectIQ, device, appId) ?: continue
            val sent = awaitSend(connectIQ, device, app, payload)
            if (sent is PushResult.Sent) {
                Log.i(TAG, "pushed $appId to ${device.friendlyName}")
            } else {
                Log.w(TAG, "push $appId to ${device.friendlyName} -> $sent")
            }
            // Any watch that took it counts as success; a second, offline watch must not
            // overwrite that with its own failure.
            if (result !is PushResult.Sent) {
                result = sent
            }
        }
        return result
    }

    /**
     * The payload the watch's Snapshot.store() expects. Keys are terse because a Connect IQ
     * message is small and this crosses a BLE link; they are mirrored verbatim in
     * garmin/shared/source-usage/Snapshot.mc, and listed in garmin/CONTRACT.md.
     *
     * Each `payload += mapOf(...)` below is one key GROUP, and a group travels whole or not at
     * all: the watch stores a group only when every key of it arrived, and clears a group that
     * is absent, so a provider the phone has no numbers for is blanked rather than left stale.
     * garmin/tools/check_contract.py reads these literals as the groups, so add a key inside
     * its group's literal, never as a lone `payload["k"] = ...`.
     *
     * Percentages are rounded to whole numbers here rather than on the watch: the watch
     * renders what it is given, and this keeps the phone as the single place that decides
     * how a figure is presented. Times are epoch SECONDS: Monkey C's Number is 32-bit, so epoch
     * milliseconds would overflow it, and Time.now().value() on the watch is seconds too.
     */
    // internal, not private, only so WatchBridgePayloadTest can check the groups' values.
    internal fun payloadOf(snapshot: WatchSnapshot): Map<String, Any> {
        val payload = mutableMapOf<String, Any>()
        snapshot.claude?.let { claude ->
            payload += mapOf(
                "fh" to claude.fiveHour.utilization.toSafeInt(),
                "fhr" to claude.fiveHour.resetsAtEpochMs.toEpochSeconds(),
                "wk" to claude.sevenDay.utilization.toSafeInt(),
                "wkr" to claude.sevenDay.resetsAtEpochMs.toEpochSeconds(),
                "ts" to claude.fetchedAtEpochMs.toEpochSeconds(),
            )
            // Inside the Claude block: a model cap is only drawn on the Claude page. Without a
            // cap the keys are omitted, which the watch treats as "clear that meter".
            claude.modelWeekly?.let { model ->
                payload += mapOf(
                    "mw" to model.window.utilization.toSafeInt(),
                    "mwr" to model.window.resetsAtEpochMs.toEpochSeconds(),
                    "mwn" to model.modelName,
                )
            }
        }
        // Codex and Cursor carry every window in their group, sending NO_WINDOW for one Orca
        // did not report: a missing window is common (Codex had no 5-hour window on
        // 2026-10-19) and must not drop the provider's other numbers with it.
        snapshot.codex?.let { codex ->
            payload += mapOf(
                "xfh" to codex.fiveHour.pct(),
                "xfhr" to codex.fiveHour.resetSec(),
                "xwk" to codex.weekly.pct(),
                "xwkr" to codex.weekly.resetSec(),
                "xts" to codex.fetchedAtEpochMs.toEpochSeconds(),
            )
        }
        snapshot.cursor?.let { cursor ->
            payload += mapOf(
                "upl" to cursor.plan.pct(),
                "uplr" to cursor.plan.resetSec(),
                "uau" to cursor.auto.pct(),
                "uaur" to cursor.auto.resetSec(),
                "uap" to cursor.api.pct(),
                "uapr" to cursor.api.resetSec(),
                "uts" to cursor.fetchedAtEpochMs.toEpochSeconds(),
            )
        }
        return payload
    }

    private fun Window?.pct(): Int = this?.utilization?.toSafeInt() ?: NO_WINDOW

    private fun Window?.resetSec(): Int = this?.resetsAtEpochMs?.toEpochSeconds() ?: 0

    private fun Float.toSafeInt(): Int = this.coerceIn(0f, 100f).toInt()

    private fun Long.toEpochSeconds(): Int = (this / 1000L).toInt()

    // ---- SDK lifecycle ------------------------------------------------------------------

    /**
     * Owns the one ConnectIQ initialisation this process is allowed.
     *
     * WHY THIS EXISTS - the bug it fixes. The wireless strategy (ConnectIQDeviceStrategy,
     * SDK 2.4.0) only ever calls `onSdkReady()` from its ServiceConnection's
     * `onServiceConnected()`. Calling `initialize()` a second time re-binds with the SAME
     * ServiceConnection object to a service that is already connected, and Android does not
     * re-deliver `onServiceConnected()` for a binding it already holds (LoadedApk's
     * ServiceDispatcher drops the duplicate). The old code initialised on every push, so it
     * got one working push per app process: every later push in that process waited for an
     * `onSdkReady` that never came, hit the timeout, and the watch went stale while the
     * phone widget - fed by the same fetch - stayed fresh. Each `initialize()` also
     * registered another BroadcastReceiver that was never unregistered.
     *
     * The simulator never showed it because the adb strategy calls `onSdkReady()` directly
     * inside every `initialize()`.
     *
     * So: initialise once, track readiness from the listener, and only re-initialise after
     * `shutdown()` - which unbinds, so the next bind is fresh and does deliver
     * `onServiceConnected()`.
     */
    private object Sdk : ConnectIQ.ConnectIQListener {

        /** How long to wait for Garmin Connect's service to bind on a fresh initialise. */
        private const val READY_TIMEOUT_MS = 8_000L

        /**
         * After Garmin Connect was killed or updated, Android rebinds automatically and the
         * SDK reports ready again by itself. Give that a moment before tearing down.
         */
        private const val RECONNECT_GRACE_MS = 2_000L

        sealed interface Acquired {
            data class Ready(val connectIQ: ConnectIQ) : Acquired
            data class Unavailable(val why: String) : Acquired
        }

        /** Serialises acquire/reset: two pushes (worker + button) must not both initialise. */
        private val lock = Mutex()

        /** Non-null once initialize() has been called and not since shut down. Under [lock]. */
        private var instance: ConnectIQ? = null

        // Written from the SDK's main-looper callbacks, read from the IO dispatcher.
        @Volatile private var ready = false
        @Volatile private var readySignal = CompletableDeferred<Boolean>()
        @Volatile private var initError: String? = null

        override fun onSdkReady() {
            ready = true
            initError = null
            readySignal.complete(true)
        }

        override fun onInitializeError(status: ConnectIQ.IQSdkErrorStatus) {
            Log.w(TAG, "SDK init error: $status")
            ready = false
            initError = status.name
            readySignal.complete(false)
        }

        override fun onSdkShutDown() {
            // Fires on our own shutdown() and when Garmin Connect's service disconnects.
            // Arm a fresh signal so a later automatic rebind's onSdkReady() can be awaited.
            ready = false
            if (readySignal.isCompleted) {
                readySignal = CompletableDeferred()
            }
        }

        suspend fun acquire(context: Context): Acquired = lock.withLock {
            // Tethered (simulator) builds keep initialise-every-time: the adb strategy
            // re-establishes its socket inside initialize() and reports ready synchronously,
            // and the simulator's adb link only listens during a push. It is a debug-only
            // build flag, so its receiver leak does not matter.
            if (BuildConfig.CIQ_TETHERED) {
                return@withLock initializeLocked(context)
            }

            val current = instance
            if (current != null && ready) {
                return@withLock Acquired.Ready(current)
            }
            if (current != null) {
                // Initialised earlier but the service dropped. Android rebinds on its own
                // when Garmin Connect comes back; wait briefly for that before starting over.
                val back = withTimeoutOrNull(RECONNECT_GRACE_MS) { readySignal.await() }
                if (back == true && ready) {
                    return@withLock Acquired.Ready(current)
                }
                shutdownLocked(context)
            }
            initializeLocked(context)
        }

        /** Drop the current initialisation so the next [acquire] binds from scratch. */
        suspend fun reset(context: Context) {
            if (BuildConfig.CIQ_TETHERED) return
            lock.withLock { shutdownLocked(context) }
        }

        /** Caller must hold [lock]. */
        private suspend fun initializeLocked(context: Context): Acquired {
            val connectType = if (BuildConfig.CIQ_TETHERED) {
                // Talks to the Connect IQ simulator over `adb forward tcp:7381 tcp:7381`
                // instead of to a real watch. Enabled only by a build flag, never at runtime,
                // so a shipped build cannot end up in this mode.
                ConnectIQ.IQConnectType.TETHERED
            } else {
                ConnectIQ.IQConnectType.WIRELESS
            }
            ready = false
            initError = null
            readySignal = CompletableDeferred()

            // getInstance and initialize both construct Handlers, so they must run on a
            // Looper thread. connectToGCM = false: the `true` variant can put up a dialog
            // prompting the user to install Garmin Connect Mobile, and this runs from a
            // background Worker where there is no Activity to host one.
            val connectIQ = withContext(Dispatchers.Main) {
                val ciq = ConnectIQ.getInstance(context, connectType)
                ciq.initialize(context, false, this@Sdk)
                ciq
            }
            instance = connectIQ

            val ok = withTimeoutOrNull(READY_TIMEOUT_MS) { readySignal.await() }
            if (ok == true && ready) {
                return Acquired.Ready(connectIQ)
            }
            val why = initError ?: if (ok == null) "not responding" else "not ready"
            // Leave nothing half-bound behind: the next acquire must start clean.
            shutdownLocked(context)
            return Acquired.Unavailable(why)
        }

        /** Caller must hold [lock]. */
        private suspend fun shutdownLocked(context: Context) {
            val ciq = instance ?: return
            instance = null
            ready = false
            withContext(Dispatchers.Main) {
                try {
                    // Unbinds the service (so the next bind delivers onServiceConnected
                    // again) and unregisters the SDK's broadcast receiver.
                    ciq.shutdown(context)
                } catch (e: Exception) {
                    // InvalidStateException when initialise never completed - nothing bound.
                    Log.i(TAG, "SDK shutdown: ${e.javaClass.simpleName}: ${e.message}")
                }
            }
        }
    }

    // ---- callback bridging -------------------------------------------------------------
    //
    // Each SDK callback can in principle fire more than once. A continuation may only be
    // resumed once, so each wrapper below guards with an AtomicBoolean rather than trusting
    // the SDK to call back exactly once.

    private suspend fun awaitApplicationInfo(connectIQ: ConnectIQ, device: IQDevice, appId: String): IQApp? =
        suspendCancellableCoroutine { cont ->
            val done = AtomicBoolean(false)
            connectIQ.getApplicationInfo(
                appId,
                device,
                object : ConnectIQ.IQApplicationInfoListener {
                    override fun onApplicationInfoReceived(app: IQApp) =
                        cont.resumeOnce(done, app)

                    override fun onApplicationNotInstalled(applicationId: String) {
                        Log.i(TAG, "app $applicationId not installed on ${device.friendlyName}")
                        cont.resumeOnce(done, null)
                    }
                },
            )
        }

    private suspend fun awaitSend(
        connectIQ: ConnectIQ,
        device: IQDevice,
        app: IQApp,
        payload: Map<String, Any>,
    ): PushResult = suspendCancellableCoroutine { cont ->
        val done = AtomicBoolean(false)
        connectIQ.sendMessage(device, app, payload) { _, _, status ->
            if (status == ConnectIQ.IQMessageStatus.SUCCESS) {
                cont.resumeOnce(done, PushResult.Sent(device.friendlyName))
            } else {
                cont.resumeOnce(done, PushResult.Failed(status.name))
            }
        }
    }

    private fun <T> CancellableContinuation<T>.resumeOnce(guard: AtomicBoolean, value: T) {
        if (guard.compareAndSet(false, true) && isActive) {
            resume(value)
        }
    }
}
