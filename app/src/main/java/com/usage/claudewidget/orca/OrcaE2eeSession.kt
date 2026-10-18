package com.usage.claudewidget.orca

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * The phone side of Orca's mobile E2EE v2 channel - a port of Orca's
 * `src/shared/paired-e2ee-v2-client-session.ts`, `mobile-e2ee-v2-contract.ts`,
 * `paired-e2ee-v2-key-schedule.ts` and `mobile-e2ee-v2-framing.ts` (stablyai/orca,
 * ported 2026-10-18 against desktop Orca 1.4.224; see docs/orca-protocol.md).
 *
 * The handshake, per WebSocket:
 *  1. phone -> desktop, plaintext JSON: [helloJson] (our ephemeral X25519 key + a nonce).
 *  2. desktop -> phone, plaintext JSON: `e2ee_ready` (desktop key + its nonce). [acceptReady]
 *     checks it field by field and pins the desktop key to the one in the pairing code -
 *     that pin is what makes a man in the middle impossible on a plain `ws://` link.
 *  3. Both sides derive the same keys: HKDF-SHA256 over NaCl `box.before(desktop, ours)`,
 *     salted with both nonces and bound to a hash of the whole handshake transcript.
 *  4. Every later message is a sealed frame ([sealText] / [openText]) whose nonce and
 *     header carry a per-direction counter, so a replayed, reordered or reflected frame
 *     fails to open.
 *
 * One instance serves exactly one socket: the counters and keys must never be reused.
 */
