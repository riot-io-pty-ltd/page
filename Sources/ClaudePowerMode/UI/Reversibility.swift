import Foundation

/// How hard a pending tool call is to take back. Drives the shape of a Decide
/// row, which keys it offers, and the chip on it (v4 trust model, section 4).
///
/// Conservative by construction: only a command Page positively recognises as
/// read-only, test or build is `.undoable`. Anything it cannot read, parse or
/// place is at least `.considered`; destructive deletes, force pushes,
/// dropped data, deploys and publishes, `sudo` and `curl | sh` are
/// `.irreversible`. A chip is a hint, never a "safe" badge.
enum Reversibility: Int, Comparable, CaseIterable, Equatable {
    case undoable = 0
    case considered = 1
    case irreversible = 2

    static func < (a: Reversibility, b: Reversibility) -> Bool { a.rawValue < b.rawValue }

    /// Short reason tags shown next to (and sent with) the class.
    enum Tag: String, Equatable {
        case readOnly = "Read-only"
        case editsInRepo = "Edits in repo"
        case runsCommands = "Runs commands"
        case networkOutside = "Network/outside repo"
        case destructive = "Destructive"
    }

    struct Verdict: Equatable {
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

    /// Pure. Classifies what a page's `context` shows. `context` is the text
    /// `InterventionDetector.describeToolUse` writes ("[Bash] cmd\ndescription",
    /// "[Edit] path ...", "One of these is waiting for approval:\n• ..."), or
    /// the hook's bare "Claude is waiting for your approval", which says
    /// nothing about the action and is therefore `.considered`. A page with
    /// several tool calls takes the worst of them. `cwd` is the session's
    /// project directory, used to tell edits inside it from edits outside.
    static func classify(context: String, cwd: String?) -> Verdict {
        let text = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let multiHeader = "One of these is waiting for approval:"
        if text.hasPrefix(multiHeader) {
            let body = String(text.dropFirst(multiHeader.count))
            let entries = body.components(separatedBy: "\n• ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .map { $0.hasPrefix("• ") ? String($0.dropFirst(2)) : $0 }
                .filter { !$0.isEmpty }
            guard !entries.isEmpty else { return unknown("no tool call to read") }
            let verdicts = entries.map { classifyEntry($0, cwd: cwd) }
            return verdicts.dropFirst().reduce(verdicts[0], Verdict.combine)
        }
        return classifyEntry(text, cwd: cwd)
    }

    /// Pure. Classifies a shell command line the way Claude's Bash tool would
    /// run it. Empty input is `.considered` (nothing to judge).
    static func classifyBash(_ command: String) -> Verdict {
        classifyBash(command, depth: 0)
    }

    // MARK: one tool call

    private static func classifyEntry(_ entry: String, cwd: String?) -> Verdict {
        let v = classifyEntryCore(entry, cwd: cwd)
        // A page's text is clipped to a fixed length ("…"): whatever was cut
        // off might be the dangerous part, so a clipped call is never Undoable.
        if entry.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("…"), v.level < .considered {
            return Verdict(level: .considered, tags: v.tags, reason: "the command was cut short")
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

        switch name {
        case "Bash":
            return classifyBashTool(first: first, rest: Array(lines.dropFirst()))
        case "Read", "Glob", "Grep", "LS", "NotebookRead":
            // Reading never changes anything; outside the project it can still
            // be a surprise, so it is not offered the Return shortcut.
            if name == "Read", !isInside(path: first, cwd: cwd) {
                return Verdict(level: .considered, tags: [.networkOutside], reason: "reads outside the project")
            }
            return Verdict(level: .undoable, tags: [.readOnly], reason: "read-only")
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            let path = first.components(separatedBy: " (").first ?? first
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

    /// Only the command itself is judged, never the model-written description
    /// on the following line; but a following line that could be more command
    /// (a multi-line script) is judged too.
    private static func classifyBashTool(first: String, rest: [String]) -> Verdict {
        let extra = rest.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !first.isEmpty, first != "(no command)" else { return unknown("no command shown") }
        // The command alone, when its first line is complete and one plain
        // prose line follows (the description).
        let firstIsComplete = !endsOpen(first)
        let descriptionOnly = firstIsComplete && extra.count <= 1 && extra.allSatisfy(isDescription)
        if descriptionOnly {
            let v = classifyBash(first, depth: 0)
            // A second line that is itself a known command (not prose that
            // merely starts with a verb) is part of the script.
            if let line = extra.first {
                let e = classifyBash(line, depth: 0)
                let recognised = !e.reason.contains("isn't one Page recognises")
                if e.level == .irreversible || (recognised && e.level > .undoable) { return Verdict.combine(v, e) }
            }
            return v
        }
        // Possibly a multi-line command: judge everything, and never call it undoable.
        var v = classifyBash(([first] + extra).joined(separator: "\n"), depth: 0)
        if v.level < .considered {
            v = Verdict(level: .considered, tags: v.tags, reason: "multi-line command")
        }
        return v
    }

    /// Claude's description of a command is a sentence: it starts with a
    /// capital letter and is plain words. "./nuke.sh" or "mycli wipe" is not
    /// one; it is judged as part of the command.
    private static func isDescription(_ line: String) -> Bool {
        guard let first = line.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) else { return false }
        return isPlainProse(line)
    }

    /// A line that cannot be shell syntax worth running: words, spaces and
    /// ordinary punctuation, none of the shell's operators.
    private static func isPlainProse(_ line: String) -> Bool {
        let operators = CharacterSet(charactersIn: ";&|<>`$(){}\\\"*?~=")
        return line.rangeOfCharacter(from: operators) == nil
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
        let (words, _, _) = stripWrappers(seg.words)
        return words.first.map(baseName)
    }

    private static func baseName(_ word: String) -> String {
        (word as NSString).lastPathComponent.lowercased()
    }

    private static let noopKeywords: Set<String> = ["for", "case", "esac", "fi", "done", "}", ")", "function", "select"]
    private static let prefixKeywords: Set<String> = ["if", "then", "else", "elif", "while", "until", "do", "!", "{", "(", "time", "coproc"]

    /// Drops env assignments, shell keywords and wrappers. Returns the
    /// remaining words, whether `sudo`-like elevation was seen, and whether
    /// the command receives its arguments from `xargs`.
    private static func stripWrappers(_ input: [String]) -> (words: [String], elevated: Bool, xargs: Bool) {
        var w = input
        var elevated = false
        var xargs = false
        func isAssignment(_ s: String) -> Bool {
            guard let eq = s.firstIndex(of: "="), eq != s.startIndex else { return false }
            let name = s[s.startIndex..<eq]
            return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } && !(name.first?.isNumber ?? false)
        }
        // Leading "(" / "{" glued to the first word.
        if let f = w.first, f.count > 1, f.hasPrefix("(") || f.hasPrefix("{") { w[0] = String(f.dropFirst()) }
        var guardCount = 0
        while let first = w.first, guardCount < 12 {
            guardCount += 1
            let name = baseName(first)
            if isAssignment(first) || prefixKeywords.contains(first) { w.removeFirst(); continue }
            switch name {
            case "sudo", "doas", "su", "pkexec":
                elevated = true
                w.removeFirst()
            case "env", "command", "builtin", "exec", "nohup", "caffeinate", "time", "stdbuf", "ionice", "unbuffer":
                w.removeFirst()
                while let f = w.first, f.hasPrefix("-") { w.removeFirst() }
            case "nice":
                w.removeFirst()
                while let f = w.first, f.hasPrefix("-") {
                    w.removeFirst()
                    if f == "-n", !w.isEmpty { w.removeFirst() }
                }
            case "timeout":
                w.removeFirst()
                while let f = w.first, f.hasPrefix("-") { w.removeFirst() }
                if !w.isEmpty { w.removeFirst() } // the duration
            case "xargs":
                xargs = true
                w.removeFirst()
                let withValue: Set<String> = ["-n", "-I", "-P", "-L", "-s", "-d", "-E", "-J", "-a"]
                while let f = w.first, f.hasPrefix("-") {
                    w.removeFirst()
                    if withValue.contains(f), !w.isEmpty { w.removeFirst() }
                }
            default:
                return (w, elevated, xargs)
            }
        }
        return (w, elevated, xargs)
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
        "aws", "gcloud", "az", "kubectl", "helm", "terraform", "tofu", "pulumi", "heroku", "fly", "flyctl", "vercel",
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
        let (words, elevated, _) = stripWrappers(seg.words)
        if elevated {
            return Verdict(level: .irreversible, tags: [.runsCommands, .destructive], reason: "runs with sudo")
        }
        guard let head = words.first else { return Verdict(level: .undoable, tags: [], reason: "no command") }
        if noopKeywords.contains(head) { return Verdict(level: .undoable, tags: [], reason: "shell syntax") }
        let cmd = baseName(head)
        let args = Array(words.dropFirst())
        if cmd.hasPrefix("mkfs") { return destroy("mkfs formats a disk") }

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
            let inPlace = args.contains { $0 == "-i" || $0.hasPrefix("-i") && !$0.hasPrefix("--") || $0 == "--in-place" || $0.hasPrefix("--in-place") }
            return inPlace ? considered("sed edits files in place") : readOnly("text filter")
        case "awk", "gawk", "mawk":
            let program = args.joined(separator: " ")
            if program.contains("system(") || program.contains(">") || program.contains("| \"") {
                return considered("awk program can run or write")
            }
            return readOnly("text filter")
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
            return classifyMake(args)
        case "pytest", "py.test", "tox", "nox", "jest", "vitest", "mocha", "ava", "rspec", "phpunit", "mypy", "pylint",
             "flake8", "pyright", "tsc", "swiftlint", "shellcheck", "tflint", "ctest", "bats", "xctest":
            if args.contains("--fix") || args.contains("--write") || args.contains("-u") && cmd == "jest" {
                return considered("may rewrite files")
            }
            return Verdict(level: .undoable, tags: [.runsCommands], reason: "test or lint run")
        case "ruff", "eslint", "prettier", "black", "isort", "swiftformat", "gofmt", "rustfmt", "clang-format":
            let checks = args.contains { ["--check", "-c", "--diff", "--list-different", "-l", "--dry-run", "--lint"].contains($0) }
                || (cmd == "ruff" && args.first == "check" && !args.contains("--fix"))
                || (cmd == "eslint" && !args.contains("--fix"))
            return checks ? Verdict(level: .undoable, tags: [.runsCommands], reason: "lint or format check")
                          : considered("\(cmd) rewrites files")
        case "xcodebuild":
            let acts = Set(args)
            if acts.contains("-exportArchive") || acts.contains("archive") { return considered("xcodebuild archive") }
            if acts.contains("build") || acts.contains("test") || acts.contains("-list") || acts.contains("-showBuildSettings")
                || acts.contains("build-for-testing") || acts.contains("test-without-building") {
                return Verdict(level: .undoable, tags: [.runsCommands], reason: "build or test")
            }
            return considered("xcodebuild")
        case "gradle", "gradlew", "mvn", "mvnw", "./gradlew":
            let ok: Set<String> = ["test", "build", "assemble", "check", "compile", "verify", "dependencies", "tasks",
                                   "compilejava", "compilekotlin", "lint", "--version", "-v", "-version", "package"]
            let targets = args.filter { !$0.hasPrefix("-") }.map { $0.lowercased() }
            if !targets.isEmpty, targets.allSatisfy({ ok.contains($0) || ok.contains($0.components(separatedBy: ":").last ?? "") }) {
                return Verdict(level: .undoable, tags: [.runsCommands], reason: "build or test")
            }
            return considered("build tool")
        case "dotnet":
            let sub = args.first ?? ""
            return ["build", "test", "--version", "--info", "list"].contains(sub)
                ? Verdict(level: .undoable, tags: [.runsCommands], reason: "build or test") : considered("dotnet")
        case "rake":
            let t = args.first ?? ""
            return ["test", "spec", "-t", "-T", "--tasks"].contains(t)
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
        if textOnly.contains(cmd) { return readOnly("read-only command") }
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
        if (cmd == "python" || cmd == "python3"), let m = args.firstIndex(of: "-m"), m + 1 < args.count {
            let module = args[m + 1]
            if ["pytest", "unittest", "mypy", "pylint", "flake8", "pyright", "doctest", "compileall"].contains(module) {
                return Verdict(level: .undoable, tags: [.runsCommands], reason: "test or lint run")
            }
        }
        if args.contains("--version") || args.contains("-V") || args.contains("-v") && args.count == 1 {
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

    /// Skips git's global options, returning the subcommand and what follows.
    private static func gitSub(_ args: [String]) -> (String, [String]) {
        var rest = args
        let withValue: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"]
        while let f = rest.first, f.hasPrefix("-") {
            rest.removeFirst()
            if withValue.contains(f), !rest.isEmpty { rest.removeFirst() }
        }
        guard let sub = rest.first else { return ("", []) }
        return (sub.lowercased(), Array(rest.dropFirst()))
    }

    private static func classifyGit(_ args: [String]) -> Verdict {
        let (sub, a) = gitSub(args)
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
             "merge-base", "for-each-ref", "show-ref", "check-ignore", "verify-commit", "help", "version", "--version",
             "diff-files", "diff-index", "ls-remote", "annotate", "range-diff", "show-branch", "var":
            if sub == "ls-remote" { return Verdict(level: .considered, tags: [.networkOutside], reason: "reads a remote") }
            if hasFlag("--output") || hasFlag("-o") && sub == "diff" { return considered("git writes a file") }
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
            if s.isEmpty || ["show", "get-url"].contains(s) { return readOnly("lists remotes") }
            return git
        case "stash":
            let s = nonFlags.first ?? "push"
            if ["list", "show"].contains(s) { return readOnly("lists stashes") }
            if ["drop", "clear"].contains(s) { return destroy("stash drop loses work") }
            return git
        case "config":
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
        switch sub {
        case "test", "t", "build", "b", "check", "c", "clippy", "doc", "bench", "tree", "metadata", "version", "--version", "-V":
            return Verdict(level: .undoable, tags: [.runsCommands], reason: "build or test")
        case "fmt":
            return args.contains("--check") ? Verdict(level: .undoable, tags: [.runsCommands], reason: "format check") : considered("cargo fmt rewrites files")
        case "publish", "yank", "owner":
            return Verdict(level: .irreversible, tags: [.networkOutside, .destructive], reason: "publishes a crate")
        default:
            return considered("cargo \(sub)")
        }
    }

    private static func classifyGo(_ args: [String]) -> Verdict {
        let sub = args.first ?? ""
        if ["test", "build", "vet", "list", "version", "env", "doc"].contains(sub) {
            return sub == "env" && args.contains("-w") ? considered("go env -w") : Verdict(level: .undoable, tags: [.runsCommands], reason: "build or test")
        }
        return considered("go \(sub)")
    }

    private static func classifyMake(_ args: [String]) -> Verdict {
        let targets = args.filter { !$0.hasPrefix("-") && !$0.contains("=") }
        let dry = args.contains("-n") || args.contains("--dry-run") || args.contains("-p")
        if dry { return readOnly("make dry run") }
        let ok: Set<String> = ["test", "tests", "check", "build", "all", "lint", "typecheck", "vet", "fmt-check", "verify"]
        if !targets.isEmpty, targets.allSatisfy({ ok.contains($0.lowercased()) }) {
            return Verdict(level: .undoable, tags: [.runsCommands], reason: "build or test")
        }
        return considered("make target")
    }

    private static func classifyNodePackage(_ cmd: String, _ args: [String]) -> Verdict {
        let sub = args.first(where: { !$0.hasPrefix("-") }) ?? ""
        let safeScripts = ["test", "lint", "build", "check", "typecheck", "type-check", "verify", "tsc", "format:check", "types", "compile"]
        func safeScript(_ name: String) -> Bool {
            let n = name.lowercased()
            return safeScripts.contains { n == $0 || n.hasPrefix($0 + ":") || n.hasPrefix($0 + "-") }
        }
        switch sub {
        case "test", "t", "tst", "lint", "build", "typecheck", "check":
            return Verdict(level: .undoable, tags: [.runsCommands], reason: "test or build")
        case "run", "run-script":
            let script = args.drop(while: { $0 != sub }).dropFirst().first(where: { !$0.hasPrefix("-") }) ?? ""
            return safeScript(script)
                ? Verdict(level: .undoable, tags: [.runsCommands], reason: "test or build script") : considered("runs a package script")
        case "ls", "list", "view", "info", "outdated", "why", "--version", "-v", "version", "explain", "help", "config":
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
        if ["kubectl", "terraform", "tofu", "pulumi", "helm", "oc"].contains(cmd), subs.contains(where: apply.contains) {
            return Verdict(level: .irreversible, tags: network + [.destructive], reason: "\(cmd) changes live infrastructure")
        }
        if cmd == "docker" || cmd == "podman", subs.first == "push" {
            return Verdict(level: .irreversible, tags: network + [.destructive], reason: "pushes an image")
        }
        if cmd == "docker" || cmd == "podman", subs.first == "system" || subs.first == "volume" || subs.first == "image", subs.contains("prune") {
            return Verdict(level: .irreversible, tags: network + [.destructive], reason: "prunes containers or images")
        }
        if let first = subs.first, readOnlySubcommands.contains(first) {
            return Verdict(level: .undoable, tags: [.readOnly], reason: "\(cmd) query")
        }
        if cmd == "aws" || cmd == "gcloud" || cmd == "az",
           subs.contains(where: { $0.hasPrefix("describe") || $0.hasPrefix("list") || $0.hasPrefix("get-") || $0 == "get" || $0 == "ls" }) {
            return Verdict(level: .undoable, tags: [.readOnly], reason: "\(cmd) query")
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
        let chars = Array(input)
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
        func readTarget(from start: Int) -> (String, Int) {
            var j = start
            while j < n, chars[j] == " " || chars[j] == "\t" { j += 1 }
            var word = ""
            if j < n, chars[j] == "\"" || chars[j] == "'" {
                let q = chars[j]
                j += 1
                while j < n, chars[j] != q { word.append(chars[j]); j += 1 }
                return (word, min(n, j + 1))
            }
            while j < n, !" \t\n;&|<>()".contains(chars[j]) { word.append(chars[j]); j += 1 }
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
                    let (_, after) = balanced(from: i + 1)
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
                if next == ">" { writes = true; i += 1; continue } // &> file; the ">" below handles the rest
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
                if i < n, chars[i] == "&" { // 2>&1
                    i += 1
                    while i < n, chars[i].isNumber || chars[i] == "-" { i += 1 }
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
                    pendingDelims.append(delim)
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
