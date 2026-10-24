import Foundation

/// How a reply reached the agent. Raw values go on the wire (`reply.injected.method`).
enum InjectionMethod: String {
    case tmux
    case terminalAppleScript = "terminal_applescript"
    case iTermAppleScript = "iterm_applescript"
    /// Typed through cmux's CLI (paste / send-key), gated on its input state.
    case cmux
    /// Answered through cmux's Feed (the request its PermissionRequest hook holds).
    case cmuxFeed = "cmux_feed"
    case headlessResume = "claude_resume_print"
    /// Nothing was typed (refused, or no target found).
    case none
}

struct InjectionResult {
    let method: InjectionMethod
    let success: Bool
    /// Diagnostic text for the Mac log / Worker log. Never shown on the phone.
    let output: String
    /// Short, human, phone-safe outcome ("Approved in tmux pane %3").
    var detail: String = ""
}

/// The kind of page a reply answers, collapsed to what matters for keystrokes.
enum ReplyPromptKind: Equatable {
    /// Permission / plan approval: a Yes/No select menu.
    case approval
    /// AskUserQuestion: a select menu of answers.
    case question
    /// Turn finished; the input box is waiting.
    case idle
    /// Anything else (rate limit, unknown).
    case other

    /// Maps a wire / stored kind. nil when the kind is absent.
    static func from(wireKind: String?) -> ReplyPromptKind? {
        switch wireKind {
        case nil: return nil
        case "permission", "plan", "approval": return .approval
        case "question", "user_input": return .question
        case "idle": return .idle
        default: return .other
        }
    }

    var isPrompt: Bool { self == .approval || self == .question }
}

/// One step of a reply, independent of the terminal it's typed into.
enum Keystroke: Equatable {
    /// Literal text; may contain "\n" (sent as one bracketed paste in tmux).
    case text(String)
    case enter
    /// Dismisses the on-screen select menu (= deny / cancel).
    case escape
    case pause(TimeInterval)
    /// Wait until the dismissed menu is gone — the sessions file has left
    /// "waiting" (any new "waiting" state counts as another menu, not as
    /// closed), or, for sessions without a status, the menu has left the
    /// screen — and abort the rest of the plan if it doesn't. Together
    /// with the status re-check before every later key, this keeps an
    /// Enter off an open menu (Enter there accepts "Yes"); it can't rule
    /// out a menu that opens after the last check, because the sessions
    /// file lags the screen slightly.
    case awaitPromptClosed
}

enum KeystrokePlan: Equatable {
    case send([Keystroke], summary: String)
    case refuse(String)
}

/// Delivers a phone reply into a live Claude Code session.
///
/// Target resolution is exact or it fails: sessionId → live pid (sessions
/// file, else argv) → that pid's tty → the tmux pane with that tty, else the
/// host app found by walking the pid's ancestors (Terminal.app, iTerm2).
/// There is no "any claude process" fallback: typing into the wrong session
/// is worse than reporting failure. Keystrokes depend on the session's live
/// status (see `plan`). Right before every key, the sessions file is read
/// again (a menu that opened since aborts the reply) and the process must
/// still own its terminal (not suspended with ^Z or behind another job,
/// which would receive the keys instead).
///
/// All entry points block; callers run them on the backend's serial
/// injection queue (never on the main thread — AppleScript hops to main).
enum InjectionExecutor {

    // MARK: keystroke plan (pure, unit-tested)

    static let newPageMessage = "Session is now waiting for approval — open the new page"
    static let promptGoneMessage = "The prompt is no longer showing"
    static let staleMessage = "That prompt was already answered — a newer one is waiting"
    static let emptyReplyMessage = "The reply was empty"
    static let notForegroundMessage = "The session is suspended or in the background — reply at the Mac"
    static let unverifiedPromptMessage = "Can't confirm which prompt is showing — answer it at the Mac"
    static let closedPageMessage = "That page already closed — answer at the Mac, or wait for the next page"
    static let inputUnverifiedMessage = "Couldn't confirm the session's input box is empty — carry on at the Mac"
    static let backgroundJobMessage = "This session is running as a Claude Code background job — reply at the Mac"
    static let sessionExitedMessage = "The session exited"

    /// What to type for `action` given the session's live `status` and the
    /// kind of page being answered. Encodes the verified Claude Code
    /// behaviour: in a select menu "1" approves, Esc denies, letters are
    /// ignored and Enter accepts the highlighted option — so a plan never
    /// sends Enter while a menu may still be open.
    static func plan(action rawAction: String?, kind: ReplyPromptKind, status: ClaudeSessionStatus, text: String) -> KeystrokePlan {
        let clean = sanitize(text)
        let action: String
        switch rawAction {
        case "approve", "deny", "carry_on", "custom": action = rawAction!
        // No action and no text is what old phones send for a plain banner
        // tap. It must never turn into "carry on".
        case nil, "": action = "custom"
        default: action = "custom"
        }
        if action == "custom" && clean.isEmpty { return .refuse(emptyReplyMessage) }
        let message = clean.isEmpty ? (phrase(for: action) ?? "carry on") : clean

        // A select menu is (or may be) on screen. With no status (older
        // Claude Code) deliverToLiveSession only gets here after checking
        // the page's prompt is the one pending and a menu is on screen.
        func promptPlan() -> KeystrokePlan {
            switch action {
            case "approve":
                switch kind {
                case .approval: return .send([.text("1")], summary: "Approved")
                case .question: return .refuse("This is a question — reply with your answer instead")
                default: return .refuse(newPageMessage)
                }
            case "deny":
                return kind.isPrompt ? .send([.escape], summary: "Denied") : .refuse(newPageMessage)
            case "carry_on":
                return .refuse(kind.isPrompt ? "This page needs approve, deny or a written reply" : newPageMessage)
            default:
                guard kind.isPrompt else { return .refuse(newPageMessage) }
                // Esc dismisses the menu and focuses an empty input box; the
                // text then goes to Claude as the next message — only once
                // the menu is verifiably gone, never after a blind pause.
                return .send([.escape, .awaitPromptClosed, .text(clean), .enter], summary: "Denied and sent your reply")
            }
        }

        switch status {
        case .waiting:
            return promptPlan()
        case .unknown:
            // No status (older Claude Code): prompt pages get prompt
            // keystrokes (deliverToLiveSession verifies the prompt first);
            // everything else is typed as a message.
            if kind.isPrompt { return promptPlan() }
            return .send([.text(message), .enter], summary: "Sent your reply")
        case .idle:
            // Approve/Deny on a prompt page with the session idle: the prompt
            // was answered (at the Mac, or by an earlier reply) before this
            // arrived. Typing "yes, proceed" as a chat message would be read
            // as a fresh instruction — refuse, as for busy. (Free text is
            // still a message; approve on a real idle page is the phrase.)
            if kind.isPrompt && (action == "approve" || action == "deny") { return .refuse(promptGoneMessage) }
            return .send([.text(message), .enter], summary: "Sent your reply")
        case .busy:
            if action == "approve" || action == "deny" { return .refuse(promptGoneMessage) }
            // Claude queues a message typed during a turn. Never Esc here:
            // it would interrupt the running turn.
            return .send([.text(message), .enter], summary: "Queued your reply")
        }
    }

    /// Text sent for a quick action when the session wants a typed message.
    static func phrase(for action: String?) -> String? {
        switch action {
        case "approve": return "yes, proceed"
        case "deny": return "no, stop"
        case "carry_on": return "carry on"
        default: return nil
        }
    }

    static let maxReplyLength = 8000

    /// Makes phone text safe to type into the TUI: drops control characters
    /// (ESC, ^C, ^U … would act as keys) except newlines (tabs become
    /// spaces — Tab would trigger completion), trims, caps the
    /// length, and prefixes a space to a leading "!" — otherwise Claude Code
    /// enters bash mode and runs the reply as a shell command with no
    /// permission check.
    static func sanitize(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var scalars = String.UnicodeScalarView()
        for s in normalized.unicodeScalars {
            switch s.value {
            case 0x0A: scalars.append(s)
            case 0x09: scalars.append(" ")
            case 0x2028, 0x2029: scalars.append("\n")
            case 0x00...0x1F, 0x7F...0x9F: continue
            default: scalars.append(s)
            }
        }
        var s = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > maxReplyLength { s = String(s.prefix(maxReplyLength)) }
        // Scalar, not Character: "!" + a combining mark is one grapheme
        // cluster, so hasPrefix("!") misses it — but the terminal still
        // receives "!" as the first byte and Claude enters bash mode.
        if s.unicodeScalars.first == "!" { s = " " + s }
        return s
    }

