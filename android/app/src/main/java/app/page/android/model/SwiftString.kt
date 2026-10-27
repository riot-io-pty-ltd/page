package app.page.android.model

import java.text.BreakIterator
import java.util.Locale

/**
 * The few Swift String behaviours the iOS models (and so this port) lean on,
 * with Swift's meaning rather than Kotlin's.
 *
 * - A Swift `Character` is a grapheme cluster, so "\r\n" and "e" + a combining
 *   accent are each one Character. [chars] gives that view.
 * - `hasPrefix` / `hasSuffix` compare Characters, so a prefix that would end in
 *   the middle of a cluster does not match.
 * - `trimmingCharacters(in: .whitespacesAndNewlines)` trims Unicode scalars from
 *   Foundation's sets, which are not the same as Kotlin's `trim()`.
 *
 * Only what the ported code uses is here; keep it that way.
 */
internal object Sw {
    /** Grapheme clusters, as Swift's `Array(string)`. */
    fun chars(s: String): List<String> {
        if (s.isEmpty()) return emptyList()
        if (s.all { it.code < 0x80 }) {
            // ASCII: every unit is a Character except "\r\n", which is one.
            val out = ArrayList<String>(s.length)
            var i = 0
            while (i < s.length) {
                if (s[i] == '\r' && i + 1 < s.length && s[i + 1] == '\n') { out.add("\r\n"); i += 2 } else { out.add(s[i].toString()); i++ }
            }
            return out
        }
        val it = BreakIterator.getCharacterInstance(Locale.ROOT)
        it.setText(s)
        val out = ArrayList<String>()
        var start = it.first()
        var end = it.next()
        while (end != BreakIterator.DONE) {
            out.add(s.substring(start, end))
            start = end
            end = it.next()
        }
        return out
    }

    /** Swift `String.count`. */
    fun count(s: String): Int = chars(s).size

    private fun isBoundary(s: String, index: Int): Boolean {
        if (index <= 0 || index >= s.length) return true
        if (s.all { it.code < 0x80 }) return !(s[index - 1] == '\r' && s[index] == '\n')
        val it = BreakIterator.getCharacterInstance(Locale.ROOT)
        it.setText(s)
        return it.isBoundary(index)
    }

    fun hasPrefix(s: String, p: String): Boolean = s.startsWith(p) && isBoundary(s, p.length)

    fun hasSuffix(s: String, p: String): Boolean = s.endsWith(p) && isBoundary(s, s.length - p.length)

    /** First Character, or null. */
    fun first(s: String): String? = chars(s).firstOrNull()

    /** `String(s.prefix(n))`: the first n Characters. */
    fun prefix(s: String, n: Int): String {
        if (n <= 0) return ""
        val cs = chars(s)
        return if (n >= cs.size) s else cs.subList(0, n).joinToString("")
    }

    /** `String(s.dropFirst(n))`: n Characters. */
    fun dropFirst(s: String, n: Int = 1): String {
        if (n <= 0) return s
        val cs = chars(s)
        return if (n >= cs.size) "" else cs.subList(n, cs.size).joinToString("")
    }

    /** `String(s.dropLast(n))`: n Characters. */
    fun dropLast(s: String, n: Int = 1): String {
        val cs = chars(s)
        return if (n >= cs.size) "" else cs.subList(0, cs.size - n).joinToString("")
    }

    /** Code-unit index of the first Character equal to [ch], or -1 (`firstIndex(of:)`). */
    fun firstIndexOf(s: String, ch: String): Int {
        var at = 0
        for (c in chars(s)) {
            if (c == ch) return at
            at += c.length
        }
        return -1
    }

    /** True when some Character of [s] equals [ch] (`s.contains(Character)`). */
    fun containsChar(s: String, ch: String): Boolean = firstIndexOf(s, ch) >= 0

    /** `s.split(separator: ch)`: Character-wise, empty pieces dropped. */
    fun splitOmittingEmpty(s: String, ch: String): List<String> {
        val out = ArrayList<String>()
        val cur = StringBuilder()
        for (c in chars(s)) {
            if (c == ch) { if (cur.isNotEmpty()) { out.add(cur.toString()); cur.setLength(0) } } else cur.append(c)
        }
        if (cur.isNotEmpty()) out.add(cur.toString())
        return out
    }

    /** `s.drop(while:)` over Characters, joined back. */
    fun dropWhile(s: String, pred: (String) -> Boolean): String = chars(s).dropWhile(pred).joinToString("")

    // MARK: Foundation character sets (scalar based)

