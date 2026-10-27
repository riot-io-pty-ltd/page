import Foundation

/// Answering a pending AskUserQuestion dialog on a Claude session, from a
/// phone's `answer` command or the Mac's own panel (SESSIONS-PROTOCOL.md §5 "Answering a question").
///
/// The gate refuses anything that isn't provably the question the person
/// saw: the session must still be `waiting`, the one pending tool call must
/// be the AskUserQuestion the phone named (`promptKey`), and no Page hook may
/// be holding the prompt. The question is re-read raw from the transcript
/// (the phone's copy is redacted) and the keys come from `AnswerDriver`,
/// which reads the screen before every one. Before each key the process
/// must still be in front of its terminal and the session still waiting on
/// the same question. Esc is never sent: on any mismatch the run stops and
/// the dialog stays open for the person at the Mac.
///
/// All I/O is behind `IO`, so the sequence is tested with fakes; production
/// runs it on the Claude backend's injection queue.
enum AnswerDelivery {
    static let questionChangedMessage = "That question changed — look at your phone for the new one"
    static let alreadyAnsweredMessage = "That question was already answered"
    static let unreadableMessage = "Page can't read this question's layout — answer at your Mac"
    static let holdMessage = "Page's phone-approval hook is handling this question — answer that page instead"
    static let severalMessage = "Several prompts are queued — answer at your Mac"
    /// Terminal.app's `do script` appends a Return to everything it types. Measured on a tmux stand-in: that
    /// Return lands on the next question or dismisses an Other answer, so no question shape is safe yet.
    static let terminalAppMessage = "Terminal.app adds a Return to every key Page types, which would skip or dismiss questions — answer at your Mac, or use tmux or iTerm2"
    static let noScreenMessage = "Page can't read this terminal's screen, so it can't check the question — answer at your Mac"
    static let confirmWait: TimeInterval = 4

    struct IO {
        var resolve: (String) -> InjectionExecutor.ClaudeTarget
        var currentRecord: (Int32) -> ClaudeSessionRecord?
        /// The session's pending tool calls, from the transcript tail; nil when unreadable.
        var pendingTools: (ClaudeLiveSession) -> [PendingToolUse]?
        var holdsSession: (String) -> Bool
        /// The session is a paused Claude Squad instance: Page leaves it alone, as for `input`.
        var squadPaused: (ClaudeLiveSession, InjectionExecutor.TerminalHost) -> Bool = { _, _ in false }
        var resolveHost: (ClaudeLiveSession, [ProcessRunner.ProcessInfoRow]) -> InjectionExecutor.TerminalHost
        var isForeground: (Int32) -> Bool?
        var screenReader: (InjectionExecutor.TerminalHost) -> (() -> String?)?
        /// Types one key. nil: sent; otherwise the phone-safe reason it wasn't.
        var sendKey: (InjectionExecutor.TerminalHost, Keystroke) -> String?
        /// The transcript's recent text, to read back what Claude received.
        var transcriptText: (ClaudeLiveSession) -> String?
        var sleep: (TimeInterval) -> Void = { usleep(useconds_t($0 * 1_000_000)) }
        var now: () -> Date = Date.init
        /// Which keys a host can press. Always `AnswerDelivery.capabilities(of:)` in the app; only the
        /// DEBUG `--probe-answer` tool swaps it, to try a host that is still gated.
        var capabilities: (InjectionExecutor.TerminalHost) -> Swift.Result<AnswerKeyCaps, AnswerPlanError> = AnswerDelivery.capabilities(of:)
    }

    /// Pure. The phone's view of a session (`SessionHostInfo`): can Page press answer keys there? Only
    /// terminals whose keys are measured against a real dialog (`TerminalCatalog`'s `answer`, by the wire
    /// host name); a blocked host, a paused Squad instance, Terminal.app or any other terminal answers by
    /// "Tell it instead".
    static func takesAnswerKeys(_ host: SessionHostInfo) -> Bool {
        guard host.canType, let id = TerminalCatalog.id(forWireHost: host.host) else { return false }
        return TerminalCatalog.entry(id).capabilities.answer.takesKeys
    }

    /// Pure. Which keys a host can press, or why it can't take an answer. Digits, Tab, Down and Enter, and
    /// the Other text, were each measured end to end (Claude Code 2.1.311) in tmux, iTerm2, cmux, WezTerm,
    /// kitty and Herdr; all six press arrow keys safely.
    static func capabilities(of host: InjectionExecutor.TerminalHost) -> Swift.Result<AnswerKeyCaps, AnswerPlanError> {
        switch host {
        case .tmux, .iTerm, .cmux, .wezterm, .kitty, .herdr: return .success(.withArrows)
        case .terminalApp: return .failure(.init(terminalAppMessage))
        case .unreachable(let why): return .failure(.init(why))
        case .unsupported(let app): return .failure(.init("Page can't type into \(app) yet — use tmux or iTerm2"))
        case .unknown: return .failure(.init("Couldn't find the session's terminal"))
        }
    }

