package app.page.android.model

// Kotlin port of `ShellParse` at the end of iOS/Page/Models/Reversibility.swift
// (itself a mirror of the Mac's classifier). Keep it diffable against the Swift:
// same function order and names. Differences are only Kotlin spelling and the
// Swift String semantics in SwiftString.kt (Characters are grapheme clusters).

/**
 * A small shell tokenizer, enough to find every command in a line: it splits
 * on `&&`, `||`, `;`, `|`, `&` and newlines, honours quotes and escapes,
 * pulls `$( )`, backticks and process substitutions out as separate
 * commands, notices output redirects (other than to /dev/null or a file
 * descriptor), and sets heredoc bodies aside. Not a full parser; where it
 * is unsure the classifier lands on `.considered`.
 */
object ShellParse {
    data class Segment(
        val words: List<String>,
        val writes: Boolean,
        val afterPipe: Boolean,
        val hasHeredoc: Boolean,
        val heredocBodies: List<String>,
    )

    data class Parsed(
        val segments: List<Segment>,
        val substitutions: List<String>,
        /** A heredoc whose body is shell or SQL text for an interpreter. */
        val interpreterHeredocBodies: List<String>,
        /**
         * Something the parser cannot read the way the shell does, so it can
         * never be `.undoable`: a heredoc body with `$(` or a backtick, a heredoc
         * that never reaches its delimiter line, or an ANSI-C (`$'...'`) or
         * locale (`$"..."`) quoted word, whose escapes can spell any command.
         */
        val hasOpaqueHeredoc: Boolean,
    )

    private val interpreters: Set<String> = setOf(
        "sh", "bash", "zsh", "dash", "ksh", "python", "python3", "node", "ruby", "perl", "php", "psql", "mysql",
        "sqlite3", "mongosh", "redis-cli", "ssh", "deno", "mariadb",
    )

    /** The Characters that end a redirect target word: " \t\n;&|<>()". */
    private val targetEnders: Set<String> = " \t\n;&|<>()".map { it.toString() }.toSet()

    /** What a backslash escapes inside double quotes: `$`, a backtick, `"`, `\` and a newline. */
    private val doubleQuoteEscapable: Set<String> = setOf("$", "`", "\"", "\\", "\n")