    /**
     * `CharacterSet.whitespaces`. Not just Zs and tab: Foundation's set also
     * holds U+200B (zero width space). Read off the real set (all scalars probed).
     */
    fun isWhitespace(cp: Int): Boolean =
        cp == 0x09 || cp == 0x20 || cp == 0xA0 || cp == 0x1680 || cp in 0x2000..0x200B || cp == 0x202F || cp == 0x205F || cp == 0x3000

    /** `CharacterSet.whitespacesAndNewlines`: the above, U+000A to U+000D, U+0085, U+2028 and U+2029. */
    fun isWhitespaceOrNewline(cp: Int): Boolean =
        isWhitespace(cp) || cp in 0x0A..0x0D || cp == 0x85 || cp == 0x2028 || cp == 0x2029

    private fun trim(s: String, drop: (Int) -> Boolean): String {
        var start = 0
        var end = s.length
        while (start < end) {
            val cp = s.codePointAt(start)
            if (!drop(cp)) break
            start += Character.charCount(cp)
        }
        while (end > start) {
            val cp = s.codePointBefore(end)
            if (!drop(cp)) break
            end -= Character.charCount(cp)
        }
        return s.substring(start, end)
    }

    /** `trimmingCharacters(in: .whitespacesAndNewlines)`. */
    fun trimWsNl(s: String): String = trim(s, ::isWhitespaceOrNewline)

    /** `trimmingCharacters(in: .whitespaces)`. */
    fun trimWs(s: String): String = trim(s, ::isWhitespace)

    /** `trimmingCharacters(in: CharacterSet(charactersIn: set))`. */
    fun trimIn(s: String, set: String): String {
        val cps = HashSet<Int>()
        var i = 0
        while (i < set.length) { val cp = set.codePointAt(i); cps.add(cp); i += Character.charCount(cp) }
        return trim(s) { it in cps }
    }

    /** `Unicode.Scalar.Properties.isWhitespace` (the White_Space property): what Swift's `Character.isWhitespace` tests. */
    fun isUnicodeWhitespace(cp: Int): Boolean =
        cp in 0x09..0x0D || cp == 0x20 || cp == 0x85 || cp == 0xA0 || cp == 0x1680 || cp in 0x2000..0x200A ||
            cp == 0x2028 || cp == 0x2029 || cp == 0x202F || cp == 0x205F || cp == 0x3000

    /** `CharacterSet.newlines`: U+000A to U+000D, U+0085, U+2028, U+2029. */
    fun isNewline(cp: Int): Boolean = cp in 0x0A..0x0D || cp == 0x85 || cp == 0x2028 || cp == 0x2029

    // MARK: Character properties (on a Character given as a String)

    private fun firstScalar(g: String): Int = if (g.isEmpty()) 0 else g.codePointAt(0)

    /** `Character.isNumber`. */
    fun isNumber(g: String): Boolean {
        val t = Character.getType(firstScalar(g))
        return t == Character.DECIMAL_DIGIT_NUMBER.toInt() || t == Character.LETTER_NUMBER.toInt() || t == Character.OTHER_NUMBER.toInt()
    }

    /** `Character.isLetter` (alphabetic). */
    fun isLetter(g: String): Boolean = Character.isAlphabetic(firstScalar(g))

    /** `Character.isASCII`. */
    fun isASCII(g: String): Boolean = g.length == 1 && g[0].code < 0x80 || g == "\r\n"

    /** `Character.isUppercase`. */
    fun isUppercase(g: String): Boolean = Character.isUpperCase(firstScalar(g))

    /** `(path as NSString).lastPathComponent`. */
    fun lastPathComponent(path: String): String {
        if (path.isEmpty()) return ""
        var end = path.length
        while (end > 0 && path[end - 1] == '/') end--
        if (end == 0) return "/"
        val start = path.lastIndexOf('/', end - 1) + 1
        return path.substring(start, end)
    }
}

/**
 * Regular expressions with the Unicode meaning of `\b`, `\s`, `\d` and `\w` that ICU gives Swift's
 * `range(of:options: .regularExpression)`. Android's own regex engine is ICU and already means that (and refuses
 * the UNICODE_CHARACTER_CLASS flag); the JVM's needs the flag, so unit tests compile with it.
 */
internal object Rx {
    fun compile(regex: String): java.util.regex.Pattern =
        try {
            java.util.regex.Pattern.compile(regex, java.util.regex.Pattern.UNICODE_CHARACTER_CLASS)
        } catch (_: IllegalArgumentException) {
            java.util.regex.Pattern.compile(regex)
        }
}
