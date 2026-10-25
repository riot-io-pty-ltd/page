package app.page.android.data

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Encrypted string storage for the relay token, relay URL, live-sessions key
 * and paired-Mac record (the Android side of iOS KeychainStore.swift).
 *
 * Values are sealed with AES-256-GCM under a key that lives in the Android
 * Keystore and never leaves it (hardware-backed where the phone has secure
 * hardware). The ciphertext sits in a private SharedPreferences file that is
 * excluded from every backup and device transfer (see
 * res/xml/data_extraction_rules.xml), and the Keystore key can't be restored
 * elsewhere anyway. No user authentication is bound to the key: notification
 * actions and the background connection must read the token while the phone
 * is locked, exactly like iOS's AfterFirstUnlockThisDeviceOnly items.
 *
 * The relay token is the only credential the Worker checks, and whoever
 * holds it can type into the Mac's agent sessions, so it is never logged and
 * never stored anywhere else.
 */
class SecretStore(context: Context) {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    @Synchronized
    fun get(key: String): String? {
        val stored = prefs.getString(key, null) ?: return null
        return try {
            val blob = Base64.decode(stored, Base64.NO_WRAP)
            if (blob.size <= IV_LENGTH) return null
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(TAG_BITS, blob, 0, IV_LENGTH))
            String(cipher.doFinal(blob, IV_LENGTH, blob.size - IV_LENGTH), Charsets.UTF_8)
        } catch (e: Exception) {
            // A value that no longer decrypts (key invalidated, data tampered)
            // reads as absent: the user re-pairs instead of the app crashing.
            Log.w(TAG, "read $key failed: ${e.javaClass.simpleName}")
            null
        }
    }

    /** Returns false if the value couldn't be sealed or written. */
    @Synchronized
    fun set(key: String, value: String): Boolean = try {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val sealed = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        prefs.edit().putString(key, Base64.encodeToString(sealed, Base64.NO_WRAP)).commit()
    } catch (e: Exception) {
        Log.w(TAG, "write $key failed: ${e.javaClass.simpleName}")
        false
    }

    @Synchronized
    fun delete(key: String) {
        prefs.edit().remove(key).commit()
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build()
        )
        return generator.generateKey()
    }

    companion object {
        private const val TAG = "SecretStore"
        private const val PREFS_NAME = "page_secure"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "page.secrets.v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val IV_LENGTH = 12
        private const val TAG_BITS = 128

        const val RELAY_URL = "page.relayURL"
        const val RELAY_TOKEN = "page.relayToken"
        const val SESSION_KEY = "page.sessionKey"
        const val PAIRED_MAC = "page.pairedMac"
    }
}
