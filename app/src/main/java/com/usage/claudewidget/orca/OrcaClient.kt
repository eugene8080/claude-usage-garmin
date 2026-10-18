package com.usage.claudewidget.orca

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONObject
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit

/** How one request to desktop Orca ended. */
sealed interface OrcaCallResult {
    /** The RPC's `result` (a JSONObject, JSONArray, primitive or JSONObject.NULL). */
    data class Ok(val result: Any?) : OrcaCallResult

    /** Orca answered with `{ok:false, error:{code, message}}`. */
    data class RpcError(val code: String, val message: String) : OrcaCallResult

    /** Orca refused this device: revoked, re-keyed, or a code from another computer. Pair again. */
    data class Unauthorized(val reason: String) : OrcaCallResult

    /** Desktop Orca could not be reached at all: off, asleep, wrong address, or no Tailscale. */
    data class Unreachable(val reason: String) : OrcaCallResult

    /** Reached Orca, but the conversation broke off (timeout, bad frame, unexpected close). */
    data class Failed(val reason: String) : OrcaCallResult
}

/**
 * One short-lived, end-to-end encrypted RPC call to desktop Orca over its mobile WebSocket
 * (port 6768) - the same channel the Orca phone app uses, opened for one request and closed.
 *
 * Why a fresh socket per refresh instead of a long-lived connection like the Orca app keeps:
 * the widget refreshes every 15 minutes from a background job that Android (and ColorOS's
 * freezer) may stop at any moment. A socket per call has no reconnect state to go stale,
 * and the handshake is three small messages.
 */
class OrcaClient(private val http: OkHttpClient = defaultHttp) {

    /**
     * Opens the socket, runs the v2 handshake pinned to [pairing]'s desktop key,
     * authenticates with its device token, sends `{id, deviceToken, method, params}` and
     * waits for the response with that id. Never throws for network or protocol failures;
     * those come back as an [OrcaCallResult].
     */
    suspend fun call(
        pairing: OrcaPairing,
        method: String,
        params: JSONObject? = null,
        responseTimeoutMs: Long = RESPONSE_TIMEOUT_MS,
    ): OrcaCallResult = withContext(Dispatchers.IO) {
        val events = Channel<Event>(Channel.UNLIMITED)
        val socket = try {
            http.newWebSocket(Request.Builder().url(pairing.endpoint).build(), EventForwarder(events))
        } catch (e: IllegalArgumentException) {
            // OkHttp rejects a URL it cannot parse before any network I/O.
            return@withContext OrcaCallResult.Unreachable("invalid address ${pairing.endpoint}")
        }
        try {
            converse(socket, events, pairing, method, params, responseTimeoutMs)
        } finally {
            // close() starts a graceful close; cancel() then frees the socket at once.
            // A finished call needs neither the close handshake nor the remaining frames.
            socket.close(NORMAL_CLOSURE, null)
            socket.cancel()
            events.close()
        }
    }

