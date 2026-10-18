package com.usage.claudewidget.orca

import org.bouncycastle.crypto.engines.Salsa20Engine
import org.bouncycastle.crypto.engines.XSalsa20Engine
import org.bouncycastle.crypto.macs.Poly1305
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.ParametersWithIV
import org.bouncycastle.math.ec.rfc7748.X25519
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * The NaCl primitives Orca's mobile E2EE uses, byte-for-byte compatible with tweetnacl
 * (which is what desktop Orca and the Orca phone app run):
 *
 *  - `box.keyPair` / `box.before`: Curve25519 key agreement, then HSalsa20 over the raw
 *    shared point to get the 32-byte "beforenm" key. v2 feeds that into HKDF as its
 *    shared secret (see [OrcaE2eeSession]), so it must match tweetnacl exactly.
 *  - `secretbox`: XSalsa20-Poly1305 - the AEAD every v2 frame is sealed with.
 *
 * Bouncy Castle supplies X25519, the Salsa20 core and XSalsa20/Poly1305; this file only
 * composes them the way NaCl does. Every function here is checked against vectors that
 * tweetnacl itself produced (OrcaE2eeVectorsTest).
 */
internal object NaCl {
    const val KEY_BYTES = 32
    const val NONCE_BYTES = 24
    const val MAC_BYTES = 16

    class KeyPair(val publicKey: ByteArray, val secretKey: ByteArray)

    private val random = SecureRandom()

    fun randomBytes(length: Int): ByteArray = ByteArray(length).also(random::nextBytes)

    /**
     * A fresh Curve25519 key pair, as `nacl.box.keyPair()`: 32 random bytes are the secret
     * key and the public key is that scalar times the base point. X25519 clamps the scalar
     * internally (RFC 7748 decodeScalar), exactly as tweetnacl's crypto_scalarmult does, so
     * the stored secret key needs no clamping of its own.
     */
    fun keyPair(): KeyPair = keyPairFromSecretKey(randomBytes(KEY_BYTES))

    /** `nacl.box.keyPair.fromSecretKey` - also what the tests use for fixed key material. */
    fun keyPairFromSecretKey(secretKey: ByteArray): KeyPair {
        require(secretKey.size == KEY_BYTES) { "secret key must be $KEY_BYTES bytes" }
        val publicKey = ByteArray(KEY_BYTES)
        X25519.scalarMultBase(secretKey, 0, publicKey, 0)
        return KeyPair(publicKey, secretKey.copyOf())
    }

    /**
     * `nacl.box.before(peerPublicKey, ourSecretKey)`: HSalsa20(X25519(sk, pk), 0^16).
     *
     * Unlike tweetnacl this refuses an all-zero shared point (a low-order peer key).
     * The peer key here is the desktop's, pinned by the pairing code, so a zero result can
     * only mean a corrupt or hostile pairing - never a key worth talking to.
     */
    fun boxBefore(peerPublicKey: ByteArray, ourSecretKey: ByteArray): ByteArray {
        require(peerPublicKey.size == KEY_BYTES) { "public key must be $KEY_BYTES bytes" }
        require(ourSecretKey.size == KEY_BYTES) { "secret key must be $KEY_BYTES bytes" }
        val shared = ByteArray(KEY_BYTES)
        val ok = X25519.calculateAgreement(ourSecretKey, 0, peerPublicKey, 0, shared, 0)
        require(ok) { "peer public key gives an all-zero shared secret" }
        return hsalsa20(shared, ByteArray(16))
    }