    /// Refusal reason when a reply would act on a different prompt than the
    /// one the user saw. Only meaningful while a menu is on screen.
    ///  - Detector pages carry the state start (`statusUpdatedAt`) and the
    ///    tool_use id of the prompt; both must still match.
    ///  - Notification-hook pages carry their creation time (whole seconds)
    ///    and, from hooks that know it, the prompt's tool_use id. With both
    ///    ids known they decide; otherwise the current waiting state must
    ///    have begun no later than 2s after the hook fired (the hook fires
    ///    once the menu is up; 2s covers the epoch's rounding).
    ///    Only statuses Page can read reach here: sessions without a status
    ///    are checked separately (see deliverToLiveSession).
    static func staleReason(status: ClaudeSessionStatus,
                            statusUpdatedAt: Date?,
                            pageStateStart: Date?,
                            pagePromptKey: String?,
                            currentPromptKey: String?,
                            hookCreatedAt: Date?) -> String? {
        guard status == .waiting, let current = statusUpdatedAt else { return nil }
        if let pageStart = pageStateStart {
            if abs(current.timeIntervalSince(pageStart)) > 1 { return staleMessage }
            if let pk = pagePromptKey, let ck = currentPromptKey, pk != ck { return staleMessage }
            return nil
        }
        if let hook = hookCreatedAt {
            if let pk = pagePromptKey, let ck = currentPromptKey { return pk == ck ? nil : staleMessage }
            if current.timeIntervalSince(hook) > hookSlack { return staleMessage }
        }
        return nil
    }

    /// How long after a notification hook's (whole-second) epoch the
    /// waiting state it paged may have begun.
    static let hookSlack: TimeInterval = 2

    /// Whether `action` would act on an open menu (and so needs the
    /// staleness check).
    static func actsOnPrompt(action: String?, kind: ReplyPromptKind) -> Bool {
        switch action {
        case "approve", "deny": return true
        case "carry_on": return false
        default: return kind.isPrompt
        }
    }

    // MARK: target selection (pure, unit-tested)

    /// Picks the process to type into among the live processes hosting a
    /// session. Exact matches first (the pid or state the page was raised
    /// for); otherwise only an unambiguous terminal-attached process.
    static func pickSession(_ candidates: [ClaudeLiveSession],
                            pagePid: Int32?,
                            pageStateStart: Date?) -> Result<ClaudeLiveSession, InjectionFailure> {
        if let pagePid, let s = candidates.first(where: { $0.pid == pagePid }) { return .success(s) }
        if let start = pageStateStart,
           let s = candidates.first(where: { c in c.statusUpdatedAt.map { abs($0.timeIntervalSince(start)) <= 1 } ?? false }) {
            return .success(s)
        }
        let withTTY = candidates.filter { $0.tty != nil }
        if withTTY.count == 1 { return .success(withTTY[0]) }
        if withTTY.count > 1 {
            return .failure(InjectionFailure("Session is open in more than one terminal — reply at the Mac"))
        }
        if candidates.count == 1 { return .success(candidates[0]) }
        return .failure(InjectionFailure("Couldn't find the session's terminal"))
    }

    struct InjectionFailure: Error, Equatable {
        let detail: String
        init(_ detail: String) { self.detail = detail }
    }

    // MARK: Claude reply entry points

    /// Everything known about the page a reply answers. Built by
    /// ClaudeBackend from its own records — the relay payload's cwd is never
    /// used, and its sessionId only for hook pages.
    struct ClaudeReplyRequest {
        let interventionId: String
        let sessionId: String
        let action: String?
        let text: String
        let kind: ReplyPromptKind?
        let pagePid: Int32?
        let pageStateStart: Date?
        let pagePromptKey: String?
        let hookCreatedAt: Date?
        /// The Worker forwarded this text to a page that had already
        /// closed (`RelayReply.closed`): it is only ever typed as a plain
        /// message into an idle or busy session — never Esc, never a
        /// prompt answer.
        var closedPage: Bool = false
        /// Automatic typing with the user possibly at the Mac (battery
        /// resume): the input box must be verified empty, not just "no
        /// draft seen", before text + Enter is sent.
        var requireEmptyInput: Bool = false
        /// Text typed on the phone's Sessions screen: refused, right before
        /// the text key, if it starts with a digit and Claude has turned
        /// busy since the gate looked (a menu opening first would take the
        /// digit as an answer).
        var refuseDigitWhileBusy: Bool = false
    }

    enum ClaudeTarget {
        case live(ClaudeLiveSession, [ProcessRunner.ProcessInfoRow])
        /// No live process hosts the session.
        case ended
        case failed(InjectionFailure)
    }

    /// Fresh (not tick-cached) lookup of where a reply should go.
    static func resolveClaudeTarget(_ req: ClaudeReplyRequest, registry: ClaudeSessionRegistry) -> ClaudeTarget {
        guard ClaudeSessionRegistry.isValidSessionId(req.sessionId) else {
            return .failed(InjectionFailure("Couldn't identify the session"))
        }
        let table = ProcessRunner.processTable()
        // Without a process table "no live process" can't be told apart
        // from "ps failed" — and `.ended` may start a background resume.
        guard !table.isEmpty else { return .failed(InjectionFailure("Couldn't check whether the session is still running")) }
        let candidates = registry.liveSessions(forSessionId: req.sessionId, processTable: table)
        if candidates.isEmpty {
            // A live background job (sessions file kind "bg" / "daemon")
            // owns it: nothing to type into, and `.ended` would start a
            // second writer on the conversation.
            if !registry.liveBackgroundOwnerPids(forSessionId: req.sessionId, processTable: table).isEmpty {
                return .failed(InjectionFailure(backgroundJobMessage))
            }
            return .ended
        }
        switch pickSession(candidates, pagePid: req.pagePid, pageStateStart: req.pageStateStart) {
        case .success(let s): return .live(s, table)
        case .failure(let f): return .failed(f)
        }
    }

