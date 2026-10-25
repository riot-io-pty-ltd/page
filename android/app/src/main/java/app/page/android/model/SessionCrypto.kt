package app.page.android.model

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// End-to-end encryption for live sessions (docs/SESSIONS-PROTOCOL.md §2).
// The relay only ever sees `{"v":1,"n":…,"c":…}`; the Mac and this phone
// share the 32-byte session key from the pairing QR. javax.crypto only, so
// the spec's test vector runs in plain JVM unit tests.

/**
 * base64url without padding, as the sessions protocol writes it. Readers
 * accept padding (and the standard alphabet) too.
 */
object Base64Url {
    fun encode(data: ByteArray): String = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(data)

    fun decode(raw: String): ByteArray? {
        var s = raw.trim().replace('-', '+').replace('_', '/')
        s = s.trimEnd('=')
        when (s.length % 4) {
            1 -> return null
            2 -> s += "=="
            3 -> s += "="
        }
        return try { java.util.Base64.getDecoder().decode(s) } catch (_: IllegalArgumentException) { null }
    }
}

/**
 * The two frame types that carry an envelope. Each is also the AAD, so the
 * relay can't relabel a Mac frame as a phone command or vice versa.
 */
object SessionFrameType {
    const val UPDATE = "sessions.update"
    const val COMMAND = "sessions.command"
}

object SessionCrypto {
    const val KEY_LENGTH = 32
    const val NONCE_LENGTH = 12
    const val TAG_LENGTH = 16
    const val ENVELOPE_VERSION = 1
    private val SALT = "page-sessions-v1".toByteArray(Charsets.UTF_8)
    private val random = SecureRandom()

    /** Per-direction subkeys: the relay can't reflect a Mac frame back to the Mac as a command. */
    enum class Direction(val info: String) {
        MAC_TO_PHONE("mac->phone"),
        PHONE_TO_MAC("phone->mac"),
    }

    /**
     * `sk` from the pairing payload: exactly 32 bytes, anything else is
     * ignored (the pairing still works, just without live sessions).
     */
    fun validRootKey(data: ByteArray?): ByteArray? = data?.takeIf { it.size == KEY_LENGTH }

    /** HKDF-SHA256(ikm: root, salt: "page-sessions-v1", info: direction, 32 bytes). */
    fun subkey(root: ByteArray, direction: Direction): ByteArray {
        // Extract: PRK = HMAC(salt, IKM).
        val prk = hmac(SALT, root)
        // Expand: one block is enough for 32 bytes. T(1) = HMAC(PRK, info || 0x01).
        val info = direction.info.toByteArray(Charsets.UTF_8)
        return hmac(prk, info + byteArrayOf(1)).copyOf(KEY_LENGTH)
    }

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    class Envelope(val nonce: ByteArray, /** Ciphertext followed by the 16-byte GCM tag. */ val sealed: ByteArray) {
        val json: JsonObject
            get() = JsonObject(
                mapOf(
                    "v" to JsonPrimitive(ENVELOPE_VERSION),
                    "n" to JsonPrimitive(Base64Url.encode(nonce)),
                    "c" to JsonPrimitive(Base64Url.encode(sealed)),
                )
            )

        override fun equals(other: Any?): Boolean =
            other is Envelope && nonce.contentEquals(other.nonce) && sealed.contentEquals(other.sealed)

        override fun hashCode(): Int = 31 * nonce.contentHashCode() + sealed.contentHashCode()

        companion object {
            /**
             * Strict shape: `v == 1`, a 12-byte nonce and at least a tag's
             * worth of ciphertext. Anything else is dropped before decrypting.
             */
            fun fromJson(json: JsonObject): Envelope? {
                val v = json.num("v") ?: return null
                if (v != ENVELOPE_VERSION.toDouble()) return null
                val n = json.str("n")?.let(Base64Url::decode)?.takeIf { it.size == NONCE_LENGTH } ?: return null
                val c = json.str("c")?.let(Base64Url::decode)?.takeIf { it.size >= TAG_LENGTH } ?: return null
                return Envelope(n, c)
            }
        }
    }

    /**
     * Encrypts [plaintext] under the [direction] subkey with [aad] (the frame
     * type). [fixedNonce] is for the spec test vector only: production
     * callers leave it null and get a fresh random nonce every time.
     */
    fun seal(
        plaintext: ByteArray,
        root: ByteArray,
        direction: Direction,
        aad: String,
        fixedNonce: ByteArray? = null,
    ): Envelope {
        val nonce = fixedNonce?.also { require(it.size == NONCE_LENGTH) }
            ?: ByteArray(NONCE_LENGTH).also(random::nextBytes)
        // A fresh Cipher every time: GCM refuses to reuse a key + IV pair on
        // one instance, and instances aren't thread-safe anyway.
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(subkey(root, direction), "AES"), GCMParameterSpec(TAG_LENGTH * 8, nonce))
        cipher.updateAAD(aad.toByteArray(Charsets.UTF_8))
        return Envelope(nonce, cipher.doFinal(plaintext))
    }

    /**
     * The plaintext, or null if the envelope doesn't authenticate under this
     * key, direction and frame type.
     */
    fun open(envelope: Envelope, root: ByteArray, direction: Direction, aad: String): ByteArray? {
        if (envelope.sealed.size < TAG_LENGTH || envelope.nonce.size != NONCE_LENGTH) return null
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(subkey(root, direction), "AES"), GCMParameterSpec(TAG_LENGTH * 8, envelope.nonce))
            cipher.updateAAD(aad.toByteArray(Charsets.UTF_8))
            cipher.doFinal(envelope.sealed)
        } catch (_: Exception) {
            null
        }
    }
}
