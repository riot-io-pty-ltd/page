import Foundation

/// The outcome of a phone's `input` / `interrupt` (SESSIONS-PROTOCOL.md §4
/// `result`). `detail` is shown on the phone: short, human, never secrets
/// or terminal output.
struct SessionCommandResult: Equatable, Error {
    enum Code: String {
        case delivered, queued, refused, failed
    }

    enum Reason: String {
        case waiting
        case unknownState = "unknown_state"
        case notTypable = "not_typable"
        case draft
        case digitWhileBusy = "digit_while_busy"
        case ended
        case codexMidTurn = "codex_mid_turn"
        case disabled, stale, replay
        case notFound = "not_found"
        case interruptUnsupported = "interrupt_unsupported"
        /// The phone's room shows a different folder or title than this session has.
        case targetMismatch = "target_mismatch"
        /// An `answer` for a question that is no longer the one showing.
        case questionChanged = "question_changed"
        /// An `answer` Page won't press (previews, a host it can't read, a hook holds it).
        case answerUnsupported = "answer_unsupported"
        case error
    }

    static let maxDetail = 200

    let code: Code
    let reason: Reason?
    let detail: String
    /// The open page, when `reason == .waiting`.
    var interventionId: String? = nil

    static func refused(_ reason: Reason, _ detail: String, interventionId: String? = nil) -> SessionCommandResult {
        SessionCommandResult(code: .refused, reason: reason, detail: detail, interventionId: interventionId)
    }

    static func failed(_ detail: String) -> SessionCommandResult {
        SessionCommandResult(code: .failed, reason: .error, detail: detail)
    }

    /// The plaintext fields after `kind/boot/seq/ts`.
    func fields(clientId: String) -> [String: Any] {
        var o: [String: Any] = [
            "kind": "result",
            "clientId": clientId,
            "ok": code == .delivered || code == .queued,
            "code": code.rawValue,
            "detail": String(detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxDetail))
        ]
        if let reason { o["reason"] = reason.rawValue }
        if let interventionId, reason == .waiting { o["interventionId"] = interventionId }
        return o
    }
}

/// The Mac's input gate for text typed on the phone's Sessions screen
/// (SESSIONS-PROTOCOL.md §5 "Mac input gate"). It never weakens the rules
/// the inbox reply path follows: Claude text goes through the same
/// `deliverToLiveSession` as a reply (as a plain message into an idle or
/// busy session, never Esc, never a prompt answer, never a background
/// resume), with the input box required to read empty.
///
/// The decisions are pure and table-tested; `runClaudeInput` /
/// `runClaudeInterrupt` take their I/O as closures so the full sequence is
/// tested with fakes. Production runs them on the backend's own queue
/// (Claude `injectionQueue`, Codex `replyQueue`), so phone typing never
/// interleaves with a reply or a battery pause.
enum SessionInputGate {
    static let maxTextLength = 8000

    static let digitWhileBusyMessage = "Starts with a number: wait for Claude to finish, or add a word first"
    static let queuedMessage = "Queued — Claude reads it after the current step"
    static let codexQueuedMessage = "Queued — Codex reads it after the current step"
    static let codexMidTurnMessage = "Codex is mid-turn — Page can type once the turn ends"
    static let waitingMessage = "A prompt is waiting — answer it first"
    static let unknownStateMessage = "Page can't tell what this session is doing — type at the Mac"
    static let endedMessage = "The session has ended"
    static let notIdleMessage = "It isn't working right now"
    static let backgroundShellMessage = "Only a background command is running — Stop can't end that; stop it at the Mac"

