package com.usage.claudewidget.orca

import org.json.JSONObject
import java.net.URI
import java.util.Base64

/**
 * What the widget keeps from a desktop Orca pairing code: where to dial, the device token
 * that authenticates this phone, and the desktop's X25519 public key that every handshake
 * is pinned to.
 */
data class OrcaPairing(
    /** Normalized `ws://host:port` (or `wss://`) of desktop Orca's mobile server. */
    val endpoint: String,
    val deviceToken: String,
    val publicKeyB64: String,
    /** The desktop's id for this paired device, when the code names one (for display). */
    val pairedDeviceId: String?,
) {
    /** The pinned desktop key as bytes; [OrcaPairingCodec.parse] has checked it is 32 bytes. */
    val publicKey: ByteArray get() = Base64.getDecoder().decode(publicKeyB64)
}

/**
 * Reads the pairing code desktop Orca shows under Settings > Mobile - Orca's
 * `src/shared/pairing.ts` and `mobile-relay-pairing-offer.ts`.
 *
 * The code is base64url JSON, either bare or inside `orca://pair?code=<b64url>` (the QR's
 * URL; older builds used a `#<b64url>` fragment). Version 2 carries `{v, endpoint,
 * deviceToken, publicKeyB64, pairedDeviceId?, scope?, relay?, hostDescriptor?}`. The widget
 * only dials the direct `endpoint` (LAN or Tailscale); the `relay` block is ignored.
 */
object OrcaPairingCodec {
    const val DEFAULT_PORT = 6768
    private const val OFFER_VERSION = 2

    // Orca's own limits (mobile-pairing-protocol-limits.ts), so a pasted blob is bounded.
    private const val CODE_MAX_CHARACTERS = 128 * 1024
    private const val INPUT_MAX_CHARACTERS = CODE_MAX_CHARACTERS + 1024
    private const val ENDPOINT_MAX_CHARACTERS = 16 * 1024
    private const val DEVICE_TOKEN_MAX_CHARACTERS = 64 * 1024

    private val BASE64URL = Regex("^[A-Za-z0-9+/_-]+={0,2}$")

    sealed interface ParseResult {
        data class Ok(val pairing: OrcaPairing) : ParseResult
        data class Invalid(val reason: String) : ParseResult
    }

    /** Parses an `orca://pair` URL or a bare code, as copied from desktop Orca or read from its QR. */
    fun parse(input: String): ParseResult {
        if (input.length > INPUT_MAX_CHARACTERS) return ParseResult.Invalid("The pairing code is too long.")
        val trimmed = input.trim()
        if (trimmed.isEmpty()) return ParseResult.Invalid("Paste or scan a pairing code first.")
        val code = if (trimmed.startsWith("orca://", ignoreCase = true)) {
            codeFromUrl(trimmed) ?: return ParseResult.Invalid(
                "That link is not an Orca pairing link (it must start with orca://pair).",
            )
        } else {
            trimmed
        }
        if (code.length > CODE_MAX_CHARACTERS || !BASE64URL.matches(code)) {
            return ParseResult.Invalid("That is not an Orca pairing code.")
        }
        val json = runCatching {
            val base64 = code.replace('-', '+').replace('_', '/')
            // The strict decoder (not the MIME one, which skips bad characters silently).
            String(Base64.getDecoder().decode(padBase64(base64)), Charsets.UTF_8)
        }.getOrNull() ?: return ParseResult.Invalid("That is not an Orca pairing code.")
        val offer = runCatching { JSONObject(json) }.getOrNull()
            ?: return ParseResult.Invalid("That is not an Orca pairing code.")
        return fromOffer(offer)
    }