internal class OrcaE2eeSession private constructor(
    private val clientSecretKey: ByteArray,
    private val clientPublicKey: ByteArray,
    private val clientNonce: ByteArray,
    private val pinnedDesktopPublicKey: ByteArray,
) {
    private var schedule: KeySchedule? = null
    // Separate counters per direction; text and binary frames share one, as in Orca.
    private var outboundCounter = 0L
    private var inboundCounter = 0L

    /** The plaintext hello, sent as the socket's first text frame. */
    val helloJson: String = JSONObject()
        .put("type", "e2ee_hello")
        .put("v", PROTOCOL_VERSION)
        .put("clientPublicKeyB64", encodeBase64(clientPublicKey))
        .put("clientNonceB64", encodeBase64(clientNonce))
        .put(
            "capabilities",
            JSONObject()
                .put("framing", JSONArray().put(PROTOCOL_VERSION))
                .put("payloadKinds", JSONArray().put("text").put("binary")),
        )
        .put("context", directContextJson())
        .toString()

    val isReady: Boolean get() = schedule != null

    /** Base64 SHA-256 of the transcript; echoed in the auth message and its reply. */
    val transcriptHashB64: String
        get() = encodeBase64(checkNotNull(schedule) { "ready not accepted" }.transcriptHash)

    /** Outcome of [acceptReady]. */
    enum class ReadyResult {
        ACCEPTED,
        /** A well-formed ready from a desktop whose key is not the paired one (re-keyed, or another computer). */
        KEY_MISMATCH,
        /** Not a valid v2 ready for this hello (malformed, wrong version, nonce not echoed...). */
        INVALID,
    }

    /**
     * Validates the desktop's `e2ee_ready` exactly as Orca's `validateMobileE2EEV2Handshake`
     * does (exact key sets, echoed client nonce, matching context, canonical base64) and
     * that its key is the pinned one; on [ReadyResult.ACCEPTED] derives the session keys.
     *
     * Anything but ACCEPTED means the caller must drop the socket - never fall back to
     * anything weaker.
     */
    fun acceptReady(readyText: String): ReadyResult {
        check(schedule == null) { "ready already accepted" }
        val invalid = ReadyResult.INVALID
        val ready = runCatching { JSONObject(readyText) }.getOrNull() ?: return invalid
        if (!hasExactKeys(ready, READY_KEYS)) return invalid
        if (ready.opt("type") != "e2ee_ready" || !isNumber(ready.opt("v"), PROTOCOL_VERSION)) return invalid
        if (!isExactSelection(ready.opt("selection"))) return invalid
        if (!isDirectContext(ready.opt("context"))) return invalid
        if (ready.opt("clientNonceB64") != encodeBase64(clientNonce)) return invalid

        val desktopPublicKey = decodeCanonicalBase64(ready.opt("desktopPublicKeyB64"), 32) ?: return invalid
        val desktopNonce = decodeCanonicalBase64(ready.opt("desktopNonceB64"), 32) ?: return invalid
        if (!MessageDigest.isEqual(desktopPublicKey, pinnedDesktopPublicKey)) return ReadyResult.KEY_MISMATCH

        val transcript = encodeTranscript(
            clientPublicKey = clientPublicKey,
            clientNonce = clientNonce,
            desktopPublicKey = desktopPublicKey,
            desktopNonce = desktopNonce,
            transport = TRANSPORT_DIRECT,
            relayHostId = null,
        )
        schedule = deriveKeySchedule(
            sharedSecret = NaCl.boxBefore(pinnedDesktopPublicKey, clientSecretKey),
            transcript = transcript,
            clientNonce = clientNonce,
            desktopNonce = desktopNonce,
        )
        return ReadyResult.ACCEPTED
    }

    /** The token-auth message for this session: `{type:'e2ee_auth', v:2, transcriptHashB64, deviceToken}`. */
    fun authJson(deviceToken: String): String = JSONObject()
        .put("type", "e2ee_auth")
        .put("v", PROTOCOL_VERSION)
        .put("transcriptHashB64", transcriptHashB64)
        .put("deviceToken", deviceToken)
        .toString()

    /**
     * True for exactly `{type:'e2ee_authenticated', v:2, transcriptHashB64:<ours>}` - Orca's
     * `classifyPairedE2EEV2AuthReply`. Anything else (including an `e2ee_error`) is not.
     */
    fun isAuthenticatedReply(plaintext: String): Boolean {
        val reply = runCatching { JSONObject(plaintext) }.getOrNull() ?: return false
        return hasExactKeys(reply, setOf("type", "v", "transcriptHashB64")) &&
            reply.opt("type") == "e2ee_authenticated" &&
            isNumber(reply.opt("v"), PROTOCOL_VERSION) &&
            reply.opt("transcriptHashB64") == transcriptHashB64
    }

    /** Seals [plaintext] as the next mobile-to-desktop text frame (base64, for a text WebSocket frame). */
    fun sealText(plaintext: String): String {
        val keys = checkNotNull(schedule) { "ready not accepted" }
        val frame = sealFrame(
            payload = plaintext.toByteArray(Charsets.UTF_8),
            key = keys.mobileToDesktopKey,
            sessionId = keys.sessionId,
            direction = DIRECTION_MOBILE_TO_DESKTOP,
            payloadKind = KIND_TEXT,
            counter = outboundCounter,
        )
        outboundCounter++
        return encodeBase64(frame)
    }

    /**
     * Opens the next desktop-to-mobile text frame. Null when it is not one (bad base64,
     * wrong counter, failed authentication); the inbound counter only advances on success.
     */
    fun openText(frameB64: String): String? {
        val frame = decodeCanonicalBase64(frameB64, null) ?: return null
        return open(frame, KIND_TEXT)?.toString(Charsets.UTF_8)
    }

    /**
     * Opens a binary frame. The widget never subscribes to a stream, so none is expected,
     * but one that does arrive must still be opened: frames of both kinds share the
     * inbound counter, and skipping one would make every later frame fail to open.
     */
    fun openBinary(frame: ByteArray): ByteArray? = open(frame, KIND_BINARY)

    private fun open(frame: ByteArray, payloadKind: Byte): ByteArray? {
        val keys = schedule ?: return null
        val plaintext = openFrame(
            frame = frame,
            key = keys.desktopToMobileKey,
            sessionId = keys.sessionId,
            direction = DIRECTION_DESKTOP_TO_MOBILE,
            payloadKind = payloadKind,
            expectedCounter = inboundCounter,
        ) ?: return null
        inboundCounter++
        return plaintext
    }

    internal class KeySchedule(
        val mobileToDesktopKey: ByteArray,
        val desktopToMobileKey: ByteArray,
        val sessionId: ByteArray,
        val transcriptHash: ByteArray,
    )

    companion object {
        const val PROTOCOL_VERSION = 2
        const val TRANSPORT_DIRECT = "direct"

        private const val PROTOCOL = "orca-mobile-e2ee"
        private const val TRANSCRIPT_DOMAIN = "orca-mobile-e2ee/v2/transcript"
        // The trailing NUL is part of each label (Orca: 'orca-mobile-e2ee/v2/salt\0').
        private val SALT_LABEL = "orca-mobile-e2ee/v2/salt\u0000".toByteArray(Charsets.UTF_8)
        private val INFO_LABEL = "orca-mobile-e2ee/v2/session\u0000".toByteArray(Charsets.UTF_8)

        private val READY_KEYS = setOf(
            "type", "v", "desktopPublicKeyB64", "clientNonceB64", "desktopNonceB64", "selection", "context",
        )
        private val CONTEXT_KEYS = setOf("protocol", "initiator", "responder", "transport")

        // Frame layout constants (mobile-e2ee-v2-framing.ts).
        private const val NONCE_LENGTH = 24
        private const val SESSION_ID_LENGTH = 32
        private const val HEADER_LENGTH = SESSION_ID_LENGTH + 1 + 1 + 8
        private const val FRAME_VERSION: Byte = 2
        internal const val DIRECTION_MOBILE_TO_DESKTOP: Byte = 0
        internal const val DIRECTION_DESKTOP_TO_MOBILE: Byte = 1
        internal const val KIND_TEXT: Byte = 0
        internal const val KIND_BINARY: Byte = 1

        /** A session with a fresh ephemeral key pair and nonce, pinned to the paired desktop key. */
        fun create(desktopPublicKey: ByteArray): OrcaE2eeSession =
            create(desktopPublicKey, NaCl.keyPair(), NaCl.randomBytes(32))

        /** Deterministic constructor for tests (fixed key pair and nonce). */
        internal fun create(
            desktopPublicKey: ByteArray,
            clientKeyPair: NaCl.KeyPair,
            clientNonce: ByteArray,
        ): OrcaE2eeSession {
            require(desktopPublicKey.size == 32) { "desktop public key must be 32 bytes" }
            require(clientNonce.size == 32) { "client nonce must be 32 bytes" }
            return OrcaE2eeSession(
                clientSecretKey = clientKeyPair.secretKey.copyOf(),
                clientPublicKey = clientKeyPair.publicKey.copyOf(),
                clientNonce = clientNonce.copyOf(),
                pinnedDesktopPublicKey = desktopPublicKey.copyOf(),
            )
        }

        private fun directContextJson(): JSONObject = JSONObject()
            .put("protocol", PROTOCOL)
            .put("initiator", "mobile")
            .put("responder", "desktop")
            .put("transport", TRANSPORT_DIRECT)

        /**
         * The handshake transcript (`encodeMobileE2EEV2Transcript`): a fixed list of named
         * fields, each written as u32 name length, name, u32 value length, value (big-endian).
         * Hashing it into the key schedule binds the keys to every handshake field, so a
         * tampered hello or ready yields keys that cannot open the other side's frames.
         *
         * The capability, selection and context fields are written from constants because
         * [acceptReady] has already required them to be exactly these values.
         */
        internal fun encodeTranscript(
            clientPublicKey: ByteArray,
            clientNonce: ByteArray,
            desktopPublicKey: ByteArray,
            desktopNonce: ByteArray,
            transport: String,
            relayHostId: String?,
        ): ByteArray {
            val payloadKinds = encodeStringList(listOf("text", "binary"))
            val fields = listOf(
                "domain" to utf8(TRANSCRIPT_DOMAIN),
                "mobile-to-desktop.type" to utf8("e2ee_hello"),
                "mobile-to-desktop.version" to uint32(PROTOCOL_VERSION),
                "mobile-to-desktop.client-public-key" to clientPublicKey,
                "mobile-to-desktop.client-nonce" to clientNonce,
                "mobile-to-desktop.capabilities.framing" to (uint32(1) + uint32(PROTOCOL_VERSION)),
                "mobile-to-desktop.capabilities.payload-kinds" to payloadKinds,
                "mobile-to-desktop.context.protocol" to utf8(PROTOCOL),
                "mobile-to-desktop.context.initiator" to utf8("mobile"),
                "mobile-to-desktop.context.responder" to utf8("desktop"),
                "mobile-to-desktop.context.transport" to utf8(transport),
                "mobile-to-desktop.context.relay-host-id" to utf8(relayHostId ?: ""),
                "desktop-to-mobile.type" to utf8("e2ee_ready"),
                "desktop-to-mobile.version" to uint32(PROTOCOL_VERSION),
                "desktop-to-mobile.desktop-public-key" to desktopPublicKey,
                "desktop-to-mobile.client-nonce-echo" to clientNonce,
                "desktop-to-mobile.desktop-nonce" to desktopNonce,
                "desktop-to-mobile.selection.framing" to uint32(PROTOCOL_VERSION),
                "desktop-to-mobile.selection.payload-kinds" to payloadKinds,
                "desktop-to-mobile.context.protocol" to utf8(PROTOCOL),
                "desktop-to-mobile.context.initiator" to utf8("mobile"),
                "desktop-to-mobile.context.responder" to utf8("desktop"),
                "desktop-to-mobile.context.transport" to utf8(transport),
                "desktop-to-mobile.context.relay-host-id" to utf8(relayHostId ?: ""),
            )
            val out = ByteArrayOutputStream()
            for ((name, value) in fields) {
                val nameBytes = utf8(name)
                out.write(uint32(nameBytes.size))
                out.write(nameBytes)
                out.write(uint32(value.size))
                out.write(value)
            }
            return out.toByteArray()
        }

        /**
         * `derivePairedE2EEV2KeySchedule`: HKDF-SHA256 with
         * salt = SHA256(SALT_LABEL || clientNonce || desktopNonce) and
         * info = INFO_LABEL || SHA256(transcript), expanded to 96 bytes and split into the
         * two direction keys and the session id.
         */
        internal fun deriveKeySchedule(
            sharedSecret: ByteArray,
            transcript: ByteArray,
            clientNonce: ByteArray,
            desktopNonce: ByteArray,
        ): KeySchedule {
            require(sharedSecret.size == 32) { "shared secret must be 32 bytes" }
            require(clientNonce.size == 32) { "client nonce must be 32 bytes" }
            require(desktopNonce.size == 32) { "desktop nonce must be 32 bytes" }
            val transcriptHash = sha256(transcript)
            val salt = sha256(SALT_LABEL + clientNonce + desktopNonce)
            val expanded = hkdfSha256(sharedSecret, salt, INFO_LABEL + transcriptHash, 96)
            return KeySchedule(
                mobileToDesktopKey = expanded.copyOfRange(0, 32),
                desktopToMobileKey = expanded.copyOfRange(32, 64),
                sessionId = expanded.copyOfRange(64, 96),
                transcriptHash = transcriptHash,
            )
        }

        /**
         * `sealMobileE2EEV2Frame`: nonce || secretbox(header || payload). The nonce is not
         * random: it is built from the session id, direction, kind and counter, which are
         * unique per frame because keys and session id are fresh for every socket.
         */
        internal fun sealFrame(
            payload: ByteArray,
            key: ByteArray,
            sessionId: ByteArray,
            direction: Byte,
            payloadKind: Byte,
            counter: Long,
        ): ByteArray {
            val nonce = frameNonce(sessionId, direction, payloadKind, counter)
            val header = frameHeader(sessionId, direction, payloadKind, counter)
            return nonce + NaCl.secretbox(header + payload, nonce, key)
        }

        /**
         * `openMobileE2EEV2Frame`: the frame must carry exactly the nonce we expect for this
         * direction/kind/counter, authenticate, and repeat the same header inside the box.
         */
        internal fun openFrame(
            frame: ByteArray,
            key: ByteArray,
            sessionId: ByteArray,
            direction: Byte,
            payloadKind: Byte,
            expectedCounter: Long,
        ): ByteArray? {
            if (frame.size < NONCE_LENGTH + NaCl.MAC_BYTES + HEADER_LENGTH) return null
            val nonce = frameNonce(sessionId, direction, payloadKind, expectedCounter)
            if (!MessageDigest.isEqual(frame.copyOfRange(0, NONCE_LENGTH), nonce)) return null
            val plaintext = NaCl.secretboxOpen(frame.copyOfRange(NONCE_LENGTH, frame.size), nonce, key)
                ?: return null
            val header = frameHeader(sessionId, direction, payloadKind, expectedCounter)
            if (!MessageDigest.isEqual(plaintext.copyOfRange(0, HEADER_LENGTH), header)) return null
            return plaintext.copyOfRange(HEADER_LENGTH, plaintext.size)
        }

        /** sessionId[0..12) | version | direction | kind | 0 | u64 counter (big-endian). */
        private fun frameNonce(sessionId: ByteArray, direction: Byte, payloadKind: Byte, counter: Long): ByteArray {
            require(sessionId.size == SESSION_ID_LENGTH) { "session id must be $SESSION_ID_LENGTH bytes" }
            require(counter >= 0) { "counter overflow" }
            return ByteBuffer.allocate(NONCE_LENGTH)
                .put(sessionId, 0, 12)
                .put(FRAME_VERSION)
                .put(direction)
                .put(payloadKind)
                .put(0)
                .putLong(counter)
                .array()
        }

        /** sessionId | direction | kind | u64 counter (big-endian). */
        private fun frameHeader(sessionId: ByteArray, direction: Byte, payloadKind: Byte, counter: Long): ByteArray =
            ByteBuffer.allocate(HEADER_LENGTH)
                .put(sessionId)
                .put(direction)
                .put(payloadKind)
                .putLong(counter)
                .array()

        /** RFC 5869 HKDF with HMAC-SHA256 (the platform's own HMAC). */
        internal fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
            require(length in 1..255 * 32) { "invalid HKDF length $length" }
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(salt, "HmacSHA256"))
            val prk = mac.doFinal(ikm)
            mac.init(SecretKeySpec(prk, "HmacSHA256"))
            val out = ByteArrayOutputStream()
            var block = ByteArray(0)
            var counter = 1
            while (out.size() < length) {
                mac.update(block)
                mac.update(info)
                mac.update(counter.toByte())
                block = mac.doFinal()
                out.write(block)
                counter++
            }
            return out.toByteArray().copyOf(length)
        }

        internal fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)

        internal fun encodeBase64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

        /**
         * Standard base64 that must re-encode to the same string (Orca rejects aliases such
         * as missing padding). [length] null accepts any length.
         */
        internal fun decodeCanonicalBase64(value: Any?, length: Int?): ByteArray? {
            if (value !is String) return null
            val bytes = runCatching { Base64.getDecoder().decode(value) }.getOrNull() ?: return null
            if (length != null && bytes.size != length) return null
            return if (encodeBase64(bytes) == value) bytes else null
        }

        private fun hasExactKeys(obj: JSONObject, keys: Set<String>): Boolean =
            obj.keys().asSequence().toSet() == keys

        /** JSON numbers can come back as Int, Long or Double; compare by value. */
        private fun isNumber(value: Any?, expected: Int): Boolean =
            value is Number && value.toDouble() == expected.toDouble()

        private fun isExactSelection(value: Any?): Boolean {
            if (value !is JSONObject || !hasExactKeys(value, setOf("framing", "payloadKinds"))) return false
            val kinds = value.opt("payloadKinds") as? JSONArray ?: return false
            return isNumber(value.opt("framing"), PROTOCOL_VERSION) &&
                kinds.length() == 2 && kinds.opt(0) == "text" && kinds.opt(1) == "binary"
        }

        /** The ready must repeat the hello's context exactly; we only ever send the direct one. */
        private fun isDirectContext(value: Any?): Boolean =
            value is JSONObject && hasExactKeys(value, CONTEXT_KEYS) &&
                value.opt("protocol") == PROTOCOL &&
                value.opt("initiator") == "mobile" &&
                value.opt("responder") == "desktop" &&
                value.opt("transport") == TRANSPORT_DIRECT

        private fun utf8(value: String): ByteArray = value.toByteArray(Charsets.UTF_8)

        private fun uint32(value: Int): ByteArray = ByteBuffer.allocate(4).putInt(value).array()

        private fun encodeStringList(values: List<String>): ByteArray {
            val out = ByteArrayOutputStream()
            out.write(uint32(values.size))
            for (value in values) {
                val bytes = utf8(value)
                out.write(uint32(bytes.size))
                out.write(bytes)
            }
            return out.toByteArray()
        }
    }
}