    /// Fresh lookup → gate → drive the dialog → check what Claude received. Blocking.
    static func run(sessionId: String, request: AnswerRequest, io: IO) -> SessionCommandResult {
        let session: ClaudeLiveSession
        let table: [ProcessRunner.ProcessInfoRow]
        switch io.resolve(sessionId) {
        case .ended: return .refused(.ended, SessionInputGate.endedMessage)
        case .failed(let f): return .refused(.notTypable, f.detail)
        case .live(let s, let t): session = s; table = t
        }
        guard session.tty != nil else { return .refused(.notTypable, "This session isn't running in a terminal Page can type into") }
        guard session.hasSessionFile, let rec = io.currentRecord(session.pid) else {
            return .refused(.unknownState, SessionInputGate.unknownStateMessage)
        }
        guard ClaudeSessionStatus(raw: rec.status) == .waiting else {
            return .refused(.questionChanged, alreadyAnsweredMessage)
        }
        let startedAt = rec.statusUpdatedAt
        guard !io.holdsSession(session.sessionId) else { return .refused(.answerUnsupported, holdMessage) }

        guard let pending = io.pendingTools(session) else { return .refused(.unknownState, SessionInputGate.unknownStateMessage) }
        guard pending.count == 1 else {
            return .refused(pending.isEmpty ? .questionChanged : .answerUnsupported, pending.isEmpty ? alreadyAnsweredMessage : severalMessage)
        }
        guard pending[0].name == "AskUserQuestion", pending[0].id == request.promptKey else {
            return .refused(.questionChanged, questionChangedMessage)
        }
        guard let asked = pending[0].asked else { return .refused(.answerUnsupported, unreadableMessage) }
        let answers: [ResolvedAnswer]
        switch AnswerPlan.resolve(asked, request.answers) {
        case .failure(let e): return .refused(e.message == AnswerPlan.previewMessage ? .answerUnsupported : .error, e.message)
        case .success(let a): answers = a
        }

        let host = io.resolveHost(session, table)
        let caps: AnswerKeyCaps
        switch io.capabilities(host) {
        case .failure(let e): return .refused(.answerUnsupported, e.message)
        case .success(let c): caps = c
        }
        if io.squadPaused(session, host) { return .refused(.notTypable, ClaudeSquad.pausedMessage) }
        if !caps.arrows, AnswerPlan.needsArrows(asked, answers) { return .refused(.answerUnsupported, AnswerPlan.arrowsMessage) }
        guard io.isForeground(session.pid) == true else { return .refused(.notTypable, InjectionExecutor.notForegroundMessage) }
        guard let read = io.screenReader(host) else { return .refused(.answerUnsupported, noScreenMessage) }

        // Before every key: still in front of its terminal, still waiting on this very question.
        func precheck() -> String? {
            guard io.isForeground(session.pid) == true else { return InjectionExecutor.notForegroundMessage }
            guard let now = io.currentRecord(session.pid) else { return InjectionExecutor.sessionExitedMessage }
            guard ClaudeSessionStatus(raw: now.status) == .waiting else { return alreadyAnsweredMessage }
            if let a = startedAt, let b = now.statusUpdatedAt, abs(b.timeIntervalSince(a)) > 0.5 { return questionChangedMessage }
            guard !io.holdsSession(session.sessionId) else { return holdMessage }
            guard let tools = io.pendingTools(session), tools.count == 1, tools[0].id == request.promptKey else { return questionChangedMessage }
            return nil
        }

        var hostFailed = false
        var driver = AnswerDriver(asked: asked, answers: answers, caps: caps)
        Logger.shared.log("Answer session=\(session.sessionId.prefix(8)) host=\(host.label) questions=\(asked.questions.count)")
        let run = AnswerLoop.run(&driver, readScreen: read, send: { key in
            if let why = precheck() { return why }
            let why = io.sendKey(host, key)
            if why != nil { hostFailed = true }
            return why
        }, sleep: io.sleep, now: io.now)

        let sent = run.typed
        switch run.result {
        case .aborted(let why):
            Logger.shared.log("Answer session=\(session.sessionId.prefix(8)) stopped after \(sent) key(s)")
            // Nothing was typed: the question moved on, or the terminal itself refused the first key.
            if sent == 0 { return .refused(hostFailed ? .notTypable : .questionChanged, why) }
            return .failed(String("\(why). The question is part-filled at your Mac.".prefix(SessionCommandResult.maxDetail)))
        case .submitted:
            return confirm(asked: asked, answers: answers, session: session, host: host, io: io)
        }
    }

