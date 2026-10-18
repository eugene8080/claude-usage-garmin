package com.usage.claudewidget.orca

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/**
 * The Kotlin port against values produced by Orca's OWN TypeScript (tweetnacl +
 * @noble/hashes running src/shared/paired-e2ee-v2-client-session.ts and friends, unchanged).
 * How the resource file was made is in docs/orca-protocol.md. If any of these fail, the
 * widget cannot talk to desktop Orca - do not "fix" the expected values.
 */
class OrcaE2eeVectorsTest {

    private val v: JSONObject = JSONObject(
        checkNotNull(javaClass.getResourceAsStream("/orca/e2ee_v2_vectors.json")).reader().readText(),
    )

    private fun hex(s: String): ByteArray = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun b64(s: String): ByteArray = Base64.getDecoder().decode(s)
    private fun bytes(fill: Int) = ByteArray(32) { fill.toByte() }

    private val clientKeyPair = NaCl.keyPairFromSecretKey(bytes(0x11))
    private val desktopKeyPair = NaCl.keyPairFromSecretKey(bytes(0x22))

    private fun newSession() = OrcaE2eeSession.create(
        desktopPublicKey = desktopKeyPair.publicKey,
        clientKeyPair = clientKeyPair,
        clientNonce = bytes(0x33),
    )

    @Test fun `X25519 public keys match tweetnacl`() {
        assertArrayEquals(b64(v.getString("clientPublicKeyB64")), clientKeyPair.publicKey)
        assertArrayEquals(b64(v.getString("desktopPublicKeyB64")), desktopKeyPair.publicKey)
    }

    @Test fun `box before matches tweetnacl from both sides`() {
        val expected = hex(v.getString("boxBeforeHex"))
        assertArrayEquals(expected, NaCl.boxBefore(desktopKeyPair.publicKey, clientKeyPair.secretKey))
        assertArrayEquals(expected, NaCl.boxBefore(clientKeyPair.publicKey, desktopKeyPair.secretKey))
    }

    @Test fun `secretbox matches tweetnacl and opens`() {
        val key = hex(v.getString("secretboxKeyHex"))
        val nonce = hex(v.getString("secretboxNonceHex"))
        val message = v.getString("secretboxMessage").toByteArray()
        val box = NaCl.secretbox(message, nonce, key)
        assertArrayEquals(hex(v.getString("secretboxHex")), box)
        assertArrayEquals(message, NaCl.secretboxOpen(box, nonce, key))
    }

    @Test fun `secretbox refuses a tampered box`() {
        val key = hex(v.getString("secretboxKeyHex"))
        val nonce = hex(v.getString("secretboxNonceHex"))
        val box = hex(v.getString("secretboxHex"))
        for (index in box.indices) {
            val tampered = box.copyOf().also { it[index] = (it[index].toInt() xor 1).toByte() }
            assertNull("byte $index flipped", NaCl.secretboxOpen(tampered, nonce, key))
        }
        assertNull(NaCl.secretboxOpen(ByteArray(15), nonce, key))
    }

    /** Orca's own golden vector, MOBILE_E2EE_V2_VECTOR in src/shared/mobile-e2ee-v2-fixtures.ts (relay context). */
    @Test fun `transcript and key schedule match Orca's fixture vector`() {
        val transcript = OrcaE2eeSession.encodeTranscript(
            clientPublicKey = bytes(1),
            clientNonce = bytes(2),
            desktopPublicKey = bytes(3),
            desktopNonce = bytes(4),
            transport = "relay",
            relayHostId = "AbCdEf0123_-xyZ9",
        )
        assertEquals(1347, transcript.size)
        val schedule = OrcaE2eeSession.deriveKeySchedule(bytes(5), transcript, bytes(2), bytes(4))
        assertArrayEquals(hex("ca6385f8bbf64a223fdd59587bfb67e2373891ce9e6d85ab41df8b7a20a168e3"), schedule.transcriptHash)
        assertArrayEquals(hex("df17ff534df77fd3a30999f4e6200c8fcedefbb15d369301ca62c3cdfea9559a"), schedule.mobileToDesktopKey)
        assertArrayEquals(hex("71365fcf8212a6d63caf909ee28de3c8f689682ef298a374136055e0ab1cde4a"), schedule.desktopToMobileKey)
        assertArrayEquals(hex("339ae1f2bdff63481857d2813c2f19dd1f5aa4824705d5e5daeb25dae7b9196e"), schedule.sessionId)
    }

