package app.page.android.model

import java.util.regex.Pattern

// Kotlin port of iOS/Page/Models/Reversibility.swift (which mirrors the Mac's
// classifier, Sources/ClaudePowerMode/UI/Reversibility.swift). The phone only
// ever sees a page's `context` text, so it runs the same classifier on it: the
// same page gets the same chip on the Mac, on the iPhone and here. It is
// conservative: only a command recognised as read-only, test or build is
// UNDOABLE; anything it cannot read is at least CONSIDERED.
//
// Keep it diffable against the Swift: same function order, same names, same
// strings. Differences are only Kotlin spelling and Swift String semantics
// (Characters are grapheme clusters; trimming uses Foundation's character
// sets), which SwiftString.kt supplies. The one function not ported is the
// private `endsOpen`, which nothing in the Swift calls.
//
// `android/tools/reversibility-golden.sh` runs the Swift original over a large
// corpus and writes `app/src/test/resources/reversibility-golden.tsv`; the
// Kotlin test requires an exact match on every row.
//
// Phone-side use goes through `PhoneReversibility` (NightWatchRows.kt), which
// decides which pages are classified at all.

/** The Mac clips a page's `context` to this many characters before it goes on the wire. */
object InterventionDetector {
    const val contextLimit = 1500
}

/**
 * How hard a pending tool call is to take back. Drives the shape of a Decide
 * row, which keys it offers, and the chip on it (v4 trust model, section 4).
 *
 * Conservative by construction: only a command Page positively recognises as
 * read-only, test or build is UNDOABLE. Anything it cannot read, parse or
 * place is at least CONSIDERED; destructive deletes, force pushes, dropped
 * data, deploys and publishes, `sudo` and `curl | sh` are IRREVERSIBLE. A
 * chip is a hint, never a "safe" badge.
 */
enum class Reversibility(val raw: Int) {
    UNDOABLE(0),
    CONSIDERED(1),
    IRREVERSIBLE(2);

    /** Short reason tags shown next to (and sent with) the class. */
    enum class Tag(val raw: String) {
        READ_ONLY("Read-only"),
        EDITS_IN_REPO("Edits in repo"),
        RUNS_COMMANDS("Runs commands"),
        NETWORK_OUTSIDE("Network/outside repo"),
        DESTRUCTIVE("Destructive"),
    }

    data class Verdict(val level: Reversibility, val tags: List<Tag>, val reason: String) {
        companion object {
            fun combine(a: Verdict, b: Verdict): Verdict {
                val tags = a.tags.toMutableList()
                for (t in b.tags) if (t !in tags) tags.add(t)
                // The reason that explains the worse class wins; ties keep the first.
                return Verdict(maxOf(a.level, b.level), tags, if (b.level > a.level) b.reason else a.reason)
            }
        }
    }