    /// Reads back what Claude received (`toolUseResult.answers`) and says so.
    static func confirm(asked: AskedQuestionSet, answers: [ResolvedAnswer], session: ClaudeLiveSession,
                        host: InjectionExecutor.TerminalHost, io: IO) -> SessionCommandResult {
        let expected = AnswerPlan.expectedAnswers(asked, answers)
        let n = asked.questions.count
        let where_ = host.label
        let deadline = io.now().addingTimeInterval(confirmWait)
        var last = AnswerReceipt.Outcome.notFound
        repeat {
            if let text = io.transcriptText(session) {
                last = AnswerReceipt.outcome(transcript: text, toolUseId: asked.toolUseId, expected: expected)
                if last != .notFound { break }
            }
            io.sleep(0.4)
        } while io.now() < deadline
        // One screen read can look "closed" by accident (blank, mid-redraw): the status is the second witness.
        let stillWaiting = last == .notFound
            && (io.currentRecord(session.pid).map { ClaudeSessionStatus(raw: $0.status) == .waiting } ?? false)
        switch last {
        case .matched:
            return SessionCommandResult(code: .delivered, reason: nil, detail: "Answered \(n) question\(n == 1 ? "" : "s") in \(where_)")
        case .different:
            return .failed("Sent, but Claude received different answers than you picked — check the transcript")
        case .rejected:
            return .failed("The question was dismissed at your Mac before the answers went in")
        case .notFound:
            // No transcript record, and the session still shows a question: the screen parse alone said "closed".
            if stillWaiting {
                return .failed("Sent the keys, but the question may still be open at your Mac — check it there")
            }
            return SessionCommandResult(code: .delivered, reason: nil,
                                        detail: "Answered \(n) question\(n == 1 ? "" : "s") in \(where_) (couldn't confirm what Claude received)")
        }
    }
}

// MARK: - Live wiring

extension AnswerDelivery {
    /// The real terminal, registry and transcript behind `IO`.
    static func liveIO(registry: ClaudeSessionRegistry) -> IO {
        func tail(_ s: ClaudeLiveSession) -> TranscriptTail? {
            registry.transcriptURL(forSessionId: s.sessionId, cwdHint: s.cwd).flatMap(InterventionDetector.readTranscriptTail)
        }
        return IO(
            resolve: { id in
                InjectionExecutor.resolveClaudeTarget(
                    InjectionExecutor.ClaudeReplyRequest(interventionId: "\(id)-answer", sessionId: id, action: nil, text: "", kind: .question,
                                                         pagePid: nil, pageStateStart: nil, pagePromptKey: nil, hookCreatedAt: nil),
                    registry: registry)
            },
            currentRecord: { pid in
                if let r = registry.currentRecord(forPid: pid) { return r }
                usleep(50_000)
                return registry.currentRecord(forPid: pid)
            },
            pendingTools: { tail($0)?.pendingToolUses },
            holdsSession: { HookHoldMarkers.heldSessions(in: HookHoldMarkers.defaultDirectory).contains($0) },
            squadPaused: { ClaudeSquad.isPausedLive(session: $0, host: $1) },
            resolveHost: { InjectionExecutor.resolveHost(for: $0, processTable: $1) },
            isForeground: { ProcessRunner.isForeground(pid: $0) },
            screenReader: { InjectionExecutor.answerScreenReader(for: $0) },
            sendKey: { host, key in InjectionExecutor.sendOneKey(key, to: host) },
            transcriptText: { s in
                registry.transcriptURL(forSessionId: s.sessionId, cwdHint: s.cwd)
                    .flatMap { InterventionDetector.readTail(of: $0, maxBytes: 512 * 1024)?.text }
            })
    }
}

extension InjectionExecutor {
    /// One key into the host's terminal, after the caller's own checks.
    /// nil on success, else the phone-safe reason. Terminal.app can't press single keys
    /// (`do script` adds a Return), so it never gets here: `AnswerDelivery.capabilities` refuses it first.
    static func sendOneKey(_ key: Keystroke, to host: TerminalHost) -> String? {
        let result: InjectionResult
        switch host {
        case .tmux(let tmux, let pane, let inMode, _):
            result = sendViaTmux([key], tmuxPath: tmux, paneId: pane, inMode: inMode, awaitClosed: { true })
        case .iTerm(let tty):
            result = sendViaITerm([key], tty: tty, awaitClosed: { true })
        case .wezterm(let target):
            result = sendViaControlCLI([key], method: .wezterm, label: target.label, awaitClosed: { true }) { key in
                WezTermBridge.sendArgs(paneId: target.paneId, key: key).map { WezTermBridge.run(target, $0.args, stdin: $0.stdin) }
            }
        case .kitty(let target):
            result = sendViaControlCLI([key], method: .kitty, label: target.label, awaitClosed: { true }) { key in
                KittyBridge.sendArgs(target: target, key: key).map { KittyBridge.run(target, $0.args, stdin: $0.stdin) }
            }
        case .herdr(let target):
            // Pane ids are reused: the same pane must still hold the same terminal, with the session in front.
            result = sendViaControlCLI([key], method: .herdr, label: target.label, awaitClosed: { true },
                                       precheck: { _ in HerdrBridge.recheck(target) }) { key in
                HerdrBridge.send(target, key: key)
            }
        case .cmux(let target):
            return sendOneKeyViaCmux(key, to: target)
        case .terminalApp, .unreachable, .unsupported, .unknown:
            return "Page can't press keys in \(host.label)"
        }
        return result.success ? nil : (result.detail.isEmpty ? "Couldn't type into \(host.label)" : result.detail)
    }
}