    private fun fromOffer(offer: JSONObject): ParseResult {
        val version = offer.opt("v")
        if (version !is Number || version.toInt() != OFFER_VERSION) {
            return ParseResult.Invalid(
                "This pairing code is version ${version ?: "?"}; this app reads version $OFFER_VERSION. " +
                    "Update Orca or this app.",
            )
        }
        val rawEndpoint = offer.optString("endpoint", "")
        val deviceToken = offer.optString("deviceToken", "")
        val publicKeyB64 = offer.optString("publicKeyB64", "")
        if (rawEndpoint.isEmpty() || rawEndpoint.length > ENDPOINT_MAX_CHARACTERS) {
            return ParseResult.Invalid("The pairing code has no address.")
        }
        if (deviceToken.isEmpty() || deviceToken.length > DEVICE_TOKEN_MAX_CHARACTERS) {
            return ParseResult.Invalid("The pairing code has no device token.")
        }
        // Orca decodes this key leniently (non-relay offers allow base64 aliases), so accept
        // any standard-base64 spelling that decodes to 32 bytes and keep the canonical form.
        val publicKey = runCatching { Base64.getDecoder().decode(publicKeyB64) }.getOrNull()
        if (publicKey == null || publicKey.size != 32) {
            return ParseResult.Invalid("The pairing code has no valid desktop key.")
        }
        // An endpoint we cannot normalize is kept as-is; the address field lets the user fix it.
        val endpoint = normalizeEndpoint(rawEndpoint) ?: rawEndpoint
        return ParseResult.Ok(
            OrcaPairing(
                endpoint = endpoint,
                deviceToken = deviceToken,
                publicKeyB64 = Base64.getEncoder().encodeToString(publicKey),
                pairedDeviceId = offer.optString("pairedDeviceId", "").ifBlank { null },
            ),
        )
    }

    /**
     * `orca://pair?code=...` (current) or `orca://pair#...` (older). Only the `pair` host
     * may carry credentials, as in Orca's `extractPairingCodeFromUrl`.
     */
    private fun codeFromUrl(url: String): String? {
        val uri = runCatching { URI(url) }.getOrNull() ?: return null
        if (!uri.scheme.equals("orca", ignoreCase = true) || uri.host != "pair") return null
        val path = uri.rawPath.orEmpty()
        if (path.isNotEmpty() && path != "/") return null
        val fromQuery = uri.rawQuery.orEmpty().split('&')
            .map { it.split('=', limit = 2) }
            .firstOrNull { it.size == 2 && it[0] == "code" }
            ?.let { java.net.URLDecoder.decode(it[1], "UTF-8") }
        return fromQuery?.ifEmpty { null } ?: uri.rawFragment?.ifEmpty { null }
    }

    private fun padBase64(value: String): String = when (value.length % 4) {
        2 -> "$value=="
        3 -> "$value="
        else -> value
    }

    /**
     * Turns what a person might type - `100.115.235.106`, `pc.tailnet.ts.net:6768`,
     * `ws://192.168.1.10:6768`, `[fd7a::1]` - into a dialable `ws://host:port`.
     * Null when it cannot be a WebSocket address.
     */
    fun normalizeEndpoint(input: String): String? {
        val trimmed = input.trim()
        if (trimmed.isEmpty() || trimmed.any { it.isWhitespace() }) return null
        val withScheme = if (trimmed.contains("://")) trimmed else "ws://$trimmed"
        val uri = runCatching { URI(withScheme) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase() ?: return null
        if (scheme != "ws" && scheme != "wss") return null
        val host = uri.host?.ifEmpty { null } ?: return null
        if (uri.rawPath.orEmpty().let { it.isNotEmpty() && it != "/" }) return null
        if (uri.rawQuery != null || uri.rawFragment != null || uri.rawUserInfo != null) return null
        val port = if (uri.port == -1) DEFAULT_PORT else uri.port
        if (port !in 1..65535) return null
        // URI.host keeps the brackets of an IPv6 literal, which is what a URL needs.
        return "$scheme://$host:$port"
    }

    /**
     * True for an address that points at the phone itself. Desktop Orca falls back to
     * loopback when it has no LAN/Tailscale address to put in a Relay-only code; dialing it
     * would reach this phone, not the computer.
     */
    fun isLoopback(endpoint: String): Boolean {
        val host = runCatching { URI(endpoint).host }.getOrNull()?.lowercase()?.trim('[', ']') ?: return false
        return host == "localhost" || host == "::1" || host.startsWith("127.")
    }
}