    @Test fun `direct transcript and keys match the session vectors`() {
        val transcript = OrcaE2eeSession.encodeTranscript(
            clientPublicKey = clientKeyPair.publicKey,
            clientNonce = bytes(0x33),
            desktopPublicKey = desktopKeyPair.publicKey,
            desktopNonce = bytes(0x44),
            transport = "direct",
            relayHostId = null,
        )
        assertEquals(v.getInt("transcriptLength"), transcript.size)
        assertArrayEquals(hex(v.getString("transcriptHex")), transcript)
        val schedule = OrcaE2eeSession.deriveKeySchedule(
            NaCl.boxBefore(desktopKeyPair.publicKey, clientKeyPair.secretKey), transcript, bytes(0x33), bytes(0x44),
        )
        assertArrayEquals(hex(v.getString("mobileToDesktopKeyHex")), schedule.mobileToDesktopKey)
        assertArrayEquals(hex(v.getString("desktopToMobileKeyHex")), schedule.desktopToMobileKey)
        assertArrayEquals(hex(v.getString("sessionIdHex")), schedule.sessionId)
    }

    @Test fun `hello carries the same fields as Orca's`() {
        val ours = JSONObject(newSession().helloJson)
        val theirs = JSONObject(v.getString("helloJson"))
        // Compare as JSON values: key order and "/" escaping differ between JSON libraries.
        assertTrue("hello: $ours vs $theirs", ours.similar(theirs))
    }

    @Test fun `full session reproduces Orca's sealed frames byte for byte`() {
        val session = newSession()
        assertEquals(OrcaE2eeSession.ReadyResult.ACCEPTED, session.acceptReady(v.getString("readyJson")))
        assertEquals(v.getString("transcriptHashB64"), session.transcriptHashB64)

        // v2 frames are deterministic (counter nonces), so the sealed bytes must be identical.
        assertEquals(v.getString("authFrameB64"), session.sealText(v.getString("authPlain")))
        assertEquals(v.getString("requestFrameB64"), session.sealText(v.getString("requestPlain")))

        assertEquals(v.getString("authenticatedPlain"), session.openText(v.getString("authenticatedFrameB64")))
        assertTrue(session.isAuthenticatedReply(v.getString("authenticatedPlain")))
        assertEquals(v.getString("responsePlain"), session.openText(v.getString("responseFrameB64")))
    }

    @Test fun `auth message has exactly Orca's fields`() {
        val session = newSession()
        session.acceptReady(v.getString("readyJson"))
        val auth = JSONObject(session.authJson(v.getString("deviceToken")))
        assertTrue(auth.similar(JSONObject(v.getString("authPlain"))))
    }

    @Test fun `inbound counter only advances on a frame that opens`() {
        val session = newSession()
        session.acceptReady(v.getString("readyJson"))
        // The second frame first: wrong counter, refused, and it must not consume counter 0.
        assertNull(session.openText(v.getString("responseFrameB64")))
        assertEquals(v.getString("authenticatedPlain"), session.openText(v.getString("authenticatedFrameB64")))
        assertEquals(v.getString("responsePlain"), session.openText(v.getString("responseFrameB64")))
        // A replay of an already-opened frame is refused.
        assertNull(session.openText(v.getString("responseFrameB64")))
    }

    @Test fun `ready from another desktop key is a key mismatch`() {
        val session = OrcaE2eeSession.create(
            desktopPublicKey = NaCl.keyPairFromSecretKey(bytes(0x77)).publicKey,
            clientKeyPair = clientKeyPair,
            clientNonce = bytes(0x33),
        )
        assertEquals(OrcaE2eeSession.ReadyResult.KEY_MISMATCH, session.acceptReady(v.getString("readyJson")))
        assertFalse(session.isReady)
    }

    @Test fun `malformed readies are invalid`() {
        val ready = JSONObject(v.getString("readyJson"))
        val variants = listOf(
            JSONObject(ready.toString()).put("clientNonceB64", Base64.getEncoder().encodeToString(bytes(0x34))),
            JSONObject(ready.toString()).put("extra", 1),
            JSONObject(ready.toString()).put("v", 1),
            JSONObject(ready.toString()).put("type", "e2ee_hello"),
            JSONObject(ready.toString()).put("desktopNonceB64", "REREREREREREREREREREREREREREREREREREREREREQ"),
            JSONObject(ready.toString()).also { it.getJSONObject("context").put("transport", "relay") },
            JSONObject(ready.toString()).also { it.getJSONObject("selection").put("framing", 1) },
        )
        variants.forEachIndexed { index, variant ->
            assertEquals("variant $index", OrcaE2eeSession.ReadyResult.INVALID, newSession().acceptReady(variant.toString()))
        }
        assertEquals(OrcaE2eeSession.ReadyResult.INVALID, newSession().acceptReady("{\"type\":\"e2ee_ready\"}"))
        assertEquals(OrcaE2eeSession.ReadyResult.INVALID, newSession().acceptReady("not json"))
    }

    @Test fun `an authenticated reply for another transcript is refused`() {
        val session = newSession()
        session.acceptReady(v.getString("readyJson"))
        val wrongHash = JSONObject(v.getString("authenticatedPlain"))
            .put("transcriptHashB64", Base64.getEncoder().encodeToString(bytes(9)))
        assertFalse(session.isAuthenticatedReply(wrongHash.toString()))
        assertFalse(session.isAuthenticatedReply("{\"type\":\"e2ee_error\"}"))
    }
}