    /**
     * NaCl's crypto_core_hsalsa20 with the "expand 32-byte k" constant.
     *
     * Bouncy Castle's [Salsa20Engine.salsaCore] runs the 20 rounds and then adds the input
     * words back in (the Salsa20 feed-forward). HSalsa20 has no feed-forward, so the input
     * is subtracted again from the eight output words it keeps - the same trick Bouncy
     * Castle's own XSalsa20 key setup uses.
     */
    fun hsalsa20(key: ByteArray, input: ByteArray): ByteArray {
        require(key.size == KEY_BYTES) { "key must be $KEY_BYTES bytes" }
        require(input.size == 16) { "input must be 16 bytes" }
        val state = IntArray(16)
        // Salsa20 state layout: constants on the diagonal, key in words 1-4 and 11-14, the
        // 16-byte input (nonce + counter for plain Salsa20) in words 6-9.
        state[0] = SIGMA[0]; state[5] = SIGMA[1]; state[10] = SIGMA[2]; state[15] = SIGMA[3]
        for (i in 0 until 4) {
            state[1 + i] = littleEndianInt(key, 4 * i)
            state[11 + i] = littleEndianInt(key, 16 + 4 * i)
            state[6 + i] = littleEndianInt(input, 4 * i)
        }
        val mixed = IntArray(16)
        Salsa20Engine.salsaCore(20, state, mixed)
        val out = ByteArray(KEY_BYTES)
        // HSalsa20's output is the diagonal (0, 5, 10, 15) then the input words (6..9).
        intArrayOf(0, 5, 10, 15, 6, 7, 8, 9).forEachIndexed { slot, word ->
            putLittleEndianInt(mixed[word] - state[word], out, 4 * slot)
        }
        return out
    }

    /**
     * `nacl.secretbox(message, nonce, key)`: returns the 16-byte Poly1305 tag followed by
     * the ciphertext (tweetnacl's layout, without the 16 zero bytes of the C API).
     *
     * The first 32 bytes of the XSalsa20 keystream are the one-time Poly1305 key; the
     * message is encrypted with the keystream from byte 32 on.
     */
    fun secretbox(message: ByteArray, nonce: ByteArray, key: ByteArray): ByteArray {
        val stream = xsalsa20(nonce, key)
        val polyKey = ByteArray(32)
        stream.processBytes(ByteArray(32), 0, 32, polyKey, 0)
        val ciphertext = ByteArray(message.size)
        stream.processBytes(message, 0, message.size, ciphertext, 0)
        return poly1305(polyKey, ciphertext) + ciphertext
    }

    /** `nacl.secretbox.open`; null when the box is too short or fails authentication. */
    fun secretboxOpen(box: ByteArray, nonce: ByteArray, key: ByteArray): ByteArray? {
        if (box.size < MAC_BYTES) return null
        val stream = xsalsa20(nonce, key)
        val polyKey = ByteArray(32)
        stream.processBytes(ByteArray(32), 0, 32, polyKey, 0)
        val tag = box.copyOfRange(0, MAC_BYTES)
        val ciphertext = box.copyOfRange(MAC_BYTES, box.size)
        // Constant-time compare: never decrypt (or leak timing about) an unauthentic box.
        if (!MessageDigest.isEqual(tag, poly1305(polyKey, ciphertext))) return null
        val plaintext = ByteArray(ciphertext.size)
        stream.processBytes(ciphertext, 0, ciphertext.size, plaintext, 0)
        return plaintext
    }

    private fun xsalsa20(nonce: ByteArray, key: ByteArray): XSalsa20Engine {
        require(nonce.size == NONCE_BYTES) { "nonce must be $NONCE_BYTES bytes" }
        require(key.size == KEY_BYTES) { "key must be $KEY_BYTES bytes" }
        return XSalsa20Engine().apply { init(true, ParametersWithIV(KeyParameter(key), nonce)) }
    }

    private fun poly1305(key: ByteArray, data: ByteArray): ByteArray {
        // No block cipher: plain Poly1305 with a 32-byte one-time key (r || s), as NaCl uses.
        val mac = Poly1305()
        mac.init(KeyParameter(key))
        mac.update(data, 0, data.size)
        return ByteArray(MAC_BYTES).also { mac.doFinal(it, 0) }
    }

    /** "expand 32-byte k" as four little-endian words. */
    private val SIGMA = "expand 32-byte k".toByteArray(Charsets.US_ASCII).let { bytes ->
        IntArray(4) { littleEndianInt(bytes, 4 * it) }
    }

    private fun littleEndianInt(bytes: ByteArray, offset: Int): Int =
        (bytes[offset].toInt() and 0xff) or
            ((bytes[offset + 1].toInt() and 0xff) shl 8) or
            ((bytes[offset + 2].toInt() and 0xff) shl 16) or
            ((bytes[offset + 3].toInt() and 0xff) shl 24)

    private fun putLittleEndianInt(value: Int, out: ByteArray, offset: Int) {
        out[offset] = value.toByte()
        out[offset + 1] = (value ushr 8).toByte()
        out[offset + 2] = (value ushr 16).toByte()
        out[offset + 3] = (value ushr 24).toByte()
    }
}
