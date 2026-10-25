package app.page.android.model

import java.net.URI
import kotlinx.serialization.json.JsonObject

/** A pairing payload that passed validation: safe to probe and adopt. */
data class ValidatedPairing(
    val token: String,
    /** Normalised HTTPS base URL of the relay (no trailing `/ws` or slash). */
    val relayBaseUrl: String,
    val macName: String,
    /**
     * `sk`: the 32-byte key that end-to-end encrypts live sessions. Null for
     * a Mac that predates them (or a malformed value): the pairing still
     * works, the Sessions tab asks for a re-pair.
     */
    val sessionKey: ByteArray? = null,
) {
    val relayHost: String get() = try { URI(relayBaseUrl).host ?: relayBaseUrl } catch (_: Exception) { relayBaseUrl }

    override fun equals(other: Any?): Boolean = other is ValidatedPairing && token == other.token &&
        relayBaseUrl == other.relayBaseUrl && macName == other.macName &&
        sameKey(sessionKey, other.sessionKey)

    private fun sameKey(a: ByteArray?, b: ByteArray?): Boolean =
        if (a == null || b == null) a == null && b == null else a.contentEquals(b)

    override fun hashCode(): Int = (token.hashCode() * 31 + relayBaseUrl.hashCode()) * 31 + macName.hashCode()

    // Never print the token or the key.
    override fun toString(): String = "ValidatedPairing(relay=$relayBaseUrl, mac=$macName, sk=${sessionKey != null})"
}

sealed interface PairingValidationError {
    data object Empty : PairingValidationError
    data object NotPageCode : PairingValidationError
    data class UnsupportedVersion(val version: Int) : PairingValidationError
    data object MissingToken : PairingValidationError
    data object InvalidRelay : PairingValidationError
    data object InsecureRelay : PairingValidationError
    data object PlaceholderRelay : PairingValidationError

    val message: String
        get() = when (this) {
            Empty -> "Paste the pairing code from your Mac first."
            NotPageCode -> "That isn't a Page pairing code. On your Mac, click the Page menu-bar icon → Pair phone… and scan the code shown there."
            is UnsupportedVersion -> "This pairing code uses a newer format (v$version) than this app understands. Update Page on your phone."
            MissingToken -> "The pairing code has no relay token. Open Pair phone… on your Mac again and use the new code."
            InvalidRelay -> "The relay address in the pairing code isn't a valid URL. Check relayURL in your Mac's Page settings."
            InsecureRelay -> "The relay address must start with https:// (or wss://). Update relayURL in your Mac's Page settings."
            PlaceholderRelay -> "Your Mac is still using the example relay address. Deploy your Cloudflare Worker, set relayURL in your Mac's Page settings, then show the pairing code again."
        }
}

/** Result of [PairingValidator.validate]: exactly one side is set. */
sealed interface PairingResult {
    data class Success(val pairing: ValidatedPairing) : PairingResult
    data class Failure(val error: PairingValidationError) : PairingResult
}

/**
 * Parses and validates the JSON the Mac shows as a QR code or copies to the
 * clipboard: `{"v":1,"token":"…","relay":"https://…","host":"Roy's MacBook"}`,
 * plus an optional `"sk"` (base64url, 32 bytes) from Macs with live sessions.
 *
 * There is deliberately no allow-list of relay hosts: every deployment is
 * self-hosted and its URL only arrives through this payload. What we can
 * check is shape, version, TLS, and that the Mac isn't still on the
 * placeholder relay (which would pair the phone to a dead host).
 */
object PairingValidator {
    const val SUPPORTED_VERSION = 1
    const val PLACEHOLDER_HOST_FRAGMENT = "your-page-relay"

    fun validate(rawText: String): PairingResult {
        val text = normaliseQuotes(rawText).trim()
        if (text.isEmpty()) return PairingResult.Failure(PairingValidationError.Empty)
        val dict = parseJsonObject(text)
        if (dict == null || (!dict.containsKey("token") && !dict.containsKey("relay"))) {
            return PairingResult.Failure(PairingValidationError.NotPageCode)
        }

        // `v` is a number on every Mac build so far; accept "1" too.
        val version: Int = dict.num("v")?.toInt() ?: dict.str("v")?.toIntOrNull()
            ?: return PairingResult.Failure(PairingValidationError.NotPageCode)
        if (version != SUPPORTED_VERSION) return PairingResult.Failure(PairingValidationError.UnsupportedVersion(version))

        val token = (dict.str("token") ?: "").trim()
        // The token goes into an Authorization header: no whitespace or
        // control characters, and it must look like a real secret.
        if (token.isEmpty() || token.length < 16 || token.codePoints().anyMatch(::isWhitespaceOrControl)) {
            return PairingResult.Failure(PairingValidationError.MissingToken)
        }

        val relay = when (val r = normaliseRelay((dict.str("relay") ?: "").trim())) {
            is RelayResult.Ok -> r.url
            is RelayResult.Bad -> return PairingResult.Failure(r.error)
        }

        val host = (dict.str("host") ?: "").trim()
        val name = if (host.isEmpty()) "Your Mac" else host.capped(60)
        return PairingResult.Success(ValidatedPairing(token, relay, name, sessionKey(dict)))
    }

    /**
     * `sk` must decode to exactly 32 bytes; anything else is ignored rather
     * than failing the pairing, since the inbox works without it.
     */
    fun sessionKey(dict: JsonObject): ByteArray? =
        SessionCrypto.validRootKey(dict.str("sk")?.let(Base64Url::decode))

    sealed interface RelayResult {
        data class Ok(val url: String) : RelayResult
        data class Bad(val error: PairingValidationError) : RelayResult
    }

    /**
     * `wss://x/ws` and `https://x` both mean the same relay; REST needs the
     * HTTPS base without the `/ws` suffix.
     */
    fun normaliseRelay(raw: String): RelayResult {
        if (raw.isEmpty()) return RelayResult.Bad(PairingValidationError.InvalidRelay)
        val uri = try { URI(raw) } catch (_: Exception) { return RelayResult.Bad(PairingValidationError.InvalidRelay) }
        when (uri.scheme?.lowercase()) {
            "https", "wss" -> Unit
            "http", "ws" -> return RelayResult.Bad(PairingValidationError.InsecureRelay)
            else -> return RelayResult.Bad(PairingValidationError.InvalidRelay)
        }
        val host = uri.host?.lowercase()
        if (host.isNullOrEmpty() || !(host.contains('.') || host == "localhost")) {
            return RelayResult.Bad(PairingValidationError.InvalidRelay)
        }
        if (host.contains(PLACEHOLDER_HOST_FRAGMENT)) return RelayResult.Bad(PairingValidationError.PlaceholderRelay)
        var path = uri.rawPath ?: ""
        if (path.endsWith("/ws")) path = path.dropLast(3)
        path = path.trimEnd('/')
        return RelayResult.Ok("https://${uri.rawAuthority}$path")
    }

    private fun isWhitespaceOrControl(cp: Int): Boolean {
        if (Character.isWhitespace(cp) || Character.isSpaceChar(cp)) return true
        val type = Character.getType(cp)
        return type == Character.CONTROL.toInt() || type == Character.FORMAT.toInt()
    }

    /** Some keyboards turn typed quotes into curly quotes; undo that. */
    private fun normaliseQuotes(s: String): String = s
        .replace('“', '"').replace('”', '"')
        .replace('‘', '\'').replace('’', '\'')
}