    /// Types a reply into a live session. Re-checks staleness against the
    /// status read moments ago, plans keystrokes, resolves the terminal and
    /// sends them — re-reading the status and the process's hold on its
    /// terminal before every key — and confirms via the sessions file that a
    /// prompt actually closed when that's the point of the reply.
    static func deliverToLiveSession(_ req: ClaudeReplyRequest,
                                     session: ClaudeLiveSession,
                                     processTable: [ProcessRunner.ProcessInfoRow],
                                     registry: ClaudeSessionRegistry) -> InjectionResult {
        // Current prompt, from the transcript: needed while a menu is up
        // (staleness), and whenever there's no status — then the
        // transcript is the only view of which prompt might be on screen.
        var currentPromptKey: String?
        var currentPromptKind: ReplyPromptKind?
        var pendingToolCount = 0
        let transcript = registry.transcriptURL(forSessionId: session.sessionId, cwdHint: session.cwd)
        if session.status == .waiting || session.status == .unknown,
           let transcript, let tail = InterventionDetector.readTranscriptTail(transcript) {
            pendingToolCount = tail.pendingToolUses.count
            if let primary = tail.pendingToolUses.first {
                currentPromptKey = primary.id
                currentPromptKind = primary.name == "AskUserQuestion" ? .question : .approval
            }
        }
        var kind = req.kind ?? currentPromptKind ?? (session.status == .waiting ? .approval : .other)

        // Text the Worker forwarded to an already-closed page: a plain
        // message into an idle or busy session, nothing else. With a menu
        // up (or no status to rule one out) it would answer a prompt the
        // user never saw.
        if req.closedPage {
            switch session.status {
            case .waiting, .unknown:
                return refused(closedPageMessage)
            case .idle, .busy:
                if req.action == "approve" || req.action == "deny" { return refused(promptGoneMessage) }
                kind = .idle
            }
        }
        let promptAction = actsOnPrompt(action: req.action, kind: kind)

        if promptAction,
           let reason = staleReason(status: session.status,
                                    statusUpdatedAt: session.statusUpdatedAt,
                                    pageStateStart: req.pageStateStart,
                                    pagePromptKey: req.pagePromptKey,
                                    currentPromptKey: currentPromptKey,
                                    hookCreatedAt: req.hookCreatedAt) {
            return refused(reason)
        }

        // No status (older Claude Code, or a status Page doesn't know): a
        // quiet long-running tool looks just like a menu, so act on a
        // prompt only when it's provably the page's own approval prompt
        // (its tool_use is the one pending, alone) — and, below, only
        // while a menu is actually on screen.
        if promptAction && session.status == .unknown {
            guard kind == .approval else { return refused("Answer this one at the Mac — Page can't see which question is showing") }
            guard let pk = req.pagePromptKey, let ck = currentPromptKey, pk == ck else { return refused(unverifiedPromptMessage) }
            if pendingToolCount > 1 { return refused("Several prompts are queued — answer at the Mac") }
        }

        // While Page's blocking PermissionRequest hook holds this session's
        // request, Claude's own dialog may not be on screen yet: "1" would
        // land in the input box and Esc would interrupt the turn. The hook's
        // own page is the one to answer.
        if promptAction,
           HookHoldMarkers.heldSessions(in: HookHoldMarkers.defaultDirectory).contains(session.sessionId) {
            return refused("Page's phone-approval hook is handling this prompt — answer that page instead")
        }

        let planned = plan(action: req.action, kind: kind, status: session.status, text: req.text)
        guard session.tty != nil else {
            if case .refuse(let reason) = planned { return refused(reason) }
            return InjectionResult(method: .none, success: false, output: "pid \(session.pid) has no tty",
                                   detail: "This session isn't running in a terminal Page can type into")
        }
        let promptWasOpen = session.status == .waiting
        // After "1" / Esc alone: did the menu go? Any change of state
        // counts (the answer landed even if the next menu replaced it).
        let confirmClosed: () -> Bool = {
            guard promptWasOpen else { return true }
            return waitForPromptToClose(pid: session.pid, openSince: session.statusUpdatedAt, registry: registry,
                                        transcript: transcript, promptKey: currentPromptKey)
        }

        // The host is resolved before honouring a refusal from `plan`: in
        // cmux, a prompt held by its Feed hook isn't on screen (the sessions
        // file may not say "waiting"), and is answered through Feed instead.
        let host = resolveHost(for: session, processTable: processTable)
        var cmuxClient: CmuxBridge.Client?
        if case .cmux(let target) = host {
            switch CmuxBridge.connect(cliPath: target.cliPath) {
            case .failure(let f):
                return InjectionResult(method: .cmux, success: false, output: f.output, detail: f.detail)
            case .success(let client):
                cmuxClient = client
                if !req.closedPage,
                   let answered = answerViaCmuxFeed(req, session: session, kind: kind, client: client,
                                                    surface: target.surfaceId, confirmClosed: confirmClosed) { return answered }
            }
        }

        let steps: [Keystroke]
        let summary: String
        switch planned {
        case .refuse(let reason): return refused(reason)
        case .send(let s, let sum): steps = s; summary = sum
        }

        switch host {
        case .tmux, .terminalApp, .iTerm, .cmux:
            // Suspended with ^Z, or behind another job (a shell, an editor,
            // a second agent): the keys would go to that job instead.
            if ProcessRunner.isForeground(pid: session.pid) != true { return refused(notForegroundMessage) }
        case .unreachable, .unsupported, .unknown:
            break
        }
        let screen = screenReader(for: host)

        // No status: the menu must be on screen before "1" / Esc (cmux
        // checks its own dialog state before every menu key).
        if promptAction && session.status == .unknown, let screen {
            guard let text = screen(), denyOptionDigit(screen: text) != nil else { return refused(promptGoneMessage) }
        }

        // A message (text + Enter, no menu involved) must not be appended
        // to something the user half-typed. cmux checks its own input row.
        let typesMessage = steps.last == .enter && !steps.contains(.escape)
        if typesMessage, let why = draftRefusal(host: host, requireEmpty: req.requireEmptyInput) {
            return refused(why)
        }

        // `.awaitPromptClosed`: strictly "the menu is gone", never "a new
        // menu replaced it".
        let gate = GateState()
        let awaitGate: () -> Bool = {
            let ok: Bool
            if promptWasOpen {
                ok = waitForPromptDismissed(pid: session.pid, openSince: session.statusUpdatedAt, registry: registry,
                                            transcript: transcript, promptKey: currentPromptKey)
            } else if session.status == .unknown, let screen {
                ok = waitForMenuToLeaveScreen(screen)
            } else {
                // cmux (no status): its text step waits for the dialog to
                // clear and only pastes into an empty prompt.
                ok = true
            }
            if ok { gate.passed = true }
            return ok
        }
        // Before every key: still in front of its terminal, and the status
        // is what the plan assumed — menu keys only into the menu the plan
        // was made for, message keys never into a menu.
        let precheck: (Keystroke) -> String? = { key in
            guard ProcessRunner.isForeground(pid: session.pid) == true else { return notForegroundMessage }
            guard session.hasSessionFile else { return nil }
            guard let rec = currentRecordRetrying(registry, pid: session.pid) else { return sessionExitedMessage }
            let now = ClaudeSessionStatus(raw: rec.status)
            if promptWasOpen && !gate.passed {
                guard now == .waiting else { return promptGoneMessage }
                if let planned = session.statusUpdatedAt, let current = rec.statusUpdatedAt,
                   abs(current.timeIntervalSince(planned)) > 0.5 {
                    return staleMessage
                }
            } else if now == .waiting {
                return newPageMessage
            }
            return digitWhileBusyRefusal(key: key, status: now, enabled: req.refuseDigitWhileBusy)
        }
        Logger.shared.log("Injection.claude session=\(session.sessionId.prefix(8)) pid=\(session.pid) status=\(session.status.rawValue) host=\(host.label) plan=\(steps.count) step(s)")

        var result: InjectionResult
        switch host {
        case .tmux(let tmux, let pane, let inMode):
            result = sendViaTmux(steps, tmuxPath: tmux, paneId: pane, inMode: inMode, awaitClosed: awaitGate, precheck: precheck)
        case .terminalApp(let tty):
            // Terminal's "1" carries a Return. With more tool calls queued,
            // that Return could land on the next menu and accept it unseen.
            if steps == [.text("1")] && pendingToolCount > 1 {
                return refused("Several prompts are queued — approve at the Mac, or use tmux or iTerm2")
            }
            result = sendViaTerminalApp(steps, tty: tty, awaitClosed: awaitGate, precheck: precheck)
        case .iTerm(let tty):
            result = sendViaITerm(steps, tty: tty, awaitClosed: awaitGate, precheck: precheck)
        case .cmux(let target):
            guard let client = cmuxClient else { return refused(CmuxBridge.blockedDetail) }
            result = sendViaCmux(steps, client: client, surface: target.surfaceId, awaitClosed: awaitGate, precheck: precheck)
        case .unreachable(let detail):
            return InjectionResult(method: .none, success: false, output: "host unreachable: \(detail)", detail: detail)
        case .unsupported(let app):
            return InjectionResult(method: .none, success: false, output: "host=\(app)",
                                   detail: "Page can't type into \(app) yet — use tmux or Terminal.app")
        case .unknown:
            return InjectionResult(method: .none, success: false, output: "no host for tty \(session.tty ?? "?")",
                                   detail: "Couldn't find the session's terminal")
        }
        guard result.success else { return result }

        // "1" / Esc alone: confirm the menu really closed, so the phone
        // doesn't show "delivered" for a keystroke the TUI swallowed.
        if promptWasOpen, steps == [.text("1")] || steps == [.escape], !confirmClosed() {
            return InjectionResult(method: result.method, success: false,
                                   output: result.output + " (status still waiting)",
                                   detail: "Sent, but the prompt is still showing — answer it at the Mac")
        }
        let verb: String
        switch summary {
        case "Approved", "Denied": verb = "\(summary) in"
        case "Queued your reply": verb = "Queued your reply in"
        case "Denied and sent your reply": verb = "Denied and sent your reply in"
        default: verb = "Typed into"
        }
        result.detail = "\(verb) \(host.label)"
        return result
    }

    /// Whether the `.awaitPromptClosed` gate of one delivery has passed.
    private final class GateState { var passed = false }

    private static func refused(_ reason: String) -> InjectionResult {
        InjectionResult(method: .none, success: false, output: "refused: \(reason)", detail: reason)
    }

    /// A sessions-file read that tolerates landing mid-rewrite (one retry).
    private static func currentRecordRetrying(_ registry: ClaudeSessionRegistry, pid: Int32) -> ClaudeSessionRecord? {
        if let rec = registry.currentRecord(forPid: pid) { return rec }
        usleep(50_000)
        return registry.currentRecord(forPid: pid)
    }

    /// Polls until the pid leaves the waiting state it was in: the sessions
    /// file shows another status or a new state (e.g. the next prompt), or
    /// the transcript shows the prompt's tool call answered with nothing
    /// else pending (Esc and "1" both write a result). If other calls are
    /// still pending, another menu may be up, so only the status counts.
    /// Loose on purpose — it confirms that "1" / Esc landed; it is NOT the
    /// gate before typing text (see `waitForPromptDismissed`).
    static func waitForPromptToClose(pid: Int32, openSince: Date?, registry: ClaudeSessionRegistry,
                                     transcript: URL? = nil, promptKey: String? = nil,
                                     timeout: TimeInterval = 2.5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var polls = 0
        repeat {
            guard let rec = registry.currentRecord(forPid: pid) else { return true }  // process exited
            if ClaudeSessionStatus(raw: rec.status) != .waiting { return true }
            if let since = openSince, let now = rec.statusUpdatedAt, abs(now.timeIntervalSince(since)) > 0.5 { return true }
            // The transcript tail is a bigger read; check it every 0.5s.
            if polls % 5 == 4, promptKey != nil, let transcript,
               let tail = InterventionDetector.readTranscriptTail(transcript),
               tail.pendingToolUses.isEmpty {
                return true
            }
            polls += 1
            usleep(100_000)
        } while Date() < deadline
        return false
    }

