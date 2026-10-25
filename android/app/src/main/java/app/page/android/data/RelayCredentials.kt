package app.page.android.data

import app.page.android.model.Base64Url
import app.page.android.model.PairingValidator
import app.page.android.model.SessionCrypto
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * The relay address and bearer token, read straight from [SecretStore].
 *
 * Every network path (including notification actions handled in a cold
 * process, before any screen exists) reads credentials through this one
 * type, so there is no in-memory copy to seed and nothing to get out of sync.
 */
data class RelayCredentials(val baseUrl: String, val token: String) {
    private val base: HttpUrl? get() = baseUrl.toHttpUrlOrNull()

    /**
     * `url("reply", id)` -> `https://relay/reply/<percent-encoded id>`. Each
     * segment is encoded on its own so an id can never inject a path.
     */
    fun url(vararg segments: String, query: Map<String, String> = emptyMap()): HttpUrl? {
        val b = base?.newBuilder() ?: return null
        for (s in segments) b.addPathSegment(s)
        for ((k, v) in query) b.addQueryParameter(k, v)
        return b.build()
    }

    /** OkHttp takes `https://…/ws` and upgrades it; the relay sees a wss connection. */
    val webSocketUrl: HttpUrl? get() = url("ws")

    // Never print the token.
    override fun toString(): String = "RelayCredentials($baseUrl)"

    companion object {
        fun current(store: SecretStore): RelayCredentials? {
            val token = store.get(SecretStore.RELAY_TOKEN)?.takeIf { it.isNotEmpty() } ?: return null
            val raw = store.get(SecretStore.RELAY_URL) ?: return null
            // A stored URL that no longer validates (e.g. the placeholder
            // host) means we're effectively unpaired.
            val url = (PairingValidator.normaliseRelay(raw) as? PairingValidator.RelayResult.Ok)?.url ?: return null
            return RelayCredentials(url, token)
        }
    }
}

/**
 * The live-sessions key (`sk`) from the pairing QR, stored beside the relay
 * token with the same protection. Absent for pairings made with a Mac that
 * predates live sessions. Never logged.
 */
object SessionKeyStore {
    fun current(store: SecretStore): ByteArray? =
        store.get(SecretStore.SESSION_KEY)?.let(Base64Url::decode)?.let(SessionCrypto::validRootKey)

    fun save(store: SecretStore, key: ByteArray): Boolean {
        if (SessionCrypto.validRootKey(key) == null) return false
        return store.set(SecretStore.SESSION_KEY, Base64Url.encode(key))
    }

    fun clear(store: SecretStore) = store.delete(SecretStore.SESSION_KEY)
}
