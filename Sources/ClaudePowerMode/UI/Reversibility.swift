import Foundation

/// How hard a pending tool call is to take back. Drives the shape of a Decide
/// row, which keys it offers, and the chip on it (v4 trust model, section 4).
///
/// Conservative by construction: only a command Page positively recognises as
/// read-only, test or build is `.undoable`. Anything it cannot read, parse or
/// place is at least `.considered`; destructive deletes, force pushes,
/// dropped data, deploys and publishes, `sudo` and `curl | sh` are
/// `.irreversible`. A chip is a hint, never a "safe" badge.
enum Reversibility: Int, Comparable, CaseIterable, Equatable, Hashable, Codable {
    case undoable = 0
    case considered = 1
    case irreversible = 2

    static func < (a: Reversibility, b: Reversibility) -> Bool { a.rawValue < b.rawValue }

    /// Short reason tags shown next to (and sent with) the class.
    enum Tag: String, Equatable, Hashable, Codable {
        case readOnly = "Read-only"
        case editsInRepo = "Edits in repo"
        case runsCommands = "Runs commands"
        case networkOutside = "Network/outside repo"
        case destructive = "Destructive"
    }

    struct Verdict: Equatable, Hashable, Codable {
        var level: Reversibility
        var tags: [Tag]
        /// One short plain reason ("rm deletes files"), for tooltips and logs.
        var reason: String

        static func combine(_ a: Verdict, _ b: Verdict) -> Verdict {
            var tags = a.tags
            for t in b.tags where !tags.contains(t) { tags.append(t) }
            // The reason that explains the worse class wins; ties keep the first.
            return Verdict(level: max(a.level, b.level), tags: tags, reason: b.level > a.level ? b.reason : a.reason)
        }
    }

    // MARK: entry points