    companion object {
        // MARK: entry points

        /**
         * Pure. Classifies a tool call from its structured input, the way the
         * agent made it: [toolName] and the full, unredacted, unclipped [input]
         * (`command` for Bash, never its `description`; `file_path` /
         * `notebook_path` for the file tools). A page's display text is redacted,
         * clipped and carries the description as a second line, none of which
         * [classify] (context) can undo. [cwd] is the session's project directory.
         */
        fun classify(toolName: String, input: Map<String, Any?>, cwd: String?): Verdict {
            fun string(key: String): String? = input[key] as? String
            if (toolName == "Bash") {
                val command = string("command")
                if (command == null || Sw.trimWsNl(command).isEmpty()) return unknown("no command shown")
                val v = classifyBash(command, 0)
                // Running outside the sandbox is never routine.
                if (v.level < CONSIDERED && flag(input["dangerouslyDisableSandbox"])) {
                    return Verdict(CONSIDERED, v.tags, "runs outside the sandbox")
                }
                return v
            }
            val path = string("file_path") ?: string("notebook_path") ?: ""
            return classifyTool(toolName, path, cwd)
        }

        /** Pure. Several tool calls waiting at once (parallel calls): the worst of them. Null for no calls. */
        fun classify(calls: List<Pair<String, Map<String, Any?>>>, cwd: String?): Verdict? {
            val verdicts = calls.map { classify(it.first, it.second, cwd) }
            val first = verdicts.firstOrNull() ?: return null
            return verdicts.drop(1).fold(first) { a, b -> Verdict.combine(a, b) }
        }

        /** The fields of a tool call's input that [classify] reads, as strings (a bool becomes "true"). */
        fun classifierFields(@Suppress("UNUSED_PARAMETER") toolName: String, input: Map<String, Any?>): Map<String, String> {
            val out = LinkedHashMap<String, String>()
            for (key in listOf("command", "file_path", "notebook_path")) {
                (input[key] as? String)?.let { out[key] = it }
            }
            if (flag(input["dangerouslyDisableSandbox"])) out["dangerouslyDisableSandbox"] = "true"
            return out
        }

        private fun flag(value: Any?): Boolean {
            if (value is Boolean) return value
            if (value is String) return value.lowercase() == "true"
            return false
        }

        /**
         * Pure. Classifies what a page's `context` shows. `context` is the text
         * `InterventionDetector.describeToolUse` writes ("[Bash] cmd\ndescription",
         * "[Edit] path ...", "One of these is waiting for approval:\n• ..."), the
         * hook's "$ cmd\n# description" (see [classifyHookBash]), or the hook's
         * bare "Claude is waiting for your approval", which says nothing about
         * the action and is therefore CONSIDERED. A page with several tool calls
         * takes the worst of them. [cwd] is the session's project directory, used
         * to tell edits inside it from edits outside.
         *
         * A conservative fallback for a page that carries no stored verdict:
         * the text is display text (redacted, clipped, description appended), so
         * a call is never UNDOABLE when it was clipped, redacted or spans lines.
         */
        fun classify(context: String, cwd: String?): Verdict {
            val text = Sw.trimWsNl(context)
            val multiHeader = "One of these is waiting for approval:"
            var v: Verdict
            if (Sw.hasPrefix(text, multiHeader)) {
                val body = text.substring(multiHeader.length)
                val entries = body.split("\n• ")
                    .map { Sw.trimWsNl(it) }
                    .map { if (Sw.hasPrefix(it, "• ")) it.substring(2) else it }
                    .filter { it.isNotEmpty() }
                if (entries.isEmpty()) return unknown("no tool call to read")
                val verdicts = entries.map { classifyEntry(it, cwd) }
                v = verdicts.drop(1).fold(verdicts[0]) { a, b -> Verdict.combine(a, b) }
            } else if (Sw.hasPrefix(text, "$ ")) {
                v = classifyHookBash(text)
            } else {
                v = classifyEntry(text, cwd)
            }
            // A page that reached the length limit was cut somewhere.
            if (Sw.count(text) >= InterventionDetector.contextLimit && v.level < CONSIDERED) {
                v = Verdict(CONSIDERED, v.tags, "the command was cut short")
            }
            return v
        }

        /**
         * A page posted by hooks/page-notify.sh shows a Bash call as
         * `"$ <command>\n# <description>"` (the command clipped at 1200 characters
         * with "…", the whole text redacted), then maybe a "— recent activity —"
         * tail. The command is every line from the `$ ` up to the description's
         * `# ` line or the tail, so a command that spans lines, or a second `$ `
         * line, is judged whole; the description and the tail are ignored. The
         * text can only ever raise the verdict to IRREVERSIBLE: it is never
         * UNDOABLE, since a hook row is a page to answer, not a command to wave
         * through, and a clipped, redacted or longer text may hide what runs.
         */
        private fun classifyHookBash(text: String): Verdict {
            var head = text.replace("\r\n", "\n")
            // The last marker: a command that quotes the marker must not hide what follows it.
            val tail = head.lastIndexOf("\n\n— recent activity —")
            if (tail >= 0) head = head.substring(0, tail)
            val lines = head.split("\n").toMutableList()
            lines[0] = lines[0].substring(2)
            val end = (1 until lines.size).firstOrNull { Sw.hasPrefix(lines[it], "# ") || lines[it] == "#" }
            if (end != null) while (lines.size > end) lines.removeAt(lines.size - 1)
            val raw = lines.joinToString("\n")
            val command = Sw.trimWsNl(raw)
            if (command.isEmpty() || command == "(no command)") return unknown("no command shown")
            val v = classifyBash(command, 0)
            if (v.level >= CONSIDERED) return v
            val why: String = if (Sw.hasSuffix(command, "…") || Sw.count(raw) >= InterventionDetector.contextLimit) "the command was cut short"
            else if (command.contains("[redacted")) "part of the command was hidden"
            else if (command.contains("\n")) "more than one line of command"
            else "a hook page's command isn't confirmed"
            return Verdict(CONSIDERED, v.tags, why)
        }

        /** Pure. Classifies a shell command line the way Claude's Bash tool would run it. Empty input is CONSIDERED. */
        fun classifyBash(command: String): Verdict = classifyBash(command, 0)

        // MARK: one tool call

        private fun classifyEntry(entry: String, cwd: String?): Verdict {
            val v = classifyEntryCore(entry, cwd)
            if (v.level >= CONSIDERED) return v
            val text = Sw.trimWsNl(entry)
            // A page's text is clipped to a fixed length ("…"): whatever was cut
            // off might be the dangerous part, so a clipped call is never Undoable.
            if (Sw.hasSuffix(text, "…") || Sw.count(text) >= InterventionDetector.contextLimit) {
                return Verdict(CONSIDERED, v.tags, "the command was cut short")
            }
            // Secrets are masked in the text; the masked part is not what runs,
            // and a mask can swallow the clip marker above.
            if (text.contains("[redacted")) {
                return Verdict(CONSIDERED, v.tags, "part of the command was hidden")
            }
            return v
        }

        private fun classifyEntryCore(entry: String, cwd: String?): Verdict {
            var text = entry
            if (Sw.hasPrefix(text, "A subagent is asking for approval")) {
                return Verdict(CONSIDERED, listOf(Tag.RUNS_COMMANDS), "a subagent is asking; its action isn't shown")
            }
            if (Sw.hasPrefix(text, "Plan ready for review")) {
                return Verdict(CONSIDERED, emptyList(), "plan approval")
            }
            val close = Sw.firstIndexOf(text, "]")
            if (!Sw.hasPrefix(text, "[") || close < 0) {
                return unknown("the action isn't shown")
            }
            val name = text.substring(1, close)
            text = Sw.trimIn(text.substring(close + 1), " ")
            val lines = text.split("\n")
            val first = Sw.trimWs(lines.firstOrNull() ?: "")

            if (name == "Bash") {
                return classifyBashTool(first, lines.drop(1))
            }
            // MultiEdit's line reads "path (3 edits)".
            val path = if (name in listOf("Edit", "MultiEdit", "Write", "NotebookEdit")) (first.split(" (").firstOrNull() ?: first) else first
            return classifyTool(name, path, cwd)
        }

        /**
         * Every tool but Bash, from its name and the path it works on (empty when
         * it has none). Shared by the structured and the text entry points so
         * they cannot disagree.
         */
        private fun classifyTool(name: String, path: String, cwd: String?): Verdict {
            when (name) {
                "Read", "Glob", "Grep", "LS", "NotebookRead" -> {
                    // Reading never changes anything; outside the project it can still
                    // be a surprise, so it is not offered the Return shortcut.
                    if (name == "Read" && !isInside(path, cwd)) {
                        return Verdict(CONSIDERED, listOf(Tag.NETWORK_OUTSIDE), "reads outside the project")
                    }
                    return Verdict(Reversibility.UNDOABLE, listOf(Tag.READ_ONLY), "read-only")
                }
                "Edit", "MultiEdit", "Write", "NotebookEdit" -> {
                    if (isInside(path, cwd)) {
                        return Verdict(CONSIDERED, listOf(Tag.EDITS_IN_REPO), "edits a file in the project")
                    }
                    return Verdict(CONSIDERED, listOf(Tag.NETWORK_OUTSIDE), "edits a file outside the project")
                }
                "WebFetch", "WebSearch" ->
                    return Verdict(CONSIDERED, listOf(Tag.NETWORK_OUTSIDE), "reaches the network")
                "Task", "Agent" ->
                    return Verdict(CONSIDERED, listOf(Tag.RUNS_COMMANDS), "starts a subagent")
                else ->
                    return Verdict(CONSIDERED, listOf(Tag.RUNS_COMMANDS), "$name isn't one Page can read")
            }
        }

        private fun unknown(why: String): Verdict = Verdict(CONSIDERED, emptyList(), why)

        /**
         * The context is `"[Bash] <command>\n<description>"`, but a command can
         * itself span lines and the description is joined with a bare newline, so
         * the two cannot be told apart reliably (and on a case-insensitive volume
         * a capitalised "description" such as `Find . -delete` really runs).
         * Every line is therefore judged as command text, and a call with more
         * than one line is never UNDOABLE.
         */
        private fun classifyBashTool(first: String, rest: List<String>): Verdict {
            val extra = rest.map { Sw.trimWs(it) }.filter { it.isNotEmpty() }
            if (first.isEmpty() || first == "(no command)") return unknown("no command shown")
            var v = classifyBash((listOf(first) + extra).joinToString("\n"), 0)
            if (extra.isNotEmpty() && v.level < CONSIDERED) {
                v = Verdict(CONSIDERED, v.tags, "more than one line; a description can't be told from a command")
            }
            return v
        }

        private fun isInside(raw: String, cwd: String?): Boolean {
            val path = Sw.trimWs(raw)
            if (path.isEmpty() || path == "?") return false
            if (Sw.hasPrefix(path, "~")) return false
            val parts = Sw.splitOmittingEmpty(path, "/")
            if (parts.contains("..")) return false
            if (!Sw.hasPrefix(path, "/")) return true // relative to the project
            if (cwd == null || cwd.isEmpty()) return false
            val base = if (Sw.hasSuffix(cwd, "/")) Sw.dropLast(cwd) else cwd
            return path == base || Sw.hasPrefix(path, "$base/")
        }

        // MARK: shell

        private fun classifyBash(command: String, depth: Int): Verdict {
            val trimmed = Sw.trimWsNl(command)
            if (trimmed.isEmpty()) return unknown("no command shown")
            if (depth >= 4) return Verdict(CONSIDERED, listOf(Tag.RUNS_COMMANDS), "deeply nested command")

            val parsed = ShellParse.parse(trimmed)
            val verdicts = ArrayList<Verdict>()
            var downloaderInPipeline = false

            for (seg in parsed.segments) {
                if (!seg.afterPipe) downloaderInPipeline = false
                var v = classifySegment(seg, depth, seg.afterPipe && downloaderInPipeline)
                if (seg.writes && v.level < CONSIDERED) {
                    v = Verdict(CONSIDERED, listOf(Tag.RUNS_COMMANDS), "writes to a file")
                }
                val cmd = commandName(seg)
                if (cmd != null && cmd in listOf("curl", "wget", "fetch")) downloaderInPipeline = true
                verdicts.add(v)
            }
            for (inner in parsed.substitutions) {
                var v = classifyBash(inner, depth + 1)
                if (v.level < CONSIDERED) v = Verdict(CONSIDERED, v.tags, "runs a nested command")
                verdicts.add(v)
            }
            if (parsed.hasOpaqueHeredoc) {
                verdicts.add(Verdict(CONSIDERED, listOf(Tag.RUNS_COMMANDS), "script passed in as text"))
            }
            for (body in parsed.interpreterHeredocBodies) {
                val why = matchesDestructiveText(body)
                if (why != null) verdicts.add(Verdict(IRREVERSIBLE, listOf(Tag.DESTRUCTIVE), matchesDestructiveText(body) ?: "destructive"))
            }
            var result: Verdict? = null
            for (v in verdicts) result = result?.let { Verdict.combine(it, v) } ?: v
            if (result == null) {
                // Only keywords, comments or assignments: nothing runs.
                return Verdict(Reversibility.UNDOABLE, listOf(Tag.READ_ONLY), "no command")
            }
            var tags = result.tags
            if (result.level == IRREVERSIBLE && Tag.DESTRUCTIVE !in tags) tags = tags + Tag.DESTRUCTIVE
            if (result.level == Reversibility.UNDOABLE && tags.isEmpty()) tags = listOf(Tag.READ_ONLY)
            return Verdict(result.level, tags, result.reason)
        }

        /** The program name of a segment after wrappers, or null. */
        private fun commandName(seg: ShellParse.Segment): String? =
            stripWrappers(seg.words).words.firstOrNull()?.let { baseName(it) }

        private fun baseName(word: String): String = Sw.lastPathComponent(word).lowercase()

        private val noopKeywords: Set<String> = setOf("for", "case", "esac", "fi", "done", "}", ")", "function", "select")
        private val prefixKeywords: Set<String> = setOf("if", "then", "else", "elif", "while", "until", "do", "!", "{", "(", "coproc")

        /** Environment variables that cannot change what a program does or runs. */
        private fun isHarmlessEnvName(name: String): Boolean =
            name in listOf("LANG", "TZ", "NO_COLOR", "TERM", "COLUMNS", "FORCE_COLOR", "CI") || Sw.hasPrefix(name, "LC_")

        /** `NAME=value` as the shell reads a variable assignment. */
        private fun isAssignment(s: String): Boolean {
            val eq = Sw.firstIndexOf(s, "=")
            if (eq <= 0) return false
            val name = Sw.chars(s.substring(0, eq))
            return name.all { Sw.isLetter(it) || Sw.isNumber(it) || it == "_" } && !(name.firstOrNull()?.let { Sw.isNumber(it) } ?: false)
        }

        class Stripped(
            var words: List<String>,
            var elevated: Boolean = false,
            var xargs: Boolean = false,
            /** Every `NAME=value` that was in front of (or after `env` in front of) the command. */
            val assignments: MutableList<String> = ArrayList(),
            /** The wrapper programs that were peeled off ("env", "nohup", "time", ...). */
            val wrappers: MutableList<String> = ArrayList(),
        )

        /**
         * Drops env assignments, shell keywords and wrappers, but remembers what
         * it dropped: the caller judges assignments and wrappers itself.
         */
        private fun stripWrappers(input: List<String>): Stripped {
            val w = input.toMutableList()
            val out = Stripped(emptyList())
            // Leading "(" / "{" glued to the first word.
            if (w.isNotEmpty()) {
                val f = w[0]
                if (Sw.count(f) > 1 && (Sw.hasPrefix(f, "(") || Sw.hasPrefix(f, "{"))) w[0] = Sw.dropFirst(f)
            }
            var guardCount = 0
            while (w.isNotEmpty() && guardCount < 12) {
                val first = w[0]
                guardCount += 1
                val name = baseName(first)
                if (isAssignment(first)) { out.assignments.add(first); w.removeAt(0); continue }
                if (first in prefixKeywords) { w.removeAt(0); continue }
                when (name) {
                    "sudo", "doas", "su", "pkexec" -> {
                        out.elevated = true
                        w.removeAt(0)
                    }
                    "env", "command", "builtin", "exec", "nohup", "caffeinate", "time", "stdbuf", "ionice", "unbuffer" -> {
                        out.wrappers.add(name)
                        w.removeAt(0)
                        while (w.isNotEmpty() && Sw.hasPrefix(w[0], "-")) w.removeAt(0)
                    }
                    "nice" -> {
                        out.wrappers.add(name)
                        w.removeAt(0)
                        while (w.isNotEmpty() && Sw.hasPrefix(w[0], "-")) {
                            val f = w.removeAt(0)
                            if (f == "-n" && w.isNotEmpty()) w.removeAt(0)
                        }
                    }
                    "timeout" -> {
                        out.wrappers.add(name)
                        w.removeAt(0)
                        while (w.isNotEmpty() && Sw.hasPrefix(w[0], "-")) w.removeAt(0)
                        if (w.isNotEmpty()) w.removeAt(0) // the duration
                    }
                    "xargs" -> {
                        out.wrappers.add(name)
                        out.xargs = true
                        w.removeAt(0)
                        val withValue = setOf("-n", "-I", "-P", "-L", "-s", "-d", "-E", "-J", "-a")
                        while (w.isNotEmpty() && Sw.hasPrefix(w[0], "-")) {
                            val f = w.removeAt(0)
                            if (f in withValue && w.isNotEmpty()) w.removeAt(0)
                        }
                    }
                    else -> {
                        out.words = w.toList()
                        return out
                    }
                }
            }
            out.words = w.toList()
            return out
        }

        /**
         * Assignments in front of a command can change what it runs (`LD_PRELOAD`,
         * `GIT_SSH_COMMAND`, `PAGER`, ...). Only a short list of names that cannot
         * is waved through; a value that is itself destructive text is worse.
         */
        private fun assignmentVerdict(assignments: List<String>): Verdict? {
            var result: Verdict? = null
            for (a in assignments) {
                val eq = Sw.firstIndexOf(a, "=")
                if (eq < 0) continue
                val name = a.substring(0, eq)
                val value = a.substring(eq + 1)
                val v: Verdict
                val why = matchesDestructiveText(value)
                if (why != null) {
                    v = destroy(why)
                } else if (isHarmlessEnvName(name)) {
                    continue
                } else {
                    v = considered("sets $name for the command")
                }
                result = result?.let { Verdict.combine(it, v) } ?: v
            }
            return result
        }

        // MARK: segments

        private val textOnly: Set<String> = setOf(
            "ls", "cat", "head", "tail", "less", "more", "wc", "grep", "egrep", "fgrep", "rg", "ag", "ack", "fd", "pwd",
            "echo", "printf", "which", "whereis", "type", "whoami", "id", "date", "uname", "hostname", "printenv", "df",
            "du", "ps", "stat", "file", "tree", "diff", "cmp", "sort", "uniq", "cut", "tr", "jq", "yq", "basename",
            "dirname", "realpath", "readlink", "test", "[", "[[", "true", "false", ":", "sleep", "cd", "pushd", "popd",
            "md5", "md5sum", "shasum", "sha256sum", "sha1sum", "hexdump", "xxd", "strings", "nl", "column", "fold",
            "paste", "comm", "join", "seq", "expr", "tput", "uptime", "sw_vers", "arch", "lsof", "pgrep", "nproc",
            "locale", "set", "unset", "export", "alias", "wait", "read", "exit", "return", "bat", "eza", "exa", "tac",
            "rev", "od", "base64", "git-lfs", "cloc", "tokei", "mdfind", "mdls", "pbpaste", "ioreg", "system_profiler",
        )

        private val shells: Set<String> = setOf("sh", "bash", "zsh", "dash", "ksh", "fish")
        private val scriptInterpreters: Set<String> = setOf("python", "python3", "node", "ruby", "perl", "php", "deno", "bun")
        private val sqlClients: Set<String> = setOf("psql", "mysql", "sqlite3", "mongosh", "mongo", "redis-cli", "mariadb", "usql", "dropdb")
        private val networkCommands: Set<String> = setOf("curl", "wget", "ssh", "scp", "rsync", "sftp", "ftp", "nc", "telnet", "ping")
        private val infraCLIs: Set<String> = setOf(
            "aws", "gcloud", "az", "kubectl", "helm", "terraform", "tofu", "terragrunt", "pulumi", "cdktf", "heroku", "fly", "flyctl", "vercel",
            "netlify", "wrangler", "firebase", "serverless", "sls", "cdk", "supabase", "railway", "doctl", "gh", "docker",
            "podman", "npm", "yarn", "pnpm", "cargo", "gem", "twine", "bun", "hub", "az", "oc", "eb", "sam", "amplify",
        )
        private val destructiveWords: Set<String> = setOf(
            "deploy", "publish", "destroy", "delete", "remove", "rm", "rmi", "rb", "prune", "purge", "terminate", "drop",
            "wipe", "erase", "unpublish", "yank", "undeploy", "teardown", "rollback", "uninstall-all",
        )
        private val readOnlySubcommands: Set<String> = setOf(
            "get", "describe", "list", "ls", "logs", "show", "status", "view", "info", "version", "plan", "validate", "diff",
            "whoami", "ps", "images", "inspect", "top", "explain", "api-resources", "cluster-info", "events", "search",
            "outdated", "config-view", "help", "--version", "-v", "--help", "-h", "fmt", "checks", "watch", "history", "stats",
        )

        private fun classifySegment(seg: ShellParse.Segment, depth: Int, pipedFromDownloader: Boolean): Verdict {
            val stripped = stripWrappers(seg.words)
            // `command -v name` only looks a name up.
            if (seg.words.size == 3 && seg.words[0] == "command" && seg.words[1] in listOf("-v", "-V")) {
                return readOnly("looks up a command")
            }
            var v = classifyCommand(seg, stripped.words, stripped.elevated, depth, pipedFromDownloader)
            // What was peeled off is judged too: the assignments (they can change
            // what the command runs) and the wrappers (they run something else).
            assignmentVerdict(stripped.assignments)?.let { v = Verdict.combine(v, it) }
            if (stripped.wrappers.isNotEmpty() && v.level < CONSIDERED) {
                if (!(stripped.wrappers == listOf("env") && seg.words.size == 1)) {
                    v = Verdict.combine(v, considered("${stripped.wrappers[0]} runs another command"))
                }
            }
            return v
        }

        /**
         * A program started by a path is only trusted from the system's own
         * directories: `./cat` or `/tmp/x/ls` is somebody's script, not `cat`.
         */
        private fun isTrustedPath(head: String): Boolean {
            if (!Sw.containsChar(head, "/")) return true
            val trusted = listOf("/bin/", "/usr/bin/", "/usr/local/bin/", "/opt/homebrew/bin/", "/usr/sbin/", "/sbin/")
            if (trusted.any { Sw.hasPrefix(head, it) && !Sw.containsChar(head.substring(it.length), "/") }) return true
            return head == "./gradlew" || head == "./mvnw"
        }

        private fun classifyCommand(seg: ShellParse.Segment, words: List<String>, elevated: Boolean, depth: Int, pipedFromDownloader: Boolean): Verdict {
            if (elevated) {
                return Verdict(IRREVERSIBLE, listOf(Tag.RUNS_COMMANDS, Tag.DESTRUCTIVE), "runs with sudo")
            }
            val head = words.firstOrNull() ?: return Verdict(Reversibility.UNDOABLE, emptyList(), "no command")
            if (head in noopKeywords) {
                // Closers are only syntax; an opener can carry a whole command
                // (`case x in x) rm -f y;;`, `for x do rm y; done`).
                val openers = setOf("case", "select", "function")
                val rest = words.drop(1)
                if (head in openers || (head == "for" && rest.any { it in prefixKeywords || Sw.hasSuffix(it, ")") })) {
                    return considered("shell $head block")
                }
                return Verdict(Reversibility.UNDOABLE, emptyList(), "shell syntax")
            }
            val cmd = baseName(head)
            val args = words.drop(1)
            if (Sw.hasPrefix(cmd, "mkfs")) return destroy("mkfs formats a disk")
            if (!isTrustedPath(head)) {
                // Still spot destructive names/text behind a path.
                val inner = classifyCommand(seg, listOf(cmd) + args, false, depth, pipedFromDownloader)
                return if (inner.level == IRREVERSIBLE) inner else considered("runs a program by path")
            }

            // Anything piped into a shell from a download runs unseen code.
            if ((cmd in shells || cmd in scriptInterpreters) && pipedFromDownloader && "-c" !in args) {
                return destroy("runs a download unseen")
            }

            when (cmd) {
                "rm", "rmdir", "unlink", "shred", "srm" -> return destroy("$cmd deletes files")
                "dd", "fdisk", "gdisk", "parted", "newfs", "newfs_apfs" -> return destroy("$cmd writes straight to a disk")
                "truncate" -> return destroy("truncate empties files")
                "reboot", "shutdown", "halt", "poweroff" -> return destroy("$cmd stops the Mac")
                "diskutil" -> {
                    val sub = args.firstOrNull()?.lowercase() ?: ""
                    if (sub in listOf("list", "info", "activity")) return readOnly("disk info")
                    if (sub.contains("erase") || sub.contains("partition") || sub.contains("secure") || Sw.hasPrefix(sub, "zero")) {
                        return destroy("diskutil changes disks")
                    }
                    return considered("diskutil")
                }
                "crontab" -> return if ("-r" in args) destroy("removes every cron job") else considered("edits cron")
                "git" -> return classifyGit(args)
                "find" -> return classifyFind(args, depth)
                "sed" -> return classifySed(args)
                "awk", "gawk", "mawk", "nawk" -> return classifyAwk(args)
                "tee" -> return considered("tee writes files")
                "sh", "bash", "zsh", "dash", "ksh", "fish" -> return classifyShellInvocation(cmd, args, depth)
                "eval" -> return combineConsidered(classifyBash(args.joinToString(" "), depth + 1), "eval")
                "source", "." -> return considered("runs a script")
                "python", "python3", "node", "ruby", "perl", "php", "deno" -> return classifyScriptInterpreter(cmd, args)
                "npx", "bunx", "pnpx" -> {
                    // `npx pulumi up` runs the CLI it names: judge that, so it is as irreversible as `pulumi up`.
                    // Anything else it runs is a downloaded program, which is not one Page recognises.
                    val skip = listOf("-y", "--yes", "-q", "--quiet", "--no-install")
                    val named = args.dropWhile { it in skip }
                    val first = named.firstOrNull()
                    if (first != null && !Sw.hasPrefix(first, "-")) {
                        val at = Sw.firstIndexOf(first, "@")
                        val tool = if (at >= 0 && at != 0) first.substring(0, at) else first
                        if (baseName(tool) in infraCLIs) {
                            val v = classifyInfra(baseName(tool), named.drop(1))
                            return if (v.level < CONSIDERED) Verdict(CONSIDERED, v.tags, "$cmd may download $tool") else v
                        }
                    }
                }
                "bundle" -> {
                    if (args.firstOrNull() == "exec" && args.size > 1) {
                        return classifySegment(ShellParse.Segment(args.drop(1), false, false, false, emptyList()), depth, false)
                    }
                    return considered("bundler")
                }
                "ssh" -> return classifySSH(args, depth)
                "rsync" -> {
                    if (args.any { Sw.hasPrefix(it, "--delete") }) return destroy("rsync --delete removes files")
                    return Verdict(CONSIDERED, listOf(Tag.NETWORK_OUTSIDE), "copies files")
                }
                "curl", "wget" -> return Verdict(CONSIDERED, listOf(Tag.NETWORK_OUTSIDE), "reaches the network")
                "swift" -> return classifySwift(args)
                "cargo" -> return classifyCargo(args)
                "go" -> return classifyGo(args)
                "npm", "yarn", "pnpm", "bun" -> return classifyNodePackage(cmd, args)
                "make", "gmake", "ninja", "just", "task" -> return classifyMake(cmd, args)
                "pytest", "py.test", "tox", "nox", "jest", "vitest", "mocha", "ava", "rspec", "phpunit", "mypy", "pylint",
                "flake8", "pyright", "tsc", "swiftlint", "shellcheck", "tflint", "ctest", "bats", "xctest" -> {
                    riskyRunnerOption(cmd, args)?.let { return considered(it) }
                    return Verdict(Reversibility.UNDOABLE, listOf(Tag.RUNS_COMMANDS), "test or lint run")
                }
                "ruff", "eslint", "prettier", "black", "isort", "swiftformat", "gofmt", "rustfmt", "clang-format" -> return classifyFormatter(cmd, args)
                "xcodebuild" -> {
                    val acts = args.toSet()
                    if ("-exportArchive" in acts || "archive" in acts) return considered("xcodebuild archive")
                    // Output paths, config files, provisioning, unvalidated plugins, and
                    // BUILD_SETTING=value overrides (CC=, SWIFT_EXEC=, ...) change what runs or where it writes.
                    val xcodeOptions = listOf(
                        "xcconfig", "resultBundlePath", "resultStreamPath", "archivePath", "exportPath", "exportOptionsPlist",
                        "toolchain", "allowProvisioningUpdates", "allowProvisioningDeviceRegistration", "authenticationKeyPath",
                        "authenticationKeyID", "authenticationKeyIssuerID", "clonedSourcePackagesDirPath", "packageCachePath",
                        "skipPackagePluginValidation", "skipMacroValidation", "xctestrun", "exportLocalizations",
                        "importLocalizations", "exportNotarizedApp", "resolvePackageDependencies", "usePackageSupportBuiltinSCM",
                    )
                    // A project or workspace outside the repo runs its build phases from there; a derived data path outside writes there.
                    if (hasOption(args, xcodeOptions) || args.any { isBuildSettingOverride(it) } || optionPointsOutside(args)) {
                        return considered("xcodebuild option or build setting can change what runs")
                    }
                    if ("build" in acts || "test" in acts || "-list" in acts || "-showBuildSettings" in acts ||
                        "build-for-testing" in acts || "test-without-building" in acts
                    ) {
                        return Verdict(Reversibility.UNDOABLE, listOf(Tag.RUNS_COMMANDS), "build or test")
                    }
                    return considered("xcodebuild")
                }
                "gradle", "gradlew", "mvn", "mvnw", "./gradlew" -> {
                    val ok = setOf(
                        "test", "build", "assemble", "check", "compile", "verify", "dependencies", "tasks",
                        "compilejava", "compilekotlin", "lint", "--version", "-v", "-version", "package",
                    )
                    // Init scripts, build files, properties and plugins can run anything:
                    // only a short list of plain flags is waved through.
                    val harmless = setOf(
                        "q", "quiet", "i", "info", "w", "warn", "s", "stacktrace", "S", "full-stacktrace", "offline", "o",
                        "no-daemon", "daemon", "continue", "parallel", "no-parallel", "build-cache", "no-build-cache",
                        "rerun-tasks", "v", "version", "h", "help", "B", "batch-mode", "e", "errors", "ntp",
                        "no-transfer-progress", "DskipTests", "DskipTests=true", "DskipTests=false", "console=plain",
                        "console=auto", "console=rich", "console=verbose",
                    )
                    val flags = args.filter { Sw.hasPrefix(it, "-") && it != "-" }
                    if (!flags.all { harmless.contains(if (Sw.hasPrefix(it, "--")) Sw.dropFirst(it, 2) else Sw.dropFirst(it)) }) {
                        return considered("build tool option can change what runs")
                    }
                    val isMaven = Sw.hasPrefix(cmd, "mvn")
                    val targets = args.filter { !Sw.hasPrefix(it, "-") }.map { it.lowercase() }
                    if (isMaven && targets.any { it.contains(":") }) return considered("maven plugin goal")
                    if (targets.isNotEmpty() && targets.all { it in ok || (it.split(":").lastOrNull() ?: "") in ok }) {
                        return Verdict(Reversibility.UNDOABLE, listOf(Tag.RUNS_COMMANDS), "build or test")
                    }
                    return considered("build tool")
                }
                "dotnet" -> {
                    val sub = args.firstOrNull() ?: ""
                    if (sub !in listOf("build", "test", "--version", "--info", "list")) return considered("dotnet")
                    // Properties (-p:), targets (-t:), loggers, output paths and settings files run or write things.
                    val dotnetOK = setOf(
                        "no-restore", "no-build", "nologo", "c", "configuration", "v", "verbosity", "f", "framework",
                        "filter", "no-dependencies", "version", "info", "outdated", "vulnerable", "deprecated",
                        "include-transitive", "include-prerelease", "package", "reference",
                    )
                    val odd = args.drop(1).filter { Sw.hasPrefix(it, "-") || Sw.hasPrefix(it, "/") }
                        .any { Sw.trimIn(it, "-/").lowercase() !in dotnetOK }
                    if (odd || positionalPointsOutside(args.drop(1))) return considered("dotnet option can change what runs")
                    return Verdict(Reversibility.UNDOABLE, listOf(Tag.RUNS_COMMANDS), "build or test")
                }
                "rake" -> {
                    // Every argument must be a known test task: `rake test deploy` runs deploy too.
                    return if (args.isNotEmpty() && args.all { it in listOf("test", "spec", "-t", "-T", "--tasks") })
                        Verdict(Reversibility.UNDOABLE, listOf(Tag.RUNS_COMMANDS), "test run") else considered("rake task")
                }
                "brew" -> {
                    val sub = args.firstOrNull() ?: ""
                    return if (sub in listOf("info", "list", "ls", "search", "outdated", "--version", "--prefix", "deps", "config", "leaves", "desc", "doctor"))
                        readOnly("brew query") else Verdict(CONSIDERED, listOf(Tag.NETWORK_OUTSIDE), "brew changes software")
                }
                "pip", "pip3", "pipx", "uv", "poetry" -> {
                    val sub = args.firstOrNull() ?: ""
                    return if (sub in listOf("list", "show", "freeze", "--version", "check", "index", "tree"))
                        readOnly("package query") else Verdict(CONSIDERED, listOf(Tag.NETWORK_OUTSIDE), "changes packages")
                }
                "launchctl", "pmset", "defaults", "scutil", "networksetup", "systemsetup", "csrutil", "nvram" -> {
                    val sub = args.firstOrNull() ?: ""
                    val reads = setOf("list", "print", "-g", "read", "--get", "-getcomputername", "status", "blame", "dumpstate", "version")
                    return if (sub in reads) readOnly("system query") else considered("changes system settings")
                }
                "kill", "pkill", "killall" -> return considered("stops processes")
                "mkdir", "touch", "cp", "mv", "ln", "chmod", "chown", "chgrp", "tar", "unzip", "zip", "gzip", "gunzip", "open",
                "osascript", "trash", "install", "patch", "xattr", "codesign", "plutil", "ditto" -> return considered("$cmd changes files or apps")
                "docker", "podman" -> return classifyInfra(cmd, args)
                else -> Unit
            }

            if (cmd in infraCLIs) return classifyInfra(cmd, args)
            if (cmd in sqlClients) {
                if (cmd == "dropdb") return destroy("dropdb deletes a database")
                val text = args.joinToString(" ")
                matchesDestructiveText(text)?.let { return destroy(it) }
                if (seg.hasHeredoc) {
                    val body = seg.heredocBodies.mapNotNull { matchesDestructiveText(it) }.firstOrNull()
                    if (body != null) return destroy(body)
                }
                return considered("talks to a database")
            }
            if (cmd == "export") assignmentVerdict(args.filter { isAssignment(it) })?.let { return it }
            if (cmd in textOnly) {
                riskyTextToolUse(cmd, args)?.let { return considered(it) }
                return readOnly("read-only command")
            }
            if (cmd in networkCommands) {
                return Verdict(CONSIDERED, listOf(Tag.NETWORK_OUTSIDE), "reaches the network")
            }
            // Unknown program: never undoable. Still, spot destructive text.
            matchesDestructiveText(words.joinToString(" "))?.let { return destroy(it) }
            return considered("$cmd isn't one Page recognises")
        }

        // MARK: helpers for verdicts

        private fun destroy(why: String): Verdict = Verdict(IRREVERSIBLE, listOf(Tag.RUNS_COMMANDS, Tag.DESTRUCTIVE), why)
        private fun considered(why: String): Verdict = Verdict(CONSIDERED, listOf(Tag.RUNS_COMMANDS), why)
        private fun readOnly(why: String): Verdict = Verdict(Reversibility.UNDOABLE, listOf(Tag.READ_ONLY), why)
        private fun combineConsidered(v: Verdict, why: String): Verdict =
            if (v.level >= CONSIDERED) v else Verdict(CONSIDERED, listOf(Tag.RUNS_COMMANDS), why)

        // ICU regular expressions on the Swift side; java.util.regex with
        // UNICODE_CHARACTER_CLASS makes \b, \s, \d and \w mean the same.
        private val destructivePatterns: List<Pair<Pattern, String>> = listOf(
            """\bdrop\s+(table|database|schema|index|view|column|collection)\b""" to "drops data",
            """\btruncate\s+(table\s+)?[a-z_"`]""" to "truncates a table",
            """\bdelete\s+from\b""" to "deletes rows",
            """\bflush(all|db)\b""" to "flushes a datastore",
            """\bdb:(drop|reset)\b|\bmigrate:fresh\b|\bmigrate\s+reset\b|--force-reset|--accept-data-loss""" to "resets a database",
            """\brm\s+-[a-z]*[rf]""" to "rm deletes files",
            """\b(rmtree|rimraf|os\.remove|os\.unlink|fs\.rm|fs\.unlink|shutil\.rmtree)\b""" to "deletes files",
            """git\s+push\s+.*(--force|-f\b)""" to "force-pushes",
            """git\s+reset\s+--hard""" to "discards work",
        ).map { (p, why) -> Rx.compile(p) to why }

        /** Pure. A SQL or CLI phrase that destroys data, or null. */
        fun matchesDestructiveText(text: String): String? {
            val t = text.lowercase()
            for ((pattern, why) in destructivePatterns) if (pattern.matcher(t).find()) return why
            return null
        }

        // MARK: per-tool

        private fun classifyShellInvocation(shell: String, args: List<String>, depth: Int): Verdict {
            val i = args.indexOfFirst { it == "-c" || (Sw.hasPrefix(it, "-") && !Sw.hasPrefix(it, "--") && it.contains("c")) }
            if (i >= 0 && i + 1 < args.size) {
                return combineConsidered(classifyBash(args[i + 1], depth + 1), "$shell -c runs a script")
            }
            return considered("runs a script")
        }

        private fun classifyScriptInterpreter(cmd: String, args: List<String>): Verdict {
            // `-m module` counts only when it is the interpreter's own option: after a
            // script name or `-c code` it is just an argument to that script.
            val harmlessPythonFlags = setOf("-u", "-B", "-E", "-s", "-S", "-I", "-O", "-OO", "-b", "-bb", "-q")
            val m = args.indexOf("-m")
            if ((cmd == "python" || cmd == "python3") && m >= 0 && m + 1 < args.size &&
                args.subList(0, m).all { it in harmlessPythonFlags }
            ) {
                val module = args[m + 1]
                if (module in listOf("pytest", "unittest", "mypy", "pylint", "flake8", "pyright", "doctest", "compileall")) {
                    val rest = args.subList(m + 2, args.size)
                    if (module == "pytest" || module == "mypy" || module == "pylint" || module == "flake8" || module == "pyright") {
                        riskyRunnerOption(module, rest)?.let { return considered(it) }
                    } else if (optionPointsOutside(rest) || positionalPointsOutside(rest) ||
                        (module == "doctest" && rest.any { Sw.hasSuffix(it, ".py") && pointsOutside(it) })
                    ) {
                        return considered("python -m $module points outside the project")
                    }
                    return Verdict(Reversibility.UNDOABLE, listOf(Tag.RUNS_COMMANDS), "test or lint run")
                }
            }
            // A version query is the one option and nothing else: `node x.js --version`
            // hands the flag to the script.
            if (args.size == 1 && args[0] in listOf("--version", "-V", "-VV", "-v", "-version")) {
                return readOnly("version")
            }
            val code = args.joinToString(" ")
            matchesDestructiveText(code)?.let { return destroy(it) }
            return considered("runs a script")
        }

        private fun classifySSH(args: List<String>, depth: Int): Verdict {
            val withValue = setOf("-p", "-i", "-l", "-o", "-F", "-J", "-L", "-R", "-D", "-b", "-c", "-E", "-e", "-m", "-O", "-Q", "-S", "-W", "-w", "-B", "-I")
            val rest = args.toMutableList()
            while (rest.isNotEmpty() && Sw.hasPrefix(rest[0], "-")) {
                val f = rest.removeAt(0)
                if (f in withValue && rest.isNotEmpty()) rest.removeAt(0)
            }
            if (rest.isEmpty()) return Verdict(CONSIDERED, listOf(Tag.NETWORK_OUTSIDE), "opens a remote shell")
            rest.removeAt(0) // host
            val remote = classifyBash(rest.joinToString(" "), depth + 1)
            var v = Verdict(CONSIDERED, listOf(Tag.NETWORK_OUTSIDE), "runs on another machine")
            if (rest.isNotEmpty()) v = Verdict.combine(v, remote)
            return v
        }

        private fun classifyFind(args: List<String>, depth: Int): Verdict {
            if ("-delete" in args) return destroy("find -delete removes files")
            val i = args.indexOfFirst { it in listOf("-exec", "-execdir", "-ok", "-okdir") }
            if (i >= 0) {
                var tail = args.subList(i + 1, args.size).toList()
                val end = tail.indexOfFirst { it == ";" || it == "+" || it == "\\;" }
                if (end >= 0) tail = tail.subList(0, end)
                val inner = classifyBash(tail.joinToString(" "), depth + 1)
                return Verdict.combine(considered("find runs a command"), inner)
            }
            if (args.any { Sw.hasPrefix(it, "-fprint") || it == "-fls" }) return considered("find writes a file")
            return readOnly("lists files")
        }

        // MARK: option checks shared by the build, test and cloud tools

        /**
         * True when an option named in [names] is among [args] (before a bare
         * `--`): `--name`, `--name=value`, `-name` (single-dash long options such
         * as Go's `-exec`), or a long option abbreviated to three letters or more.
         * [shorts] are one-letter options that may carry their value attached
         * (`-Xswiftc`, `-C/tmp`).
         */
        private fun hasOption(args: List<String>, names: List<String>, shorts: String = ""): Boolean {
            val shortSet = Sw.chars(shorts).toSet()
            for (a in args) {
                if (a == "--") break
                if (!(Sw.hasPrefix(a, "-") && Sw.count(a) > 1)) continue
                if (Sw.hasPrefix(a, "--")) {
                    val name = Sw.dropFirst(a, 2).split("=")[0]
                    if (names.any { it == name || (Sw.count(name) >= 3 && Sw.hasPrefix(it, name)) }) return true
                } else {
                    val name = Sw.dropFirst(a).split("=")[0]
                    if (name in names) return true
                    val f = Sw.chars(Sw.dropFirst(a)).firstOrNull()
                    if (f != null && f in shortSet) return true
                }
            }
            return false
        }

        /** A value that leaves the project: absolute, `~`, `..`, or built from a variable or substitution. */
        private fun pointsOutside(v: String): Boolean =
            Sw.hasPrefix(v, "/") || Sw.hasPrefix(v, "~") || v.contains("$") || Sw.splitOmittingEmpty(v, "/").contains("..")

        /** True when an option's value (`--opt=/x`, `-o/x`, `-o /x`) points outside the project. */
        private fun optionPointsOutside(args: List<String>): Boolean {
            var afterOption = false
            for (a in args) {
                if (a == "--") break
                if (Sw.hasPrefix(a, "-") && Sw.count(a) > 1) {
                    val eq = Sw.firstIndexOf(a, "=")
                    if (eq >= 0 && pointsOutside(a.substring(eq + 1))) return true
                    if (!Sw.hasPrefix(a, "--") && Sw.count(a) > 2 && pointsOutside(Sw.dropFirst(a, 2))) return true
                    afterOption = !a.contains("=")
                    continue
                }
                if (afterOption && pointsOutside(a)) return true
                afterOption = false
            }
            return false
        }

        /**
         * True when a bare (non-option) argument names a path outside the project. Test
         * runners, linters and `python -m` tools load or execute the files they are given.
         */
        private fun positionalPointsOutside(args: List<String>): Boolean =
            args.any { !Sw.hasPrefix(it, "-") && pointsOutside(it) }

        /** `CC=/tmp/x`, `SWIFT_EXEC=...`: an upper-case build setting given on the command line. */
        private fun isBuildSettingOverride(arg: String): Boolean {
            val eq = Sw.firstIndexOf(arg, "=")
            if (eq <= 0) return false
            return Sw.chars(arg.substring(0, eq)).all {
                (Sw.isASCII(it) && Sw.isUppercase(it)) || it == "_" || (Sw.isASCII(it) && Sw.isNumber(it))
            }
        }

        /**
         * Options that make a test or lint runner load code, run a program or
         * write a file. Null when none is present. The JavaScript runners are held
         * to an allowlist because their config and reporter options load modules.
         */
        private fun riskyRunnerOption(cmd: String, args: List<String>): String? {
            val before = args.takeWhile { it != "--" }
            if (hasOption(before, listOf("fix", "write", "fix-only", "unsafe-fixes", "add-noqa"))) {
                return "$cmd may rewrite files"
            }
            if (optionPointsOutside(before)) return "$cmd option points outside the project"
            if (positionalPointsOutside(before)) return "$cmd runs a file outside the project"
            when (cmd) {
                "pytest", "py.test" -> {
                    var i = 0
                    while (i < before.size) {
                        val a = before[i]
                        i += 1
                        if (Sw.hasPrefix(a, "-p") && !Sw.hasPrefix(a, "--")) {
                            val v = if (Sw.count(a) > 2) Sw.dropFirst(a, 2) else (if (i < before.size) before[i] else "")
                            if (!Sw.hasPrefix(v, "no:")) return "pytest -p loads a plugin"
                        }
                    }
                    if (hasOption(
                            before,
                            listOf(
                                "rootdir", "basetemp", "junitxml", "junit-xml", "html", "log-file", "result-log", "resultlog",
                                "report-log", "confcutdir", "override-ini", "pastebin", "debug", "cov-report", "config-file",
                                "pyargs", "import-mode",
                            ),
                            shorts = "co",
                        )
                    ) {
                        return "pytest option loads code or writes files"
                    }
                }
                "tox", "nox" -> {
                    if (hasOption(before, listOf("conf", "override", "workdir", "root", "installpkg", "recreate", "sdistonly", "noxfile", "force-python"), shorts = "cxrf")) {
                        return "$cmd option changes what runs"
                    }
                }
                "jest", "vitest", "mocha", "ava" -> {
                    val fine = setOf(
                        "coverage", "verbose", "silent", "ci", "runInBand", "i", "bail", "b", "t", "testNamePattern", "colors",
                        "no-colors", "color", "no-color", "passWithNoTests", "run", "watch", "no-watch", "watchAll", "w",
                        "maxWorkers", "forceExit", "detectOpenHandles", "testPathPattern", "listTests", "onlyChanged", "changed",
                        "no-cache", "grep", "g", "fgrep", "timeout", "parallel", "exit", "recursive", "serial", "s",
                        "fail-fast", "match", "m", "tap", "version", "help", "h", "testTimeout", "retry",
                    )
                    for (a in before) {
                        if (Sw.hasPrefix(a, "-") && Sw.count(a) > 1) {
                            val name = Sw.dropWhile(a) { it == "-" }.split("=")[0]
                            if (name !in fine) return "$cmd option can load code or write files"
                        }
                    }
                }
                "mypy" -> {
                    if (hasOption(
                            before,
                            listOf(
                                "python-executable", "junit-xml", "html-report", "xml-report", "txt-report", "any-exprs-report",
                                "linecount-report", "linecoverage-report", "lineprecision-report", "cobertura-xml-report",
                                "xslt-html-report", "xslt-txt-report", "cache-dir", "config-file", "install-types", "shadow-file",
                            ),
                        )
                    ) {
                        return "mypy option runs a program or writes files"
                    }
                }
                "pylint" -> {
                    if (hasOption(before, listOf("init-hook", "load-plugins", "rcfile", "output", "output-format", "generate-rcfile", "generate-toml-config"))) {
                        return "pylint option loads code or writes files"
                    }
                }
                "flake8" -> {
                    if (hasOption(before, listOf("output-file", "config", "append-config", "install-hook", "tee"))) {
                        return "flake8 option writes files or loads config"
                    }
                }
                "pyright" -> {
                    if (hasOption(before, listOf("pythonpath", "createstub", "project", "verifytypes", "watch"), shorts = "p")) {
                        return "pyright option runs a program or writes files"
                    }
                }
                "tsc" -> {
                    // tsc emits JavaScript unless told not to.
                    if ("--noEmit" !in before && "-noEmit" !in before) return "tsc writes build output"
                    if (hasOption(before, listOf("build", "generateTrace", "generateCpuProfile", "tsBuildInfoFile", "incremental", "composite"), shorts = "b")) {
                        return "tsc option writes files"
                    }
                }
                "swiftlint" -> {
                    if (hasOption(before, listOf("autocorrect", "format", "output", "write-baseline", "cache-path", "config"))) return "swiftlint option rewrites files"
                    val sub = before.firstOrNull { !Sw.hasPrefix(it, "-") }
                    if (sub != null && sub !in listOf("lint", "analyze", "rules", "version")) {
                        return "swiftlint $sub isn't a plain lint"
                    }
                }
                "tflint" -> {
                    if (hasOption(before, listOf("init", "config", "chdir"))) return "tflint option downloads plugins or loads config"
                }
                "ctest" -> {
                    if (hasOption(
                            before,
                            listOf(
                                "script", "script-new-process", "dashboard", "build-and-test", "output-log", "output-junit",
                                "test-command", "extra-submit", "submit-index",
                            ),
                            shorts = "SDTO",
                        )
                    ) {
                        return "ctest option runs scripts or writes files"
                    }
                }
                "bats" -> {
                    if (hasOption(before, listOf("output", "report-formatter", "gather-test-outputs-in", "formatter"), shorts = "oF")) return "bats option writes files"
                }
                "rspec" -> {
                    // --format/-f takes `json:path` as well as a name, and the path is a file it writes.
                    if (hasOption(
                            before,
                            listOf("require", "options", "out", "output", "format", "init", "default-path", "example-status-persistence-file-path"),
                            shorts = "roOf",
                        )
                    ) {
                        return "rspec option loads code or writes files"
                    }
                }
                "phpunit" -> {
                    if (hasOption(
                            before,
                            listOf(
                                "configuration", "bootstrap", "log-junit", "log-teamcity", "coverage-html", "coverage-clover", "coverage-xml",
                                "coverage-php", "coverage-text", "testdox-html", "testdox-text", "testdox-xml", "include-path", "extension",
                                "generate-configuration", "migrate-configuration", "cache-directory", "cache-result-file", "log-events-text",
                                "log-tap", "coverage-cobertura", "coverage-crap4j", "coverage-cache", "printer",
                            ),
                            shorts = "cd",
                        )
                    ) {
                        return "phpunit option loads code or writes files"
                    }
                }
                else -> Unit
            }
            return null
        }

        /** `eslint -f ./fmt.js`: a formatter given as a path is code that runs. */
        private fun loadsFormatter(args: List<String>): Boolean {
            var i = 0
            while (i < args.size) {
                val a = args[i]
                i += 1
                var value: String? = null
                if (a == "-f" || a == "--format" || a == "--formatter") value = if (i < args.size) args[i] else ""
                else if (Sw.hasPrefix(a, "--format=") && Sw.firstIndexOf(a, "=") >= 0) value = a.substring(Sw.firstIndexOf(a, "=") + 1)
                else if (Sw.hasPrefix(a, "-f") && !Sw.hasPrefix(a, "--")) value = Sw.dropFirst(a, 2)
                if (value != null && (value.contains("/") || value.contains("."))) return true
            }
            return false
        }

        /**
         * Formatters and fixers are checks only when told to be, and only when
         * nothing in the call also writes, loads code or points elsewhere.
         */
        private fun classifyFormatter(cmd: String, args: List<String>): Verdict {
            val before = args.takeWhile { it != "--" }
            val checks = before.any { it in listOf("--check", "-c", "--diff", "--list-different", "-l", "--dry-run", "--lint") } ||
                (cmd == "ruff" && before.firstOrNull() == "check") ||
                (cmd == "eslint")
            val writes = hasOption(
                before,
                listOf(
                    "write", "fix", "fix-only", "unsafe-fixes", "add-noqa", "overwrite-in-place", "in-place", "output-file",
                    "output", "outfile", "init", "config", "rcfile", "rulesdir", "plugin", "parser", "resolve-plugins-relative-to",
                    "cache-location", "stdin-filepath", "ignore-path", "watch", "emit",
                ),
            ) || hasShort(before, "wio") || optionPointsOutside(before) || loadsFormatter(before)
            // ESLint reads the config files above each file it is given, so a file outside the project runs code too.
            val outsideFile = positionalPointsOutside(before)
            if (checks && !writes && !outsideFile) return Verdict(Reversibility.UNDOABLE, listOf(Tag.RUNS_COMMANDS), "lint or format check")
            return considered(if (outsideFile) "$cmd reads a file outside the project" else "$cmd rewrites files or loads code")
        }

        // MARK: text tools that can write or run things

        /**
         * True when [arg] is a long option spelled out or shortened (`--out` for
         * `--output`), with or without `=value`. GNU tools accept abbreviations.
         */
        private fun isLong(arg: String, full: String, minLength: Int = 1): Boolean {
            if (!Sw.hasPrefix(arg, "--")) return false
            val name = Sw.dropFirst(arg, 2).split("=")[0]
            return Sw.count(name) >= minLength && Sw.hasPrefix(full, name)
        }

        /** True when a short-option cluster (`-nro`) contains one of [letters]. */
        private fun hasShort(args: List<String>, letters: String): Boolean {
            val set = Sw.chars(letters).toSet()
            return args.any { Sw.hasPrefix(it, "-") && !Sw.hasPrefix(it, "--") && Sw.chars(Sw.dropFirst(it)).any { c -> c in set } }
        }

        private fun nonFlagCount(args: List<String>, valueFlags: Set<String>): Int {
            var count = 0
            var skip = false
            for (a in args) {
                if (skip) { skip = false; continue }
                if (a == "--") continue
                if (Sw.hasPrefix(a, "-") && Sw.count(a) > 1) { if (a in valueFlags) skip = true; continue }
                count += 1
            }
            return count
        }

        /**
         * For tools that are otherwise plain text readers: the options that make
         * them write a file or run another program. Null when none is present.
         */
        private fun riskyTextToolUse(cmd: String, args: List<String>): String? {
            if (args.any { Sw.hasPrefix(it, "--pager") }) return "$cmd --pager runs a program"
            when (cmd) {
                "less", "more" -> return "$cmd is a pager that can run commands"
                "rg" -> {
                    if (args.any { Sw.hasPrefix(it, "--pre") || Sw.hasPrefix(it, "--hostname-bin") || it == "--search-zip" } || hasShort(args, "z")) {
                        return "rg runs a helper program"
                    }
                }
                "fd" -> {
                    if (args.any { Sw.hasPrefix(it, "--exec") || isLong(it, "exec", 3) } || hasShort(args, "xX")) {
                        return "fd runs a command"
                    }
                }
                "sort" -> {
                    if (hasShort(args, "o") || args.any { isLong(it, "output") || isLong(it, "compress-program", 2) }) {
                        return "sort writes a file or runs a helper"
                    }
                }
                "tree" -> {
                    // -o writes the listing; -R with -H writes 00Tree.html into every directory;
                    // --fromfile reads a listing from a file.
                    if (hasShort(args, "oRH") || args.any { isLong(it, "output") || isLong(it, "fromfile") || isLong(it, "fromtabfile") || isLong(it, "html") }) {
                        return "tree writes a file"
                    }
                }
                "bat" -> {
                    if (args.any { isLong(it, "generate-config-file") || isLong(it, "build-cache") || isLong(it, "clear-cache") || isLong(it, "init-config") }) {
                        return "bat writes its config or cache"
                    }
                }
                "diff" -> {
                    if (hasShort(args, "l") || args.any { isLong(it, "paginate", 3) }) return "diff --paginate runs pr"
                }
                "base64" -> {
                    if (hasShort(args, "o") || args.any { isLong(it, "output") }) return "base64 writes a file"
                }
                "yq" -> {
                    if (hasShort(args, "is") || args.any { Sw.hasPrefix(it, "--inplace") || Sw.hasPrefix(it, "--in-place") || Sw.hasPrefix(it, "--split-exp") || Sw.hasPrefix(it, "--security") }) {
                        return "yq writes files"
                    }
                }
                "jq" -> {
                    if (hasShort(args, "i") || args.any { Sw.hasPrefix(it, "--inplace") || Sw.hasPrefix(it, "--in-place") }) {
                        return "jq writes files"
                    }
                }
                "uniq" -> {
                    if (nonFlagCount(args, setOf("-f", "-s", "-w")) > 1) return "uniq writes its second file"
                }
                "xxd" -> {
                    if (nonFlagCount(args, setOf("-l", "-s", "-c", "-g", "-o", "-n", "-b", "-R")) > 1) return "xxd writes its second file"
                }
                "cd", "pushd" -> {
                    // Moving out of the project makes whatever runs next (`cd /tmp/x && make test`) somebody else's.
                    val target = args.firstOrNull { !Sw.hasPrefix(it, "-") || it == "-" }
                        ?: return "$cmd with no folder goes to the home folder"
                    if (target == "-" || pointsOutside(target)) return "$cmd leaves the project"
                }
                "arch" -> {
                    if (args.isNotEmpty()) return "arch runs another program"
                }
                "alias" -> {
                    if (args.isNotEmpty()) return "alias changes how commands run"
                }
                "date" -> {
                    if (hasShort(args, "s") || args.any { Sw.hasPrefix(it, "--set") }) return "date sets the clock"
                }
                "hostname" -> {
                    if (nonFlagCount(args, emptySet()) > 0) return "hostname renames the Mac"
                }
                "file" -> {
                    if (hasShort(args, "C") || "--compile" in args) return "file compiles a magic file"
                }
                "cloc" -> {
                    // Only the reporting options that print to the terminal. Anything else can write a file
                    // (--out, --write-lang-def, --strip-comments, --counted, --sdir ...) or run git or sloccount (--vcs, --git).
                    val plain = setOf(
                        "by-file", "by-file-by-lang", "by-percent", "csv", "json", "yaml", "xml", "md", "quiet", "hide-rate", "sum-one",
                        "skip-uniqueness", "follow-links", "no-autogen", "unicode", "exclude-dir", "exclude-ext", "exclude-lang",
                        "include-lang", "include-ext", "match-d", "not-match-d", "match-f", "not-match-f", "max-file-size", "sort",
                        "show-ext", "show-lang", "progress-rate", "no-color", "version", "help", "v", "h",
                    )
                    if (args.any { arg ->
                            if (!Sw.hasPrefix(arg, "-")) false
                            else Sw.dropWhile(arg) { it == "-" }.split("=")[0] !in plain
                        }
                    ) {
                        return "cloc option writes a file or runs a program"
                    }
                }
                "git-lfs" -> {
                    if ((args.firstOrNull() ?: "") !in listOf("ls-files", "status", "version", "env")) return "git-lfs changes files or reaches a remote"
                }
                else -> Unit
            }
            return null
        }

        /**
         * `sed` is read-only only for a known set of commands. `-i`, `-f`, and the
         * `w`, `W`, `e`, `r` family (as commands or `s` flags) write or run things.
         */
        private fun classifySed(args: List<String>): Verdict {
            val unsafe = "sed can edit files or run commands"
            val scripts = ArrayList<String>()
            var scriptFromArg = false
            var i = 0
            var afterDashDash = false
            val clusterOK = Sw.chars("nErsuze").toSet()
            while (i < args.size) {
                val a = args[i]
                i += 1
                if (afterDashDash || !Sw.hasPrefix(a, "-") || a == "-") {
                    if (!scriptFromArg && scripts.isEmpty()) { scripts.add(a); scriptFromArg = true }
                    continue
                }
                if (a == "--") { afterDashDash = true; continue }
                if (a == "-i" || (Sw.hasPrefix(a, "-i") && !Sw.hasPrefix(a, "--")) || Sw.hasPrefix(a, "--in-place")) {
                    return considered("sed edits files in place")
                }
                if (a == "-e" || a == "--expression") {
                    if (i >= args.size) return considered(unsafe)
                    scripts.add(args[i]); i += 1; scriptFromArg = true; continue
                }
                if (Sw.hasPrefix(a, "--expression=")) { scripts.add(a.substring("--expression=".length)); scriptFromArg = true; continue }
                if (a in listOf("--quiet", "--silent", "--regexp-extended", "--posix", "--separate", "--unbuffered", "--null-data", "--debug", "--sandbox")) continue
                if (!Sw.hasPrefix(a, "--") && Sw.chars(Sw.dropFirst(a)).all { it in clusterOK }) {
                    if (a.contains("e")) {
                        if (!(Sw.hasSuffix(a, "e") && i < args.size)) return considered(unsafe)
                        scripts.add(args[i]); i += 1; scriptFromArg = true
                    }
                    continue
                }
                return considered(unsafe) // -f, -l, an unknown option: not judged
            }
            if (scripts.isEmpty()) return considered(unsafe)
            for (script in scripts) {
                if (!(sedScriptIsReadOnly(script, false) && sedScriptIsReadOnly(script, true))) return considered(unsafe)
            }
            return readOnly("text filter")
        }

        private val sedSFlags: Set<String> = Sw.chars("gpiImM0123456789").toSet()

        /**
         * A small sed script reader: true only when every command is one of a
         * short list that only prints, deletes lines or substitutes text. Parsed
         * twice (brackets special or not) because seds disagree on `s/[/]/x/`.
         */
        private fun sedScriptIsReadOnly(script: String, bracketAware: Boolean): Boolean {
            val c = Sw.chars(script)
            val n = c.size
            var i = 0
            fun spaces() { while (i < n && (c[i] == " " || c[i] == "\t")) i += 1 }
            fun skipDelimited(d: String, brackets: Boolean): Boolean {
                var inBracket = false
                while (i < n) {
                    val ch = c[i]
                    if (ch == "\\") { i += 2; continue }
                    if (brackets && ch == "[" && !inBracket) {
                        inBracket = true
                        i += 1
                        if (i < n && c[i] == "^") i += 1
                        if (i < n && c[i] == "]") i += 1
                        continue
                    }
                    if (brackets && ch == "]" && inBracket) { inBracket = false; i += 1; continue }
                    if (ch == d && !inBracket) { i += 1; return true }
                    i += 1
                }
                return false
            }
            fun digits() { while (i < n && Sw.isASCII(c[i]) && Sw.isNumber(c[i])) i += 1 }
            /** null: syntax not understood. true/false: an address was/was not there. */
            fun address(second: Boolean): Boolean? {
                if (i >= n) return false
                val ch = c[i]
                if (Sw.isASCII(ch) && Sw.isNumber(ch)) { digits(); if (i < n && c[i] == "~") { i += 1; digits() }; return true }
                if (second && (ch == "+" || ch == "~")) { i += 1; digits(); return true }
                if (ch == "$") { i += 1; return true }
                var delim: String? = null
                if (ch == "/") { delim = "/"; i += 1 }
                else if (ch == "\\" && i + 1 < n) { delim = c[i + 1]; i += 2 }
                if (delim != null) {
                    if (!skipDelimited(delim, bracketAware)) return null
                    while (i < n && (c[i] == "I" || c[i] == "M")) i += 1
                    return true
                }
                return false
            }
            fun endOfCommand(): Boolean {
                spaces()
                if (i >= n) return true
                if (c[i] == ";" || c[i] == "\n" || c[i] == "}") return true
                return false
            }
            while (true) {
                spaces()
                while (i < n && (c[i] == ";" || c[i] == "\n")) { i += 1; spaces() }
                if (i >= n) return true
                if (c[i] == "#") { while (i < n && c[i] != "\n") i += 1; continue }
                val first = address(false) ?: return false
                if (first) {
                    spaces()
                    if (i < n && c[i] == ",") {
                        i += 1; spaces()
                        val second = address(true) ?: return false
                        if (!second) return false
                    }
                }
                spaces()
                while (i < n && c[i] == "!") { i += 1; spaces() }
                if (i >= n) return false
                val cmd = c[i]
                i += 1
                when (cmd) {
                    "{" -> continue
                    "}" -> continue
                    "p", "d", "=", "n", "N", "D", "P", "g", "G", "h", "H", "x", "z", "F" -> {
                        if (!endOfCommand()) return false
                    }
                    "q", "Q", "l" -> {
                        spaces(); digits()
                        if (!endOfCommand()) return false
                    }
                    "y" -> {
                        if (i >= n) return false
                        val d = c[i]; i += 1
                        if (!(skipDelimited(d, false) && skipDelimited(d, false))) return false
                        if (!endOfCommand()) return false
                    }
                    "s" -> {
                        if (i >= n) return false
                        val d = c[i]; i += 1
                        if (!(d != "\\" && d != "\n" && d != " " && skipDelimited(d, bracketAware) && skipDelimited(d, false))) return false
                        while (i < n && c[i] in sedSFlags) i += 1
                        if (!endOfCommand()) return false
                    }
                    else -> return false // a, i, c, r, R, w, W, e, b, t, T, ":" ...
                }
            }
        }

        /**
         * `awk` is read-only only for a plain program: no file program, no
         * `system`, `getline`, pipe or redirection, however it is spaced.
         */
        private fun classifyAwk(args: List<String>): Verdict {
            val unsafe = "awk program can run or write"
            var i = 0
            var program: String? = null
            while (i < args.size) {
                val a = args[i]
                i += 1
                if (a == "--") { program = if (i < args.size) args[i] else null; break }
                if (!Sw.hasPrefix(a, "-") || a == "-") { program = a; break }
                if (a == "-F" || a == "-v") { i += 1; continue }
                if ((Sw.hasPrefix(a, "-F") || Sw.hasPrefix(a, "-v")) && !Sw.hasPrefix(a, "--")) continue
                if (a == "--version" || a == "-version") return readOnly("awk version")
                return considered(unsafe) // -f, -i, -e, -l, an unknown option
            }
            if (program == null) return considered(unsafe)
            for (bad in listOf(">", "|", "system", "getline", "@")) if (program.contains(bad)) return considered(unsafe)
            return readOnly("text filter")
        }

        /**
         * Splits git's global options from the subcommand. Options that move git
         * elsewhere or change what it runs (`-c`, `--exec-path`, `--git-dir`,
         * `--work-tree`, `--namespace`, a `-C` that leaves the project) come back
         * as a verdict that is at least CONSIDERED; an option not known to be
         * harmless does too.
         */
        private fun gitSub(args: List<String>): Triple<String, List<String>, Verdict?> {
            val rest = args.toMutableList()
            var issue: Verdict? = null
            fun note(why: String, text: String? = null) {
                var v = considered(why)
                if (text != null) matchesDestructiveText(text)?.let { v = destroy(it) }
                issue = issue?.let { Verdict.combine(it, v) } ?: v
            }
            fun takeValue(): String? = if (rest.isEmpty()) null else rest.removeAt(0)
            fun staysInside(path: String?): Boolean {
                if (path == null || path.contains("$") || path.contains("`")) return false
                return isInside(path, null)
            }
            val harmless = setOf(
                "--no-pager", "-P", "--no-optional-locks", "--no-replace-objects", "--literal-pathspecs",
                "--glob-pathspecs", "--noglob-pathspecs", "--icase-pathspecs", "--no-lazy-fetch",
            )
            val withValue = setOf("--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix", "--attr-source")
            while (rest.isNotEmpty() && Sw.hasPrefix(rest[0], "-")) {
                val f = rest.removeAt(0)
                if (f == "-c") {
                    note("git -c overrides config for this command", takeValue())
                } else if (Sw.hasPrefix(f, "-c") && !Sw.hasPrefix(f, "--")) {
                    note("git -c overrides config for this command", Sw.dropFirst(f, 2))
                } else if (f == "-C") {
                    if (!staysInside(takeValue())) note("git -C points outside the project")
                } else if (Sw.hasPrefix(f, "-C") && !Sw.hasPrefix(f, "--")) {
                    if (!staysInside(Sw.dropFirst(f, 2))) note("git -C points outside the project")
                } else if (f == "--exec-path" || Sw.hasPrefix(f, "--exec-path=")) {
                    note("git --exec-path changes which programs git runs")
                } else if (f.split("=").first() in withValue) {
                    val name = f.split("=").first()
                    if (!f.contains("=")) takeValue()
                    note("git $name points git somewhere else")
                } else if (f !in harmless) {
                    note("git option $f isn't one Page recognises")
                }
            }
            val sub = rest.firstOrNull() ?: return Triple("", emptyList(), issue)
            return Triple(sub.lowercase(), rest.drop(1), issue)
        }

        private fun classifyGit(args: List<String>): Verdict {
            val (sub, a, issue) = gitSub(args)
            val v = classifyGitSub(sub, a)
            return issue?.let { Verdict.combine(v, it) } ?: v
        }

        private fun classifyGitSub(sub: String, a: List<String>): Verdict {
            val nonFlags = a.filter { !Sw.hasPrefix(it, "-") }
            fun hasFlag(vararg names: String): Boolean =
                a.any { arg -> names.any { arg == it || Sw.hasPrefix(arg, "$it=") } }
            fun shortCluster(letter: String): Boolean =
                a.any { Sw.hasPrefix(it, "-") && !Sw.hasPrefix(it, "--") && Sw.chars(Sw.dropFirst(it)).contains(letter) }
            val git = Verdict(CONSIDERED, listOf(Tag.RUNS_COMMANDS), "git changes the repo")
            when (sub) {
                "status", "log", "diff", "show", "blame", "shortlog", "rev-parse", "rev-list", "ls-files", "ls-tree",
                "describe", "cat-file", "grep", "whatchanged", "count-objects", "fsck", "diff-tree", "name-rev",
                "merge-base", "for-each-ref", "show-ref", "check-ignore", "version", "--version",
                "diff-files", "diff-index", "annotate", "range-diff", "show-branch", "var" -> {
                    if (sub == "ls-remote") return Verdict(CONSIDERED, listOf(Tag.NETWORK_OUTSIDE), "reads a remote")
                    if (a.any { isLong(it, "output", 3) } || (hasFlag("-o") && sub == "diff")) return considered("git writes a file")
                    if (sub == "grep" && a.any { it == "--open-files-in-pager" || Sw.hasPrefix(it, "--open-files-in-pager=") || (Sw.hasPrefix(it, "-O") && !Sw.hasPrefix(it, "--")) }) {
                        return considered("git grep opens a pager program")
                    }
                    // Textconv, external diff and lost-found run programs or write files; --filters runs filter drivers;
                    // --show-signature runs gpg.
                    if (a.any {
                            isLong(it, "ext-diff", 3) || isLong(it, "textconv", 3) || isLong(it, "lost-found", 3) ||
                                isLong(it, "filters", 3) || isLong(it, "show-signature", 3)
                        }
                    ) {
                        return considered("git runs a configured program")
                    }
                    return readOnly("read-only git")
                }
                "branch" -> {
                    if (hasFlag("--delete") || shortCluster("D") || (shortCluster("d") && (hasFlag("--force") || shortCluster("f")))) {
                        return destroy("deletes a branch")
                    }
                    if (shortCluster("d")) return Verdict(CONSIDERED, listOf(Tag.RUNS_COMMANDS), "deletes a merged branch")
                    val listing = hasFlag("--list") || shortCluster("l") || nonFlags.isEmpty()
                    val changing = hasFlag("-m", "-M", "--move", "-c", "-C", "--copy", "--set-upstream-to", "-u", "--unset-upstream", "--edit-description", "-f", "--force")
                    if (listing && !changing) return readOnly("lists branches")
                    return git
                }
                "tag" -> {
                    if (shortCluster("d") || hasFlag("--delete")) return Verdict(CONSIDERED, listOf(Tag.RUNS_COMMANDS), "deletes a tag")
                    if (nonFlags.isEmpty() || hasFlag("-l", "--list")) return readOnly("lists tags")
                    return git
                }
                "remote" -> {
                    val s = nonFlags.firstOrNull() ?: ""
                    // `remote show` asks the remote for its branches, so it reaches the network.
                    if (s.isEmpty() || s == "get-url") return readOnly("lists remotes")
                    return git
                }
                "stash" -> {
                    val s = nonFlags.firstOrNull() ?: "push"
                    if (s in listOf("list", "show")) return readOnly("lists stashes")
                    if (s in listOf("drop", "clear")) return destroy("stash drop loses work")
                    return git
                }
                "config" -> {
                    if (hasFlag("--edit", "-e", "--unset", "--unset-all", "--replace-all", "--add", "--remove-section", "--rename-section", "--set") || shortCluster("e")) {
                        return git
                    }
                    if (hasFlag("--get", "--get-all", "--get-regexp", "--list", "-l", "--show-origin")) return readOnly("reads git config")
                    return git
                }
                "push" -> {
                    val refspecForce = nonFlags.any { Sw.hasPrefix(it, "+") || Sw.hasPrefix(it, ":") }
                    if (hasFlag("--force", "-f", "--force-with-lease", "--force-if-includes", "--delete", "--mirror", "--prune") || shortCluster("f") || shortCluster("d") || refspecForce) {
                        return Verdict(IRREVERSIBLE, listOf(Tag.NETWORK_OUTSIDE, Tag.DESTRUCTIVE), "force-push or remote delete")
                    }
                    return Verdict(CONSIDERED, listOf(Tag.NETWORK_OUTSIDE), "pushes to a remote")
                }
                "reset" -> {
                    if (hasFlag("--hard", "--merge")) return destroy("reset --hard discards work")
                    return git
                }
                "clean" -> {
                    if (hasFlag("--dry-run") || shortCluster("n")) return readOnly("git clean preview")
                    return destroy("git clean deletes untracked files")
                }
                "restore" -> {
                    if (hasFlag("--staged") && !hasFlag("--worktree") && !shortCluster("W")) return git
                    return destroy("restore discards changes")
                }
                "checkout" -> {
                    if ("--" in a || "." in nonFlags || hasFlag("--force", "-f") || shortCluster("f")) {
                        return destroy("checkout discards changes")
                    }
                    return git
                }
                "filter-branch", "filter-repo", "prune", "update-ref", "replace" -> return destroy("rewrites git history")
                "reflog" -> {
                    val s = nonFlags.firstOrNull() ?: "show"
                    if (s in listOf("expire", "delete")) return destroy("reflog expire drops history")
                    return if (s == "show") readOnly("shows the reflog") else git
                }
                "gc" -> return if (hasFlag("--prune") && a.any { it.contains("now") }) destroy("gc prunes objects") else git
                "fetch", "pull", "clone", "submodule", "lfs" -> return Verdict(CONSIDERED, listOf(Tag.NETWORK_OUTSIDE), "reaches a remote")
                "worktree" -> return if (nonFlags.firstOrNull() == "list") readOnly("lists worktrees") else git
                else -> return git
            }
        }

        private fun classifySwift(args: List<String>): Verdict {
            val sub = args.firstOrNull() ?: ""
            // Compiler pass-through (-Xswiftc ...), sandbox and path options change what runs or where it writes.
            val risky = hasOption(
                args,
                listOf(
                    "disable-sandbox", "allow-writing-to-package-directory", "allow-network-connections", "xunit-output",
                    "scratch-path", "build-path", "package-path", "cache-path", "config-path", "security-path",
                    "manifest-cache", "toolchain", "sdk", "vfs-overlay", "enable-experimental-prebuilts",
                ),
                shorts = "X",
            ) || optionPointsOutside(args)
            if (risky && sub in listOf("build", "test", "package")) return considered("swift $sub option can change what runs")
            if (sub in listOf("build", "test", "--version", "-version", "--help", "-h")) {
                return Verdict(Reversibility.UNDOABLE, listOf(Tag.RUNS_COMMANDS), "build or test")
            }
            if (sub == "package") {
                val s = args.drop(1).firstOrNull { !Sw.hasPrefix(it, "-") } ?: ""
                if (s in listOf("describe", "dump-package", "show-dependencies", "dump-pif")) return readOnly("package info")
                return Verdict(CONSIDERED, listOf(Tag.NETWORK_OUTSIDE), "changes packages")
            }
            return considered("swift $sub")
        }

        private fun classifyCargo(args: List<String>): Verdict {
            val sub = args.firstOrNull { !Sw.hasPrefix(it, "+") } ?: ""
            val before = args.takeWhile { it != "--" }
            // --config can name a runner or wrapper; --fix rewrites files; --open starts a browser.
            val risky = hasOption(
                before,
                listOf(
                    "config", "manifest-path", "fix", "open", "target-dir", "out-dir", "timings", "allow-dirty",
                    "allow-staged", "allow-no-vcs", "artifact-dir",
                ),
                shorts = "Z",
            ) || optionPointsOutside(before)
            when (sub) {
                "test", "t", "build", "b", "check", "c", "clippy", "doc", "bench", "tree", "metadata", "version", "--version", "-V" -> {
                    if (risky) return considered("cargo option can change what runs")
                    return Verdict(Reversibility.UNDOABLE, listOf(Tag.RUNS_COMMANDS), "build or test")
                }
                "fmt" -> {
                    // After `--` the arguments go to rustfmt, which can be told to write.
                    return if ("--check" in args && !risky && "--" !in args)
                        Verdict(Reversibility.UNDOABLE, listOf(Tag.RUNS_COMMANDS), "format check") else considered("cargo fmt rewrites files")
                }
                "publish", "yank", "owner" -> return Verdict(IRREVERSIBLE, listOf(Tag.NETWORK_OUTSIDE, Tag.DESTRUCTIVE), "publishes a crate")
                else -> return considered("cargo $sub")
            }
        }

        private fun classifyGo(args: List<String>): Verdict {
            val sub = args.firstOrNull() ?: ""
            // -exec/-toolexec/-vettool run a program, -o and the profile flags write files, -ldflags can name a linker.
            // `-test.*` and everything after `-args` go to the test binary, which writes its own profiles and logs.
            val risky = hasOption(
                args,
                listOf(
                    "exec", "toolexec", "vettool", "o", "c", "coverprofile", "cpuprofile", "memprofile", "blockprofile",
                    "mutexprofile", "trace", "overlay", "modfile", "pkgdir", "C", "work", "gcflags", "ldflags", "asmflags",
                    "gccgoflags", "fuzz", "fuzzcachedir", "outputdir", "installsuffix", "w", "u",
                ),
            ) || optionPointsOutside(args) ||
                args.any { it == "-args" || Sw.hasPrefix(it, "-test.") } ||
                positionalPointsOutside(args)
            if (sub in listOf("test", "build", "vet", "list", "version", "env", "doc")) {
                if (risky) return considered("go option can change what runs or writes files")
                return Verdict(Reversibility.UNDOABLE, listOf(Tag.RUNS_COMMANDS), "build or test")
            }
            return considered("go $sub")
        }

        private val makeShortOK: Set<String> = Sw.chars("skwBeirRSdbmphv").toSet()
        private val makeShortDry: Set<String> = setOf("n", "q")
        private val makeLongOK: Set<String> = setOf(
            "silent", "quiet", "keep-going", "print-directory", "no-print-directory", "warn-undefined-variables",
            "no-builtin-rules", "no-builtin-variables", "always-make", "ignore-errors", "environment-overrides",
            "check-symlink-times", "no-keep-going", "stop", "print-data-base", "trace", "help", "version", "no-silent",
            "debug", "jobs",
        )
        private val makeLongDry: Set<String> = setOf("just-print", "dry-run", "recon", "question")

        /**
         * `make` and friends. Options are judged first and by exact allowlist: a
         * makefile, directory, include path, eval string or variable override
         * (`-f`, `-C`, `-I`, `-E`, `--eval`, `SHELL=x`) changes what runs, and an
         * abbreviated long option (`--fil=x`) is not an allowlisted one.
         * `-n`/`--just-print`/`--dry-run`/`--recon` and `-q`/`--question` are dry
         * runs, but GNU make still runs `+` lines, `$(MAKE)` recursion and
         * `$(shell ...)` during one, so they are CONSIDERED; `-p` still runs
         * the target. `ninja`, `just` and `task` have their own options, so any
         * option on them is simply CONSIDERED.
         */
        private fun classifyMake(cmd: String, args: List<String>): Verdict {
            val isMake = cmd == "make" || cmd == "gmake"
            val unsafe = considered("$cmd option or variable can change what runs")
            fun digits(s: String): Boolean = Sw.chars(s).all { Sw.isASCII(it) && Sw.isNumber(it) }
            val targets = ArrayList<String>()
            var dry = false
            var i = 0
            var onlyTargets = false
            while (i < args.size) {
                val a = args[i]
                i += 1
                if (onlyTargets) { targets.add(a); continue }
                if (a == "--") { onlyTargets = true; continue }
                if (Sw.hasPrefix(a, "--")) {
                    if (!isMake) return unsafe
                    val rest = Sw.dropFirst(a, 2)
                    val eq = Sw.firstIndexOf(rest, "=")
                    val parts = if (eq >= 0) listOf(rest.substring(0, eq), rest.substring(eq + 1)) else listOf(rest)
                    val name = parts.first()
                    if (name in makeLongDry && parts.size == 1) { dry = true; continue }
                    if (name == "jobs" && parts.size == 2 && digits(parts[1])) continue
                    if (name == "jobs" && parts.size == 1) {
                        if (i < args.size && digits(args[i]) && args[i].isNotEmpty()) i += 1
                        continue
                    }
                    if (name == "debug" && parts.size == 2 && Sw.chars(parts[1]).all { Sw.isLetter(it) }) continue
                    if (name in makeLongOK && parts.size == 1) continue
                    return unsafe
                }
                if (Sw.hasPrefix(a, "-") && Sw.count(a) > 1) {
                    if (!isMake) return unsafe
                    val letters = Sw.chars(Sw.dropFirst(a))
                    var k = 0
                    while (k < letters.size) {
                        val ch = letters[k]
                        k += 1
                        if (ch in makeShortDry) { dry = true; continue }
                        if (ch in makeShortOK) continue
                        if (ch == "j") {
                            val attached = letters.subList(k, letters.size).joinToString("")
                            if (attached.isEmpty()) {
                                if (i < args.size && args[i].isNotEmpty() && digits(args[i])) i += 1
                            } else if (!digits(attached)) {
                                return unsafe
                            }
                            break
                        }
                        return unsafe // -f, -C, -I, -E, -o, -W, -t, -l, -O or one it does not know
                    }
                    continue
                }
                if (a == "-") return unsafe
                if (a.contains("=")) return unsafe // NAME=value overrides a make or just variable
                targets.add(a)
            }
            // A dry run still runs `+` lines, `$(MAKE)` recursion and `$(shell ...)`
            // (GNU make), and `-q` runs the same: never Undoable.
            if (dry) return considered("make -n/-q still runs \$(shell), \$(MAKE) and + lines")
            val ok = setOf("test", "tests", "check", "build", "all", "lint", "typecheck", "vet", "fmt-check", "verify")
            if (targets.isNotEmpty() && targets.all { it.lowercase() in ok }) {
                return Verdict(Reversibility.UNDOABLE, listOf(Tag.RUNS_COMMANDS), "build or test")
            }
            return considered("make target")
        }

        private fun classifyNodePackage(cmd: String, args: List<String>): Verdict {
            val v = classifyNodePackageSub(cmd, args)
            // A shell, prefix, config or preload option changes what the script runs.
            val before = args.takeWhile { it != "--" }
            if (v.level < CONSIDERED &&
                hasOption(
                    before,
                    listOf(
                        "script-shell", "shell", "prefix", "userconfig", "globalconfig", "cwd", "dir", "preload", "require", "registry",
                        "node-options", "config", "cache", "workspace-root",
                    ),
                    shorts = "Cr",
                )
            ) {
                return considered("$cmd option can change what runs")
            }
            if (v.level < CONSIDERED && optionPointsOutside(before)) return considered("$cmd option points outside the project")
            // Whatever follows `--` goes to the script (jest's --outputFile, a build's --outDir), so it is not judged.
            if (v.level < CONSIDERED) {
                val dash = args.indexOf("--")
                if (dash >= 0 && dash + 1 < args.size) return considered("$cmd passes arguments to the script")
            }
            return v
        }

        private fun classifyNodePackageSub(cmd: String, args: List<String>): Verdict {
            val nonFlags = args.takeWhile { it != "--" }.filter { !Sw.hasPrefix(it, "-") }
            val sub = nonFlags.firstOrNull() ?: ""
            val safeScripts = listOf("test", "lint", "build", "check", "typecheck", "type-check", "verify", "tsc", "format:check", "types", "compile")
            fun safeScript(name: String): Boolean {
                val n = name.lowercase()
                return safeScripts.any { n == it || Sw.hasPrefix(n, "$it:") || Sw.hasPrefix(n, "$it-") }
            }
            if (cmd == "bun" && sub == "build") return considered("bun build writes bundles")
            when (sub) {
                "test", "t", "tst", "lint", "build", "typecheck", "check" ->
                    return Verdict(Reversibility.UNDOABLE, listOf(Tag.RUNS_COMMANDS), "test or build")
                "run", "run-script" -> {
                    val script = nonFlags.drop(1).firstOrNull() ?: ""
                    return if (safeScript(script)) Verdict(Reversibility.UNDOABLE, listOf(Tag.RUNS_COMMANDS), "test or build script") else considered("runs a package script")
                }
                "config" -> {
                    // `npm config set script-shell x` changes what every script runs.
                    return if ((nonFlags.drop(1).firstOrNull() ?: "") in listOf("get", "list", "ls")) readOnly("package query") else considered("$cmd config")
                }
                "version" -> {
                    // Bare, it prints versions; with a bump it edits package.json and tags the repo.
                    return if (args.size == 1) readOnly("package query") else considered("$cmd version bumps the package")
                }
                "ls", "list", "view", "info", "outdated", "why", "--version", "-v", "explain", "help" -> return readOnly("package query")
                "publish", "unpublish", "deprecate", "dist-tag", "owner", "access", "login", "adduser", "token" ->
                    return Verdict(IRREVERSIBLE, listOf(Tag.NETWORK_OUTSIDE, Tag.DESTRUCTIVE), "publishes a package")
                "install", "i", "ci", "add", "update", "up", "upgrade", "remove", "uninstall", "rm", "link", "init", "create", "dlx", "exec", "start" ->
                    return Verdict(CONSIDERED, listOf(Tag.NETWORK_OUTSIDE), "$cmd changes packages")
                else -> {
                    if (sub.isEmpty()) return considered(cmd)
                    if ((cmd == "yarn" || cmd == "pnpm" || cmd == "bun") && safeScript(sub)) {
                        return Verdict(Reversibility.UNDOABLE, listOf(Tag.RUNS_COMMANDS), "test or build script")
                    }
                    return considered("$cmd $sub")
                }
            }
        }

        /**
         * Cloud, container and publish CLIs. Anything that deploys, deletes or
         * publishes is irreversible; plain queries are undoable; the rest is
         * considered.
         */
        private fun classifyInfra(cmd: String, args: List<String>): Verdict {
            val subs = args.filter { !Sw.hasPrefix(it, "-") }.take(4).map { it.lowercase() }
            val network = listOf(Tag.NETWORK_OUTSIDE)
            if (subs.any { it in destructiveWords }) {
                return Verdict(IRREVERSIBLE, network + Tag.DESTRUCTIVE, "$cmd ${subs.firstOrNull { it in destructiveWords } ?: ""} changes live systems")
            }
            val apply = setOf("apply", "up", "push", "replace", "install", "upgrade", "release", "promote", "migrate")
            if (cmd in listOf("kubectl", "terraform", "tofu", "terragrunt", "pulumi", "helm", "oc") && subs.any { it in apply }) {
                return Verdict(IRREVERSIBLE, network + Tag.DESTRUCTIVE, "$cmd changes live infrastructure")
            }
            // `pulumi watch` keeps deploying to the stack as files change, with no confirmation.
            if (cmd == "pulumi" && subs.firstOrNull() == "watch") {
                return Verdict(IRREVERSIBLE, network + Tag.DESTRUCTIVE, "pulumi watch keeps deploying to live infrastructure")
            }
            // `terraform test` applies its plans to real resources unless the providers are mocked.
            if ((cmd == "terraform" || cmd == "tofu") && subs.firstOrNull() == "test") {
                return Verdict(IRREVERSIBLE, network + Tag.DESTRUCTIVE, "$cmd test creates real resources")
            }
            if ((cmd == "docker" || cmd == "podman") && subs.firstOrNull() == "push") {
                return Verdict(IRREVERSIBLE, network + Tag.DESTRUCTIVE, "pushes an image")
            }
            if ((cmd == "docker" || cmd == "podman") && (subs.firstOrNull() == "system" || subs.firstOrNull() == "volume" || subs.firstOrNull() == "image") && "prune" in subs) {
                return Verdict(IRREVERSIBLE, network + Tag.DESTRUCTIVE, "prunes containers or images")
            }
            // The CDK CLIs run the app (`--app`, cdk.json) to synthesize before they diff, list or
            // synthesize: only asking for their version or help is a query.
            if (cmd == "cdk" || cmd == "cdktf") {
                val query = setOf("--version", "-v", "--help", "-h", "version", "help")
                if (args.all { it in query } && args.isNotEmpty()) {
                    return Verdict(Reversibility.UNDOABLE, listOf(Tag.READ_ONLY), "$cmd version")
                }
                return Verdict(CONSIDERED, network, Sw.trimWs("$cmd ${subs.firstOrNull() ?: ""} runs the CDK app"))
            }
            // Terragrunt parses terragrunt.hcl (which can `run_cmd`) and runs its hooks before it
            // passes any command, even `version` or `fmt`, through to terraform: never a query.
            if (cmd == "terragrunt") {
                return Verdict(CONSIDERED, network, "terragrunt runs terragrunt.hcl")
            }
            // Options that point a CLI at another config, cluster, host or server (a kubeconfig or
            // docker config can name a program to run) or make it write a file are not a plain query.
            val before = args.takeWhile { it != "--" }
            val shorts = if (cmd == "docker" || cmd == "podman") "H" else if (cmd == "kubectl" || cmd == "oc") "s" else ""
            if (hasOption(
                    before,
                    listOf(
                        "kubeconfig", "server", "token", "as", "as-group", "certificate-authority", "client-certificate", "client-key",
                        "chdir", "endpoint-url", "ca-bundle", "cli-input-json", "cli-input-yaml", "host", "config", "kube-apiserver",
                        "insecure-skip-tls-verify", "out", "generate-config-out",
                    ),
                    shorts = shorts,
                )
            ) {
                return Verdict(CONSIDERED, network, "$cmd option points somewhere else or writes a file")
            }
            val firstSub = subs.firstOrNull()
            if (firstSub != null && firstSub in readOnlySubcommands) {
                // `plan`, `validate`, `show` and `preview` start provider plugins and run project code
                // (a `data "external"` block, a Pulumi program), like the CDK app above: only asking for
                // a version or help, a format check or `whoami` is a query.
                if (cmd in listOf("terraform", "tofu", "terragrunt", "pulumi") && firstSub !in listOf("version", "help", "fmt", "whoami")) {
                    return Verdict(CONSIDERED, network, "$cmd $firstSub runs providers or project code")
                }
                // `terraform fmt` rewrites files unless it only checks.
                if (firstSub == "fmt" && !("-check" in args || "-write=false" in args)) {
                    return Verdict(CONSIDERED, network, "$cmd fmt rewrites files")
                }
                return Verdict(Reversibility.UNDOABLE, listOf(Tag.READ_ONLY), "$cmd query")
            }
            // aws <service> <operation>: the operation is the second word, not any value after it.
            // `get-object` and `get-*-torrent` write a local file.
            if (cmd == "aws") {
                val operation = if (subs.size > 1) subs[1] else ""
                if (Sw.hasPrefix(operation, "get-object")) return Verdict(CONSIDERED, network, "aws get-object writes a file")
                if (Sw.hasPrefix(operation, "describe") || Sw.hasPrefix(operation, "list") || Sw.hasPrefix(operation, "get-") || operation == "get" || operation == "ls") {
                    return Verdict(Reversibility.UNDOABLE, listOf(Tag.READ_ONLY), "aws query")
                }
            } else if (cmd == "gcloud" || cmd == "az") {
                val mutators = setOf(
                    "create", "update", "set", "add", "start", "stop", "restart", "reset", "invoke", "run", "exec", "ssh",
                    "scp", "copy", "cp", "mv", "sync", "put", "patch", "import", "export", "attach", "detach", "enable",
                    "disable", "login", "resize", "scale", "rotate", "tag", "untag", "deploy", "call", "execute",
                )
                if (subs.none { it in mutators } &&
                    subs.any { Sw.hasPrefix(it, "describe") || Sw.hasPrefix(it, "list") || Sw.hasPrefix(it, "get-") || it == "get" || it == "ls" || it == "show" }
                ) {
                    return Verdict(Reversibility.UNDOABLE, listOf(Tag.READ_ONLY), "$cmd query")
                }
            }
            return Verdict(CONSIDERED, network, Sw.trimWs("$cmd ${subs.firstOrNull() ?: ""}"))
        }
    }
}