    /// The gate before typing text after Esc dismissed a menu. True only
    /// once the sessions file reads idle or busy — and, when the prompt's
    /// tool_use id is known, the transcript no longer lists it as pending.
    /// A *new* waiting state means another menu replaced the dismissed one:
    /// false at once (Enter would accept it). An exited process is false
    /// too (the text would go to the shell).
    static func waitForPromptDismissed(pid: Int32, openSince: Date?, registry: ClaudeSessionRegistry,
                                       transcript: URL? = nil, promptKey: String? = nil,
                                       timeout: TimeInterval = 4) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let rec = registry.currentRecord(forPid: pid) {
                switch ClaudeSessionStatus(raw: rec.status) {
                case .waiting:
                    if let since = openSince, let now = rec.statusUpdatedAt, abs(now.timeIntervalSince(since)) > 0.5 {
                        return false
                    }
                case .idle, .busy:
                    guard let promptKey, let transcript else { return true }
                    if let tail = InterventionDetector.readTranscriptTail(transcript),
                       !tail.pendingToolUses.contains(where: { $0.id == promptKey }) {
                        return true
                    }
                case .unknown:
                    break   // can't tell; keep waiting
                }
            } else if !ProcessRunner.isAlive(pid) {
                return false
            }
            usleep(100_000)
        } while Date() < deadline
        return false
    }

    /// The gate for sessions without a status: polls the screen until no
    /// approval menu ("1. Yes …") is left among its last lines.
    static func waitForMenuToLeaveScreen(_ screen: () -> String?, timeout: TimeInterval = 2.5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let text = screen(), !approvalMenuLingers(screen: text) { return true }
            usleep(150_000)
        } while Date() < deadline
        return false
    }

    // MARK: reading the screen

    /// Lines of `screen` as the menu parsers see them: frame and cursor
    /// glyphs trimmed, blanks dropped, the last 30 kept.
    private static func menuLines(_ screen: String) -> ArraySlice<String> {
        let frame = CharacterSet(charactersIn: "│┃|║ \t❯›>▶▸*").union(.whitespaces)
        return screen.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: frame) }
            .filter { !$0.isEmpty }
            .suffix(30)
    }

    /// Any "1. Yes…" option line still among the screen's last lines.
    /// Looser than `denyOptionDigit` on purpose: used to decide a menu is
    /// *gone*, so anything resembling one counts as still there.
    static func approvalMenuLingers(screen: String) -> Bool {
        menuLines(screen).contains { $0.hasPrefix("1. Yes") }
    }

    /// Reads the visible screen of the session's terminal, for hosts where
    /// Page reads it itself (cmux reports its own input state instead).
    static func screenReader(for host: TerminalHost) -> (() -> String?)? {
        switch host {
        case .tmux(let tmux, let pane, _):
            return {
                let r = ProcessRunner.run(tmux, ["capture-pane", "-p", "-t", pane], timeout: 3)
                return r.succeeded ? r.stdout : nil
            }
        case .terminalApp(let tty):
            return {
                let r = runTerminalCommand(tty: tty, body: "return \"ok:\" & (contents of t)")
                return r.ok ? String(r.output.dropFirst(3)) : nil
            }
        case .iTerm(let tty):
            return { iTermContents(tty: tty) }
        case .cmux, .unreachable, .unsupported, .unknown:
            return nil
        }
    }

    /// Why a message must not be typed into the session's input box now:
    /// the user has text in it, or (`requireEmpty`) it couldn't be seen to
    /// be empty. tmux is read with colours, so Claude Code's dim / grey
    /// placeholder and suggestion text isn't mistaken for a draft;
    /// Terminal.app and iTerm2 only give plain text, so they're read only
    /// when emptiness must be proven (a suggestion there reads as "can't
    /// tell"). cmux checks its own input row when pasting.
    static func draftRefusal(host: TerminalHost, requireEmpty: Bool) -> String? {
        let row: ClaudeInputRow
        switch host {
        case .tmux(let tmux, let pane, _):
            let r = ProcessRunner.run(tmux, ["capture-pane", "-p", "-e", "-t", pane], timeout: 3)
            row = r.succeeded ? claudeInputRow(screen: r.stdout, styled: true) : .unknown
        case .terminalApp, .iTerm:
            guard requireEmpty else { return nil }
            row = screenReader(for: host)?().map { claudeInputRow(screen: $0, styled: false) } ?? .unknown
        case .cmux, .unreachable, .unsupported, .unknown:
            return nil
        }
        switch row {
        case .empty: return nil
        case .draft: return CmuxBridge.draftDetail
        case .unknown: return requireEmpty ? inputUnverifiedMessage : nil
        }
    }

    /// Claude Code's input box as read off the screen.
    enum ClaudeInputRow: Equatable {
        /// Found, with nothing typed in it.
        case empty
        /// Found, with text in it.
        case draft
        /// Not found (another mode, a menu, an unfamiliar layout).
        case unknown
    }

    /// Pure. Finds Claude Code's input box near the bottom of `screen` — a
    /// line starting with the prompt glyph (">" / "❯") right under a
    /// horizontal rule, with another rule below it — and says whether any
    /// text is typed in it. With `styled`, `screen` carries SGR escapes
    /// (`tmux capture-pane -e`) and dim / grey characters (placeholder or
    /// suggestion text, never what the user typed) are ignored. Anything
    /// that doesn't fit the shape is `.unknown`.
    static func claudeInputRow(screen: String, styled: Bool) -> ClaudeInputRow {
        let rows = screen.components(separatedBy: "\n").suffix(40).map { styled ? styledCells($0) : $0.map { ($0, false) } }
        let plain = rows.map { String($0.map(\.0)) }
        let frame = CharacterSet(charactersIn: "│┃║").union(.whitespaces)

        func isRule(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard t.count >= 8 else { return false }
            let ruleChars: Set<Character> = ["─", "━", "═", "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘", "│", " "]
            return t.allSatisfy { ruleChars.contains($0) } && t.filter({ $0 == "─" || $0 == "━" || $0 == "═" }).count >= 8
        }
        /// Offset of the first character after the prompt glyph, if `s` is a prompt line.
        func promptOffset(_ s: String) -> Int? {
            let chars = Array(s)
            var i = 0
            while i < chars.count, chars[i].unicodeScalars.allSatisfy({ frame.contains($0) }) { i += 1 }
            guard i < chars.count, chars[i] == ">" || chars[i] == "❯" else { return nil }
            let next = i + 1
            guard next == chars.count || chars[next] == " " || chars[next] == "\u{00A0}" else { return nil }
            return next
        }
        /// Typed (non-placeholder) characters of `cells` from `from` on, frame trimmed.
        func typed(_ cells: [(Character, Bool)], from: Int) -> String {
            let s = String(cells.dropFirst(from).filter { !$0.1 }.map(\.0))
            return s.trimmingCharacters(in: frame.union(CharacterSet(charactersIn: "\u{00A0}")))
        }

        var i = rows.count - 1
        while i >= 1 {
            if let offset = promptOffset(plain[i]), isRule(plain[i - 1]),
               let close = ((i + 1)..<min(rows.count, i + 21)).first(where: { isRule(plain[$0]) }) {
                var content = typed(rows[i], from: offset)
                for j in (i + 1)..<close { content += typed(rows[j], from: 0) }
                return content.isEmpty ? .empty : .draft
            }
            i -= 1
        }
        return .unknown
    }

    /// Splits one line of `tmux capture-pane -e` output into characters,
    /// each flagged when drawn dim or grey. Escape sequences are dropped.
    static func styledCells(_ line: String) -> [(Character, Bool)] {
        var out: [(Character, Bool)] = []
        var dim = false
        var grey = false
        var chars = Array(line)[...]
        while let c = chars.first {
            chars = chars.dropFirst()
            guard c == "\u{1B}" else {
                out.append((c, dim || grey))
                continue
            }
            guard let kind = chars.first else { break }
            chars = chars.dropFirst()
            if kind == "[" {
                var params = ""
                while let p = chars.first, !(p.isASCII && p.isLetter) && p != "~" { params.append(p); chars = chars.dropFirst() }
                let final = chars.first
                chars = chars.dropFirst()
                guard final == "m" else { continue }
                let codes = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
                var k = 0
                while k < codes.count {
                    switch codes[k] {
                    case 0: dim = false; grey = false
                    case 2: dim = true
                    case 22: dim = false
                    case 39: grey = false
                    case 90: grey = true
                    case 30...37, 91...97: grey = false
                    case 38, 48, 58:
                        // Extended colours carry their own parameters
                        // (5;n or 2;r;g;b). Consume them whole — otherwise
                        // the "2" of a background colour reads as dim and a
                        // real draft on a coloured background looks empty.
                        // Only the foreground (38) decides "grey placeholder".
                        let isForeground = codes[k] == 38
                        if k + 2 < codes.count, codes[k + 1] == 5 {
                            let n = codes[k + 2]
                            if isForeground { grey = n == 8 || (232...250).contains(n) }
                            k += 2
                        } else if k + 4 < codes.count, codes[k + 1] == 2 {
                            let (r, g, b) = (codes[k + 2], codes[k + 3], codes[k + 4])
                            if isForeground { grey = max(r, g, b) - min(r, g, b) <= 16 && (64...190).contains(r) }
                            k += 4
                        }
                    default: break
                    }
                    k += 1
                }
            } else if kind == "]" {
                // OSC (e.g. hyperlinks): up to BEL or ESC \.
                while let p = chars.first {
                    chars = chars.dropFirst()
                    if p == "\u{07}" { break }
                    if p == "\u{1B}" { chars = chars.dropFirst(); break }
                }
            }
        }
        return out
    }

    // MARK: host resolution

    enum TerminalHost: Equatable {
        case tmux(tmuxPath: String, paneId: String, inMode: Bool)
        case terminalApp(tty: String)
        case iTerm(tty: String)
        case cmux(CmuxBridge.Target)
        /// The host app is known and supported, but the session's exact
        /// place in it couldn't be pinned down (phone-safe reason).
        case unreachable(String)
        case unsupported(String)
        case unknown

        var label: String {
            switch self {
            case .tmux(_, let pane, _): return "tmux pane \(pane)"
            case .terminalApp(let tty): return "Terminal tab \(tty.replacingOccurrences(of: "/dev/", with: ""))"
            case .iTerm(let tty): return "iTerm2 session \(tty.replacingOccurrences(of: "/dev/", with: ""))"
            case .cmux(let target): return target.label
            case .unreachable: return "unknown terminal"
            case .unsupported(let app): return app
            case .unknown: return "unknown terminal"
            }
        }

        /// Whether Page can press a lone Esc here (interrupts a busy turn).
        /// Terminal.app's `do script` always appends Return, and ESC+Return
        /// can read as Meta-Return — so it can't.
        var canSendLoneEscape: Bool {
            switch self {
            case .tmux, .iTerm, .cmux: return true
            case .terminalApp, .unreachable, .unsupported, .unknown: return false
            }
        }
    }

    /// tmux pane with the session's tty first (claude inside tmux inside
    /// Terminal — or inside cmux — has the pane's pty, and typing into the
    /// outer terminal would go to the tmux client), else the GUI app found
    /// among the pid's ancestors.
    static func resolveHost(for session: ClaudeLiveSession, processTable: [ProcessRunner.ProcessInfoRow]) -> TerminalHost {
        guard let tty = session.devTTY else { return .unknown }
        if let tmux = ProcessRunner.findExecutable("tmux") {
            let r = ProcessRunner.run(tmux, ["list-panes", "-a", "-F", "#{pane_id}\t#{pane_tty}\t#{pane_in_mode}"], timeout: 3)
            if r.succeeded, let pane = tmuxPane(forTTY: tty, listing: r.stdout) {
                return .tmux(tmuxPath: tmux, paneId: pane.id, inMode: pane.inMode)
            }
        }
        guard let appCommand = hostAppCommand(forPid: session.pid, processTable: processTable) else { return .unknown }
        if let bundle = CmuxBridge.bundlePath(fromAppCommand: appCommand) {
            switch CmuxBridge.locateSurface(pid: session.pid, sessionId: session.sessionId, agent: .claude, bundlePath: bundle) {
            case .success(let target): return .cmux(target)
            case .failure(let f):
                Logger.shared.log("Injection.claude cmux pane not found: \(f.output)")
                return .unreachable(f.detail)
            }
        }
        switch appName(forCommand: appCommand) {
        case "Terminal"?: return .terminalApp(tty: tty)
        case "iTerm2"?: return .iTerm(tty: tty)
        case let app?: return .unsupported(app)
        case nil: return .unknown
        }
    }

    /// Parses `list-panes -F "#{pane_id}\t#{pane_tty}\t#{pane_in_mode}"`.
    static func tmuxPane(forTTY tty: String, listing: String) -> (id: String, inMode: Bool)? {
        for line in listing.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 2, cols[1] == tty, cols[0].hasPrefix("%") else { continue }
            let inMode = cols.count >= 3 && (Int(cols[2]) ?? 0) > 0
            return (String(cols[0]), inMode)
        }
        return nil
    }

    /// Name of the GUI app hosting `pid`, by walking its ancestors in one
    /// process-table snapshot (no per-pid ps spawns).
    static func hostApp(forPid pid: Int32, processTable: [ProcessRunner.ProcessInfoRow]) -> String? {
        hostAppCommand(forPid: pid, processTable: processTable).flatMap(appName(forCommand:))
    }

    /// Command line of the nearest GUI-app ancestor of `pid`.
    static func hostAppCommand(forPid pid: Int32, processTable: [ProcessRunner.ProcessInfoRow]) -> String? {
        var byPid: [Int32: ProcessRunner.ProcessInfoRow] = [:]
        for row in processTable { byPid[row.pid] = row }
        var current = byPid[pid]?.ppid
        var hops = 0
        while let p = current, p > 1, hops < 32 {
            guard let row = byPid[p] else { break }
            if appName(forCommand: row.command) != nil { return row.command }
            current = row.ppid
            hops += 1
        }
        return nil
    }

    static func appName(forCommand cmd: String) -> String? {
        if cmd.contains("Terminal.app/Contents/MacOS/Terminal") { return "Terminal" }
        if cmd.contains("iTerm.app/Contents/MacOS/") || cmd.contains("iTerm2.app/Contents/MacOS/") { return "iTerm2" }
        if cmd.contains("Warp.app/Contents/MacOS/") { return "Warp" }
        if cmd.contains("Ghostty.app/Contents/MacOS/") { return "Ghostty" }
        if cmd.contains("WezTerm.app/Contents/MacOS/") { return "WezTerm" }
        if cmd.contains("kitty.app/Contents/MacOS/") { return "kitty" }
        if cmd.contains("Alacritty.app/Contents/MacOS/") { return "Alacritty" }
        if cmd.contains("Hyper.app/Contents/MacOS/") { return "Hyper" }
        if cmd.contains("Zed.app/Contents/MacOS/") { return "Zed" }
        // VS Code / Cursor terminals hang off "Code Helper" / "Cursor Helper".
        if cmd.contains("Visual Studio Code.app/Contents/") || cmd.contains("/Code Helper") { return "VS Code" }
        if cmd.contains("Cursor.app/Contents/") || cmd.contains("/Cursor Helper") { return "Cursor" }
        // Any other app bundle (cmux, Tabby, …): name it so the phone can say
        // which terminal isn't supported.
        if let r = cmd.range(of: ".app/Contents/MacOS/") {
            let name = (String(cmd[..<r.lowerBound]) as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        return nil
    }

    /// Display hint for a page's `source` (VS Code/Cursor vs terminal).
    static func sessionSource(pid: Int32, processTable: [ProcessRunner.ProcessInfoRow]) -> AgentSessionSource {
        switch hostApp(forPid: pid, processTable: processTable) {
        case "VS Code"?, "Cursor"?: return .vscode
        default: return .terminal
        }
    }

    // MARK: tmux transport

    /// `precheck` runs before every key (text, Enter, Esc); a non-nil
    /// result aborts the rest of the plan with that phone-safe reason.
    static func sendViaTmux(_ steps: [Keystroke], tmuxPath: String, paneId: String, inMode: Bool,
                            awaitClosed: () -> Bool,
                            precheck: (Keystroke) -> String? = { _ in nil }) -> InjectionResult {
        func fail(_ output: String, _ detail: String) -> InjectionResult {
            InjectionResult(method: .tmux, success: false, output: output, detail: detail)
        }
        // A pane in copy-mode would swallow the keys as mode commands.
        if inMode {
            let r = ProcessRunner.run(tmuxPath, ["send-keys", "-t", paneId, "-X", "cancel"], timeout: 3)
            if !r.succeeded { return fail("copy-mode cancel failed: \(r.stderr)", "Couldn't take tmux pane \(paneId) out of copy mode") }
        }
        var sentSomething = false
        for step in steps {
            switch step {
            case .text, .enter, .escape:
                if let why = precheck(step) { return fail("precheck: \(why)", partialDetail(sentSomething, why)) }
            case .pause, .awaitPromptClosed:
                break
            }
            var r: ProcessRunner.Result
            switch step {
            case .text(let s) where s.contains("\n"):
                // Multi-line: one bracketed paste, so newlines don't submit.
                let buffer = "page-\(UUID().uuidString.prefix(8))"
                let load = ProcessRunner.run(tmuxPath, ["load-buffer", "-b", buffer, "-"], timeout: 3, stdin: Data(s.utf8))
                guard load.succeeded else { return fail("load-buffer: \(load.stderr)", partialDetail(sentSomething, "Couldn't type into tmux pane \(paneId)")) }
                r = ProcessRunner.run(tmuxPath, ["paste-buffer", "-p", "-d", "-b", buffer, "-t", paneId], timeout: 3)
                if !r.succeeded { ProcessRunner.run(tmuxPath, ["delete-buffer", "-b", buffer], timeout: 3) }
            case .text(let s):
                // `--` so a reply starting with "-" isn't parsed as flags;
                // trailing ";" sent as raw bytes (tmux would eat them).
                r = ProcessRunner.Result(status: 0, stdout: "", stderr: "", timedOut: false, launched: true)
                for args in ProcessRunner.tmuxLiteralSendKeys(target: paneId, text: s) {
                    r = ProcessRunner.run(tmuxPath, args, timeout: 3)
                    if !r.succeeded { break }
                }
            case .enter:
                r = ProcessRunner.run(tmuxPath, ["send-keys", "-t", paneId, "Enter"], timeout: 3)
            case .escape:
                r = ProcessRunner.run(tmuxPath, ["send-keys", "-t", paneId, "Escape"], timeout: 3)
            case .pause(let t):
                usleep(useconds_t(t * 1_000_000))
                continue
            case .awaitPromptClosed:
                if !awaitClosed() {
                    return fail("prompt still open after Esc", "Denied, but the prompt didn't close — your message wasn't sent")
                }
                continue
            }
            guard r.succeeded else {
                return fail("tmux exit \(r.status): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                            partialDetail(sentSomething, "Couldn't type into tmux pane \(paneId)"))
            }
            sentSomething = true
        }
        return InjectionResult(method: .tmux, success: true, output: "ok \(paneId)")
    }

    /// Pure. Phone text starting with a digit, about to be typed while
    /// Claude is busy: refused (`SessionInputGate.digitWhileBusyMessage`).
    /// Only the text key — once the digit is in the input box, Enter just
    /// queues the message.
    static func digitWhileBusyRefusal(key: Keystroke, status: ClaudeSessionStatus, enabled: Bool) -> String? {
        guard enabled, status == .busy, case .text(let text) = key, SessionInputGate.startsWithDigit(text) else { return nil }
        return SessionInputGate.digitWhileBusyMessage
    }

    private static func partialDetail(_ sentSomething: Bool, _ base: String) -> String {
        sentSomething ? base + " (part of the reply was typed)" : base
    }

    // MARK: Terminal.app transport

    /// Terminal's `do script "<x>" in tab` types x followed by Return; there
    /// is no way to send a key without Return. That's fine for "1" (the
    /// menu takes the digit; the Return lands on an empty input) and for
    /// text. It is NOT fine for Esc: ESC+Return arrives as one chunk that a
    /// key parser can read as Meta-Return — i.e. Enter on the menu, which
    /// accepts "Yes". So Esc is replaced by typing the menu's own "N. No"
    /// digit read off the visible screen, and refused when that isn't there.
    static func sendViaTerminalApp(_ steps: [Keystroke], tty: String, awaitClosed: () -> Bool,
                                   precheck: (Keystroke) -> String? = { _ in nil }) -> InjectionResult {
        func fail(_ output: String, _ detail: String) -> InjectionResult {
            InjectionResult(method: .terminalAppleScript, success: false, output: output, detail: detail)
        }
        var i = 0
        var sentSomething = false
        while i < steps.count {
            let step = steps[i]
            switch step {
            case .text, .enter, .escape:
                if let why = precheck(step) { return fail("precheck: \(why)", partialDetail(sentSomething, why)) }
            case .pause, .awaitPromptClosed:
                break
            }
            switch step {
            case .text(let s):
                let r = runTerminalCommand(tty: tty, body: "do script \(ProcessRunner.appleScriptQuote(flattenLines(s))) in t\nreturn \"ok\"")
                guard r.ok else { return fail(r.output, partialDetail(sentSomething, r.detail)) }
                sentSomething = true
                // `do script` already pressed Return.
                if i + 1 < steps.count, steps[i + 1] == .enter { i += 1 }
            case .enter:
                let r = runTerminalCommand(tty: tty, body: "do script \"\" in t\nreturn \"ok\"")
                guard r.ok else { return fail(r.output, partialDetail(sentSomething, r.detail)) }
                sentSomething = true
            case .escape:
                let screen = runTerminalCommand(tty: tty, body: "return \"ok:\" & (contents of t)")
                guard screen.ok else { return fail(screen.output, screen.detail) }
                guard let digit = denyOptionDigit(screen: String(screen.output.dropFirst(3))) else {
                    return fail("no 'N. No' option on screen",
                                "Terminal.app can't press Esc — deny this one at the Mac, or use tmux or iTerm2")
                }
                let r = runTerminalCommand(tty: tty, body: "do script \"\(digit)\" in t\nreturn \"ok\"")
                guard r.ok else { return fail(r.output, r.detail) }
                sentSomething = true
            case .pause(let t):
                usleep(useconds_t(t * 1_000_000))
            case .awaitPromptClosed:
                if !awaitClosed() {
                    return fail("prompt still open after deny", "Denied, but the prompt didn't close — your message wasn't sent")
                }
            }
            i += 1
        }
        return InjectionResult(method: .terminalAppleScript, success: true, output: "ok \(tty)")
    }

    /// The digit of the "No" option in a Claude Code select menu at the
    /// bottom of `screen`, or nil unless exactly one "N. No…" line follows a
    /// "1. Yes…" line among the last 30 lines. Fail-closed by design.
    static func denyOptionDigit(screen: String) -> Character? {
        let frame = CharacterSet(charactersIn: "│┃|║ \t❯›>▶▸*").union(.whitespaces)
        let lines = screen.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: frame) }
            .filter { !$0.isEmpty }
            .suffix(30)
        guard let yesIndex = lines.lastIndex(where: { $0.hasPrefix("1. Yes") }) else { return nil }
        var digits: [Character] = []
        for line in lines[lines.index(after: yesIndex)...] {
            let chars = Array(line)
            guard chars.count >= 5, chars[0].isNumber, chars[0] != "1", chars[1] == ".", chars[2] == " " else { continue }
            let rest = String(chars[3...])
            if rest == "No" || rest.hasPrefix("No,") || rest.hasPrefix("No ") || rest.hasPrefix("No\u{00A0}") {
                digits.append(chars[0])
            }
        }
        return digits.count == 1 ? digits[0] : nil
    }

    /// Runs `body` with `t` bound to the Terminal tab whose tty is `tty`.
    private static func runTerminalCommand(tty: String, body: String) -> (ok: Bool, output: String, detail: String) {
        let script = """
        with timeout of 10 seconds
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        set tabTTY to ""
                        try
                            set tabTTY to (tty of t as string)
                        end try
                        if tabTTY is \(ProcessRunner.appleScriptQuote(tty)) then
                            \(body)
                        end if
                    end repeat
                end repeat
            end tell
        end timeout
        return "no_match"
        """
        return interpretAppleScript(runAppleScript(script), app: "Terminal")
    }

    // MARK: iTerm2 transport

    /// iTerm2's `write text … newline NO` sends exact bytes, so Esc and
    /// "1" go through as single keys and Return is sent separately.
    static func sendViaITerm(_ steps: [Keystroke], tty: String, awaitClosed: () -> Bool,
                             precheck: (Keystroke) -> String? = { _ in nil }) -> InjectionResult {
        func fail(_ output: String, _ detail: String) -> InjectionResult {
            InjectionResult(method: .iTermAppleScript, success: false, output: output, detail: detail)
        }
        var sentSomething = false
        for step in steps {
            switch step {
            case .text, .enter, .escape:
                // After the text's pause, so the Return is checked last.
                if let why = precheck(step) { return fail("precheck: \(why)", partialDetail(sentSomething, why)) }
            case .pause, .awaitPromptClosed:
                break
            }
            let payload: String
            switch step {
            case .text(let s): payload = ProcessRunner.appleScriptQuote(flattenLines(s))
            case .enter: payload = "(character id 13)"
            case .escape: payload = "(character id 27)"
            case .pause(let t):
                usleep(useconds_t(t * 1_000_000))
                continue
            case .awaitPromptClosed:
                if !awaitClosed() {
                    return fail("prompt still open after Esc", "Denied, but the prompt didn't close — your message wasn't sent")
                }
                continue
            }
            let script = """
            with timeout of 10 seconds
                tell application id "com.googlecode.iterm2"
                    repeat with w in windows
                        repeat with tb in tabs of w
                            repeat with s in sessions of tb
                                set sTTY to ""
                                try
                                    set sTTY to (tty of s as string)
                                end try
                                if sTTY is \(ProcessRunner.appleScriptQuote(tty)) then
                                    tell s to write text \(payload) newline NO
                                    return "ok"
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
            end timeout
            return "no_match"
            """
            let r = interpretAppleScript(runAppleScript(script), app: "iTerm2")
            guard r.ok else { return fail(r.output, partialDetail(sentSomething, r.detail)) }
            sentSomething = true
            // Keep text and its Return in separate reads so the TUI sees a
            // keypress, not a pasted newline.
            if case .text = step { usleep(150_000) }
        }
        return InjectionResult(method: .iTermAppleScript, success: true, output: "ok \(tty)")
    }

    /// Visible text of the iTerm2 session whose tty is `tty`, or nil.
    static func iTermContents(tty: String) -> String? {
        let script = """
        with timeout of 10 seconds
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with tb in tabs of w
                        repeat with s in sessions of tb
                            set sTTY to ""
                            try
                                set sTTY to (tty of s as string)
                            end try
                            if sTTY is \(ProcessRunner.appleScriptQuote(tty)) then
                                return "ok:" & (contents of s)
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
        end timeout
        return "no_match"
        """
        let r = interpretAppleScript(runAppleScript(script), app: "iTerm2")
        return r.ok ? String(r.output.dropFirst(3)) : nil
    }

    // MARK: cmux transport

    /// Answers a prompt that cmux's PermissionRequest hook is holding in its
    /// Feed (Claude's own menu isn't on screen meanwhile). nil when Feed
    /// holds nothing for this session — or can't be read — and the reply
    /// should go through the screen (where every key is gated on cmux's
    /// view of the input row, so a hidden prompt is never typed into).
    ///
    /// `confirmClosed` re-checks the sessions file when it said "waiting":
    /// cmux resolving its Feed item proves its hook got the answer, but if
    /// Claude's own menu was already up (the hook had given up), only the
    /// menu closing proves the answer landed.
    static func answerViaCmuxFeed(_ req: ClaudeReplyRequest, session: ClaudeLiveSession, kind: ReplyPromptKind,
                                  client: CmuxBridge.Client, surface: String,
                                  confirmClosed: () -> Bool) -> InjectionResult? {
        guard actsOnPrompt(action: req.action, kind: kind) || kind.isPrompt else { return nil }
        let items: [CmuxBridge.FeedItem]
        switch client.pendingFeedItems() {
        case .success(let i): items = i
        case .failure(let f):
            Logger.shared.log("Injection.claude cmux feed.list unavailable (\(f.output)) — using the screen")
            return nil
        }
        func fail(_ output: String, _ detail: String) -> InjectionResult {
            InjectionResult(method: .cmuxFeed, success: false, output: output, detail: detail)
        }
        let decision = CmuxBridge.claudeFeedDecision(items: items, sessionId: session.sessionId, action: req.action,
                                                     text: req.text, pageStart: req.pageStateStart ?? req.hookCreatedAt)
        Logger.shared.log("Injection.claude cmux feed decision for \(session.sessionId.prefix(8)): \(decision)")
        switch decision {
        case .none:
            return nil
        case .refuse(let reason):
            return refused(reason)
        case .exitPlan(let id, let mode, let feedback):
            if case .failure(let f) = client.replyExitPlan(requestId: id, mode: mode, feedback: feedback) {
                return fail(f.output, f.detail)
            }
            guard client.waitForFeedResolution(requestId: id, timeout: 3) else {
                return fail("feed request \(id) still pending", "Sent to cmux, but the plan is still waiting — answer it at the Mac")
            }
            guard confirmClosed() else {
                return fail("status still waiting after feed reply", "Sent to cmux, but the plan is still showing — answer it at the Mac")
            }
            let detail = mode == "manual" ? "Approved the plan in cmux"
                : (feedback == nil ? "Rejected the plan in cmux" : "Rejected the plan in cmux and sent your feedback")
            return InjectionResult(method: .cmuxFeed, success: true, output: "feed.exit_plan.reply \(mode)", detail: detail)
        case .permission(let id, let mode, let thenType):
            if case .failure(let f) = client.replyPermission(requestId: id, mode: mode) {
                return fail(f.output, f.detail)
            }
            guard client.waitForFeedResolution(requestId: id, timeout: 3) else {
                return fail("feed request \(id) still pending", "Sent to cmux, but the prompt is still waiting — answer it at the Mac")
            }
            guard confirmClosed() else {
                return fail("status still waiting after feed reply", "Sent to cmux, but the prompt is still showing — answer it at the Mac")
            }
            guard let text = thenType else {
                return InjectionResult(method: .cmuxFeed, success: true, output: "feed.permission.reply \(mode)",
                                       detail: mode == "once" ? "Approved in cmux" : "Denied in cmux")
            }
            // Feed's deny can't carry text. After it, Claude either carries
            // on (busy: an empty prompt queues the message) or stops (idle:
            // it's submitted) — both fine, as long as the box is empty.
            let state: CmuxBridge.InputState
            switch client.waitForInputState(surface: surface, notEqualTo: .dialog, timeout: 2) {
            case .success(let st): state = st
            case .failure(let f): return fail(f.output, "Denied in cmux, but your message wasn't sent — \(f.detail)")
            }
            if let why = CmuxBridge.refusalForTyping(state) {
                return fail("input state \(state.rawValue) after deny", "Denied in cmux, but your message wasn't sent — \(why)")
            }
            if case .failure(let f) = client.pasteAndSubmit(surface: surface, text: text) {
                return fail(f.output, "Denied in cmux, but your message wasn't sent — \(f.detail)")
            }
            return InjectionResult(method: .cmuxFeed, success: true, output: "feed deny + paste", detail: "Denied in cmux and sent your reply")
        }
    }

    /// Types `steps` into a cmux pane. Every step re-reads cmux's view of
    /// the agent's input row first: menu keys ("1", Esc) only while a
    /// dialog is open (then with `--force`, since Page has just seen it);
    /// text only into an empty prompt (`paste`, no `--force`, so cmux checks
    /// again at the moment of typing). A bare Enter is never sent — on a
    /// menu it would accept "Yes".
    static func sendViaCmux(_ steps: [Keystroke], client: CmuxBridge.Client, surface: String,
                            awaitClosed: () -> Bool,
                            precheck: (Keystroke) -> String? = { _ in nil }) -> InjectionResult {
        func fail(_ output: String, _ detail: String) -> InjectionResult {
            InjectionResult(method: .cmux, success: false, output: output, detail: detail)
        }
        var i = 0
        var sentSomething = false
        var dismissedMenu = false
        while i < steps.count {
            switch steps[i] {
            case .text, .enter, .escape:
                if let why = precheck(steps[i]) {
                    return fail("precheck: \(why)", dismissedMenu ? "Denied, but your message wasn't sent — \(why)" : partialDetail(sentSomething, why))
                }
            case .pause, .awaitPromptClosed:
                break
            }
            switch steps[i] {
            case .escape:
                switch client.inputState(surface: surface) {
                case .failure(let f): return fail(f.output, f.detail)
                case .success(let state):
                    guard state == .dialog else {
                        return fail("input state \(state.rawValue), wanted dialog",
                                    state == .unknown ? CmuxBridge.noInputBoxDetail : promptGoneMessage)
                    }
                }
                if case .failure(let f) = client.sendKey(surface: surface, key: "escape", force: true) {
                    return fail(f.output, f.detail)
                }
                sentSomething = true
                dismissedMenu = true
            case .text(let text):
                let isMessage = i + 1 < steps.count && steps[i + 1] == .enter
                if isMessage {
                    // A dismissed menu takes a redraw to leave the screen.
                    let read = dismissedMenu
                        ? client.waitForInputState(surface: surface, notEqualTo: .dialog, timeout: 1.5)
                        : client.inputState(surface: surface)
                    let state: CmuxBridge.InputState
                    switch read {
                    case .failure(let f):
                        return fail(f.output, dismissedMenu ? "Denied, but your message wasn't sent — \(f.detail)" : f.detail)
                    case .success(let st): state = st
                    }
                    if let why = CmuxBridge.refusalForTyping(state) {
                        return fail("input state \(state.rawValue)", dismissedMenu ? "Denied, but your message wasn't sent — \(why)" : why)
                    }
                    if case .failure(let f) = client.pasteAndSubmit(surface: surface, text: text) {
                        return fail(f.output, dismissedMenu ? "Denied, but your message wasn't sent — \(f.detail)" : partialDetail(sentSomething, f.detail))
                    }
                    i += 1   // --submit pressed the Enter
                } else {
                    // A lone digit answers the open menu.
                    guard text.count == 1, let digit = text.first, digit.isNumber else {
                        return fail("refused lone text step", "Couldn't type into that cmux pane")
                    }
                    switch client.inputState(surface: surface) {
                    case .failure(let f): return fail(f.output, f.detail)
                    case .success(let state):
                        guard state == .dialog else {
                            return fail("input state \(state.rawValue), wanted dialog",
                                        state == .unknown ? CmuxBridge.noInputBoxDetail : promptGoneMessage)
                        }
                    }
                    if case .failure(let f) = client.sendDialogDigit(surface: surface, digit: digit) {
                        return fail(f.output, f.detail)
                    }
                }
                sentSomething = true
            case .enter:
                return fail("refused bare Enter", partialDetail(sentSomething, "Couldn't type into that cmux pane"))
            case .pause(let t):
                usleep(useconds_t(t * 1_000_000))
            case .awaitPromptClosed:
                if !awaitClosed() {
                    return fail("prompt still open after Esc", "Denied, but the prompt didn't close — your message wasn't sent")
                }
            }
            i += 1
        }
        return InjectionResult(method: .cmux, success: true, output: "ok \(surface)")
    }

    /// AppleScript paths type a single line (Return would submit early).
    /// Trimming would undo `sanitize`'s space before a leading "!", so it
    /// is re-applied to the final line: "!" first in Claude Code's input
    /// box switches to bash mode and runs the rest as a shell command.
    static func flattenLines(_ s: String) -> String {
        let line = s.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        return line.unicodeScalars.first == "!" ? " " + line : line
    }

    // MARK: AppleScript

    /// Runs AppleScript in-process (so TCC attributes the Automation grant
    /// to Page, not to a spawned osascript). NSAppleScript isn't
    /// thread-safe, so it always runs on the main thread; callers are on
    /// the injection queue, and nothing on main ever waits on that queue.
    static func runAppleScript(_ source: String) -> (value: String?, error: String?, errorNumber: Int?) {
        let work: () -> (String?, String?, Int?) = {
            guard let script = NSAppleScript(source: source) else { return (nil, "NSAppleScript init failed", nil) }
            var errorDict: NSDictionary?
            let descriptor = script.executeAndReturnError(&errorDict)
            if let err = errorDict {
                let msg = (err[NSAppleScript.errorMessage] as? String) ?? "\(err)"
                let num = (err[NSAppleScript.errorNumber] as? Int)
                return (nil, msg, num)
            }
            return (descriptor.stringValue ?? "", nil, nil)
        }
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    private static func interpretAppleScript(_ r: (value: String?, error: String?, errorNumber: Int?), app: String) -> (ok: Bool, output: String, detail: String) {
        if let err = r.error {
            let detail: String
            switch r.errorNumber {
            case .some(-1743): detail = "Allow Page to control \(app) in System Settings → Privacy & Security → Automation"
            case .some(-600): detail = "\(app) isn't running"
            case .some(-1712): detail = "\(app) didn't respond"
            default: detail = "Couldn't type into \(app)"
            }
            return (false, "AppleScript error \(r.errorNumber ?? 0): \(err)", detail)
        }
        let value = r.value ?? ""
        if value.hasPrefix("ok") { return (true, value, "") }
        return (false, value.isEmpty ? "no result" : value, "Couldn't find the session's \(app) window")
    }

    // MARK: interrupt (low-battery pause)

    /// Presses a lone Esc in a busy session's terminal, which makes Claude
    /// Code interrupt the running turn. Only hosts that can send Esc alone
    /// (`TerminalHost.canSendLoneEscape`). The caller re-checks the session
    /// is still busy right before — Esc on an open menu would deny it — and
    /// still in the foreground (`ProcessRunner.isForeground`): after ^Z the
    /// Esc would go to the shell.
    static func sendInterrupt(host: TerminalHost) -> InjectionResult {
        switch host {
        case .tmux(let tmux, let pane, let inMode):
            return sendViaTmux([.escape], tmuxPath: tmux, paneId: pane, inMode: inMode, awaitClosed: { true })
        case .iTerm(let tty):
            return sendViaITerm([.escape], tty: tty, awaitClosed: { true })
        case .cmux(let target):
            let client: CmuxBridge.Client
            switch CmuxBridge.connect(cliPath: target.cliPath) {
            case .failure(let f): return InjectionResult(method: .cmux, success: false, output: f.output, detail: f.detail)
            case .success(let c): client = c
            }
            switch client.inputState(surface: target.surfaceId) {
            case .failure(let f):
                return InjectionResult(method: .cmux, success: false, output: f.output, detail: f.detail)
            case .success(let state) where state == .dialog || state == .unknown:
                // A dialog means it's waiting on the user, not working;
                // unknown means Page can't tell what Esc would hit.
                return InjectionResult(method: .cmux, success: false, output: "input state \(state.rawValue)",
                                       detail: state == .dialog ? "A prompt is open in that pane" : CmuxBridge.noInputBoxDetail)
            case .success:
                break
            }
            // No --force: cmux refuses a key into a dialog that opened since.
            if case .failure(let f) = client.sendKey(surface: target.surfaceId, key: "escape", force: false) {
                return InjectionResult(method: .cmux, success: false, output: f.output, detail: f.detail)
            }
            return InjectionResult(method: .cmux, success: true, output: "escape \(target.surfaceId)")
        case .terminalApp, .unreachable, .unsupported, .unknown:
            return InjectionResult(method: .none, success: false, output: "no lone Esc for \(host.label)",
                                   detail: "Page can't press Esc in \(host.label)")
        }
    }

    /// Why a background `claude --resume` must not run for `sessionId` right
    /// now, or nil. Two writers on one session fork the conversation, so
    /// anything hinting at a live owner the registry missed blocks it: a
    /// claude process naming the session in argv (another resume, a
    /// scheduled job), a live background job's sessions file for it
    /// (`backgroundOwnerPids`, from ClaudeSessionRegistry), a live
    /// cmux-recorded process for it, or a transcript written moments ago.
    ///
    /// `providerEvidence` (ResumeProviderGate): the background run doesn't
    /// carry the session's environment, so it always goes to the user's
    /// Anthropic account — refused unless the session positively ran on
    /// Anthropic. nil skips that check; the reply path always passes it.
    static func headlessBlocker(sessionId: String,
                                processTable: [ProcessRunner.ProcessInfoRow],
                                transcript: URL?,
                                now: Date = Date(),
                                cmuxEntry: CmuxBridge.HookSession? = nil,
                                backgroundOwnerPids: [Int32] = [],
                                providerEvidence: ResumeProviderGate.Evidence? = nil,
                                startSeconds: (Int32) -> Int? = CmuxBridge.processStartSeconds) -> String? {
        if let providerEvidence, let why = ResumeProviderGate.refusal(providerEvidence) { return why }
        guard !processTable.isEmpty else { return "Couldn't check whether the session is still running" }
        if !backgroundOwnerPids.isEmpty { return backgroundJobMessage }
        let sid = sessionId.lowercased()
        if processTable.contains(where: { ClaudeSessionRegistry.isClaudeCommand($0.command) && $0.command.lowercased().contains(sid) }) {
            return "The session is still running — reply at the Mac"
        }
        if let entry = cmuxEntry, let pid = entry.pid, processTable.contains(where: { $0.pid == pid }),
           let recorded = entry.pidStartSeconds, let actual = startSeconds(pid), abs(recorded - actual) <= 1 {
            return "The session is still open in cmux — reply at the Mac"
        }
        if let transcript,
           let mtime = (try? FileManager.default.attributesOfItem(atPath: transcript.path))?[.modificationDate] as? Date,
           now.timeIntervalSince(mtime) < 90 {
            return "The session was active moments ago — reply again in a couple of minutes"
        }
        return nil
    }

    // MARK: headless fallback

    /// Delivers a text reply to a session whose process has exited, via
    /// `claude --resume <id> --print -- <text>` in the session's own cwd
    /// (from its transcript, never from the relay payload). Output goes to
    /// ~/Library/Logs/ClaudePowerMode-resumes/. Blocks up to `timeout`.
    static func injectHeadless(sessionId: String, text: String, transcript: URL?,
                               timeout: TimeInterval = 15 * 60) -> InjectionResult {
        func fail(_ output: String, _ detail: String) -> InjectionResult {
            InjectionResult(method: .headlessResume, success: false, output: output, detail: detail)
        }
        let clean = sanitize(text)
        guard !clean.isEmpty else { return fail("empty", "The reply was empty") }
        guard ClaudeSessionRegistry.isValidSessionId(sessionId) else { return fail("bad session id", "Couldn't identify the session") }
        guard let transcript, FileManager.default.fileExists(atPath: transcript.path) else {
            return fail("no transcript", "Session ended and its transcript wasn't found")
        }
        guard let cwd = InterventionDetector.readTranscriptTail(transcript)?.cwd else {
            return fail("no cwd in transcript", "Session ended and its folder is unknown")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            return fail("cwd missing: \(cwd)", "Session ended and its folder no longer exists")
        }
        guard let claude = ProcessRunner.findExecutable("claude") else {
            return fail("claude not found", "Session ended and the claude CLI wasn't found")
        }

        let logDir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("ClaudePowerMode-resumes", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("\(timestamp())-\(sessionId.prefix(8)).log")

        Logger.shared.log("Injection.headless session=\(sessionId.prefix(8)) cwd=\(cwd)")
        let r = ProcessRunner.run(claude, ["--resume", sessionId, "--print", "--", clean],
                                  timeout: timeout,
                                  environment: ProcessRunner.augmentedEnvironment(),
                                  currentDirectory: cwd)
        let log = "$ claude --resume \(sessionId) --print …\nexit=\(r.status) timedOut=\(r.timedOut)\n\n\(r.stdout)\n--- stderr ---\n\(r.stderr)"
        try? log.data(using: .utf8)?.write(to: logURL)
        if r.succeeded {
            return InjectionResult(method: .headlessResume, success: true,
                                   output: "ok (log: \(logURL.lastPathComponent))",
                                   detail: "Session ended — sent via background resume")
        }
        if r.timedOut { return fail("timed out (log: \(logURL.lastPathComponent))", "Background resume timed out") }
        if !r.launched { return fail("launch failed", "Couldn't start claude") }
        return fail("exit \(r.status): \(String(r.stderr.suffix(280)))", "Background resume failed (exit \(r.status))")
    }

    /// Filename-safe local timestamp for reply logs. Fixed-format, so pin
    /// the POSIX locale and Gregorian calendar (user locales can otherwise
    /// produce non-ASCII digits or a Buddhist-era year).
    static func timestamp() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "yyyyMMdd-HHmmss"
        return df.string(from: Date())
    }
}