    private suspend fun converse(
        socket: WebSocket,
        events: Channel<Event>,
        pairing: OrcaPairing,
        method: String,
        params: JSONObject?,
        responseTimeoutMs: Long,
    ): OrcaCallResult {
        // 1. TCP + WebSocket upgrade.
        when (val opened = withTimeoutOrNull(CONNECT_TIMEOUT_MS) { events.receive() }) {
            Event.Open -> Unit
            is Event.Failure -> return OrcaCallResult.Unreachable(describeFailure(opened, pairing.endpoint))
            is Event.Closed -> return OrcaCallResult.Unreachable("Orca closed the connection (${opened.code})")
            null -> return OrcaCallResult.Unreachable(
                "no answer from ${pairing.endpoint} within ${CONNECT_TIMEOUT_MS / 1000} s",
            )
            else -> return OrcaCallResult.Failed("unexpected first event")
        }

        // 2. Plaintext hello -> plaintext ready.
        val session = OrcaE2eeSession.create(pairing.publicKey)
        if (!socket.send(session.helloJson)) return OrcaCallResult.Failed("could not send the hello")
        val ready = when (val event = withTimeoutOrNull(HANDSHAKE_TIMEOUT_MS) { events.receive() }) {
            is Event.Text -> event.text
            // A host older than E2EE v2 refuses the v2 hello with 4001 before any ready.
            is Event.Closed -> return OrcaCallResult.Failed(
                if (event.code == UNAUTHORIZED_CLOSE) "Orca refused the handshake - update desktop Orca"
                else "Orca closed the connection during the handshake (${event.code})",
            )
            is Event.Failure -> return OrcaCallResult.Failed("connection lost during the handshake")
            null -> return OrcaCallResult.Failed("no handshake reply within ${HANDSHAKE_TIMEOUT_MS / 1000} s")
            else -> return OrcaCallResult.Failed("unexpected handshake reply")
        }
        when (session.acceptReady(ready)) {
            OrcaE2eeSession.ReadyResult.ACCEPTED -> Unit
            OrcaE2eeSession.ReadyResult.KEY_MISMATCH -> return OrcaCallResult.Unauthorized(
                "this computer's Orca key does not match the pairing - pair again",
            )
            OrcaE2eeSession.ReadyResult.INVALID -> return OrcaCallResult.Failed("invalid handshake reply")
        }

        // 3. Sealed device-token auth -> sealed `e2ee_authenticated`.
        if (!socket.send(session.sealText(session.authJson(pairing.deviceToken)))) {
            return OrcaCallResult.Failed("could not send the authentication")
        }
        when (val event = withTimeoutOrNull(HANDSHAKE_TIMEOUT_MS) { events.receive() }) {
            is Event.Text -> {
                val plaintext = session.openText(event.text)
                    ?: return OrcaCallResult.Failed("could not decrypt the authentication reply")
                if (!session.isAuthenticatedReply(plaintext)) {
                    return if (messageType(plaintext) == "e2ee_error") {
                        OrcaCallResult.Unauthorized("Orca refused this device - it may have been revoked")
                    } else {
                        OrcaCallResult.Failed("unexpected authentication reply")
                    }
                }
            }
            // Orca closes with 4001 when the token is unknown or revoked.
            is Event.Closed -> return if (event.code == UNAUTHORIZED_CLOSE) {
                OrcaCallResult.Unauthorized("Orca refused this device - it may have been revoked")
            } else {
                OrcaCallResult.Failed("Orca closed the connection during authentication (${event.code})")
            }
            is Event.Failure -> return OrcaCallResult.Failed("connection lost during authentication")
            null -> return OrcaCallResult.Failed("no authentication reply within ${HANDSHAKE_TIMEOUT_MS / 1000} s")
            else -> return OrcaCallResult.Failed("unexpected authentication reply")
        }

        // 4. The request itself. The device token rides inside every request too (Orca's wire format).
        val id = "widget-${System.currentTimeMillis()}"
        val request = JSONObject()
            .put("id", id)
            .put("deviceToken", pairing.deviceToken)
            .put("method", method)
        if (params != null) request.put("params", params)
        if (!socket.send(session.sealText(request.toString()))) {
            return OrcaCallResult.Failed("could not send the request")
        }

        val deadline = System.currentTimeMillis() + responseTimeoutMs
        while (true) {
            val remaining = deadline - System.currentTimeMillis()
            val event = if (remaining > 0) withTimeoutOrNull(remaining) { events.receive() } else null
            when (event) {
                is Event.Text -> {
                    val plaintext = session.openText(event.text)
                        ?: return OrcaCallResult.Failed("could not decrypt Orca's reply")
                    val response = runCatching { JSONObject(plaintext) }.getOrNull() ?: continue
                    // Anything not answering our id (a pushed event) is not for us.
                    if (response.optString("id") != id) continue
                    return toResult(response)
                }
                // Keep the shared inbound counter in step; the widget has no use for streams.
                is Event.Binary -> session.openBinary(event.bytes)
                is Event.Closed -> return OrcaCallResult.Failed("Orca closed the connection before answering (${event.code})")
                is Event.Failure -> return OrcaCallResult.Failed("connection lost before Orca answered")
                null -> return OrcaCallResult.Failed("Orca did not answer within ${responseTimeoutMs / 1000} s")
                Event.Open -> Unit
            }
        }
    }

