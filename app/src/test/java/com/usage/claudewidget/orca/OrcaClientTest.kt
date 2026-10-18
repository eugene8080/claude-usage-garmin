package com.usage.claudewidget.orca

import kotlinx.coroutines.runBlocking
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.ServerSocket
import java.util.Base64
import java.util.Collections

/**
 * [OrcaClient] end to end over a real socket, with a MockWebServer playing desktop Orca's
 * side of the v2 handshake (written from Orca's e2ee-channel.ts / DesktopMobileE2EEV2Session
 * behaviour). The crypto itself is pinned to Orca's own output in OrcaE2eeVectorsTest; this
 * covers the conversation: ordering, auth, ignoring unrelated frames, and each failure.
 */
class OrcaClientTest {

    private lateinit var server: MockWebServer
    private val desktopKeys = NaCl.keyPairFromSecretKey(ByteArray(32) { 0x22 })
    private val token = "device-token-123"

    @Before fun setUp() {
        server = MockWebServer()
        server.start()
    }

    @After fun tearDown() {
        server.shutdown()
    }

    private fun pairing(publicKey: ByteArray = desktopKeys.publicKey) = OrcaPairing(
        endpoint = "ws://${server.hostName}:${server.port}",
        deviceToken = token,
        publicKeyB64 = Base64.getEncoder().encodeToString(publicKey),
        pairedDeviceId = null,
    )

    private fun serve(desktop: FakeDesktop): FakeDesktop {
        server.enqueue(MockResponse().withWebSocketUpgrade(desktop))
        return desktop
    }

    @Test fun `handshake, auth and one request`() = runBlocking {
        val desktop = serve(FakeDesktop(desktopKeys, token) { _, _ ->
            JSONObject().put("ok", true).put("result", JSONObject().put("rateLimits", JSONObject()))
        })
        val result = OrcaClient().call(pairing(), "accounts.list", JSONObject().put("refreshUsage", true))
        assertTrue("got $result", result is OrcaCallResult.Ok)
        val body = (result as OrcaCallResult.Ok).result as JSONObject
        assertTrue(body.has("rateLimits"))
        val request = desktop.requests.single()
        assertEquals("accounts.list", request.getString("method"))
        assertEquals(token, request.getString("deviceToken"))
        assertEquals(true, request.getJSONObject("params").getBoolean("refreshUsage"))
    }

    @Test fun `an unknown device token is unauthorized`() = runBlocking {
        serve(FakeDesktop(desktopKeys, acceptedToken = "someone-else") { _, _ -> JSONObject().put("ok", true) })
        val result = OrcaClient().call(pairing(), "accounts.list")
        assertTrue("got $result", result is OrcaCallResult.Unauthorized)
    }

    @Test fun `a desktop whose key is not the paired one is unauthorized`() = runBlocking {
        serve(FakeDesktop(NaCl.keyPairFromSecretKey(ByteArray(32) { 0x55 }), token) { _, _ -> JSONObject().put("ok", true) })
        val result = OrcaClient().call(pairing(), "accounts.list")
        assertTrue("got $result", result is OrcaCallResult.Unauthorized)
    }

    @Test fun `an RPC error comes back with its code`() = runBlocking {
        serve(FakeDesktop(desktopKeys, token) { _, _ ->
            JSONObject().put("ok", false).put("error", JSONObject().put("code", "method_unavailable").put("message", "nope"))
        })
        val result = OrcaClient().call(pairing(), "accounts.list")
        assertEquals(OrcaCallResult.RpcError("method_unavailable", "nope"), result)
    }

    @Test fun `no answer to the request is a failure, not a hang`() = runBlocking {
        serve(FakeDesktop(desktopKeys, token, answer = false) { _, _ -> JSONObject() })
        val result = OrcaClient().call(pairing(), "accounts.list", responseTimeoutMs = 500)
        assertTrue("got $result", result is OrcaCallResult.Failed)
    }

    @Test fun `a closed port is unreachable`() = runBlocking {
        val port = ServerSocket(0).use { it.localPort }
        val result = OrcaClient().call(pairing().copy(endpoint = "ws://127.0.0.1:$port"), "accounts.list")
        assertTrue("got $result", result is OrcaCallResult.Unreachable)
    }

