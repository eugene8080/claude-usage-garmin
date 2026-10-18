package com.usage.claudewidget.orca

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class OrcaPairingCodecTest {

    private val key = Base64.getEncoder().encodeToString(ByteArray(32) { 7 })

    private fun offer(
        endpoint: String = "ws://100.115.235.106:6768",
        version: Int = 2,
        publicKey: String = key,
    ) = JSONObject()
        .put("v", version)
        .put("endpoint", endpoint)
        .put("deviceToken", "tok_abc123")
        .put("publicKeyB64", publicKey)
        .put("pairedDeviceId", "dev-1")
        .put("scope", "mobile")

    /** Orca's encodePairingOffer: base64url without padding. */
    private fun code(json: JSONObject): String = Base64.getUrlEncoder().withoutPadding()
        .encodeToString(json.toString().toByteArray())

    private fun ok(input: String): OrcaPairing {
        val result = OrcaPairingCodec.parse(input)
        assertTrue("expected Ok, got $result", result is OrcaPairingCodec.ParseResult.Ok)
        return (result as OrcaPairingCodec.ParseResult.Ok).pairing
    }

    @Test fun `reads the orca pair URL from the QR`() {
        val pairing = ok("orca://pair?code=${code(offer())}")
        assertEquals("ws://100.115.235.106:6768", pairing.endpoint)
        assertEquals("tok_abc123", pairing.deviceToken)
        assertEquals(key, pairing.publicKeyB64)
        assertEquals("dev-1", pairing.pairedDeviceId)
        assertEquals(32, pairing.publicKey.size)
    }

    @Test fun `reads a bare code, a fragment URL, and surrounding whitespace`() {
        assertEquals("tok_abc123", ok(code(offer())).deviceToken)
        assertEquals("tok_abc123", ok("orca://pair#${code(offer())}").deviceToken)
        assertEquals("tok_abc123", ok("  orca://pair?code=${code(offer())}\n").deviceToken)
    }

    @Test fun `ignores a relay block and keeps the direct endpoint`() {
        val withRelay = offer().put("relay", JSONObject().put("v", 1).put("directorUrl", "https://relay.example"))
        assertEquals("ws://100.115.235.106:6768", ok(code(withRelay)).endpoint)
    }

    @Test fun `normalizes a bare endpoint inside the code`() {
        assertEquals("ws://192.168.50.100:6768", ok(code(offer(endpoint = "192.168.50.100"))).endpoint)
    }

    @Test fun `refuses other links, versions and keys`() {
        assertTrue(OrcaPairingCodec.parse("orca://pairing?code=${code(offer())}") is OrcaPairingCodec.ParseResult.Invalid)
        assertTrue(OrcaPairingCodec.parse("orca://pair/x?code=${code(offer())}") is OrcaPairingCodec.ParseResult.Invalid)
        assertTrue(OrcaPairingCodec.parse(code(offer(version = 1))) is OrcaPairingCodec.ParseResult.Invalid)
        assertTrue(OrcaPairingCodec.parse(code(offer(publicKey = "AAAA"))) is OrcaPairingCodec.ParseResult.Invalid)
        assertTrue(OrcaPairingCodec.parse("hello world") is OrcaPairingCodec.ParseResult.Invalid)
        assertTrue(OrcaPairingCodec.parse("") is OrcaPairingCodec.ParseResult.Invalid)
        assertTrue(OrcaPairingCodec.parse(code(JSONObject().put("v", 2))) is OrcaPairingCodec.ParseResult.Invalid)
    }

    @Test fun `normalizes typed addresses`() {
        assertEquals("ws://100.64.0.5:6768", OrcaPairingCodec.normalizeEndpoint("100.64.0.5"))
        assertEquals("ws://100.64.0.5:7000", OrcaPairingCodec.normalizeEndpoint("100.64.0.5:7000"))
        assertEquals("ws://pc.tail1234.ts.net:6768", OrcaPairingCodec.normalizeEndpoint("pc.tail1234.ts.net"))
        assertEquals("wss://orca.example:443", OrcaPairingCodec.normalizeEndpoint("wss://orca.example:443"))
        assertEquals("ws://[fd7a:115c::1]:6768", OrcaPairingCodec.normalizeEndpoint("[fd7a:115c::1]"))
        assertEquals("ws://10.0.0.2:6768", OrcaPairingCodec.normalizeEndpoint(" ws://10.0.0.2:6768/ "))
        assertNull(OrcaPairingCodec.normalizeEndpoint("http://10.0.0.2:6768"))
        assertNull(OrcaPairingCodec.normalizeEndpoint("ws://10.0.0.2:6768/path"))
        assertNull(OrcaPairingCodec.normalizeEndpoint("two words"))
        assertNull(OrcaPairingCodec.normalizeEndpoint(""))
    }

    @Test fun `recognizes loopback addresses`() {
        assertTrue(OrcaPairingCodec.isLoopback("ws://127.0.0.1:6768"))
        assertTrue(OrcaPairingCodec.isLoopback("ws://localhost:6768"))
        assertTrue(OrcaPairingCodec.isLoopback("ws://[::1]:6768"))
        assertFalse(OrcaPairingCodec.isLoopback("ws://100.115.235.106:6768"))
    }
}