    fun parse(input: String): Parsed {
        // "\r\n" is one Character to Swift but two bytes to the shell, where the "\n" ends the command.
        val chars = Sw.chars(input.replace("\r\n", "\n"))
        val n = chars.size
        var i = 0
        val segments = ArrayList<Segment>()
        val subs = ArrayList<String>()
        val bodies = ArrayList<String>()
        val interpreterBodies = ArrayList<String>()
        var opaque = false

        var words = ArrayList<String>()
        var cur = StringBuilder()
        var inWord = false
        var writes = false
        var heredoc = false
        var segBodies = ArrayList<String>()
        var segAfterPipe = false
        var pendingDelims = ArrayList<String>()

        fun endWord() {
            if (inWord) { words.add(cur.toString()); cur = StringBuilder(); inWord = false }
        }
        fun endSegment(nextAfterPipe: Boolean) {
            endWord()
            if (words.isNotEmpty() || writes) {
                segments.add(Segment(words.toList(), writes, segAfterPipe, heredoc, segBodies.toList()))
                val head = words.firstOrNull()?.let { Sw.lastPathComponent(it).lowercase() }
                if (heredoc && head != null &&
                    (head in interpreters || words.any { Sw.lastPathComponent(it).lowercase() in interpreters })
                ) {
                    interpreterBodies.addAll(segBodies)
                }
            }
            words = ArrayList(); writes = false; heredoc = false; segBodies = ArrayList()
            segAfterPipe = nextAfterPipe
        }

        /**
         * The raw text of an ANSI-C string (`$'...'`) whose opening quote is at `start`, and the
         * index after its closing quote. A backslash takes the next character, a quote included.
         */
        fun ansiC(start: Int): Pair<String, Int> {
            var j = start + 1
            val inner = StringBuilder()
            while (j < n && chars[j] != "'") {
                if (chars[j] == "\\" && j + 1 < n) { inner.append(chars[j]); inner.append(chars[j + 1]); j += 2; continue }
                inner.append(chars[j]); j += 1
            }
            return Pair(inner.toString(), minOf(n, j + 1))
        }
        /** Text between a balanced "(" at `start` and its ")", and the index after it. */
        fun balanced(start: Int): Pair<String, Int> {
            var depth = 0
            var j = start
            val inner = StringBuilder()
            var single = false
            var double = false
            while (j < n) {
                val c = chars[j]
                if (c == "\\" && j + 1 < n && !single) { inner.append(c); inner.append(chars[j + 1]); j += 2; continue }
                if (c == "$" && j + 1 < n && chars[j + 1] == "'" && !single && !double) { // ANSI-C: a backslash can escape the closing quote
                    val (text, after) = ansiC(j + 1)
                    inner.append("$'"); inner.append(text); inner.append("'")
                    j = after
                    continue
                }
                if (c == "'" && !double) single = !single
                else if (c == "\"" && !single) double = !double
                else if (!single && !double) {
                    if (c == "(") { depth += 1; if (depth == 1) { j += 1; continue } }
                    else if (c == ")") { depth -= 1; if (depth == 0) return Pair(inner.toString(), j + 1) }
                }
                inner.append(c)
                j += 1
            }
            return Pair(inner.toString(), n)
        }
        fun backtick(start: Int): Pair<String, Int> {
            var j = start + 1
            val inner = StringBuilder()
            while (j < n && chars[j] != "`") {
                if (chars[j] == "\\" && j + 1 < n) { inner.append(chars[j + 1]); j += 2; continue }
                inner.append(chars[j]); j += 1
            }
            return Pair(inner.toString(), minOf(n, j + 1))
        }
        /**
         * The word after a redirect operator, or the delimiter after `<<` / `<<-`, with the
         * shell's quote removal applied anywhere in it: `E"OF"`, `'E'OF`, `E\OF` and `"EOF"` all
         * read `EOF`, and `x'a b'` or `"a\" b"` stay one word. A `$'...'` or `$"..."` part makes the
         * parse opaque. A word that holds `$(`, a backtick or `<(` is not read here: it is left for
         * the main loop so the command inside is classified (the returned word is then empty).
         */
        fun readTarget(start: Int): Pair<String, Int> {
            var j = start
            while (j < n && (chars[j] == " " || chars[j] == "\t")) j += 1
            val word = StringBuilder()
            while (j < n && chars[j] !in targetEnders) {
                val ch = chars[j]
                if (ch == "\\") {
                    if (j + 1 < n) { if (chars[j + 1] != "\n") word.append(chars[j + 1]); j += 2 } else { j += 1 }
                } else if (ch == "'") {
                    j += 1
                    while (j < n && chars[j] != "'") { word.append(chars[j]); j += 1 }
                    j += 1
                } else if (ch == "\"") {
                    val open = j
                    j += 1
                    while (j < n && chars[j] != "\"") {
                        if (chars[j] == "`" || (chars[j] == "$" && j + 1 < n && chars[j + 1] == "(")) return Pair("", open)
                        if (chars[j] == "\\" && j + 1 < n && chars[j + 1] in doubleQuoteEscapable) {
                            if (chars[j + 1] != "\n") word.append(chars[j + 1])
                            j += 2; continue
                        }
                        word.append(chars[j]); j += 1
                    }
                    j += 1
                } else if (ch == "$" && j + 1 < n && chars[j + 1] == "'") { // ANSI-C
                    opaque = true
                    val (inner, after) = ansiC(j + 1)
                    word.append(inner); j = after
                } else if (ch == "$" && j + 1 < n && chars[j + 1] == "\"") { // `$"..."`
                    opaque = true
                    j += 1
                } else if (ch == "`" || (ch == "$" && j + 1 < n && chars[j + 1] == "(")) {
                    return Pair("", j)
                } else {
                    word.append(ch); j += 1
                }
            }
            return Pair(word.toString(), minOf(n, j))
        }

        while (i < n) {
            val c = chars[i]
            val next: String? = if (i + 1 < n) chars[i + 1] else null

            if (c == "\\") {
                if (next != null) { if (next != "\n") { cur.append(next); inWord = true }; i += 2 } else { i += 1 }
                continue
            }
            if (c == "$" && next == "'") { // ANSI-C quoting: `$'\x72m'` is `rm`, so the word is opaque
                inWord = true; opaque = true
                val (inner, after) = ansiC(i + 1)
                cur.append(inner); i = after
                continue
            }
            if (c == "$" && next == "\"") { opaque = true; i += 1; continue } // `$"..."`: the double-quote branch reads the rest
            if (c == "'") {
                inWord = true
                i += 1
                while (i < n && chars[i] != "'") { cur.append(chars[i]); i += 1 }
                i += 1
                continue
            }
            if (c == "\"") {
                inWord = true
                i += 1
                while (i < n && chars[i] != "\"") {
                    if (chars[i] == "\\" && i + 1 < n) { cur.append(chars[i + 1]); i += 2; continue }
                    if (chars[i] == "$" && i + 1 < n && chars[i + 1] == "(") {
                        val (inner, after) = balanced(i + 1)
                        subs.add(inner); cur.append("\$SUB"); i = after; continue
                    }
                    if (chars[i] == "`") {
                        val (inner, after) = backtick(i)
                        subs.add(inner); cur.append("\$SUB"); i = after; continue
                    }
                    cur.append(chars[i]); i += 1
                }
                i += 1
                continue
            }
            if (c == "$" && next == "(") {
                if (i + 2 < n && chars[i + 2] == "(") { // arithmetic
                    val (inner, after) = balanced(i + 1)
                    // Arithmetic is not a command, but it can hold one: $(( $(rm x) )).
                    if (inner.contains("$(") || inner.contains("`")) subs.add(inner)
                    cur.append("0"); inWord = true; i = after
                } else {
                    val (inner, after) = balanced(i + 1)
                    subs.add(inner); cur.append("\$SUB"); inWord = true; i = after
                }
                continue
            }
            if (c == "`") {
                val (inner, after) = backtick(i)
                subs.add(inner); cur.append("\$SUB"); inWord = true; i = after
                continue
            }
            if ((c == "<" || c == ">") && next == "(") {
                val (inner, after) = balanced(i + 1)
                subs.add(inner); cur.append("\$SUB"); inWord = true; i = after
                continue
            }
            if (c == "#" && !inWord) {
                while (i < n && chars[i] != "\n") i += 1
                continue
            }
            if (c == " " || c == "\t") { endWord(); i += 1; continue }
            if (c == "\n") {
                i += 1
                // A heredoc body runs to its delimiter line.
                for (delim in pendingDelims) {
                    val body = ArrayList<String>()
                    var closed = false
                    while (i < n) {
                        val line = StringBuilder()
                        while (i < n && chars[i] != "\n") { line.append(chars[i]); i += 1 }
                        i += 1
                        if (Sw.trimWs(line.toString()) == delim) { closed = true; break }
                        body.add(line.toString())
                    }
                    val text = body.joinToString("\n")
                    segBodies.add(text); bodies.add(text)
                    if (text.contains("$(") || text.contains("`")) opaque = true
                    // No delimiter line: the shell may read the rest of the input as commands (or the
                    // delimiter was misread), so the swallowed text is opaque and is judged as commands too.
                    if (!closed) { opaque = true; if (text.isNotEmpty()) subs.add(text) }
                }
                pendingDelims = ArrayList()
                endSegment(nextAfterPipe = false)
                continue
            }
            if (c == ";") { endSegment(nextAfterPipe = false); i += 1; continue }
            if (c == "&") {
                if (next == "&") { endSegment(nextAfterPipe = false); i += 2; continue }
                if (next == ">") { i += 1; continue } // &> file; the ">" below judges the target (/dev/null is not a write)
                endSegment(nextAfterPipe = false); i += 1; continue
            }
            if (c == "|") {
                if (next == "|") { endSegment(nextAfterPipe = false); i += 2; continue }
                if (next == "&") { endSegment(nextAfterPipe = true); i += 2; continue }
                endSegment(nextAfterPipe = true); i += 1; continue
            }
            if (c == ">") {
                if (inWord && Sw.chars(cur.toString()).all { Sw.isNumber(it) }) { cur = StringBuilder(); inWord = false } // "2>" is not a word
                i += 1
                if (i < n && chars[i] == ">") i += 1
                if (i < n && chars[i] == "|") i += 1
                if (i < n && chars[i] == "&") { // 2>&1 duplicates a descriptor; >&file writes a file
                    i += 1
                    val (dup, after) = readTarget(i)
                    i = after
                    if (dup.isEmpty() || (!(Sw.chars(dup).all { Sw.isNumber(it) } || dup == "-") && dup != "/dev/null")) writes = true
                    continue
                }
                val (target, after) = readTarget(i)
                i = after
                if (target != "/dev/null") writes = true
                continue
            }
            if (c == "<") {
                if (next == "<") {
                    if (i + 2 < n && chars[i + 2] == "<") { i += 3; continue } // here-string
                    i += 2
                    if (i < n && chars[i] == "-") i += 1
                    val (delim, after) = readTarget(i)
                    i = after
                    // A quoted delimiter (`<<\EOF`, `<<'EOF'`, `<<E"OF"`) names the same end line as a bare one.
                    pendingDelims.add(delim)
                    heredoc = true
                    continue
                }
                i += 1
                val (_, after) = readTarget(i) // input redirect: the file is not an argument
                i = after
                continue
            }
            cur.append(c)
            inWord = true
            i += 1
        }
        endSegment(nextAfterPipe = false)
        return Parsed(segments, subs, interpreterBodies, opaque)
    }
}
