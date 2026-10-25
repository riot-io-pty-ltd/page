package app.page.android.model

/**
 * The data URI of a notification action's intent: `page-action://<id>/<action>`.
 *
 * The inline-reply PendingIntent has to be mutable (the system writes the
 * typed text into it), and a mutable PendingIntent's extras can be changed
 * by whoever fills it in. Its data URI can't: fill-in never replaces data
 * that was already set. So the page id and the action are read from this URI
 * only, and everything else about the page comes from the phone's own record
 * of what it posted. Pure, so the parsing rules are unit tested.
 */
object NotificationActionUri {
    const val SCHEME = "page-action"
    private const val PREFIX = "$SCHEME://"

    /** The actions a notification can carry. */
    val knownActions: Set<String> = setOf(
        NotificationActionId.APPROVE, NotificationActionId.DENY, NotificationActionId.REPLY,
        NotificationActionId.CARRY_ON, NotificationActionId.STOP,
    )

    data class Parsed(val interventionId: String, val action: String)

    fun build(interventionId: String, action: String): String = PREFIX + encode(interventionId) + "/" + action

    /** Null for anything that isn't exactly a well-formed action URI. */
    fun parse(uri: String?): Parsed? {
        if (uri == null || !uri.startsWith(PREFIX)) return null
        val rest = uri.substring(PREFIX.length)
        val slash = rest.indexOf('/')
        if (slash <= 0 || slash != rest.lastIndexOf('/')) return null
        val action = rest.substring(slash + 1)
        if (action !in knownActions) return null
        val id = decode(rest.substring(0, slash)) ?: return null
        if (id.isEmpty() || id.length > 200) return null
        return Parsed(id, action)
    }

    private const val UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

    /** Percent-encodes everything but RFC 3986 unreserved characters. */
    private fun encode(s: String): String {
        val out = StringBuilder()
        for (b in s.toByteArray(Charsets.UTF_8)) {
            val c = (b.toInt() and 0xff).toChar()
            if (c in UNRESERVED) out.append(c) else out.append('%').append(String.format("%02X", b.toInt() and 0xff))
        }
        return out.toString()
    }

    /** Strict percent-decoding: only unreserved characters and valid %XX escapes. */
    private fun decode(s: String): String? {
        val bytes = java.io.ByteArrayOutputStream()
        var i = 0
        while (i < s.length) {
            val c = s[i]
            when {
                c == '%' -> {
                    if (i + 2 >= s.length) return null
                    val hex = s.substring(i + 1, i + 3)
                    if (!hex.all { it in "0123456789abcdefABCDEF" }) return null
                    bytes.write(hex.toInt(16))
                    i += 3
                }
                c in UNRESERVED -> {
                    bytes.write(c.code)
                    i++
                }
                else -> return null
            }
        }
        val decoded = bytes.toByteArray()
        val text = String(decoded, Charsets.UTF_8)
        // Reject malformed UTF-8 (it would not round-trip).
        if (!text.toByteArray(Charsets.UTF_8).contentEquals(decoded)) return null
        return text
    }
}
