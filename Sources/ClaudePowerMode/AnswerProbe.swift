#if DEBUG
import Foundation

/// A measuring tool for "can Page answer a question dialog in this terminal?". DEBUG builds only: the
/// whole file is compiled out of `swift build -c release`, so it can never ship in Page.app.
///
///     .build/debug/ClaudePowerMode --probe-answer --session <id> --answers '<json>' \
///         [--caps arrows|plain|terminalReturn] [--tmux-socket <name>] [--dry-run]
///     .build/debug/ClaudePowerMode --probe-screen --session <id> [--tmux-socket <name>]
///
/// `--probe-answer` runs the real `AnswerDelivery.run` with `liveIO` (registry, transcript, screen reader,
/// `sendOneKey`). Only the one thing `capabilities(of:)` gates is overridable (`--caps`), plus, for
/// `terminalReturn`, Terminal.app's `do script` transport. It never presses a key unless the session's cwd
/// is under `allowedRoot` (throwaway sessions started by `ask.sh`), and it never sends Esc.
enum AnswerProbe {
    static let answerFlag = "--probe-answer"
    static let screenFlag = "--probe-screen"
    /// `PAGE_PROBE_ROOT`, else `$TMPDIR/page-answer-probe`: start throwaway sessions under it.
    static let allowedRoot: String = {
        if let r = ProcessInfo.processInfo.environment["PAGE_PROBE_ROOT"], r.hasPrefix("/") { return r }
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("page-answer-probe")
    }()

    enum CapsMode: String, Equatable {
        /// tmux's measured set: digits, Tab, Enter and the arrow keys.
        case arrows
        /// Digits, Tab, Enter, no arrows (`AnswerKeyCaps.plainKeysOnly`).
        case plain
        /// Terminal.app: `do script` types the text and always adds Return. As plain, with that transport,
        /// and only for a one-question single-select (the Return after the digit lands on an empty input).
        case terminalReturn
    }

    struct Options: Equatable {
        var screenOnly = false
        var sessionId = ""
        var answersJSON: String?
        var caps: CapsMode?
        var dryRun = false
        var tmuxSocket: String?
    }

    static func isRequested(_ args: [String]) -> Bool { args.contains(answerFlag) || args.contains(screenFlag) }

    // MARK: Pure parts (unit-tested)