    /** Desktop Orca's side of one socket, as far as the widget exercises it. */
    private class FakeDesktop(
        private val keys: NaCl.KeyPair,
        private val acceptedToken: String,
        private val answer: Boolean = true,
        private val respond: (method: String, params: JSONObject?) -> JSONObject,
    ) : WebSocketListener() {
        val requests: MutableList<JSONObject> = Collections.synchronizedList(mutableListOf())
        private var schedule: OrcaE2eeSession.KeySchedule? = null
        private var authenticated = false
        private var inbound = 0L
        private var outbound = 0L

        override fun onMessage(webSocket: WebSocket, text: String) {
            val keys = schedule
            if (keys == null) {
                ready(webSocket, JSONObject(text))
                return
            }
            val plaintext = OrcaE2eeSession.openFrame(
                Base64.getDecoder().decode(text), keys.mobileToDesktopKey, keys.sessionId,
                OrcaE2eeSession.DIRECTION_MOBILE_TO_DESKTOP, OrcaE2eeSession.KIND_TEXT, inbound++,
            )
            if (plaintext == null) {
                webSocket.close(4001, "Unauthorized")
                return
            }
            val message = JSONObject(String(plaintext))
            if (!authenticated) {
                val transcriptHash = Base64.getEncoder().encodeToString(keys.transcriptHash)
                if (message.optString("deviceToken") == acceptedToken &&
                    message.optString("transcriptHashB64") == transcriptHash
                ) {
                    authenticated = true
                    send(webSocket, JSONObject().put("type", "e2ee_authenticated").put("v", 2).put("transcriptHashB64", transcriptHash))
                } else {
                    // Orca: a sealed e2ee_error, then close 4001.
                    send(webSocket, JSONObject().put("type", "e2ee_error").put("error", JSONObject().put("code", "unauthorized")))
                    webSocket.close(4001, "Unauthorized")
                }
                return
            }
            requests += message
            if (!answer) return
            // An unrelated frame first: the client must skip anything not answering its id.
            send(webSocket, JSONObject().put("id", "someone-elses-request").put("ok", true).put("result", 1))
            send(webSocket, respond(message.getString("method"), message.optJSONObject("params")).put("id", message.getString("id")))
        }

        private fun ready(webSocket: WebSocket, hello: JSONObject) {
            val clientPublicKey = Base64.getDecoder().decode(hello.getString("clientPublicKeyB64"))
            val clientNonce = Base64.getDecoder().decode(hello.getString("clientNonceB64"))
            val desktopNonce = NaCl.randomBytes(32)
            val transcript = OrcaE2eeSession.encodeTranscript(
                clientPublicKey, clientNonce, keys.publicKey, desktopNonce, "direct", null,
            )
            schedule = OrcaE2eeSession.deriveKeySchedule(
                NaCl.boxBefore(clientPublicKey, keys.secretKey), transcript, clientNonce, desktopNonce,
            )
            webSocket.send(
                JSONObject()
                    .put("type", "e2ee_ready")
                    .put("v", 2)
                    .put("desktopPublicKeyB64", Base64.getEncoder().encodeToString(keys.publicKey))
                    .put("clientNonceB64", hello.getString("clientNonceB64"))
                    .put("desktopNonceB64", Base64.getEncoder().encodeToString(desktopNonce))
                    .put("selection", JSONObject().put("framing", 2).put("payloadKinds", JSONArray().put("text").put("binary")))
                    .put("context", hello.getJSONObject("context"))
                    .toString(),
            )
        }

        private fun send(webSocket: WebSocket, message: JSONObject) {
            val keys = checkNotNull(schedule)
            val frame = OrcaE2eeSession.sealFrame(
                message.toString().toByteArray(), keys.desktopToMobileKey, keys.sessionId,
                OrcaE2eeSession.DIRECTION_DESKTOP_TO_MOBILE, OrcaE2eeSession.KIND_TEXT, outbound++,
            )
            webSocket.send(Base64.getEncoder().encodeToString(frame))
        }

        override fun onOpen(webSocket: WebSocket, response: Response) = Unit
    }
}