    /// Pure. Classifies a tool call from its structured input, the way the
    /// agent made it: `toolName` and the full, unredacted, unclipped `input`
    /// dictionary (`command` for Bash, never its `description`; `file_path` /
    /// `notebook_path` for the file tools). This is the entry point to trust:
    /// a page's display text is redacted, clipped and carries the description
    /// as a second line, none of which `classify(context:)` can undo. `cwd` is
    /// the session's project directory, used to tell paths inside it from
    /// outside.
    static func classify(toolName: String, input: [String: Any], cwd: String?) -> Verdict {
        func string(_ key: String) -> String? { input[key] as? String }
        if toolName == "Bash" {
            guard let command = string("command"), !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return unknown("no command shown")
            }
            let v = classifyBash(command, depth: 0)
            // Running outside the sandbox is never routine.
            if v.level < .considered, flag(input["dangerouslyDisableSandbox"]) {
                return Verdict(level: .considered, tags: v.tags, reason: "runs outside the sandbox")
            }
            return v
        }
        let path = string("file_path") ?? string("notebook_path") ?? ""
        return classifyTool(named: toolName, path: path, cwd: cwd)
    }

    /// Pure. Several tool calls waiting at once (parallel calls): the worst of
    /// them. Nil for no calls.
    static func classify(calls: [(name: String, input: [String: Any])], cwd: String?) -> Verdict? {
        let verdicts = calls.map { classify(toolName: $0.name, input: $0.input, cwd: cwd) }
        guard let first = verdicts.first else { return nil }
        return verdicts.dropFirst().reduce(first, Verdict.combine)
    }

    /// The fields of a tool call's input that `classify(toolName:input:cwd:)`
    /// reads, as strings (a bool becomes "true" / "false"). Small enough to
    /// keep next to a parsed transcript; everything else in the input (file
    /// contents, edit text) is dropped.
    static func classifierFields(toolName: String, input: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for key in ["command", "file_path", "notebook_path"] {
            if let v = input[key] as? String { out[key] = v }
        }
        if flag(input["dangerouslyDisableSandbox"]) { out["dangerouslyDisableSandbox"] = "true" }
        return out
    }

    private static func flag(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let s = value as? String { return s.lowercased() == "true" }
        return false
    }

    /// Pure. Classifies what a page's `context` shows. `context` is the text
    /// `InterventionDetector.describeToolUse` writes ("[Bash] cmd\ndescription",
    /// "[Edit] path ...", "One of these is waiting for approval:\n• ..."), the
    /// hook's "$ cmd\n# description" (see `classifyHookBash`), or the hook's
    /// bare "Claude is waiting for your approval", which says nothing about
    /// the action and is therefore `.considered`. A page with
    /// several tool calls takes the worst of them. `cwd` is the session's
    /// project directory, used to tell edits inside it from edits outside.
    ///
    /// A conservative fallback for a page that carries no stored verdict:
    /// the text is display text (redacted, clipped, description appended), so
    /// a call is never `.undoable` when it was clipped, redacted or spans
    /// lines. Prefer `classify(toolName:input:cwd:)`.
    static func classify(context: String, cwd: String?) -> Verdict {
        let text = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let multiHeader = "One of these is waiting for approval:"
        var v: Verdict
        if text.hasPrefix(multiHeader) {
            let body = String(text.dropFirst(multiHeader.count))
            let entries = body.components(separatedBy: "\n• ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .map { $0.hasPrefix("• ") ? String($0.dropFirst(2)) : $0 }
                .filter { !$0.isEmpty }
            guard !entries.isEmpty else { return unknown("no tool call to read") }
            let verdicts = entries.map { classifyEntry($0, cwd: cwd) }
            v = verdicts.dropFirst().reduce(verdicts[0], Verdict.combine)
        } else if text.hasPrefix("$ ") {
            v = classifyHookBash(text)
        } else {
            v = classifyEntry(text, cwd: cwd)
        }
        // A page that reached the length limit was cut somewhere.
        if text.count >= InterventionDetector.contextLimit, v.level < .considered {
            v = Verdict(level: .considered, tags: v.tags, reason: "the command was cut short")
        }
        return v
    }

    /// A page posted by hooks/page-notify.sh shows a Bash call as
    /// `"$ <command>\n# <description>"` (the command clipped at 1200 characters
    /// with "…", the whole text redacted), then maybe a "— recent activity —"
    /// tail. The command is every line from the `$ ` up to the description's
    /// `# ` line or the tail, so a command that spans lines, or a second `$ `
    /// line, is judged whole; the description, which the model writes, and the
    /// tail are ignored. The text can only ever raise the verdict to
    /// `.irreversible`: it is never `.undoable`, since a hook row is a page to
    /// answer, not a command to wave through, and a clipped, redacted or longer
    /// text may hide what runs. A command that is `.irreversible` on its own
    /// stays so.
    private static func classifyHookBash(_ text: String) -> Verdict {
        var head = text.replacingOccurrences(of: "\r\n", with: "\n")
        // The last marker: a command that quotes the marker must not hide what follows it.
        if let tail = head.range(of: "\n\n— recent activity —", options: .backwards) { head = String(head[..<tail.lowerBound]) }
        var lines = head.components(separatedBy: "\n")
        lines[0] = String(lines[0].dropFirst(2))
        if let end = lines.indices.dropFirst().first(where: { lines[$0].hasPrefix("# ") || lines[$0] == "#" }) {
            lines.removeSubrange(end...)
        }
        let raw = lines.joined(separator: "\n")
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, command != "(no command)" else { return unknown("no command shown") }
        let v = classifyBash(command, depth: 0)
        guard v.level < .considered else { return v }
        let why: String
        if command.hasSuffix("…") || raw.count >= InterventionDetector.contextLimit { why = "the command was cut short" }
        else if command.contains("[redacted") { why = "part of the command was hidden" }
        else if command.contains("\n") { why = "more than one line of command" }
        else { why = "a hook page's command isn't confirmed" }
        return Verdict(level: .considered, tags: v.tags, reason: why)
    }

    /// Pure. Classifies a shell command line the way Claude's Bash tool would
    /// run it. Empty input is `.considered` (nothing to judge).
    static func classifyBash(_ command: String) -> Verdict {
        classifyBash(command, depth: 0)
    }

    // MARK: one tool call

    private static func classifyEntry(_ entry: String, cwd: String?) -> Verdict {
        let v = classifyEntryCore(entry, cwd: cwd)
        guard v.level < .considered else { return v }
        let text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        // A page's text is clipped to a fixed length ("…"): whatever was cut
        // off might be the dangerous part, so a clipped call is never Undoable.
        if text.hasSuffix("…") || text.count >= InterventionDetector.contextLimit {
            return Verdict(level: .considered, tags: v.tags, reason: "the command was cut short")
        }
        // Secrets are masked in the text; the masked part is not what runs,
        // and a mask can swallow the clip marker above.
        if text.contains("[redacted") {
            return Verdict(level: .considered, tags: v.tags, reason: "part of the command was hidden")
        }
        return v
    }

    private static func classifyEntryCore(_ entry: String, cwd: String?) -> Verdict {
        var text = entry
        if text.hasPrefix("A subagent is asking for approval") {
            return Verdict(level: .considered, tags: [.runsCommands], reason: "a subagent is asking; its action isn't shown")
        }
        if text.hasPrefix("Plan ready for review") {
            return Verdict(level: .considered, tags: [], reason: "plan approval")
        }
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else {
            return unknown("the action isn't shown")
        }
        let name = String(text[text.index(after: text.startIndex)..<close])
        text = String(text[text.index(after: close)...]).trimmingCharacters(in: CharacterSet(charactersIn: " "))
        let lines = text.components(separatedBy: "\n")
        let first = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""

        if name == "Bash" {
            return classifyBashTool(first: first, rest: Array(lines.dropFirst()))
        }
        // MultiEdit's line reads "path (3 edits)".
        let path = ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(name) ? (first.components(separatedBy: " (").first ?? first) : first
        return classifyTool(named: name, path: path, cwd: cwd)
    }

    /// Every tool but Bash, from its name and the path it works on (empty when
    /// it has none). Shared by the structured and the text entry points so
    /// they cannot disagree.
    private static func classifyTool(named name: String, path: String, cwd: String?) -> Verdict {
        switch name {
        case "Read", "Glob", "Grep", "LS", "NotebookRead":
            // Reading never changes anything; outside the project it can still
            // be a surprise, so it is not offered the Return shortcut.
            if name == "Read", !isInside(path: path, cwd: cwd) {
                return Verdict(level: .considered, tags: [.networkOutside], reason: "reads outside the project")
            }
            return Verdict(level: .undoable, tags: [.readOnly], reason: "read-only")
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            if isInside(path: path, cwd: cwd) {
                return Verdict(level: .considered, tags: [.editsInRepo], reason: "edits a file in the project")
            }
            return Verdict(level: .considered, tags: [.networkOutside], reason: "edits a file outside the project")
        case "WebFetch", "WebSearch":
            return Verdict(level: .considered, tags: [.networkOutside], reason: "reaches the network")
        case "Task", "Agent":
            return Verdict(level: .considered, tags: [.runsCommands], reason: "starts a subagent")
        default:
            return Verdict(level: .considered, tags: [.runsCommands], reason: "\(name) isn't one Page can read")
        }
    }

    private static func unknown(_ why: String) -> Verdict {
        Verdict(level: .considered, tags: [], reason: why)
    }

    /// The context is `"[Bash] <command>\n<description>"`, but a command can
    /// itself span lines and the description is joined with a bare newline, so
    /// the two cannot be told apart reliably (and on a case-insensitive volume
    /// a capitalised "description" such as `Find . -delete` really runs).
    /// Every line is therefore judged as command text, and a call with more
    /// than one line is never `.undoable`.
    private static func classifyBashTool(first: String, rest: [String]) -> Verdict {
        let extra = rest.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !first.isEmpty, first != "(no command)" else { return unknown("no command shown") }
        var v = classifyBash(([first] + extra).joined(separator: "\n"), depth: 0)
        if !extra.isEmpty, v.level < .considered {
            v = Verdict(level: .considered, tags: v.tags, reason: "more than one line; a description can't be told from a command")
        }
        return v
    }

    /// An unterminated quote, backslash continuation or heredoc: the command
    /// carries on onto the next line.
    private static func endsOpen(_ line: String) -> Bool {
        if line.hasSuffix("\\") || line.contains("<<") { return true }
        var single = false, double = false, escaped = false
        for ch in line {
            if escaped { escaped = false; continue }
            if ch == "\\" && !single { escaped = true; continue }
            if ch == "'" && !double { single.toggle() }
            else if ch == "\"" && !single { double.toggle() }
        }
        return single || double
    }

    private static func isInside(path raw: String, cwd: String?) -> Bool {
        let path = raw.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, path != "?" else { return false }
        if path.hasPrefix("~") { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.contains("..") { return false }
        if !path.hasPrefix("/") { return true } // relative to the project
        guard let cwd, !cwd.isEmpty else { return false }
        let base = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return path == base || path.hasPrefix(base + "/")
    }

    // MARK: shell

    private static func classifyBash(_ command: String, depth: Int) -> Verdict {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return unknown("no command shown") }
        guard depth < 4 else { return Verdict(level: .considered, tags: [.runsCommands], reason: "deeply nested command") }

        let parsed = ShellParse.parse(trimmed)
        var verdicts: [Verdict] = []
        var downloaderInPipeline = false

        for seg in parsed.segments {
            if !seg.afterPipe { downloaderInPipeline = false }
            var v = classifySegment(seg, depth: depth, pipedFromDownloader: seg.afterPipe && downloaderInPipeline)
            if seg.writes && v.level < .considered {
                v = Verdict(level: .considered, tags: [.runsCommands], reason: "writes to a file")
            }
            if let cmd = commandName(of: seg), ["curl", "wget", "fetch"].contains(cmd) { downloaderInPipeline = true }
            verdicts.append(v)
        }
        for inner in parsed.substitutions {
            var v = classifyBash(inner, depth: depth + 1)
            if v.level < .considered { v = Verdict(level: .considered, tags: v.tags, reason: "runs a nested command") }
            verdicts.append(v)
        }
        if parsed.hasOpaqueHeredoc {
            verdicts.append(Verdict(level: .considered, tags: [.runsCommands], reason: "script passed in as text"))
        }
        for body in parsed.interpreterHeredocBodies where matchesDestructiveText(body) != nil {
            verdicts.append(Verdict(level: .irreversible, tags: [.destructive], reason: matchesDestructiveText(body) ?? "destructive"))
        }
        guard var result = verdicts.reduce(nil, { (acc: Verdict?, v) in acc.map { Verdict.combine($0, v) } ?? v }) else {
            // Only keywords, comments or assignments: nothing runs.
            return Verdict(level: .undoable, tags: [.readOnly], reason: "no command")
        }
        if result.level == .irreversible, !result.tags.contains(.destructive) { result.tags.append(.destructive) }
        if result.level == .undoable, result.tags.isEmpty { result.tags = [.readOnly] }
        return result
    }

    /// The program name of a segment after wrappers, or nil.
    private static func commandName(of seg: ShellParse.Segment) -> String? {
        stripWrappers(seg.words).words.first.map(baseName)
    }

    private static func baseName(_ word: String) -> String {
        (word as NSString).lastPathComponent.lowercased()
    }

    private static let noopKeywords: Set<String> = ["for", "case", "esac", "fi", "done", "}", ")", "function", "select"]
    private static let prefixKeywords: Set<String> = ["if", "then", "else", "elif", "while", "until", "do", "!", "{", "(", "coproc"]
    /// Programs that run another program, so the real command is one step removed.
    private static let wrapperCommands: Set<String> = [
        "env", "command", "builtin", "exec", "nohup", "caffeinate", "time", "stdbuf", "ionice", "unbuffer", "nice", "timeout", "xargs"
    ]
    /// Environment variables that cannot change what a program does or runs.
    private static func isHarmlessEnvName(_ name: String) -> Bool {
        ["LANG", "TZ", "NO_COLOR", "TERM", "COLUMNS", "FORCE_COLOR", "CI"].contains(name) || name.hasPrefix("LC_")
    }

    /// `NAME=value` as the shell reads a variable assignment.
    private static func isAssignment(_ s: String) -> Bool {
        guard let eq = s.firstIndex(of: "="), eq != s.startIndex else { return false }
        let name = s[s.startIndex..<eq]
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } && !(name.first?.isNumber ?? false)
    }

    struct Stripped {
        var words: [String]
        var elevated = false
        var xargs = false
        /// Every `NAME=value` that was in front of (or after `env` in front of) the command.
        var assignments: [String] = []
        /// The wrapper programs that were peeled off ("env", "nohup", "time", ...).
        var wrappers: [String] = []
    }

    /// Drops env assignments, shell keywords and wrappers, but remembers what
    /// it dropped: the caller judges assignments and wrappers itself.
    private static func stripWrappers(_ input: [String]) -> Stripped {
        var w = input
        var out = Stripped(words: [])
        // Leading "(" / "{" glued to the first word.
        if let f = w.first, f.count > 1, f.hasPrefix("(") || f.hasPrefix("{") { w[0] = String(f.dropFirst()) }
        var guardCount = 0
        while let first = w.first, guardCount < 12 {
            guardCount += 1
            let name = baseName(first)
            if isAssignment(first) { out.assignments.append(first); w.removeFirst(); continue }
            if prefixKeywords.contains(first) { w.removeFirst(); continue }
            switch name {
            case "sudo", "doas", "su", "pkexec":
                out.elevated = true
                w.removeFirst()
            case "env", "command", "builtin", "exec", "nohup", "caffeinate", "time", "stdbuf", "ionice", "unbuffer":
                out.wrappers.append(name)
                w.removeFirst()
                while let f = w.first, f.hasPrefix("-") { w.removeFirst() }
            case "nice":
                out.wrappers.append(name)
                w.removeFirst()
                while let f = w.first, f.hasPrefix("-") {
                    w.removeFirst()
                    if f == "-n", !w.isEmpty { w.removeFirst() }
                }
            case "timeout":
                out.wrappers.append(name)
                w.removeFirst()
                while let f = w.first, f.hasPrefix("-") { w.removeFirst() }
                if !w.isEmpty { w.removeFirst() } // the duration
            case "xargs":
                out.wrappers.append(name)
                out.xargs = true
                w.removeFirst()
                let withValue: Set<String> = ["-n", "-I", "-P", "-L", "-s", "-d", "-E", "-J", "-a"]
                while let f = w.first, f.hasPrefix("-") {
                    w.removeFirst()
                    if withValue.contains(f), !w.isEmpty { w.removeFirst() }
                }
            default:
                out.words = w
                return out
            }
        }
        out.words = w
        return out
    }

    /// Assignments in front of a command can change what it runs (`LD_PRELOAD`,
    /// `GIT_SSH_COMMAND`, `PAGER`, ...). Only a short list of names that cannot
    /// is waved through; a value that is itself destructive text is worse.
    private static func assignmentVerdict(_ assignments: [String]) -> Verdict? {
        var result: Verdict?
        for a in assignments {
            guard let eq = a.firstIndex(of: "=") else { continue }
            let name = String(a[a.startIndex..<eq])
            let value = String(a[a.index(after: eq)...])
            let v: Verdict
            if let why = matchesDestructiveText(value) {
                v = destroy(why)
            } else if isHarmlessEnvName(name) {
                continue
            } else {
                v = considered("sets \(name) for the command")
            }
            result = result.map { Verdict.combine($0, v) } ?? v
        }
        return result
    }

    // MARK: segments

    private static let textOnly: Set<String> = [
        "ls", "cat", "head", "tail", "less", "more", "wc", "grep", "egrep", "fgrep", "rg", "ag", "ack", "fd", "pwd",
        "echo", "printf", "which", "whereis", "type", "whoami", "id", "date", "uname", "hostname", "printenv", "df",
        "du", "ps", "stat", "file", "tree", "diff", "cmp", "sort", "uniq", "cut", "tr", "jq", "yq", "basename",
        "dirname", "realpath", "readlink", "test", "[", "[[", "true", "false", ":", "sleep", "cd", "pushd", "popd",
        "md5", "md5sum", "shasum", "sha256sum", "sha1sum", "hexdump", "xxd", "strings", "nl", "column", "fold",
        "paste", "comm", "join", "seq", "expr", "tput", "uptime", "sw_vers", "arch", "lsof", "pgrep", "nproc",
        "locale", "set", "unset", "export", "alias", "wait", "read", "exit", "return", "bat", "eza", "exa", "tac",
        "rev", "od", "base64", "git-lfs", "cloc", "tokei", "mdfind", "mdls", "pbpaste", "ioreg", "system_profiler"
    ]

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
    private static let scriptInterpreters: Set<String> = ["python", "python3", "node", "ruby", "perl", "php", "deno", "bun"]
    private static let sqlClients: Set<String> = ["psql", "mysql", "sqlite3", "mongosh", "mongo", "redis-cli", "mariadb", "usql", "dropdb"]
    private static let networkCommands: Set<String> = ["curl", "wget", "ssh", "scp", "rsync", "sftp", "ftp", "nc", "telnet", "ping"]
    private static let infraCLIs: Set<String> = [
        "aws", "gcloud", "az", "kubectl", "helm", "terraform", "tofu", "terragrunt", "pulumi", "cdktf", "heroku", "fly", "flyctl", "vercel",
        "netlify", "wrangler", "firebase", "serverless", "sls", "cdk", "supabase", "railway", "doctl", "gh", "docker",
        "podman", "npm", "yarn", "pnpm", "cargo", "gem", "twine", "bun", "hub", "az", "oc", "eb", "sam", "amplify"
    ]
    private static let destructiveWords: Set<String> = [
        "deploy", "publish", "destroy", "delete", "remove", "rm", "rmi", "rb", "prune", "purge", "terminate", "drop",
        "wipe", "erase", "unpublish", "yank", "undeploy", "teardown", "rollback", "uninstall-all"
    ]
    private static let readOnlySubcommands: Set<String> = [
        "get", "describe", "list", "ls", "logs", "show", "status", "view", "info", "version", "plan", "validate", "diff",
        "whoami", "ps", "images", "inspect", "top", "explain", "api-resources", "cluster-info", "events", "search",
        "outdated", "config-view", "help", "--version", "-v", "--help", "-h", "fmt", "checks", "watch", "history", "stats"
    ]

    private static func classifySegment(_ seg: ShellParse.Segment, depth: Int, pipedFromDownloader: Bool) -> Verdict {
        let stripped = stripWrappers(seg.words)
        // `command -v name` only looks a name up.
        if seg.words.count == 3, seg.words[0] == "command", ["-v", "-V"].contains(seg.words[1]) {
            return readOnly("looks up a command")
        }
        var v = classifyCommand(seg, stripped.words, elevated: stripped.elevated, depth: depth, pipedFromDownloader: pipedFromDownloader)
        // What was peeled off is judged too: the assignments (they can change
        // what the command runs) and the wrappers (they run something else).
        if let a = assignmentVerdict(stripped.assignments) { v = Verdict.combine(v, a) }
        if !stripped.wrappers.isEmpty, v.level < .considered {
            if !(stripped.wrappers == ["env"] && seg.words.count == 1) {
                v = Verdict.combine(v, considered("\(stripped.wrappers[0]) runs another command"))
            }
        }
        return v
    }

    /// A program started by a path is only trusted from the system's own
    /// directories: `./cat` or `/tmp/x/ls` is somebody's script, not `cat`.
    private static func isTrustedPath(_ head: String) -> Bool {
        guard head.contains("/") else { return true }
        let trusted = ["/bin/", "/usr/bin/", "/usr/local/bin/", "/opt/homebrew/bin/", "/usr/sbin/", "/sbin/"]
        if trusted.contains(where: { head.hasPrefix($0) && !head.dropFirst($0.count).contains("/") }) { return true }
        return head == "./gradlew" || head == "./mvnw"
    }

    private static func classifyCommand(_ seg: ShellParse.Segment, _ words: [String], elevated: Bool, depth: Int, pipedFromDownloader: Bool) -> Verdict {
        if elevated {
            return Verdict(level: .irreversible, tags: [.runsCommands, .destructive], reason: "runs with sudo")
        }
        guard let head = words.first else { return Verdict(level: .undoable, tags: [], reason: "no command") }
        if noopKeywords.contains(head) {
            // Closers are only syntax; an opener can carry a whole command
            // (`case x in x) rm -f y;;`, `for x do rm y; done`).
            let openers: Set<String> = ["case", "select", "function"]
            let rest = words.dropFirst()
            if openers.contains(head) || (head == "for" && rest.contains { prefixKeywords.contains($0) || $0.hasSuffix(")") }) {
                return considered("shell \(head) block")
            }
            return Verdict(level: .undoable, tags: [], reason: "shell syntax")
        }
        let cmd = baseName(head)
        let args = Array(words.dropFirst())
        if cmd.hasPrefix("mkfs") { return destroy("mkfs formats a disk") }
        if !isTrustedPath(head) {
            // Still spot destructive names/text behind a path.
            let inner = classifyCommand(seg, [cmd] + args, elevated: false, depth: depth, pipedFromDownloader: pipedFromDownloader)
            return inner.level == .irreversible ? inner : considered("runs a program by path")
        }

        // Anything piped into a shell from a download runs unseen code.
        if (shells.contains(cmd) || scriptInterpreters.contains(cmd)),
           pipedFromDownloader, !args.contains("-c") {
            return destroy("runs a download unseen")
        }

        switch cmd {
        case "rm", "rmdir", "unlink", "shred", "srm":
            return destroy("\(cmd) deletes files")
        case "dd", "fdisk", "gdisk", "parted", "newfs", "newfs_apfs":
            return destroy("\(cmd) writes straight to a disk")
        case "truncate":
            return destroy("truncate empties files")
        case "reboot", "shutdown", "halt", "poweroff":
            return destroy("\(cmd) stops the Mac")
        case "diskutil":
            let sub = args.first?.lowercased() ?? ""
            if ["list", "info", "activity"].contains(sub) { return readOnly("disk info") }
            if sub.contains("erase") || sub.contains("partition") || sub.contains("secure") || sub.hasPrefix("zero") {
                return destroy("diskutil changes disks")
            }
            return considered("diskutil")
        case "crontab":
            return args.contains("-r") ? destroy("removes every cron job") : considered("edits cron")
        case "git":
            return classifyGit(args)
        case "find":
            return classifyFind(args, depth: depth)
        case "sed":
            return classifySed(args)
        case "awk", "gawk", "mawk", "nawk":
            return classifyAwk(args)
        case "tee":
            return considered("tee writes files")
        case "sh", "bash", "zsh", "dash", "ksh", "fish":
            return classifyShellInvocation(cmd, args, depth: depth)
        case "eval":
            return combineConsidered(classifyBash(args.joined(separator: " "), depth: depth + 1), "eval")
        case "source", ".":
            return considered("runs a script")
        case "python", "python3", "node", "ruby", "perl", "php", "deno":
            return classifyScriptInterpreter(cmd, args)
        case "npx", "bunx", "pnpx":
            // `npx pulumi up` runs the CLI it names: judge that, so it is as irreversible as `pulumi up`.
            // Anything else it runs is a downloaded program, which is not one Page recognises.
            let named = Array(args.drop(while: { ["-y", "--yes", "-q", "--quiet", "--no-install"].contains($0) }))
            if let first = named.first, !first.hasPrefix("-") {
                let tool = first.firstIndex(of: "@").flatMap { $0 == first.startIndex ? nil : String(first[..<$0]) } ?? first
                if infraCLIs.contains(baseName(tool)) {
                    let v = classifyInfra(baseName(tool), Array(named.dropFirst()))
                    return v.level < .considered ? Verdict(level: .considered, tags: v.tags, reason: "\(cmd) may download \(tool)") : v
                }
            }
        case "bundle":
            if args.first == "exec", args.count > 1 {
                return classifySegment(.init(words: Array(args.dropFirst()), writes: false, afterPipe: false, hasHeredoc: false, heredocBodies: []),
                                       depth: depth, pipedFromDownloader: false)
            }
            return considered("bundler")
        case "ssh":
            return classifySSH(args, depth: depth)
        case "rsync":
            if args.contains(where: { $0.hasPrefix("--delete") }) { return destroy("rsync --delete removes files") }
            return Verdict(level: .considered, tags: [.networkOutside], reason: "copies files")
        case "curl", "wget":
            return Verdict(level: .considered, tags: [.networkOutside], reason: "reaches the network")
        case "swift":
            return classifySwift(args)
        case "cargo":
            return classifyCargo(args)
        case "go":
            return classifyGo(args)
        case "npm", "yarn", "pnpm", "bun":
            return classifyNodePackage(cmd, args)
        case "make", "gmake", "ninja", "just", "task":
            return classifyMake(cmd, args)
        case "pytest", "py.test", "tox", "nox", "jest", "vitest", "mocha", "ava", "rspec", "phpunit", "mypy", "pylint",
             "flake8", "pyright", "tsc", "swiftlint", "shellcheck", "tflint", "ctest", "bats", "xctest":
            if let why = riskyRunnerOption(cmd, args) { return considered(why) }
            return Verdict(level: .undoable, tags: [.runsCommands], reason: "test or lint run")
        case "ruff", "eslint", "prettier", "black", "isort", "swiftformat", "gofmt", "rustfmt", "clang-format":
            return classifyFormatter(cmd, args)
        case "xcodebuild":
            let acts = Set(args)
            if acts.contains("-exportArchive") || acts.contains("archive") { return considered("xcodebuild archive") }
            // Output paths, config files, provisioning, unvalidated plugins, and
            // BUILD_SETTING=value overrides (CC=, SWIFT_EXEC=, ...) change what runs or where it writes.
            let xcodeOptions = ["xcconfig", "resultBundlePath", "resultStreamPath", "archivePath", "exportPath", "exportOptionsPlist",
                                "toolchain", "allowProvisioningUpdates", "allowProvisioningDeviceRegistration", "authenticationKeyPath",
                                "authenticationKeyID", "authenticationKeyIssuerID", "clonedSourcePackagesDirPath", "packageCachePath",
                                "skipPackagePluginValidation", "skipMacroValidation", "xctestrun", "exportLocalizations",
                                "importLocalizations", "exportNotarizedApp", "resolvePackageDependencies", "usePackageSupportBuiltinSCM"]
            // A project or workspace outside the repo runs its build phases from there; a derived data path outside writes there.
            if hasOption(args, xcodeOptions) || args.contains(where: isBuildSettingOverride) || optionPointsOutside(args) {
                return considered("xcodebuild option or build setting can change what runs")
            }
            if acts.contains("build") || acts.contains("test") || acts.contains("-list") || acts.contains("-showBuildSettings")
                || acts.contains("build-for-testing") || acts.contains("test-without-building") {
                return Verdict(level: .undoable, tags: [.runsCommands], reason: "build or test")
            }
            return considered("xcodebuild")
        case "gradle", "gradlew", "mvn", "mvnw", "./gradlew":
            let ok: Set<String> = ["test", "build", "assemble", "check", "compile", "verify", "dependencies", "tasks",
                                   "compilejava", "compilekotlin", "lint", "--version", "-v", "-version", "package"]
            // Init scripts, build files, properties and plugins can run anything:
            // only a short list of plain flags is waved through.
            let harmless: Set<String> = ["q", "quiet", "i", "info", "w", "warn", "s", "stacktrace", "S", "full-stacktrace", "offline", "o",
                                         "no-daemon", "daemon", "continue", "parallel", "no-parallel", "build-cache", "no-build-cache",
                                         "rerun-tasks", "v", "version", "h", "help", "B", "batch-mode", "e", "errors", "ntp",
                                         "no-transfer-progress", "DskipTests", "DskipTests=true", "DskipTests=false", "console=plain",
                                         "console=auto", "console=rich", "console=verbose"]
            let flags = args.filter { $0.hasPrefix("-") && $0 != "-" }
            if !flags.allSatisfy({ harmless.contains($0.hasPrefix("--") ? String($0.dropFirst(2)) : String($0.dropFirst())) }) {
                return considered("build tool option can change what runs")
            }
            let isMaven = cmd.hasPrefix("mvn")
            let targets = args.filter { !$0.hasPrefix("-") }.map { $0.lowercased() }
            if isMaven, targets.contains(where: { $0.contains(":") }) { return considered("maven plugin goal") }
            if !targets.isEmpty, targets.allSatisfy({ ok.contains($0) || ok.contains($0.components(separatedBy: ":").last ?? "") }) {
                return Verdict(level: .undoable, tags: [.runsCommands], reason: "build or test")
            }
            return considered("build tool")
        case "dotnet":
            let sub = args.first ?? ""
            guard ["build", "test", "--version", "--info", "list"].contains(sub) else { return considered("dotnet") }
            // Properties (-p:), targets (-t:), loggers, output paths and settings files run or write things.
            let dotnetOK: Set<String> = ["no-restore", "no-build", "nologo", "c", "configuration", "v", "verbosity", "f", "framework",
                                         "filter", "no-dependencies", "version", "info", "outdated", "vulnerable", "deprecated",
                                         "include-transitive", "include-prerelease", "package", "reference"]
            let odd = args.dropFirst().filter { $0.hasPrefix("-") || $0.hasPrefix("/") }
                .contains { !dotnetOK.contains($0.trimmingCharacters(in: CharacterSet(charactersIn: "-/")).lowercased()) }
            if odd || positionalPointsOutside(Array(args.dropFirst())) { return considered("dotnet option can change what runs") }
            return Verdict(level: .undoable, tags: [.runsCommands], reason: "build or test")
        case "rake":
            // Every argument must be a known test task: `rake test deploy` runs deploy too.
            return !args.isEmpty && args.allSatisfy({ ["test", "spec", "-t", "-T", "--tasks"].contains($0) })
                ? Verdict(level: .undoable, tags: [.runsCommands], reason: "test run") : considered("rake task")
        case "brew":
            let sub = args.first ?? ""
            return ["info", "list", "ls", "search", "outdated", "--version", "--prefix", "deps", "config", "leaves", "desc", "doctor"].contains(sub)
                ? readOnly("brew query") : Verdict(level: .considered, tags: [.networkOutside], reason: "brew changes software")
        case "pip", "pip3", "pipx", "uv", "poetry":
            let sub = args.first ?? ""
            return ["list", "show", "freeze", "--version", "check", "index", "tree"].contains(sub)
                ? readOnly("package query") : Verdict(level: .considered, tags: [.networkOutside], reason: "changes packages")
        case "launchctl", "pmset", "defaults", "scutil", "networksetup", "systemsetup", "csrutil", "nvram":
            let sub = args.first ?? ""
            let reads: Set<String> = ["list", "print", "-g", "read", "--get", "-getcomputername", "status", "blame", "dumpstate", "version"]
            return reads.contains(sub) ? readOnly("system query") : considered("changes system settings")
        case "kill", "pkill", "killall":
            return considered("stops processes")
        case "mkdir", "touch", "cp", "mv", "ln", "chmod", "chown", "chgrp", "tar", "unzip", "zip", "gzip", "gunzip", "open",
             "osascript", "trash", "install", "patch", "xattr", "codesign", "plutil", "ditto":
            return considered("\(cmd) changes files or apps")
        case "docker", "podman":
            return classifyInfra(cmd, args)
        default:
            break
        }

        if infraCLIs.contains(cmd) { return classifyInfra(cmd, args) }
        if sqlClients.contains(cmd) {
            if cmd == "dropdb" { return destroy("dropdb deletes a database") }
            let text = args.joined(separator: " ")
            if let why = matchesDestructiveText(text) { return destroy(why) }
            if seg.hasHeredoc, let body = seg.heredocBodies.compactMap(matchesDestructiveText).first { return destroy(body) }
            return considered("talks to a database")
        }
        if cmd == "export", let a = assignmentVerdict(args.filter(isAssignment)) { return a }
        if textOnly.contains(cmd) {
            if let why = riskyTextToolUse(cmd, args) { return considered(why) }
            return readOnly("read-only command")
        }
        if networkCommands.contains(cmd) {
            return Verdict(level: .considered, tags: [.networkOutside], reason: "reaches the network")
        }
        // Unknown program: never undoable. Still, spot destructive text.
        if let why = matchesDestructiveText(words.joined(separator: " ")) { return destroy(why) }
        return considered("\(cmd) isn't one Page recognises")
    }

    // MARK: helpers for verdicts

    private static func destroy(_ why: String) -> Verdict {
        Verdict(level: .irreversible, tags: [.runsCommands, .destructive], reason: why)
    }
    private static func considered(_ why: String) -> Verdict {
        Verdict(level: .considered, tags: [.runsCommands], reason: why)
    }
    private static func readOnly(_ why: String) -> Verdict {
        Verdict(level: .undoable, tags: [.readOnly], reason: why)
    }
    private static func combineConsidered(_ v: Verdict, _ why: String) -> Verdict {
        v.level >= .considered ? v : Verdict(level: .considered, tags: [.runsCommands], reason: why)
    }

    /// Pure. A SQL or CLI phrase that destroys data, or nil.
    static func matchesDestructiveText(_ text: String) -> String? {
        let t = text.lowercased()
        let patterns: [(String, String)] = [
            (#"\bdrop\s+(table|database|schema|index|view|column|collection)\b"#, "drops data"),
            (#"\btruncate\s+(table\s+)?[a-z_"`]"#, "truncates a table"),
            (#"\bdelete\s+from\b"#, "deletes rows"),
            (#"\bflush(all|db)\b"#, "flushes a datastore"),
            (#"\bdb:(drop|reset)\b|\bmigrate:fresh\b|\bmigrate\s+reset\b|--force-reset|--accept-data-loss"#, "resets a database"),
            (#"\brm\s+-[a-z]*[rf]"#, "rm deletes files"),
            (#"\b(rmtree|rimraf|os\.remove|os\.unlink|fs\.rm|fs\.unlink|shutil\.rmtree)\b"#, "deletes files"),
            (#"git\s+push\s+.*(--force|-f\b)"#, "force-pushes"),
            (#"git\s+reset\s+--hard"#, "discards work")
        ]
        for (pattern, why) in patterns where t.range(of: pattern, options: .regularExpression) != nil { return why }
        return nil
    }

    // MARK: per-tool

    private static func classifyShellInvocation(_ shell: String, _ args: [String], depth: Int) -> Verdict {
        if let i = args.firstIndex(where: { $0 == "-c" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c")) }), i + 1 < args.count {
            return combineConsidered(classifyBash(args[i + 1], depth: depth + 1), "\(shell) -c runs a script")
        }
        return considered("runs a script")
    }

    private static func classifyScriptInterpreter(_ cmd: String, _ args: [String]) -> Verdict {
        // `-m module` counts only when it is the interpreter's own option: after a
        // script name or `-c code` it is just an argument to that script.
        let harmlessPythonFlags: Set<String> = ["-u", "-B", "-E", "-s", "-S", "-I", "-O", "-OO", "-b", "-bb", "-q"]
        if cmd == "python" || cmd == "python3", let m = args.firstIndex(of: "-m"), m + 1 < args.count,
           args[..<m].allSatisfy(harmlessPythonFlags.contains) {
            let module = args[m + 1]
            if ["pytest", "unittest", "mypy", "pylint", "flake8", "pyright", "doctest", "compileall"].contains(module) {
                let rest = Array(args[(m + 2)...])
                if module == "pytest" || module == "mypy" || module == "pylint" || module == "flake8" || module == "pyright" {
                    if let why = riskyRunnerOption(module, rest) { return considered(why) }
                } else if optionPointsOutside(rest) || positionalPointsOutside(rest)
                            || module == "doctest" && rest.contains(where: { $0.hasSuffix(".py") && pointsOutside($0) }) {
                    return considered("python -m \(module) points outside the project")
                }
                return Verdict(level: .undoable, tags: [.runsCommands], reason: "test or lint run")
            }
        }
        // A version query is the one option and nothing else: `node x.js --version`
        // hands the flag to the script.
        if args.count == 1, ["--version", "-V", "-VV", "-v", "-version"].contains(args[0]) {
            return readOnly("version")
        }
        let code = args.joined(separator: " ")
        if let why = matchesDestructiveText(code) { return destroy(why) }
        return considered("runs a script")
    }

    private static func classifySSH(_ args: [String], depth: Int) -> Verdict {
        let withValue: Set<String> = ["-p", "-i", "-l", "-o", "-F", "-J", "-L", "-R", "-D", "-b", "-c", "-E", "-e", "-m", "-O", "-Q", "-S", "-W", "-w", "-B", "-I"]
        var rest = args
        while let f = rest.first, f.hasPrefix("-") {
            rest.removeFirst()
            if withValue.contains(f), !rest.isEmpty { rest.removeFirst() }
        }
        guard !rest.isEmpty else { return Verdict(level: .considered, tags: [.networkOutside], reason: "opens a remote shell") }
        rest.removeFirst() // host
        let remote = classifyBash(rest.joined(separator: " "), depth: depth + 1)
        var v = Verdict(level: .considered, tags: [.networkOutside], reason: "runs on another machine")
        if !rest.isEmpty { v = Verdict.combine(v, remote) }
        return v
    }

    private static func classifyFind(_ args: [String], depth: Int) -> Verdict {
        if args.contains("-delete") { return destroy("find -delete removes files") }
        if let i = args.firstIndex(where: { ["-exec", "-execdir", "-ok", "-okdir"].contains($0) }) {
            var tail = Array(args[(i + 1)...])
            if let end = tail.firstIndex(where: { $0 == ";" || $0 == "+" || $0 == "\\;" }) { tail = Array(tail[..<end]) }
            let inner = classifyBash(tail.joined(separator: " "), depth: depth + 1)
            return Verdict.combine(considered("find runs a command"), inner)
        }
        if args.contains(where: { $0.hasPrefix("-fprint") || $0 == "-fls" }) { return considered("find writes a file") }
        return readOnly("lists files")
    }

    // MARK: option checks shared by the build, test and cloud tools

    /// True when an option named in `names` is among `args` (before a bare
    /// `--`): `--name`, `--name=value`, `-name` (single-dash long options such
    /// as Go's `-exec`), or a long option abbreviated to three letters or more.
    /// `shorts` are one-letter options that may carry their value attached
    /// (`-Xswiftc`, `-C/tmp`).
    private static func hasOption(_ args: [String], _ names: [String], shorts: String = "") -> Bool {
        for a in args {
            if a == "--" { break }
            guard a.hasPrefix("-"), a.count > 1 else { continue }
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2)).components(separatedBy: "=")[0]
                if names.contains(where: { $0 == name || (name.count >= 3 && $0.hasPrefix(name)) }) { return true }
            } else {
                let name = String(a.dropFirst()).components(separatedBy: "=")[0]
                if names.contains(name) { return true }
                if let f = a.dropFirst().first, shorts.contains(f) { return true }
            }
        }
        return false
    }

    /// A value that leaves the project: absolute, `~`, `..`, or built from a variable or substitution.
    private static func pointsOutside(_ v: String) -> Bool {
        v.hasPrefix("/") || v.hasPrefix("~") || v.contains("$") || v.split(separator: "/").contains("..")
    }

    /// True when an option's value (`--opt=/x`, `-o/x`, `-o /x`) points outside the project.
    private static func optionPointsOutside(_ args: [String]) -> Bool {
        var afterOption = false
        for a in args {
            if a == "--" { break }
            if a.hasPrefix("-"), a.count > 1 {
                if let eq = a.firstIndex(of: "="), pointsOutside(String(a[a.index(after: eq)...])) { return true }
                if !a.hasPrefix("--"), a.count > 2, pointsOutside(String(a.dropFirst(2))) { return true }
                afterOption = !a.contains("=")
                continue
            }
            if afterOption, pointsOutside(a) { return true }
            afterOption = false
        }
        return false
    }

    /// True when a bare (non-option) argument names a path outside the project. Test
    /// runners, linters and `python -m` tools load or execute the files they are given.
    private static func positionalPointsOutside(_ args: [String]) -> Bool {
        args.contains { !$0.hasPrefix("-") && pointsOutside($0) }
    }

    /// `CC=/tmp/x`, `SWIFT_EXEC=...`: an upper-case build setting given on the command line.
    private static func isBuildSettingOverride(_ arg: String) -> Bool {
        guard let eq = arg.firstIndex(of: "="), eq != arg.startIndex else { return false }
        return arg[arg.startIndex..<eq].allSatisfy { ($0.isASCII && $0.isUppercase) || $0 == "_" || ($0.isASCII && $0.isNumber) }
    }

    /// Options that make a test or lint runner load code, run a program or
    /// write a file. Nil when none is present. The JavaScript runners are held
    /// to an allowlist because their config and reporter options load modules.
    private static func riskyRunnerOption(_ cmd: String, _ args: [String]) -> String? {
        let before = Array(args.prefix(while: { $0 != "--" }))
        if hasOption(before, ["fix", "write", "fix-only", "unsafe-fixes", "add-noqa"]) {
            return "\(cmd) may rewrite files"
        }
        if optionPointsOutside(before) { return "\(cmd) option points outside the project" }
        if positionalPointsOutside(before) { return "\(cmd) runs a file outside the project" }
        switch cmd {
        case "pytest", "py.test":
            var i = 0
            while i < before.count {
                let a = before[i]
                i += 1
                if a.hasPrefix("-p"), !a.hasPrefix("--") {
                    let v = a.count > 2 ? String(a.dropFirst(2)) : (i < before.count ? before[i] : "")
                    if !v.hasPrefix("no:") { return "pytest -p loads a plugin" }
                }
            }
            if hasOption(before, ["rootdir", "basetemp", "junitxml", "junit-xml", "html", "log-file", "result-log", "resultlog",
                                  "report-log", "confcutdir", "override-ini", "pastebin", "debug", "cov-report", "config-file",
                                  "pyargs", "import-mode"], shorts: "co") {
                return "pytest option loads code or writes files"
            }
        case "tox", "nox":
            if hasOption(before, ["conf", "override", "workdir", "root", "installpkg", "recreate", "sdistonly", "noxfile", "force-python"], shorts: "cxrf") {
                return "\(cmd) option changes what runs"
            }
        case "jest", "vitest", "mocha", "ava":
            let fine: Set<String> = ["coverage", "verbose", "silent", "ci", "runInBand", "i", "bail", "b", "t", "testNamePattern", "colors",
                                     "no-colors", "color", "no-color", "passWithNoTests", "run", "watch", "no-watch", "watchAll", "w",
                                     "maxWorkers", "forceExit", "detectOpenHandles", "testPathPattern", "listTests", "onlyChanged", "changed",
                                     "no-cache", "grep", "g", "fgrep", "timeout", "parallel", "exit", "recursive", "serial", "s",
                                     "fail-fast", "match", "m", "tap", "version", "help", "h", "testTimeout", "retry"]
            for a in before where a.hasPrefix("-") && a.count > 1 {
                let name = String(a.drop(while: { $0 == "-" })).components(separatedBy: "=")[0]
                if !fine.contains(name) { return "\(cmd) option can load code or write files" }
            }
        case "mypy":
            if hasOption(before, ["python-executable", "junit-xml", "html-report", "xml-report", "txt-report", "any-exprs-report",
                                  "linecount-report", "linecoverage-report", "lineprecision-report", "cobertura-xml-report",
                                  "xslt-html-report", "xslt-txt-report", "cache-dir", "config-file", "install-types", "shadow-file"]) {
                return "mypy option runs a program or writes files"
            }
        case "pylint":
            if hasOption(before, ["init-hook", "load-plugins", "rcfile", "output", "output-format", "generate-rcfile", "generate-toml-config"]) {
                return "pylint option loads code or writes files"
            }
        case "flake8":
            if hasOption(before, ["output-file", "config", "append-config", "install-hook", "tee"]) {
                return "flake8 option writes files or loads config"
            }
        case "pyright":
            if hasOption(before, ["pythonpath", "createstub", "project", "verifytypes", "watch"], shorts: "p") {
                return "pyright option runs a program or writes files"
            }
        case "tsc":
            // tsc emits JavaScript unless told not to.
            if !before.contains("--noEmit") && !before.contains("-noEmit") { return "tsc writes build output" }
            if hasOption(before, ["build", "generateTrace", "generateCpuProfile", "tsBuildInfoFile", "incremental", "composite"], shorts: "b") {
                return "tsc option writes files"
            }
        case "swiftlint":
            if hasOption(before, ["autocorrect", "format", "output", "write-baseline", "cache-path", "config"]) { return "swiftlint option rewrites files" }
            if let sub = before.first(where: { !$0.hasPrefix("-") }), !["lint", "analyze", "rules", "version"].contains(sub) {
                return "swiftlint \(sub) isn't a plain lint"
            }
        case "tflint":
            if hasOption(before, ["init", "config", "chdir"]) { return "tflint option downloads plugins or loads config" }
        case "ctest":
            if hasOption(before, ["script", "script-new-process", "dashboard", "build-and-test", "output-log", "output-junit",
                                  "test-command", "extra-submit", "submit-index"], shorts: "SDTO") {
                return "ctest option runs scripts or writes files"
            }
        case "bats":
            if hasOption(before, ["output", "report-formatter", "gather-test-outputs-in", "formatter"], shorts: "oF") { return "bats option writes files" }
        case "rspec":
            // --format/-f takes `json:path` as well as a name, and the path is a file it writes.
            if hasOption(before, ["require", "options", "out", "output", "format", "init", "default-path", "example-status-persistence-file-path"], shorts: "roOf") {
                return "rspec option loads code or writes files"
            }
        case "phpunit":
            if hasOption(before, ["configuration", "bootstrap", "log-junit", "log-teamcity", "coverage-html", "coverage-clover", "coverage-xml",
                                  "coverage-php", "coverage-text", "testdox-html", "testdox-text", "testdox-xml", "include-path", "extension",
                                  "generate-configuration", "migrate-configuration", "cache-directory", "cache-result-file", "log-events-text",
                                  "log-tap", "coverage-cobertura", "coverage-crap4j", "coverage-cache", "printer"],
                          shorts: "cd") {
                return "phpunit option loads code or writes files"
            }
        default:
            break
        }
        return nil
    }

    /// `eslint -f ./fmt.js`: a formatter given as a path is code that runs.
    private static func loadsFormatter(_ args: [String]) -> Bool {
        var i = 0
        while i < args.count {
            let a = args[i]
            i += 1
            var value: String?
            if a == "-f" || a == "--format" || a == "--formatter" { value = i < args.count ? args[i] : "" }
            else if a.hasPrefix("--format="), let eq = a.firstIndex(of: "=") { value = String(a[a.index(after: eq)...]) }
            else if a.hasPrefix("-f"), !a.hasPrefix("--") { value = String(a.dropFirst(2)) }
            if let value, value.contains("/") || value.contains(".") { return true }
        }
        return false
    }

    /// Formatters and fixers are checks only when told to be, and only when
    /// nothing in the call also writes, loads code or points elsewhere.
    private static func classifyFormatter(_ cmd: String, _ args: [String]) -> Verdict {
        let before = Array(args.prefix(while: { $0 != "--" }))
        let checks = before.contains { ["--check", "-c", "--diff", "--list-different", "-l", "--dry-run", "--lint"].contains($0) }
            || (cmd == "ruff" && before.first == "check")
            || (cmd == "eslint")
        let writes = hasOption(before, ["write", "fix", "fix-only", "unsafe-fixes", "add-noqa", "overwrite-in-place", "in-place", "output-file",
                                        "output", "outfile", "init", "config", "rcfile", "rulesdir", "plugin", "parser", "resolve-plugins-relative-to",
                                        "cache-location", "stdin-filepath", "ignore-path", "watch", "emit"])
            || hasShort(before, "wio") || optionPointsOutside(before) || loadsFormatter(before)
        // ESLint reads the config files above each file it is given, so a file outside the project runs code too.
        let outsideFile = positionalPointsOutside(before)
        if checks, !writes, !outsideFile { return Verdict(level: .undoable, tags: [.runsCommands], reason: "lint or format check") }
        return considered(outsideFile ? "\(cmd) reads a file outside the project" : "\(cmd) rewrites files or loads code")
    }

    // MARK: text tools that can write or run things

    /// True when `arg` is a long option spelled out or shortened (`--out` for
    /// `--output`), with or without `=value`. GNU tools accept abbreviations.
    private static func isLong(_ arg: String, _ full: String, minLength: Int = 1) -> Bool {
        guard arg.hasPrefix("--") else { return false }
        let name = String(arg.dropFirst(2)).components(separatedBy: "=")[0]
        return name.count >= minLength && full.hasPrefix(name)
    }

    /// True when a short-option cluster (`-nro`) contains one of `letters`.
    private static func hasShort(_ args: [String], _ letters: String) -> Bool {
        args.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains { letters.contains($0) } }
    }

    private static func nonFlagCount(_ args: [String], valueFlags: Set<String>) -> Int {
        var count = 0
        var skip = false
        for a in args {
            if skip { skip = false; continue }
            if a == "--" { continue }
            if a.hasPrefix("-"), a.count > 1 { if valueFlags.contains(a) { skip = true }; continue }
            count += 1
        }
        return count
    }

    /// For tools that are otherwise plain text readers: the options that make
    /// them write a file or run another program. Nil when none is present.
    private static func riskyTextToolUse(_ cmd: String, _ args: [String]) -> String? {
        if args.contains(where: { $0.hasPrefix("--pager") }) { return "\(cmd) --pager runs a program" }
        switch cmd {
        case "less", "more":
            return "\(cmd) is a pager that can run commands"
        case "rg":
            if args.contains(where: { $0.hasPrefix("--pre") || $0.hasPrefix("--hostname-bin") || $0 == "--search-zip" }) || hasShort(args, "z") {
                return "rg runs a helper program"
            }
        case "fd":
            if args.contains(where: { $0.hasPrefix("--exec") || isLong($0, "exec", minLength: 3) }) || hasShort(args, "xX") {
                return "fd runs a command"
            }
        case "sort":
            if hasShort(args, "o") || args.contains(where: { isLong($0, "output") || isLong($0, "compress-program", minLength: 2) }) {
                return "sort writes a file or runs a helper"
            }
        case "tree":
            // -o writes the listing; -R with -H writes 00Tree.html into every directory;
            // --fromfile reads a listing from a file.
            if hasShort(args, "oRH") || args.contains(where: { isLong($0, "output") || isLong($0, "fromfile") || isLong($0, "fromtabfile") || isLong($0, "html") }) {
                return "tree writes a file"
            }
        case "bat":
            if args.contains(where: { isLong($0, "generate-config-file") || isLong($0, "build-cache") || isLong($0, "clear-cache") || isLong($0, "init-config") }) {
                return "bat writes its config or cache"
            }
        case "diff":
            if hasShort(args, "l") || args.contains(where: { isLong($0, "paginate", minLength: 3) }) { return "diff --paginate runs pr" }
        case "base64":
            if hasShort(args, "o") || args.contains(where: { isLong($0, "output") }) { return "base64 writes a file" }
        case "yq":
            if hasShort(args, "is") || args.contains(where: { $0.hasPrefix("--inplace") || $0.hasPrefix("--in-place") || $0.hasPrefix("--split-exp") || $0.hasPrefix("--security") }) {
                return "yq writes files"
            }
        case "jq":
            if hasShort(args, "i") || args.contains(where: { $0.hasPrefix("--inplace") || $0.hasPrefix("--in-place") }) {
                return "jq writes files"
            }
        case "uniq":
            if nonFlagCount(args, valueFlags: ["-f", "-s", "-w"]) > 1 { return "uniq writes its second file" }
        case "xxd":
            if nonFlagCount(args, valueFlags: ["-l", "-s", "-c", "-g", "-o", "-n", "-b", "-R"]) > 1 { return "xxd writes its second file" }
        case "cd", "pushd":
            // Moving out of the project makes whatever runs next (`cd /tmp/x && make test`) somebody else's.
            let target = args.first(where: { !$0.hasPrefix("-") || $0 == "-" })
            guard let target else { return "\(cmd) with no folder goes to the home folder" }
            if target == "-" || pointsOutside(target) { return "\(cmd) leaves the project" }
        case "arch":
            if !args.isEmpty { return "arch runs another program" }
        case "alias":
            if !args.isEmpty { return "alias changes how commands run" }
        case "date":
            if hasShort(args, "s") || args.contains(where: { $0.hasPrefix("--set") }) { return "date sets the clock" }
        case "hostname":
            if nonFlagCount(args, valueFlags: []) > 0 { return "hostname renames the Mac" }
        case "file":
            if hasShort(args, "C") || args.contains("--compile") { return "file compiles a magic file" }
        case "cloc":
            // Only the reporting options that print to the terminal. Anything else can write a file
            // (--out, --write-lang-def, --strip-comments, --counted, --sdir ...) or run git or sloccount (--vcs, --git).
            let plain: Set<String> = [
                "by-file", "by-file-by-lang", "by-percent", "csv", "json", "yaml", "xml", "md", "quiet", "hide-rate", "sum-one",
                "skip-uniqueness", "follow-links", "no-autogen", "unicode", "exclude-dir", "exclude-ext", "exclude-lang",
                "include-lang", "include-ext", "match-d", "not-match-d", "match-f", "not-match-f", "max-file-size", "sort",
                "show-ext", "show-lang", "progress-rate", "no-color", "version", "help", "v", "h"
            ]
            if args.contains(where: { arg in
                guard arg.hasPrefix("-") else { return false }
                let name = String(arg.drop(while: { $0 == "-" })).components(separatedBy: "=")[0]
                return !plain.contains(name)
            }) {
                return "cloc option writes a file or runs a program"
            }
        case "git-lfs":
            if !["ls-files", "status", "version", "env"].contains(args.first ?? "") { return "git-lfs changes files or reaches a remote" }
        default:
            break
        }
        return nil
    }

    /// `sed` is read-only only for a known set of commands. `-i`, `-f`, and the
    /// `w`, `W`, `e`, `r` family (as commands or `s` flags) write or run things.
    private static func classifySed(_ args: [String]) -> Verdict {
        let unsafe = "sed can edit files or run commands"
        var scripts: [String] = []
        var scriptFromArg = false
        var i = 0
        var afterDashDash = false
        while i < args.count {
            let a = args[i]
            i += 1
            if afterDashDash || !a.hasPrefix("-") || a == "-" {
                if !scriptFromArg, scripts.isEmpty { scripts.append(a); scriptFromArg = true }
                continue
            }
            if a == "--" { afterDashDash = true; continue }
            if a == "-i" || (a.hasPrefix("-i") && !a.hasPrefix("--")) || a.hasPrefix("--in-place") {
                return considered("sed edits files in place")
            }
            if a == "-e" || a == "--expression" {
                guard i < args.count else { return considered(unsafe) }
                scripts.append(args[i]); i += 1; scriptFromArg = true; continue
            }
            if a.hasPrefix("--expression=") { scripts.append(String(a.dropFirst("--expression=".count))); scriptFromArg = true; continue }
            if ["--quiet", "--silent", "--regexp-extended", "--posix", "--separate", "--unbuffered", "--null-data", "--debug", "--sandbox"].contains(a) { continue }
            if !a.hasPrefix("--"), a.dropFirst().allSatisfy({ "nErsuze".contains($0) }) {
                if a.contains("e") {
                    guard a.hasSuffix("e"), i < args.count else { return considered(unsafe) }
                    scripts.append(args[i]); i += 1; scriptFromArg = true
                }
                continue
            }
            return considered(unsafe) // -f, -l, an unknown option: not judged
        }
        guard !scripts.isEmpty else { return considered(unsafe) }
        for script in scripts where !(sedScriptIsReadOnly(script, bracketAware: false) && sedScriptIsReadOnly(script, bracketAware: true)) {
            return considered(unsafe)
        }
        return readOnly("text filter")
    }

    /// A small sed script reader: true only when every command is one of a
    /// short list that only prints, deletes lines or substitutes text. Parsed
    /// twice (brackets special or not) because seds disagree on `s/[/]/x/`.
    private static func sedScriptIsReadOnly(_ script: String, bracketAware: Bool) -> Bool {
        let c = Array(script)
        let n = c.count
        var i = 0
        func spaces() { while i < n, c[i] == " " || c[i] == "\t" { i += 1 } }
        func skipDelimited(_ d: Character, brackets: Bool) -> Bool {
            var inBracket = false
            while i < n {
                let ch = c[i]
                if ch == "\\" { i += 2; continue }
                if brackets, ch == "[", !inBracket {
                    inBracket = true
                    i += 1
                    if i < n, c[i] == "^" { i += 1 }
                    if i < n, c[i] == "]" { i += 1 }
                    continue
                }
                if brackets, ch == "]", inBracket { inBracket = false; i += 1; continue }
                if ch == d, !inBracket { i += 1; return true }
                i += 1
            }
            return false
        }
        func digits() { while i < n, c[i].isASCII, c[i].isNumber { i += 1 } }
        /// nil: syntax not understood. true/false: an address was/was not there.
        func address(second: Bool) -> Bool? {
            guard i < n else { return false }
            let ch = c[i]
            if ch.isASCII, ch.isNumber { digits(); if i < n, c[i] == "~" { i += 1; digits() }; return true }
            if second, ch == "+" || ch == "~" { i += 1; digits(); return true }
            if ch == "$" { i += 1; return true }
            var delim: Character?
            if ch == "/" { delim = "/"; i += 1 }
            else if ch == "\\", i + 1 < n { delim = c[i + 1]; i += 2 }
            if let d = delim {
                guard skipDelimited(d, brackets: bracketAware) else { return nil }
                while i < n, c[i] == "I" || c[i] == "M" { i += 1 }
                return true
            }
            return false
        }
        func endOfCommand() -> Bool {
            spaces()
            if i >= n { return true }
            if c[i] == ";" || c[i] == "\n" || c[i] == "}" { return true }
            return false
        }
        while true {
            spaces()
            while i < n, c[i] == ";" || c[i] == "\n" { i += 1; spaces() }
            if i >= n { return true }
            if c[i] == "#" { while i < n, c[i] != "\n" { i += 1 }; continue }
            guard let first = address(second: false) else { return false }
            if first {
                spaces()
                if i < n, c[i] == "," {
                    i += 1; spaces()
                    guard let second = address(second: true), second else { return false }
                }
            }
            spaces()
            while i < n, c[i] == "!" { i += 1; spaces() }
            guard i < n else { return false }
            let cmd = c[i]
            i += 1
            switch cmd {
            case "{":
                continue
            case "}":
                continue
            case "p", "d", "=", "n", "N", "D", "P", "g", "G", "h", "H", "x", "z", "F":
                if !endOfCommand() { return false }
            case "q", "Q", "l":
                spaces(); digits()
                if !endOfCommand() { return false }
            case "y":
                guard i < n else { return false }
                let d = c[i]; i += 1
                guard skipDelimited(d, brackets: false), skipDelimited(d, brackets: false) else { return false }
                if !endOfCommand() { return false }
            case "s":
                guard i < n else { return false }
                let d = c[i]; i += 1
                guard d != "\\", d != "\n", d != " ", skipDelimited(d, brackets: bracketAware), skipDelimited(d, brackets: false) else { return false }
                while i < n, "gpiImM0123456789".contains(c[i]) { i += 1 }
                if !endOfCommand() { return false }
            default:
                return false // a, i, c, r, R, w, W, e, b, t, T, ":" ...
            }
        }
    }

    /// `awk` is read-only only for a plain program: no file program, no
    /// `system`, `getline`, pipe or redirection, however it is spaced.
    private static func classifyAwk(_ args: [String]) -> Verdict {
        let unsafe = "awk program can run or write"
        var i = 0
        var program: String?
        while i < args.count {
            let a = args[i]
            i += 1
            if a == "--" { program = i < args.count ? args[i] : nil; break }
            if !a.hasPrefix("-") || a == "-" { program = a; break }
            if a == "-F" || a == "-v" { i += 1; continue }
            if (a.hasPrefix("-F") || a.hasPrefix("-v")) && !a.hasPrefix("--") { continue }
            if a == "--version" || a == "-version" { return readOnly("awk version") }
            return considered(unsafe) // -f, -i, -e, -l, an unknown option
        }
        guard let program else { return considered(unsafe) }
        for bad in [">", "|", "system", "getline", "@"] where program.contains(bad) { return considered(unsafe) }
        return readOnly("text filter")
    }

    /// Splits git's global options from the subcommand. Options that move git
    /// elsewhere or change what it runs (`-c`, `--exec-path`, `--git-dir`,
    /// `--work-tree`, `--namespace`, a `-C` that leaves the project) come back
    /// as a verdict that is at least `.considered`; an option not known to be
    /// harmless does too.
    private static func gitSub(_ args: [String]) -> (sub: String, rest: [String], issue: Verdict?) {
        var rest = args
        var issue: Verdict?
        func note(_ why: String, text: String? = nil) {
            var v = considered(why)
            if let text, let d = matchesDestructiveText(text) { v = destroy(d) }
            issue = issue.map { Verdict.combine($0, v) } ?? v
        }
        func takeValue() -> String? { rest.isEmpty ? nil : rest.removeFirst() }
        func staysInside(_ path: String?) -> Bool {
            guard let path, !path.contains("$"), !path.contains("`") else { return false }
            return isInside(path: path, cwd: nil)
        }
        let harmless: Set<String> = ["--no-pager", "-P", "--no-optional-locks", "--no-replace-objects", "--literal-pathspecs",
                                     "--glob-pathspecs", "--noglob-pathspecs", "--icase-pathspecs", "--no-lazy-fetch"]
        let withValue: Set<String> = ["--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix", "--attr-source"]
        while let f = rest.first, f.hasPrefix("-") {
            rest.removeFirst()
            if f == "-c" {
                note("git -c overrides config for this command", text: takeValue())
            } else if f.hasPrefix("-c"), !f.hasPrefix("--") {
                note("git -c overrides config for this command", text: String(f.dropFirst(2)))
            } else if f == "-C" {
                if !staysInside(takeValue()) { note("git -C points outside the project") }
            } else if f.hasPrefix("-C"), !f.hasPrefix("--") {
                if !staysInside(String(f.dropFirst(2))) { note("git -C points outside the project") }
            } else if f == "--exec-path" || f.hasPrefix("--exec-path=") {
                note("git --exec-path changes which programs git runs")
            } else if let name = f.components(separatedBy: "=").first, withValue.contains(name) {
                if !f.contains("=") { _ = takeValue() }
                note("git \(name) points git somewhere else")
            } else if !harmless.contains(f) {
                note("git option \(f) isn't one Page recognises")
            }
        }
        guard let sub = rest.first else { return ("", [], issue) }
        return (sub.lowercased(), Array(rest.dropFirst()), issue)
    }

    private static func classifyGit(_ args: [String]) -> Verdict {
        let (sub, a, issue) = gitSub(args)
        let v = classifyGitSub(sub, a)
        return issue.map { Verdict.combine(v, $0) } ?? v
    }

    private static func classifyGitSub(_ sub: String, _ a: [String]) -> Verdict {
        let nonFlags = a.filter { !$0.hasPrefix("-") }
        func hasFlag(_ names: String...) -> Bool {
            a.contains { arg in names.contains { arg == $0 || arg.hasPrefix($0 + "=") } }
        }
        func shortCluster(_ letter: Character) -> Bool {
            a.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains(letter) }
        }
        let git = Verdict(level: .considered, tags: [.runsCommands], reason: "git changes the repo")
        switch sub {
        case "status", "log", "diff", "show", "blame", "shortlog", "rev-parse", "rev-list", "ls-files", "ls-tree",
             "describe", "cat-file", "grep", "whatchanged", "count-objects", "fsck", "diff-tree", "name-rev",
             "merge-base", "for-each-ref", "show-ref", "check-ignore", "version", "--version",
             "diff-files", "diff-index", "annotate", "range-diff", "show-branch", "var":
            if sub == "ls-remote" { return Verdict(level: .considered, tags: [.networkOutside], reason: "reads a remote") }
            if a.contains(where: { isLong($0, "output", minLength: 3) }) || hasFlag("-o") && sub == "diff" { return considered("git writes a file") }
            if sub == "grep", a.contains(where: { $0 == "--open-files-in-pager" || $0.hasPrefix("--open-files-in-pager=") || ($0.hasPrefix("-O") && !$0.hasPrefix("--")) }) {
                return considered("git grep opens a pager program")
            }
            // Textconv, external diff and lost-found run programs or write files; --filters runs filter drivers;
            // --show-signature runs gpg.
            if a.contains(where: { isLong($0, "ext-diff", minLength: 3) || isLong($0, "textconv", minLength: 3) || isLong($0, "lost-found", minLength: 3)
                || isLong($0, "filters", minLength: 3) || isLong($0, "show-signature", minLength: 3) }) {
                return considered("git runs a configured program")
            }
            return readOnly("read-only git")
        case "branch":
            if hasFlag("--delete") || shortCluster("D") || (shortCluster("d") && (hasFlag("--force") || shortCluster("f"))) {
                return destroy("deletes a branch")
            }
            if shortCluster("d") { return Verdict(level: .considered, tags: [.runsCommands], reason: "deletes a merged branch") }
            let listing = hasFlag("--list") || shortCluster("l") || nonFlags.isEmpty
            let changing = hasFlag("-m", "-M", "--move", "-c", "-C", "--copy", "--set-upstream-to", "-u", "--unset-upstream", "--edit-description", "-f", "--force")
            if listing && !changing { return readOnly("lists branches") }
            return git
        case "tag":
            if shortCluster("d") || hasFlag("--delete") { return Verdict(level: .considered, tags: [.runsCommands], reason: "deletes a tag") }
            if nonFlags.isEmpty || hasFlag("-l", "--list") { return readOnly("lists tags") }
            return git
        case "remote":
            let s = nonFlags.first ?? ""
            // `remote show` asks the remote for its branches, so it reaches the network.
            if s.isEmpty || s == "get-url" { return readOnly("lists remotes") }
            return git
        case "stash":
            let s = nonFlags.first ?? "push"
            if ["list", "show"].contains(s) { return readOnly("lists stashes") }
            if ["drop", "clear"].contains(s) { return destroy("stash drop loses work") }
            return git
        case "config":
            if hasFlag("--edit", "-e", "--unset", "--unset-all", "--replace-all", "--add", "--remove-section", "--rename-section", "--set") || shortCluster("e") {
                return git
            }
            if hasFlag("--get", "--get-all", "--get-regexp", "--list", "-l", "--show-origin") { return readOnly("reads git config") }
            return git
        case "push":
            let refspecForce = nonFlags.contains { $0.hasPrefix("+") || $0.hasPrefix(":") }
            if hasFlag("--force", "-f", "--force-with-lease", "--force-if-includes", "--delete", "--mirror", "--prune") || shortCluster("f") || shortCluster("d") || refspecForce {
                return Verdict(level: .irreversible, tags: [.networkOutside, .destructive], reason: "force-push or remote delete")
            }
            return Verdict(level: .considered, tags: [.networkOutside], reason: "pushes to a remote")
        case "reset":
            if hasFlag("--hard", "--merge") { return destroy("reset --hard discards work") }
            return git
        case "clean":
            if hasFlag("--dry-run") || shortCluster("n") { return readOnly("git clean preview") }
            return destroy("git clean deletes untracked files")
        case "restore":
            if hasFlag("--staged") && !hasFlag("--worktree") && !shortCluster("W") { return git }
            return destroy("restore discards changes")
        case "checkout":
            if a.contains("--") || nonFlags.contains(".") || hasFlag("--force", "-f") || shortCluster("f") {
                return destroy("checkout discards changes")
            }
            return git
        case "filter-branch", "filter-repo", "prune", "update-ref", "replace":
            return destroy("rewrites git history")
        case "reflog":
            let s = nonFlags.first ?? "show"
            if ["expire", "delete"].contains(s) { return destroy("reflog expire drops history") }
            return s == "show" ? readOnly("shows the reflog") : git
        case "gc":
            return hasFlag("--prune") && a.contains(where: { $0.contains("now") }) ? destroy("gc prunes objects") : git
        case "fetch", "pull", "clone", "submodule", "lfs":
            return Verdict(level: .considered, tags: [.networkOutside], reason: "reaches a remote")
        case "worktree":
            return nonFlags.first == "list" ? readOnly("lists worktrees") : git
        default:
            return git
        }
    }

    private static func classifySwift(_ args: [String]) -> Verdict {
        let sub = args.first ?? ""
        // Compiler pass-through (-Xswiftc ...), sandbox and path options change what runs or where it writes.
        let risky = hasOption(args, ["disable-sandbox", "allow-writing-to-package-directory", "allow-network-connections", "xunit-output",
                                     "scratch-path", "build-path", "package-path", "cache-path", "config-path", "security-path",
                                     "manifest-cache", "toolchain", "sdk", "vfs-overlay", "enable-experimental-prebuilts"], shorts: "X")
            || optionPointsOutside(args)
        if risky, ["build", "test", "package"].contains(sub) { return considered("swift \(sub) option can change what runs") }
        if ["build", "test", "--version", "-version", "--help", "-h"].contains(sub) {
            return Verdict(level: .undoable, tags: [.runsCommands], reason: "build or test")
        }
        if sub == "package" {
            let s = args.dropFirst().first(where: { !$0.hasPrefix("-") }) ?? ""
            if ["describe", "dump-package", "show-dependencies", "dump-pif"].contains(s) { return readOnly("package info") }
            return Verdict(level: .considered, tags: [.networkOutside], reason: "changes packages")
        }
        return considered("swift \(sub)")
    }

    private static func classifyCargo(_ args: [String]) -> Verdict {
        let sub = args.first(where: { !$0.hasPrefix("+") }) ?? ""
        let before = Array(args.prefix(while: { $0 != "--" }))
        // --config can name a runner or wrapper; --fix rewrites files; --open starts a browser.
        let risky = hasOption(before, ["config", "manifest-path", "fix", "open", "target-dir", "out-dir", "timings", "allow-dirty",
                                       "allow-staged", "allow-no-vcs", "artifact-dir"], shorts: "Z")
            || optionPointsOutside(before)
        switch sub {
        case "test", "t", "build", "b", "check", "c", "clippy", "doc", "bench", "tree", "metadata", "version", "--version", "-V":
            if risky { return considered("cargo option can change what runs") }
            return Verdict(level: .undoable, tags: [.runsCommands], reason: "build or test")
        case "fmt":
            // After `--` the arguments go to rustfmt, which can be told to write.
            return args.contains("--check") && !risky && !args.contains("--")
                ? Verdict(level: .undoable, tags: [.runsCommands], reason: "format check") : considered("cargo fmt rewrites files")
        case "publish", "yank", "owner":
            return Verdict(level: .irreversible, tags: [.networkOutside, .destructive], reason: "publishes a crate")
        default:
            return considered("cargo \(sub)")
        }
    }

    private static func classifyGo(_ args: [String]) -> Verdict {
        let sub = args.first ?? ""
        // -exec/-toolexec/-vettool run a program, -o and the profile flags write files, -ldflags can name a linker.
        // `-test.*` and everything after `-args` go to the test binary, which writes its own profiles and logs.
        let risky = hasOption(args, ["exec", "toolexec", "vettool", "o", "c", "coverprofile", "cpuprofile", "memprofile", "blockprofile",
                                     "mutexprofile", "trace", "overlay", "modfile", "pkgdir", "C", "work", "gcflags", "ldflags", "asmflags",
                                     "gccgoflags", "fuzz", "fuzzcachedir", "outputdir", "installsuffix", "w", "u"])
            || optionPointsOutside(args)
            || args.contains { $0 == "-args" || $0.hasPrefix("-test.") }
            || positionalPointsOutside(args)
        if ["test", "build", "vet", "list", "version", "env", "doc"].contains(sub) {
            if risky { return considered("go option can change what runs or writes files") }
            return Verdict(level: .undoable, tags: [.runsCommands], reason: "build or test")
        }
        return considered("go \(sub)")
    }

    /// `make` and friends. Options are judged first and by exact allowlist: a
    /// makefile, directory, include path, eval string or variable override
    /// (`-f`, `-C`, `-I`, `-E`, `--eval`, `SHELL=x`) changes what runs, and an
    /// abbreviated long option (`--fil=x`) is not an allowlisted one.
    /// `-n`/`--just-print`/`--dry-run`/`--recon` and `-q`/`--question` are dry
    /// runs, but GNU make still runs `+` lines, `$(MAKE)` recursion and
    /// `$(shell ...)` during one, so they are `.considered`; `-p` still runs
    /// the target. `ninja`, `just` and `task` have their own options, so any
    /// option on them is simply `.considered`.
    private static func classifyMake(_ cmd: String, _ args: [String]) -> Verdict {
        let isMake = cmd == "make" || cmd == "gmake"
        let shortOK: Set<Character> = ["s", "k", "w", "B", "e", "i", "r", "R", "S", "d", "b", "m", "p", "h", "v"]
        let shortDry: Set<Character> = ["n", "q"]
        let longOK: Set<String> = [
            "silent", "quiet", "keep-going", "print-directory", "no-print-directory", "warn-undefined-variables",
            "no-builtin-rules", "no-builtin-variables", "always-make", "ignore-errors", "environment-overrides",
            "check-symlink-times", "no-keep-going", "stop", "print-data-base", "trace", "help", "version", "no-silent",
            "debug", "jobs"
        ]
        let longDry: Set<String> = ["just-print", "dry-run", "recon", "question"]
        let unsafe = considered("\(cmd) option or variable can change what runs")
        func digits(_ s: Substring) -> Bool { s.allSatisfy { $0.isASCII && $0.isNumber } }
        var targets: [String] = []
        var dry = false
        var i = 0
        var onlyTargets = false
        while i < args.count {
            let a = args[i]
            i += 1
            if onlyTargets { targets.append(a); continue }
            if a == "--" { onlyTargets = true; continue }
            if a.hasPrefix("--") {
                guard isMake else { return unsafe }
                let parts = a.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts.first ?? "")
                if longDry.contains(name), parts.count == 1 { dry = true; continue }
                if name == "jobs", parts.count == 2, digits(parts[1]) { continue }
                if name == "jobs", parts.count == 1 {
                    if i < args.count, digits(Substring(args[i])), !args[i].isEmpty { i += 1 }
                    continue
                }
                if name == "debug", parts.count == 2, parts[1].allSatisfy({ $0.isLetter }) { continue }
                if longOK.contains(name), parts.count == 1 { continue }
                return unsafe
            }
            if a.hasPrefix("-"), a.count > 1 {
                guard isMake else { return unsafe }
                let letters = Array(a.dropFirst())
                var k = 0
                while k < letters.count {
                    let ch = letters[k]
                    k += 1
                    if shortDry.contains(ch) { dry = true; continue }
                    if shortOK.contains(ch) { continue }
                    if ch == "j" {
                        let attached = String(letters[k...])
                        if attached.isEmpty {
                            if i < args.count, !args[i].isEmpty, digits(Substring(args[i])) { i += 1 }
                        } else if !digits(Substring(attached)) {
                            return unsafe
                        }
                        break
                    }
                    return unsafe // -f, -C, -I, -E, -o, -W, -t, -l, -O or one it does not know
                }
                continue
            }
            if a == "-" { return unsafe }
            if a.contains("=") { return unsafe } // NAME=value overrides a make or just variable
            targets.append(a)
        }
        // A dry run still runs `+` lines, `$(MAKE)` recursion and `$(shell ...)`
        // (GNU make), and `-q` runs the same: never Undoable.
        if dry { return considered("make -n/-q still runs $(shell), $(MAKE) and + lines") }
        let ok: Set<String> = ["test", "tests", "check", "build", "all", "lint", "typecheck", "vet", "fmt-check", "verify"]
        if !targets.isEmpty, targets.allSatisfy({ ok.contains($0.lowercased()) }) {
            return Verdict(level: .undoable, tags: [.runsCommands], reason: "build or test")
        }
        return considered("make target")
    }

    private static func classifyNodePackage(_ cmd: String, _ args: [String]) -> Verdict {
        let v = classifyNodePackageSub(cmd, args)
        // A shell, prefix, config or preload option changes what the script runs.
        let before = Array(args.prefix(while: { $0 != "--" }))
        if v.level < .considered,
           hasOption(before, ["script-shell", "shell", "prefix", "userconfig", "globalconfig", "cwd", "dir", "preload", "require", "registry",
                              "node-options", "config", "cache", "workspace-root"], shorts: "Cr") {
            return considered("\(cmd) option can change what runs")
        }
        if v.level < .considered, optionPointsOutside(before) { return considered("\(cmd) option points outside the project") }
        // Whatever follows `--` goes to the script (jest's --outputFile, a build's --outDir), so it is not judged.
        if v.level < .considered, let dash = args.firstIndex(of: "--"), dash + 1 < args.count {
            return considered("\(cmd) passes arguments to the script")
        }
        return v
    }

    private static func classifyNodePackageSub(_ cmd: String, _ args: [String]) -> Verdict {
        let nonFlags = args.prefix(while: { $0 != "--" }).filter { !$0.hasPrefix("-") }
        let sub = nonFlags.first ?? ""
        let safeScripts = ["test", "lint", "build", "check", "typecheck", "type-check", "verify", "tsc", "format:check", "types", "compile"]
        func safeScript(_ name: String) -> Bool {
            let n = name.lowercased()
            return safeScripts.contains { n == $0 || n.hasPrefix($0 + ":") || n.hasPrefix($0 + "-") }
        }
        if cmd == "bun", sub == "build" { return considered("bun build writes bundles") }
        switch sub {
        case "test", "t", "tst", "lint", "build", "typecheck", "check":
            return Verdict(level: .undoable, tags: [.runsCommands], reason: "test or build")
        case "run", "run-script":
            let script = nonFlags.dropFirst().first ?? ""
            return safeScript(script)
                ? Verdict(level: .undoable, tags: [.runsCommands], reason: "test or build script") : considered("runs a package script")
        case "config":
            // `npm config set script-shell x` changes what every script runs.
            return ["get", "list", "ls"].contains(nonFlags.dropFirst().first ?? "") ? readOnly("package query") : considered("\(cmd) config")
        case "version":
            // Bare, it prints versions; with a bump it edits package.json and tags the repo.
            return args.count == 1 ? readOnly("package query") : considered("\(cmd) version bumps the package")
        case "ls", "list", "view", "info", "outdated", "why", "--version", "-v", "explain", "help":
            return readOnly("package query")
        case "publish", "unpublish", "deprecate", "dist-tag", "owner", "access", "login", "adduser", "token":
            return Verdict(level: .irreversible, tags: [.networkOutside, .destructive], reason: "publishes a package")
        case "install", "i", "ci", "add", "update", "up", "upgrade", "remove", "uninstall", "rm", "link", "init", "create", "dlx", "exec", "start":
            return Verdict(level: .considered, tags: [.networkOutside], reason: "\(cmd) changes packages")
        default:
            if sub.isEmpty { return considered("\(cmd)") }
            if cmd == "yarn" || cmd == "pnpm" || cmd == "bun", safeScript(sub) {
                return Verdict(level: .undoable, tags: [.runsCommands], reason: "test or build script")
            }
            return considered("\(cmd) \(sub)")
        }
    }

    /// Cloud, container and publish CLIs. Anything that deploys, deletes or
    /// publishes is irreversible; plain queries are undoable; the rest is
    /// considered.
    private static func classifyInfra(_ cmd: String, _ args: [String]) -> Verdict {
        let subs = args.filter { !$0.hasPrefix("-") }.prefix(4).map { $0.lowercased() }
        let network: [Reversibility.Tag] = [.networkOutside]
        if subs.contains(where: { destructiveWords.contains($0) }) {
            return Verdict(level: .irreversible, tags: network + [.destructive], reason: "\(cmd) \(subs.first(where: { destructiveWords.contains($0) }) ?? "") changes live systems")
        }
        let apply: Set<String> = ["apply", "up", "push", "replace", "install", "upgrade", "release", "promote", "migrate"]
        if ["kubectl", "terraform", "tofu", "terragrunt", "pulumi", "helm", "oc"].contains(cmd), subs.contains(where: apply.contains) {
            return Verdict(level: .irreversible, tags: network + [.destructive], reason: "\(cmd) changes live infrastructure")
        }
        // `pulumi watch` keeps deploying to the stack as files change, with no confirmation.
        if cmd == "pulumi", subs.first == "watch" {
            return Verdict(level: .irreversible, tags: network + [.destructive], reason: "pulumi watch keeps deploying to live infrastructure")
        }
        // `terraform test` applies its plans to real resources unless the providers are mocked.
        if cmd == "terraform" || cmd == "tofu", subs.first == "test" {
            return Verdict(level: .irreversible, tags: network + [.destructive], reason: "\(cmd) test creates real resources")
        }
        if cmd == "docker" || cmd == "podman", subs.first == "push" {
            return Verdict(level: .irreversible, tags: network + [.destructive], reason: "pushes an image")
        }
        if cmd == "docker" || cmd == "podman", subs.first == "system" || subs.first == "volume" || subs.first == "image", subs.contains("prune") {
            return Verdict(level: .irreversible, tags: network + [.destructive], reason: "prunes containers or images")
        }
        // The CDK CLIs run the app (`--app`, cdk.json) to synthesize before they diff, list or
        // synthesize: only asking for their version or help is a query.
        if cmd == "cdk" || cmd == "cdktf" {
            let query: Set<String> = ["--version", "-v", "--help", "-h", "version", "help"]
            if args.allSatisfy({ query.contains($0) }), !args.isEmpty {
                return Verdict(level: .undoable, tags: [.readOnly], reason: "\(cmd) version")
            }
            return Verdict(level: .considered, tags: network, reason: "\(cmd) \(subs.first ?? "") runs the CDK app".trimmingCharacters(in: .whitespaces))
        }
        // Options that point a CLI at another config, cluster, host or server (a kubeconfig or
        // docker config can name a program to run) or make it write a file are not a plain query.
        let before = Array(args.prefix(while: { $0 != "--" }))
        let shorts = (cmd == "docker" || cmd == "podman") ? "H" : (cmd == "kubectl" || cmd == "oc") ? "s" : ""
        if hasOption(before, ["kubeconfig", "server", "token", "as", "as-group", "certificate-authority", "client-certificate", "client-key",
                              "chdir", "endpoint-url", "ca-bundle", "cli-input-json", "cli-input-yaml", "host", "config", "kube-apiserver",
                              "insecure-skip-tls-verify", "out", "generate-config-out"], shorts: shorts) {
            return Verdict(level: .considered, tags: network, reason: "\(cmd) option points somewhere else or writes a file")
        }
        if let first = subs.first, readOnlySubcommands.contains(first) {
            // `plan`, `validate`, `show` and `preview` start provider plugins and run project code
            // (a `data "external"` block, a Pulumi program), like the CDK app above: only asking for
            // a version or help, a format check or `whoami` is a query.
            if ["terraform", "tofu", "terragrunt", "pulumi"].contains(cmd), !["version", "help", "fmt", "whoami"].contains(first) {
                return Verdict(level: .considered, tags: network, reason: "\(cmd) \(first) runs providers or project code")
            }
            // `terraform fmt` rewrites files unless it only checks.
            if first == "fmt", !(args.contains("-check") || args.contains("-write=false")) {
                return Verdict(level: .considered, tags: network, reason: "\(cmd) fmt rewrites files")
            }
            return Verdict(level: .undoable, tags: [.readOnly], reason: "\(cmd) query")
        }
        // aws <service> <operation>: the operation is the second word, not any value after it.
        // `get-object` and `get-*-torrent` write a local file.
        if cmd == "aws" {
            let operation = subs.count > 1 ? subs[1] : ""
            if operation.hasPrefix("get-object") { return Verdict(level: .considered, tags: network, reason: "aws get-object writes a file") }
            if operation.hasPrefix("describe") || operation.hasPrefix("list") || operation.hasPrefix("get-") || operation == "get" || operation == "ls" {
                return Verdict(level: .undoable, tags: [.readOnly], reason: "aws query")
            }
        } else if cmd == "gcloud" || cmd == "az" {
            let mutators: Set<String> = ["create", "update", "set", "add", "start", "stop", "restart", "reset", "invoke", "run", "exec", "ssh",
                                         "scp", "copy", "cp", "mv", "sync", "put", "patch", "import", "export", "attach", "detach", "enable",
                                         "disable", "login", "resize", "scale", "rotate", "tag", "untag", "deploy", "call", "execute"]
            if !subs.contains(where: mutators.contains),
               subs.contains(where: { $0.hasPrefix("describe") || $0.hasPrefix("list") || $0.hasPrefix("get-") || $0 == "get" || $0 == "ls" || $0 == "show" }) {
                return Verdict(level: .undoable, tags: [.readOnly], reason: "\(cmd) query")
            }
        }
        return Verdict(level: .considered, tags: network, reason: "\(cmd) \(subs.first ?? "")".trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Shell parsing

/// A small shell tokenizer, enough to find every command in a line: it splits
/// on `&&`, `||`, `;`, `|`, `&` and newlines, honours quotes and escapes,
/// pulls `$( )`, backticks and process substitutions out as separate
/// commands, notices output redirects (other than to /dev/null or a file
/// descriptor), and sets heredoc bodies aside. Not a full parser; where it
/// is unsure the classifier lands on `.considered`.
enum ShellParse {
    struct Segment: Equatable {
        var words: [String]
        var writes: Bool
        var afterPipe: Bool
        var hasHeredoc: Bool
        var heredocBodies: [String]
    }

    struct Parsed: Equatable {
        var segments: [Segment]
        var substitutions: [String]
        /// A heredoc whose body is shell or SQL text for an interpreter.
        var interpreterHeredocBodies: [String]
        /// A heredoc body with `$(` or a backtick that might run something.
        var hasOpaqueHeredoc: Bool
    }

    private static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "python", "python3", "node", "ruby", "perl", "php", "psql", "mysql",
        "sqlite3", "mongosh", "redis-cli", "ssh", "deno", "mariadb"
    ]

    static func parse(_ input: String) -> Parsed {
        // "\r\n" is one Character to Swift but two bytes to the shell, where the "\n" ends the command.
        let chars = Array(input.replacingOccurrences(of: "\r\n", with: "\n"))
        let n = chars.count
        var i = 0
        var segments: [Segment] = []
        var subs: [String] = []
        var bodies: [String] = []
        var interpreterBodies: [String] = []
        var opaque = false

        var words: [String] = []
        var cur = ""
        var inWord = false
        var writes = false
        var heredoc = false
        var segBodies: [String] = []
        var segAfterPipe = false
        var pendingDelims: [String] = []

        func endWord() {
            if inWord { words.append(cur); cur = ""; inWord = false }
        }
        func endSegment(nextAfterPipe: Bool) {
            endWord()
            if !words.isEmpty || writes {
                segments.append(Segment(words: words, writes: writes, afterPipe: segAfterPipe,
                                        hasHeredoc: heredoc, heredocBodies: segBodies))
                if heredoc, let head = words.first.map({ (($0 as NSString).lastPathComponent).lowercased() }),
                   interpreters.contains(head) || words.contains(where: { interpreters.contains(($0 as NSString).lastPathComponent.lowercased()) }) {
                    interpreterBodies.append(contentsOf: segBodies)
                }
            }
            words = []; writes = false; heredoc = false; segBodies = []
            segAfterPipe = nextAfterPipe
        }

        /// Text between a balanced "(" at `start` and its ")", and the index after it.
        func balanced(from start: Int) -> (String, Int) {
            var depth = 0
            var j = start
            var inner = ""
            var single = false, double = false
            while j < n {
                let c = chars[j]
                if c == "\\" && j + 1 < n && !single { inner.append(c); inner.append(chars[j + 1]); j += 2; continue }
                if c == "'" && !double { single.toggle() }
                else if c == "\"" && !single { double.toggle() }
                else if !single && !double {
                    if c == "(" { depth += 1; if depth == 1 { j += 1; continue } }
                    else if c == ")" { depth -= 1; if depth == 0 { return (inner, j + 1) } }
                }
                inner.append(c)
                j += 1
            }
            return (inner, n)
        }
        func backtick(from start: Int) -> (String, Int) {
            var j = start + 1
            var inner = ""
            while j < n, chars[j] != "`" {
                if chars[j] == "\\" && j + 1 < n { inner.append(chars[j + 1]); j += 2; continue }
                inner.append(chars[j]); j += 1
            }
            return (inner, min(n, j + 1))
        }
        /// The word after a redirect operator. A target that holds `$(`, a backtick
        /// or `<(` is not read here: it is left for the main loop so the command
        /// inside is classified (the returned word is then empty).
        func readTarget(from start: Int) -> (String, Int) {
            var j = start
            while j < n, chars[j] == " " || chars[j] == "\t" { j += 1 }
            func runsSomething(_ k: Int) -> Bool {
                chars[k] == "`" || (chars[k] == "$" && k + 1 < n && chars[k + 1] == "(")
            }
            var word = ""
            if j < n, chars[j] == "\"" || chars[j] == "'" {
                let q = chars[j]
                var k = j + 1
                var inner = ""
                while k < n, chars[k] != q { inner.append(chars[k]); k += 1 }
                if q == "\"", inner.contains("$(") || inner.contains("`") { return ("", j) }
                return (inner, min(n, k + 1))
            }
            while j < n, !" \t\n;&|<>()".contains(chars[j]) {
                if runsSomething(j) { return ("", j) }
                word.append(chars[j]); j += 1
            }
            return (word, j)
        }

        while i < n {
            let c = chars[i]
            let next: Character? = i + 1 < n ? chars[i + 1] : nil

            if c == "\\" {
                if let next { if next != "\n" { cur.append(next); inWord = true }; i += 2 } else { i += 1 }
                continue
            }
            if c == "'" {
                inWord = true
                i += 1
                while i < n, chars[i] != "'" { cur.append(chars[i]); i += 1 }
                i += 1
                continue
            }
            if c == "\"" {
                inWord = true
                i += 1
                while i < n, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < n { cur.append(chars[i + 1]); i += 2; continue }
                    if chars[i] == "$", i + 1 < n, chars[i + 1] == "(" {
                        let (inner, after) = balanced(from: i + 1)
                        subs.append(inner); cur += "$SUB"; i = after; continue
                    }
                    if chars[i] == "`" {
                        let (inner, after) = backtick(from: i)
                        subs.append(inner); cur += "$SUB"; i = after; continue
                    }
                    cur.append(chars[i]); i += 1
                }
                i += 1
                continue
            }
            if c == "$", next == "(" {
                if i + 2 < n, chars[i + 2] == "(" { // arithmetic
                    let (inner, after) = balanced(from: i + 1)
                    // Arithmetic is not a command, but it can hold one: $(( $(rm x) )).
                    if inner.contains("$(") || inner.contains("`") { subs.append(inner) }
                    cur += "0"; inWord = true; i = after
                } else {
                    let (inner, after) = balanced(from: i + 1)
                    subs.append(inner); cur += "$SUB"; inWord = true; i = after
                }
                continue
            }
            if c == "`" {
                let (inner, after) = backtick(from: i)
                subs.append(inner); cur += "$SUB"; inWord = true; i = after
                continue
            }
            if (c == "<" || c == ">"), next == "(" {
                let (inner, after) = balanced(from: i + 1)
                subs.append(inner); cur += "$SUB"; inWord = true; i = after
                continue
            }
            if c == "#" && !inWord {
                while i < n, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == " " || c == "\t" { endWord(); i += 1; continue }
            if c == "\n" {
                i += 1
                // A heredoc body runs to its delimiter line.
                for delim in pendingDelims {
                    var body: [String] = []
                    while i < n {
                        var line = ""
                        while i < n, chars[i] != "\n" { line.append(chars[i]); i += 1 }
                        i += 1
                        if line.trimmingCharacters(in: .whitespaces) == delim { break }
                        body.append(line)
                    }
                    let text = body.joined(separator: "\n")
                    segBodies.append(text); bodies.append(text)
                    if text.contains("$(") || text.contains("`") { opaque = true }
                }
                pendingDelims = []
                endSegment(nextAfterPipe: false)
                continue
            }
            if c == ";" { endSegment(nextAfterPipe: false); i += 1; continue }
            if c == "&" {
                if next == "&" { endSegment(nextAfterPipe: false); i += 2; continue }
                if next == ">" { i += 1; continue } // &> file; the ">" below judges the target (/dev/null is not a write)
                endSegment(nextAfterPipe: false); i += 1; continue
            }
            if c == "|" {
                if next == "|" { endSegment(nextAfterPipe: false); i += 2; continue }
                if next == "&" { endSegment(nextAfterPipe: true); i += 2; continue }
                endSegment(nextAfterPipe: true); i += 1; continue
            }
            if c == ">" {
                if inWord, cur.allSatisfy({ $0.isNumber }) { cur = ""; inWord = false } // "2>" is not a word
                i += 1
                if i < n, chars[i] == ">" { i += 1 }
                if i < n, chars[i] == "|" { i += 1 }
                if i < n, chars[i] == "&" { // 2>&1 duplicates a descriptor; >&file writes a file
                    i += 1
                    let (dup, after) = readTarget(from: i)
                    i = after
                    if dup.isEmpty || !(dup.allSatisfy({ $0.isNumber }) || dup == "-") && dup != "/dev/null" { writes = true }
                    continue
                }
                let (target, after) = readTarget(from: i)
                i = after
                if target != "/dev/null" { writes = true }
                continue
            }
            if c == "<" {
                if next == "<" {
                    if i + 2 < n, chars[i + 2] == "<" { i += 3; continue } // here-string
                    i += 2
                    if i < n, chars[i] == "-" { i += 1 }
                    let (delim, after) = readTarget(from: i)
                    i = after
                    // A quoted delimiter (`<<\EOF`, `<<'EOF'`) names the same end line as a bare one.
                    pendingDelims.append(delim.filter { $0 != "\\" })
                    heredoc = true
                    continue
                }
                i += 1
                let (_, after) = readTarget(from: i) // input redirect: the file is not an argument
                i = after
                continue
            }
            cur.append(c)
            inWord = true
            i += 1
        }
        endSegment(nextAfterPipe: false)
        _ = bodies
        return Parsed(segments: segments, substitutions: subs, interpreterHeredocBodies: interpreterBodies,
                      hasOpaqueHeredoc: opaque)
    }
}