    static func parse(_ args: [String]) -> Swift.Result<Options, ProbeError> {
        var o = Options()
        o.screenOnly = args.contains(screenFlag)
        if o.screenOnly && args.contains(answerFlag) { return .failure(.init("use --probe-answer or --probe-screen, not both")) }
        var i = 1
        func value(_ flag: String) -> String? {
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return nil }
            i += 1
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case answerFlag, screenFlag: break
            case "--session":
                guard let v = value("--session") else { return .failure(.init("--session needs a session id")) }
                o.sessionId = v
            case "--answers":
                guard let v = value("--answers") else { return .failure(.init("--answers needs a JSON array")) }
                o.answersJSON = v
            case "--caps":
                guard let v = value("--caps"), let c = CapsMode(rawValue: v) else {
                    return .failure(.init("--caps is one of arrows, plain, terminalReturn"))
                }
                o.caps = c
            case "--tmux-socket":
                guard let v = value("--tmux-socket"), v.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else {
                    return .failure(.init("--tmux-socket needs a tmux -L socket name"))
                }
                o.tmuxSocket = v
            case "--dry-run": o.dryRun = true
            default: return .failure(.init("unknown argument \(args[i])"))
            }
            i += 1
        }
        if o.sessionId.isEmpty { return .failure(.init("--session <id> is required")) }
        if !o.screenOnly {
            guard o.answersJSON != nil else { return .failure(.init("--answers '<json>' is required")) }
        }
        return .success(o)
    }

    struct ProbeError: Error, Equatable {
        let message: String
        init(_ m: String) { message = m }
    }

    /// True only for a cwd strictly inside `root` after symlinks and `..` are resolved on both sides.
    static func cwdAllowed(_ cwd: String?, root: String = allowedRoot) -> Bool {
        guard let cwd, !cwd.isEmpty, cwd.hasPrefix("/") else { return false }
        // realpath(3) on the deepest ancestor that exists (Foundation's resolvingSymlinksInPath rewrites
        // /private/tmp to /tmp only for paths that exist, which would make an existing root and a
        // not-yet-created child compare unequal), then the remaining components, with `..` already folded.
        func real(_ p: String) -> String {
            var head = URL(fileURLWithPath: p).standardizedFileURL.path
            var tail: [String] = []
            while true {
                if let r = realpath(head, nil) { defer { free(r) }; return ([String(cString: r)] + tail.reversed()).joined(separator: "/").replacingOccurrences(of: "//", with: "/") }
                guard head != "/", !head.isEmpty else { return p }
                tail.append((head as NSString).lastPathComponent)
                head = (head as NSString).deletingLastPathComponent
            }
        }
        let r = real(root)
        let c = real(cwd)
        return c.hasPrefix(r + "/") && c.count > r.count + 1
    }

    static func describe(_ key: Keystroke) -> String {
        switch key {
        case .text(let s): return "text(\"\(s)\")"
        case .enter: return "Enter"
        case .escape: return "ESC"
        case .key(let k): return "key(\(k.rawValue))"
        case .pause(let t): return "pause(\(t))"
        case .awaitPromptClosed: return "awaitPromptClosed"
        }
    }

    /// The only shape `--caps terminalReturn` may press into: one single-select question, one pick, no Other.
    /// Anything else returns the reason, and the probe stops before a key is sent. Pure.
    static func terminalReturnRefusal(_ asked: AskedQuestionSet, _ picks: [AnswerPick]) -> String? {
        guard asked.questions.count == 1, !asked.questions[0].multi, picks.count == 1,
              picks[0].question == 0, picks[0].picks.count == 1, picks[0].other == nil else {
            return "terminalReturn (Terminal.app's do script adds a Return) is only safe for a one-question single-select with no Other"
        }
        return nil
    }

    static func caps(for mode: CapsMode?, host: InjectionExecutor.TerminalHost) -> Swift.Result<AnswerKeyCaps, AnswerPlanError> {
        switch mode {
        case nil: return AnswerDelivery.capabilities(of: host)
        case .arrows?: return .success(AnswerKeyCaps(arrows: true))
        case .plain?, .terminalReturn?: return .success(.plainKeysOnly)
        }
    }

    /// The `toolUseResult.answers` of the user record answering `toolUseId`, as JSON text; nil when none yet.
    static func transcriptAnswers(transcript text: String, toolUseId: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.first == "{", line.contains(toolUseId),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "user",
                  let tur = obj["toolUseResult"] as? [String: Any], let answers = tur["answers"],
                  let data = try? JSONSerialization.data(withJSONObject: answers, options: [.sortedKeys]) else { continue }
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    // MARK: Output

    private static func say(_ s: String = "") {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }

    private static func indent(_ screen: String?) -> String {
        guard let screen else { return "    (nil: no screen)" }
        var lines = screen.components(separatedBy: "\n")
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if lines.isEmpty { return "    (blank screen)" }
        return lines.map { "    | " + $0 }.joined(separator: "\n")
    }

    // MARK: Entry point

    /// Returns the process exit code: 0 delivered (or a clean dry run / screen read), 1 not delivered, 2 refused / bad usage.
    static func run(arguments: [String]) -> Int32 {
        let opts: Options
        switch parse(arguments) {
        case .failure(let e):
            say("probe: \(e.message)")
            say("usage: ClaudePowerMode --probe-answer --session <id> --answers '<json>' [--caps arrows|plain|terminalReturn] [--tmux-socket <name>] [--dry-run]")
            say("       ClaudePowerMode --probe-screen --session <id> [--tmux-socket <name>]")
            return 2
        case .success(let o): opts = o
        }

        // Point every tmux call at the probe's own server, never the user's.
        unsetenv("TMUX_TMPDIR")
        if let name = opts.tmuxSocket {
            guard let tmux = ProcessRunner.findExecutable("tmux") else { say("probe: tmux not found"); return 2 }
            unsetenv("TMUX")
            let r = ProcessRunner.run(tmux, ["-L", name, "display-message", "-p", "#{socket_path}"], timeout: 3)
            let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard r.succeeded, !path.isEmpty else { say("probe: no tmux server on -L \(name) (\(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))"); return 2 }
            setenv("TMUX", "\(path),0,0", 1)
            say("probe: tmux calls go to socket \(path)")
        }

        let registry = ClaudeSessionRegistry(projectsDirectory: "~/.claude/projects")
        let live = AnswerDelivery.liveIO(registry: registry)

        // 1. Who is this? Print it before anything else, and refuse anything outside the throwaway area.
        let session: ClaudeLiveSession
        let table: [ProcessRunner.ProcessInfoRow]
        switch live.resolve(opts.sessionId) {
        case .ended: say("probe: REFUSED: no live Claude process for session \(opts.sessionId)"); return 2
        case .failed(let f): say("probe: REFUSED: \(f.detail)"); return 2
        case .live(let s, let t): session = s; table = t
        }
        let host = live.resolveHost(session, table)
        say("probe: session \(session.sessionId) pid=\(session.pid) tty=\(session.tty ?? "nil") status=\(session.status) cwd=\(session.cwd ?? "nil")")
        say("probe: host = \(host.label)  (\(host))")
        guard cwdAllowed(session.cwd) else {
            say("probe: REFUSED: this session's cwd is not under \(allowedRoot)/ — the probe only touches throwaway sessions started with ask.sh")
            return 2
        }

        if opts.screenOnly {
            guard let read = live.screenReader(host) else { say("probe: screen reader for \(host.label): nil (Page cannot read this host)"); return 1 }
            say("probe: screen as Page's reader returns it:")
            say(indent(read()))
            return 0
        }

        // 2. The pending question, and the answers.
        guard let tools = live.pendingTools(session) else { say("probe: REFUSED: transcript unreadable"); return 2 }
        say("probe: pending tools: \(tools.map { "\($0.name)#\($0.id)" })")
        guard let ask = tools.first(where: { $0.name == "AskUserQuestion" }), let asked = ask.asked else {
            say("probe: no AskUserQuestion is pending in this session"); return 2
        }
        for (i, q) in asked.questions.enumerated() {
            say("probe: Q\(i + 1) \(q.multi ? "multi" : "single") \"\(q.question)\" options=\(q.options.map(\.label))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data((opts.answersJSON ?? "").utf8)),
              let picks = AnswerRequest.parseAnswers(json) else {
            say("probe: --answers must be a JSON array like [{\"i\":0,\"picks\":[1]},{\"i\":1,\"picks\":[0,2]},{\"i\":2,\"picks\":[],\"other\":\"x\"}]")
            return 2
        }
        if opts.caps == .terminalReturn, let why = terminalReturnRefusal(asked, picks) {
            say("probe: REFUSED: \(why)")
            return 2
        }
        let request = AnswerRequest(promptKey: ask.id, answers: picks)
        if case .success(let answers) = AnswerPlan.resolve(asked, picks) {
            say("probe: intended answers = \(AnswerPlan.expectedAnswers(asked, answers).map { "\"\($0.question)\" => \"\($0.answer)\"" })")
        }

        // 3. The real path, wrapped to print what it reads and sends.
        var io = live
        var lastScreen: String?
        var keyNo = 0
        let mode = opts.caps
        io.capabilities = { h in
            let c = caps(for: mode, host: h)
            if case .success(let k) = c { say("probe: capabilities for \(h.label): arrows=\(k.arrows) (\(mode.map { "--caps \($0.rawValue)" } ?? "Page's own gate"))") }
            if case .failure(let e) = c { say("probe: capabilities for \(h.label): REFUSED by Page: \(e.message)") }
            return c
        }
        io.screenReader = { h in
            guard let read = live.screenReader(h) else { say("probe: no screen reader for \(h.label)"); return nil }
            return { let s = read(); lastScreen = s; return s }
        }
        io.sendKey = { h, key in
            keyNo += 1
            say("--- screen read before key #\(keyNo) ---")
            say(indent(lastScreen))
            if case .escape = key { say(">>> key #\(keyNo) ESC: BLOCKED by the probe (never sent)"); return "probe never sends Esc" }
            if opts.dryRun { say(">>> key #\(keyNo) \(describe(key)): DRY RUN, not sent"); return "dry-run" }
            say(">>> key #\(keyNo) \(describe(key)) -> \(h.label)")
            let why: String?
            if opts.caps == .terminalReturn, case .terminalApp(let tty) = h {
                let r = InjectionExecutor.sendViaTerminalApp([key], tty: tty, awaitClosed: { true })
                why = r.success ? nil : (r.detail.isEmpty ? r.output : r.detail)
            } else {
                why = live.sendKey(h, key)
            }
            say(why == nil ? "    sent" : "    NOT sent: \(why!)")
            return why
        }
        let started = Date()
        let result = AnswerDelivery.run(sessionId: opts.sessionId, request: request, io: io)
        let took = String(format: "%.1f", Date().timeIntervalSince(started))

        // 4. Report.
        say("--- final screen ---")
        say(indent(live.screenReader(host)?()))
        say("probe: RESULT code=\(result.code.rawValue) reason=\(result.reason?.rawValue ?? "-") detail=\"\(result.detail)\" keys=\(keyNo) in \(took)s")
        let text = live.transcriptText(session)
        let got = text.flatMap { transcriptAnswers(transcript: $0, toolUseId: ask.id) }
        say("probe: transcript toolUseResult.answers = \(got ?? "(none yet)")")
        if opts.dryRun { say("probe: dry run: nothing was sent"); return 0 }
        return result.code == .delivered ? 0 : 1
    }
}
#endif
