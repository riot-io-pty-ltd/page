package app.page.android.model

/**
 * The golden-row comparison shared by the JVM unit test and the instrumented test (which runs the same rows on
 * Android's own regex engine, where `Rx` cannot ask for Unicode character classes). Test code only.
 */
object ReversibilityGoldenCheck {
    class Result(val rows: Int, val mismatches: List<String>)

    fun unescape(s: String): String {
        val out = StringBuilder()
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c != '\\') { out.append(c); i++; continue }
            when (s[i + 1]) {
                '\\' -> { out.append('\\'); i += 2 }
                'n' -> { out.append('\n'); i += 2 }
                'r' -> { out.append('\r'); i += 2 }
                't' -> { out.append('\t'); i += 2 }
                'u' -> {
                    val end = s.indexOf('}', i)
                    out.appendCodePoint(s.substring(i + 3, end).toInt(16))
                    i = end + 1
                }
                else -> { out.append(c); i++ }
            }
        }
        return out.toString()
    }

    fun run(text: String): Result {
        val mismatches = ArrayList<String>()
        var rows = 0
        for (line in text.split("\n")) {
            if (line.isEmpty()) continue
            val f = line.split("\t")
            if (f.size < 5) continue
            rows++
            val context = unescape(f[0])
            val cwd = if (f[1] == "<nil>") null else unescape(f[1])
            val v = Reversibility.classify(context, cwd)
            val got = listOf(v.level.name, v.tags.joinToString("|") { it.raw }, v.reason)
            val want = listOf(f[2], f[3], unescape(f[4]))
            if (got != want) mismatches.add("${f[0].take(120)} [cwd ${f[1]}]\n   want $want\n   got  $got")
        }
        return Result(rows, mismatches)
    }
}