    private fun toResult(response: JSONObject): OrcaCallResult {
        if (response.optBoolean("ok", false)) {
            return OrcaCallResult.Ok(response.opt("result"))
        }
        val error = response.optJSONObject("error")
        val code = error?.optString("code").orEmpty().ifEmpty { "unknown" }
        val message = error?.optString("message").orEmpty()
        return if (code == "unauthorized") {
            OrcaCallResult.Unauthorized("Orca refused this device - it may have been revoked")
        } else {
            OrcaCallResult.RpcError(code, message)
        }
    }

    private fun messageType(plaintext: String): String? =
        runCatching { JSONObject(plaintext).optString("type") }.getOrNull()

    /** A short, actionable reason for a failed connect; the exception's own text goes to logcat. */
    private fun describeFailure(failure: Event.Failure, endpoint: String): String {
        Log.i(TAG, "connect to $endpoint failed", failure.error)
        return when (val error = failure.error) {
            is UnknownHostException -> "unknown host in $endpoint"
            is ConnectException, is NoRouteToHostException ->
                "can't reach $endpoint - is the computer on, Orca running and Tailscale connected?"
            is SocketTimeoutException -> "no answer from $endpoint (timed out)"
            else -> when {
                failure.httpCode != null -> "$endpoint answered HTTP ${failure.httpCode}, not Orca's WebSocket"
                error.message?.contains("CLEARTEXT", ignoreCase = true) == true ->
                    "the phone blocked the unencrypted ws:// link"
                else -> "connection to $endpoint failed (${error.javaClass.simpleName})"
            }
        }
    }

    private sealed interface Event {
        data object Open : Event
        data class Text(val text: String) : Event
        class Binary(val bytes: ByteArray) : Event
        data class Closed(val code: Int, val reason: String) : Event
        class Failure(val error: Throwable, val httpCode: Int?) : Event
    }

    /** OkHttp calls back on its own threads; everything goes into the channel the call reads. */
    private class EventForwarder(private val events: Channel<Event>) : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            events.trySend(Event.Open)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            events.trySend(Event.Text(text))
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            events.trySend(Event.Binary(bytes.toByteArray()))
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            events.trySend(Event.Closed(code, reason))
            webSocket.close(code, null)
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            events.trySend(Event.Failure(t, response?.code))
        }
    }

    companion object {
        private const val TAG = "OrcaClient"

        /** Same as the Orca app's own connect timeout. */
        const val CONNECT_TIMEOUT_MS = 12_000L

        /**
         * Per handshake step. The Orca app allows 5 s on a LAN; a Tailscale path relayed
         * through a DERP server can take longer, and a slow handshake costs nothing here.
         */
        const val HANDSHAKE_TIMEOUT_MS = 10_000L

        /**
         * `accounts.list` with `refreshUsage` makes desktop Orca poll every provider before
         * it answers (Codex may start its CLI to ask), so allow far longer than a plain read.
         */
        const val RESPONSE_TIMEOUT_MS = 45_000L

        private const val NORMAL_CLOSURE = 1000
        private const val UNAUTHORIZED_CLOSE = 4001

        private val defaultHttp: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(CONNECT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                // No read timeout on the socket: the call's own deadlines bound every wait.
                .readTimeout(0, TimeUnit.MILLISECONDS)
                .build()
        }
    }
}