    /// Trimmed text of 1–8000 characters, or why not.
    static func validateText(_ raw: String) -> Result<String, SessionCommandResult> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.refused(.error, "The message was empty")) }
        if trimmed.count > maxTextLength { return .failure(.refused(.error, "The message is too long (8000 characters at most)")) }
        return .success(trimmed)
    }

    /// The first non-space character is a digit: typed while Claude is busy
    /// and a menu opens first, it would pick a menu option.
    static func startsWithDigit(_ text: String) -> Bool {
        InjectionExecutor.sanitize(text).first(where: { !$0.isWhitespace })?.isNumber ?? false
    }

    // MARK: Claude

    enum ClaudeTargetState: Equatable {
        case live
        case ended
        case failed(String)
    }

    enum ClaudeStep: Equatable {
        /// Text + Enter: `queued` when Claude is busy (it reads it after the
        /// current step), else delivered.
        case deliver(queued: Bool)
        case refuse(SessionCommandResult)
    }

    /// Pure. `status` is the fresh sessions-file status (nil: unreadable);
    /// `interventionId` the session's open page, for a `waiting` refusal.
    static func claudePlan(target: ClaudeTargetState, status: ClaudeSessionStatus?, hasSessionFile: Bool,
                           host: InjectionExecutor.TerminalHost?, text: String, interventionId: String?,
                           squadPaused: Bool = false) -> ClaudeStep {
        switch target {
        case .ended: return .refuse(.refused(.ended, endedMessage))
        case .failed(let why): return .refuse(.refused(.notTypable, why))
        case .live: break
        }
        guard hasSessionFile, let status, status != .unknown else {
            return .refuse(.refused(.unknownState, unknownStateMessage))
        }
        if status == .waiting {
            return .refuse(.refused(.waiting, waitingMessage, interventionId: interventionId))
        }
        switch host {
        case .tmux?, .terminalApp?, .iTerm?, .cmux?, .wezterm?, .kitty?, .herdr?:
            break
        case .unsupported(let app)?:
            return .refuse(.refused(.notTypable, "Page can't type into \(app) yet"))
        case .unreachable(let why)?:
            return .refuse(.refused(.notTypable, why))
        case .unknown?, nil:
            return .refuse(.refused(.notTypable, "Couldn't find the session's terminal"))
        }
        if squadPaused { return .refuse(.refused(.notTypable, ClaudeSquad.pausedMessage)) }
        if status == .busy && startsWithDigit(text) {
            return .refuse(.refused(.digitWhileBusy, digitWhileBusyMessage))
        }
        return .deliver(queued: status == .busy)
    }

    /// Pure. Maps what `deliverToLiveSession` returned to a phone result.
    static func claudeResult(_ r: InjectionResult, queued: Bool, interventionId: String?) -> SessionCommandResult {
        if r.success {
            return queued
                ? SessionCommandResult(code: .queued, reason: nil, detail: queuedMessage)
                : SessionCommandResult(code: .delivered, reason: nil, detail: r.detail.isEmpty ? "Sent" : r.detail)
        }
        switch r.detail {
        case CmuxBridge.draftDetail, InjectionExecutor.inputUnverifiedMessage, CmuxBridge.noInputBoxDetail:
            return .refused(.draft, r.detail)
        case InjectionExecutor.newPageMessage, InjectionExecutor.closedPageMessage, CmuxBridge.dialogOpenDetail:
            return .refused(.waiting, r.detail, interventionId: interventionId)
        case digitWhileBusyMessage:
            return .refused(.digitWhileBusy, r.detail)
        case InjectionExecutor.notForegroundMessage:
            return .refused(.notTypable, r.detail)
        case InjectionExecutor.sessionExitedMessage:
            return .refused(.ended, r.detail)
        default:
            return .failed(r.detail.isEmpty ? "Couldn't type into the session" : r.detail)
        }
    }

    /// The synthetic request phone text is delivered with: a plain message
    /// (kind idle, closed-page semantics: never Esc, never a prompt answer,
    /// refused while a menu may be up), with the input box required empty
    /// and the digit rule checked again right before the text key.
    static func claudeRequest(sessionId: String, clientId: String, text: String) -> InjectionExecutor.ClaudeReplyRequest {
        InjectionExecutor.ClaudeReplyRequest(
            interventionId: "\(sessionId)-phone-\(clientId)", sessionId: sessionId,
            action: "custom", text: text, kind: .idle,
            pagePid: nil, pageStateStart: nil, pagePromptKey: nil, hookCreatedAt: nil,
            closedPage: true, requireEmptyInput: true, refuseDigitWhileBusy: true
        )
    }

    /// I/O for the Claude runners (the registry, ps, the terminal).
    struct ClaudeIO {
        var resolve: (InjectionExecutor.ClaudeReplyRequest) -> InjectionExecutor.ClaudeTarget
        var currentRecord: (Int32) -> ClaudeSessionRecord?
        var resolveHost: (ClaudeLiveSession, [ProcessRunner.ProcessInfoRow]) -> InjectionExecutor.TerminalHost
        var deliver: (InjectionExecutor.ClaudeReplyRequest, ClaudeLiveSession, [ProcessRunner.ProcessInfoRow]) -> InjectionResult
        var isForeground: (Int32) -> Bool?
        var sendInterrupt: (InjectionExecutor.TerminalHost) -> InjectionResult
        /// Whether the session is a paused Claude Squad instance (read fresh).
        var squadPaused: (ClaudeLiveSession, InjectionExecutor.TerminalHost) -> Bool = { _, _ in false }
    }

    /// Fresh lookup → gate → `deliverToLiveSession`. Blocking.
    static func runClaudeInput(sessionId: String, clientId: String, text raw: String,
                               interventionId: String?, io: ClaudeIO) -> SessionCommandResult {
        let text: String
        switch validateText(raw) {
        case .failure(let refusal): return refusal
        case .success(let t): text = t
        }
        let req = claudeRequest(sessionId: sessionId, clientId: clientId, text: text)
        let target = io.resolve(req)
        var session: ClaudeLiveSession?
        var table: [ProcessRunner.ProcessInfoRow] = []
        var state = ClaudeTargetState.ended
        switch target {
        case .live(let s, let t): session = s; table = t; state = .live
        case .ended: state = .ended
        case .failed(let f): state = .failed(f.detail)
        }
        // The status as of now, not the registry's tick-old value.
        let status = session.map { s in s.hasSessionFile ? io.currentRecord(s.pid).map { ClaudeSessionStatus(raw: $0.status) } : nil } ?? nil
        let host = session.flatMap { s -> InjectionExecutor.TerminalHost? in
            guard state == .live, s.hasSessionFile, let status, status != .unknown, status != .waiting else { return nil }
            return io.resolveHost(s, table)
        }
        let paused = session.flatMap { s in host.map { io.squadPaused(s, $0) } } ?? false
        let step = claudePlan(target: state, status: status, hasSessionFile: session?.hasSessionFile ?? false,
                              host: host, text: text, interventionId: interventionId, squadPaused: paused)
        switch step {
        case .refuse(let r):
            return r
        case .deliver(let queued):
            guard let session else { return .refused(.ended, endedMessage) }
            return claudeResult(io.deliver(req, session, table), queued: queued, interventionId: interventionId)
        }
    }

    /// Esc in a working session (`sendInterrupt`): only while it is busy
    /// (Esc on a menu would deny it), in the foreground of its terminal,
    /// in a host that can press a lone Esc.
    static func runClaudeInterrupt(sessionId: String, interventionId: String?, io: ClaudeIO) -> SessionCommandResult {
        let req = claudeRequest(sessionId: sessionId, clientId: "interrupt", text: "")
        let session: ClaudeLiveSession
        let table: [ProcessRunner.ProcessInfoRow]
        switch io.resolve(req) {
        case .ended: return .refused(.ended, endedMessage)
        case .failed(let f): return .refused(.interruptUnsupported, f.detail)
        case .live(let s, let t): session = s; table = t
        }
        guard session.hasSessionFile, let rec = io.currentRecord(session.pid) else {
            return .refused(.unknownState, unknownStateMessage)
        }
        switch ClaudeSessionStatus(raw: rec.status) {
        case .busy: break
        case .waiting: return .refused(.waiting, waitingMessage, interventionId: interventionId)
        case .idle: return .refused(.interruptUnsupported, notIdleMessage)
        // Esc at the prompt doesn't stop a background shell.
        case .shell: return .refused(.interruptUnsupported, backgroundShellMessage)
        case .unknown: return .refused(.unknownState, unknownStateMessage)
        }
        guard io.isForeground(session.pid) == true else {
            return .refused(.notTypable, InjectionExecutor.notForegroundMessage)
        }
        let host = io.resolveHost(session, table)
        if io.squadPaused(session, host) { return .refused(.interruptUnsupported, ClaudeSquad.pausedMessage) }
        guard host.canSendLoneEscape else {
            return .refused(.interruptUnsupported, "Page can't press Esc in \(host.label)")
        }
        // Re-read right before the key: a menu that opened since would be
        // denied by it, and a job brought to the front since would get it.
        guard let again = io.currentRecord(session.pid), ClaudeSessionStatus(raw: again.status) == .busy else {
            return .refused(.interruptUnsupported, notIdleMessage)
        }
        guard io.isForeground(session.pid) == true else {
            return .refused(.notTypable, InjectionExecutor.notForegroundMessage)
        }
        let r = io.sendInterrupt(host)
        if r.success { return SessionCommandResult(code: .delivered, reason: nil, detail: "Pressed Esc in \(host.label)") }
        if r.detail == "A prompt is open in that pane" {
            return .refused(.waiting, r.detail, interventionId: interventionId)
        }
        return .failed(r.detail.isEmpty ? "Couldn't press Esc" : r.detail)
    }

    // MARK: Codex

    enum CodexStep: Equatable {
        /// The turn is over: type with the composer verified empty.
        case deliverIdle
        /// Mid-turn in a cmux pane: paste, which cmux only does into an
        /// empty composer (the battery `PauseStrategy.queue` path).
        case queueMidTurn
        case refuse(SessionCommandResult)
    }

    /// Pure. `terminal` is where the thread's codex runs (nil: no
    /// terminal Page can reach — `targetProblem` says why).
    static func codexPlan(phase: CodexRollout.Summary.Phase, hasPendingRequest: Bool, execResumeRunning: Bool,
                          terminal: CodexInjector.Terminal?, targetProblem: SessionCommandResult?,
                          interventionId: String?) -> CodexStep {
        if execResumeRunning {
            return .refuse(.refused(.notTypable, "A background Codex resume is running for this session — try once it finishes"))
        }
        if hasPendingRequest {
            return .refuse(.refused(.waiting, codexWaitingMessage, interventionId: interventionId))
        }
        switch phase {
        case .unknown:
            return .refuse(.refused(.unknownState, "Couldn't confirm Codex is waiting for input — type at the Mac"))
        case .inTurn:
            guard case .cmux? = terminal else { return .refuse(.refused(.codexMidTurn, codexMidTurnMessage)) }
            return .queueMidTurn
        case .completed, .aborted:
            guard let terminal else { return .refuse(targetProblem ?? .refused(.notTypable, "Couldn't find the Codex session's terminal")) }
            switch terminal {
            case .tmux, .cmux:
                return .deliverIdle
            case .terminalApp:
                return .refuse(.refused(.notTypable, codexTerminalAppBlocker))
            case .unavailable(let why):
                return .refuse(.refused(.notTypable, why))
            }
        }
    }

    static let codexWaitingMessage = "Codex is waiting on a prompt — answer it on the Mac"
    static let codexChangedMessage = "Codex's state changed while Page was checking — try again"

    /// Pure. The rollout read again right before the keys: the plan's read
    /// came before ps, lsof and the terminal lookups, and an approval
    /// overlay that opened since would take the text as hotkeys or be
    /// denied by Esc. nil: still as planned. `interrupt` is the Stop
    /// button (planned mid-turn); otherwise text, planned on `planned`.
    static func codexRecheck(planned: CodexRollout.Summary.Phase, now: CodexRollout.Summary, interrupt: Bool,
                             interventionId: String?) -> SessionCommandResult? {
        if now.pendingRequest != nil {
            return .refused(.waiting, codexWaitingMessage, interventionId: interventionId)
        }
        if interrupt {
            return now.phase == .inTurn ? nil : .refused(.interruptUnsupported, notIdleMessage)
        }
        switch (planned, now.phase) {
        case (.completed, .completed), (.completed, .aborted), (.aborted, .completed), (.aborted, .aborted),
             (.inTurn, .inTurn):
            return nil
        case (_, .inTurn):
            return .refused(.codexMidTurn, codexMidTurnMessage)
        default:
            return .refused(.unknownState, codexChangedMessage)
        }
    }

    static let codexTerminalAppBlocker = "Page can't check Codex's input box in Terminal.app — use tmux or cmux"

    /// Pure. Why a resolved target can't be typed into, as a result.
    static func codexTargetProblem(_ target: CodexInjector.Target, project: String) -> SessionCommandResult? {
        switch target {
        case .tty: return nil
        case .none: return .refused(.ended, "Codex isn't open in \(project) any more")
        case .ambiguous(let n): return .refused(.notTypable, "\(n) Codex sessions are open in \(project) — type at the Mac")
        case .noTerminal: return .refused(.notTypable, "Codex is running in \(project) without a terminal Page can type into")
        case .unconfirmed: return .refused(.notTypable, "Codex is open in \(project), but Page can't tell if it's this session")
        }
    }

    /// Pure. Maps a Codex delivery to a phone result.
    static func codexResult(_ outcome: CodexDeliveryOutcome, queued: Bool, interventionId: String?) -> SessionCommandResult {
        if outcome.success {
            return queued
                ? SessionCommandResult(code: .queued, reason: nil, detail: codexQueuedMessage)
                : SessionCommandResult(code: .delivered, reason: nil, detail: outcome.detail.isEmpty ? "Sent" : outcome.detail)
        }
        switch outcome.detail {
        case CmuxBridge.draftDetail, CodexInjector.composerUnverifiedDetail, CodexInjector.terminalComposerUnverifiedDetail:
            return .refused(.draft, outcome.detail)
        case CmuxBridge.dialogOpenDetail:
            return .refused(.waiting, outcome.detail, interventionId: interventionId)
        case CmuxBridge.noInputBoxDetail:
            return .refused(queued ? .codexMidTurn : .draft, outcome.detail)
        case CodexInjector.notForegroundDetail:
            return .refused(.notTypable, outcome.detail)
        default:
            return .failed(outcome.detail.isEmpty ? "Couldn't type into Codex" : outcome.detail)
        }
    }
}
