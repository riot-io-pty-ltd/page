import Foundation

// The Session Room as plain values: who the agent is, which lenses the room
// offers, what the header says, what the composer may do right now and what
// it will type, and the Story built from the Mac's transcript. Foundation-only
// (no clock, no services), so the logic tests cover it and the macOS proxy
// renderer can draw the views that read it.
//
// Trust model: while a session is waiting on a prompt, free text never goes
// to the terminal as text plus Enter (that would approve the highlighted
// "Yes"). The only way to write to a waiting session is "Tell it instead",
// which the page sends as Esc, then the text, then Return. Steering a busy
// session is text plus Return, which queues. Nothing here types anything:
// the composer hands its text to a closure and the container picks the one
// existing path.

// MARK: - Who the agent is

/// What kind of agent a room is for. Each keeps its own character: Claude
/// narrates and runs steps, Codex shows plans and patches, a local model
/// streams an answer and costs nothing.
struct AgentCharacter: Equatable {
    enum Kind: String, Equatable { case claude, codex, local, other }

    let kind: Kind
    /// "Claude", "Codex", "Ollama", or the agent's own name.
    let name: String
    /// SF Symbol drawn in the header and beside the agent's lines.
    let symbol: String
    /// Set for a local model: "Private · nothing leaves this Mac".
    let privacyTitle: String?
    let privacyNote: String?
    /// The local runtime's own name when the model runs locally ("Ollama").
    let runtime: String?

    /// Providers the Mac reports for models that run on the Mac itself.
    static let localProviders: Set<String> = ["ollama", "lmStudio", "otherLocal"]

    static func runtimeName(provider: String?) -> String? {
        switch provider {
        case "ollama": return "Ollama"
        case "lmStudio": return "LM Studio"
        case "otherLocal": return "A local model"
        default: return nil
        }
    }

    static func from(backend: AgentBackend, provider: String?) -> AgentCharacter {
        if let provider, localProviders.contains(provider), let runtime = runtimeName(provider: provider) {
            // Claude or Codex pointed at a local model, or a harness (opencode, aider) around one.
            let harness: String?
            switch backend {
            case .known(let b): harness = b.displayName
            case .other(let raw): harness = raw == "unknown" ? nil : backend.displayName
            }
            return AgentCharacter(kind: .local, name: harness == nil ? runtime : (runtime == "A local model" ? harness! : runtime),
                                  symbol: "cpu", privacyTitle: "Private · nothing leaves this Mac",
                                  privacyNote: "No usage limits or cost. Page keeps the Mac awake only while it's generating.",
                                  runtime: runtime)
        }
        switch backend {
        case .known(.claude):
            return AgentCharacter(kind: .claude, name: "Claude", symbol: "sparkle", privacyTitle: nil, privacyNote: nil, runtime: nil)
        case .known(.codex):
            return AgentCharacter(kind: .codex, name: "Codex", symbol: "hexagon", privacyTitle: nil, privacyNote: nil, runtime: nil)
        case .other:
            return AgentCharacter(kind: .other, name: backend.displayName, symbol: "questionmark.circle",
                                  privacyTitle: nil, privacyNote: nil, runtime: nil)
        }
    }

    /// "Claude · cmux", "Claude · on Ollama · cmux", "Ollama · via opencode · cmux".
    func subtitle(backend: AgentBackend, provider: String?, host: String) -> String {
        var parts: [String] = []
        if kind == .local, let runtime {
            switch backend {
            case .known(let b): parts += [b.displayName, "on \(runtime)"]
            case .other(let raw): parts += raw == "unknown" ? [runtime] : [runtime, "via \(backend.displayName)"]
            }
        } else {
            parts.append(name)
        }
        let h = host.trimmingCharacters(in: .whitespaces)
        if !h.isEmpty, h.lowercased() != "unknown host", h.lowercased() != "unknown" { parts.append(h) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Lenses

/// The four ways into a session. Story is the default; Screen, Changes and
/// Workflows appear only when there is something behind them.
enum RoomLens: String, CaseIterable, Identifiable, Equatable {
    case story, screen, changes, workflows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .story: return "Story"
        case .screen: return "Screen"
        case .changes: return "Changes"
        case .workflows: return "Workflows"
        }
    }

    struct Inputs: Equatable {
        var character: AgentCharacter
        /// The Mac has sent this session's terminal mirror (tmux and cmux only).
        var hasScreen: Bool
        /// The session's dynamic workflows (Claude Code only).
        var workflowCount: Int
        /// The room can ask the Mac for this session's changes (a live session, a ready relay).
        var canAskForChanges: Bool

        init(character: AgentCharacter, hasScreen: Bool, workflowCount: Int, canAskForChanges: Bool) {
            self.character = character; self.hasScreen = hasScreen
            self.workflowCount = workflowCount; self.canAskForChanges = canAskForChanges
        }
    }

    /// Which lenses to offer, in order. Workflows is Claude's alone and only
    /// once a run exists; Changes needs a live session to ask; an agent Page
    /// has no adapter for gets Story only. Pure.
    static func available(_ i: Inputs) -> [RoomLens] {
        var out: [RoomLens] = [.story]
        if i.hasScreen && i.character.kind != .other { out.append(.screen) }
        if i.canAskForChanges && i.character.kind != .other { out.append(.changes) }
        if i.workflowCount > 0 && i.character.kind == .claude { out.append(.workflows) }
        return out
    }

    /// Story by default (the board shows a waiting session on Story, with
    /// the decision pinned in it). The lens a room was last on stays if it is
    /// still offered. Pure.
    static func resolve(_ wanted: RoomLens?, offered: [RoomLens]) -> RoomLens {
        if let wanted, offered.contains(wanted) { return wanted }
        return .story
    }

    /// The small count on a lens: files changed, workflows running. Pure.
    static func badge(for lens: RoomLens, changedFiles: Int?, runningWorkflows: Int) -> Int? {
        switch lens {
        case .changes: return (changedFiles ?? 0) > 0 ? changedFiles : nil
        case .workflows: return runningWorkflows > 0 ? runningWorkflows : nil
        default: return nil
        }
    }
}

// MARK: - Header

/// A chip under the room's title: the state, then what the agent can tell us.
struct RoomChip: Equatable, Identifiable {
    enum Tone: Equatable { case working, needsYou, quiet, warm, local }

    let text: String
    let tone: Tone
    /// An SF Symbol, when the chip has one.
    let symbol: String?
    var id: String { text }
}

enum RoomHeader {
    /// The state chip and the signals the wire really carries. There is no
    /// model name, turn number or context figure on the wire, so none is
    /// invented: the working chip says how long since the agent last did
    /// something, and the usage chip is the Mac's 5-hour reading.
    ///
    /// `waitingSince` is when the open page was raised (for "NEEDS YOU · 1m").
    static func chips(session: LiveSession, character: AgentCharacter, ended: Bool, waitingSince: Date?,
                      hasReviewPage: Bool, fiveHourPct: Double?, now: Date) -> [RoomChip] {
        var out: [RoomChip] = []
        let since = session.lastActivityAt.map { max(0, Int(now.timeIntervalSince($0))) }
        func age(_ s: Int?) -> String? { s.map { RelativeTime.compact(seconds: $0) } }

        if ended {
            out.append(RoomChip(text: "ENDED", tone: .quiet, symbol: nil))
        } else {
            switch session.state {
            case .active:
                let word = character.kind == .local ? "GENERATING" : "WORKING"
                // Busy, but nothing new for a while: say when its last step was. (The Mac
                // sends no start time, so this is never how long it has been working.)
                if let s = since, s >= 30 {
                    out.append(RoomChip(text: "\(word) · last step \(RelativeTime.compact(seconds: s)) ago", tone: .working, symbol: nil))
                } else {
                    out.append(RoomChip(text: word, tone: .working, symbol: nil))
                }
            case .waitingOnApproval, .waitingOnUser:
                let waited = (waitingSince ?? session.lastActivityAt).map { RelativeTime.compact(seconds: max(0, Int(now.timeIntervalSince($0)))) }
                out.append(RoomChip(text: "NEEDS YOU" + (waited.map { " · \($0)" } ?? ""), tone: .needsYou, symbol: nil))
            case .idle:
                let word = hasReviewPage ? "FINISHED" : "IDLE"
                out.append(RoomChip(text: word + (age(since).map { " · \($0) ago" } ?? ""), tone: .quiet, symbol: nil))
            case .rateLimited: out.append(RoomChip(text: "RATE LIMITED", tone: .warm, symbol: nil))
            case .interrupted: out.append(RoomChip(text: "INTERRUPTED" + (age(since).map { " · \($0) ago" } ?? ""), tone: .quiet, symbol: nil))
            case .failed: out.append(RoomChip(text: "FAILED", tone: .warm, symbol: nil))
            case .offline: out.append(RoomChip(text: "OFFLINE", tone: .quiet, symbol: nil))
            case .unknown: out.append(RoomChip(text: "STATE UNKNOWN", tone: .quiet, symbol: nil))
            }
        }
        if character.kind == .local {
            out.append(RoomChip(text: "on-device", tone: .local, symbol: "lock"))
        } else if character.kind == .claude, let pct = fiveHourPct {
            out.append(RoomChip(text: "5h \(Int(pct.rounded()))%", tone: pct >= 80 ? .warm : .quiet, symbol: "gauge.with.needle"))
        }
        return out
    }
}

// MARK: - The composer

/// What the room's composer does right now. This is the trust model in one
/// switch: a waiting session is never typed into as text plus Enter.
enum RoomComposerMode: Equatable {
    /// The session is ended, or the Mac cannot be reached.
    case disabled(String)
    /// Waiting on a prompt with no page to answer it from.
    case locked(String)
    /// Waiting on a prompt that has a page: a written reply goes Esc, then
    /// the text, then Return, through that page.
    case tellInstead(pageId: String)
    /// Page cannot type in this session's terminal.
    case blocked(String)
    /// Busy: text plus Return, which queues behind the current step.
    case steer
    /// Idle: the next task.
    case nextTask

    struct Inputs: Equatable {
        var state: LiveSessionState
        var canType: Bool
        var typeBlocker: String?
        /// The open page for this session, as a row the phone holds. Nil when
        /// the page has not arrived (or there is none).
        var pageId: String?
        /// That page is a decision (Approve, Deny, a question): the session is
        /// blocked on you, whatever its state says while the list catches up.
        var pageIsDecide: Bool
        /// The page offers a written reply (Esc, then your message).
        var pageAcceptsReply: Bool
        /// The session says it is waiting on a page that has not loaded yet.
        var pageArriving: Bool
        var ended: Bool
        /// Live sessions are available (the Mac is connected and sending).
        var ready: Bool
        /// Page can't type here now (`canType` false) but can hold a message until the turn ends
        /// (`hold-v1` with `canHold`): a busy Codex thread outside cmux. The composer takes the text and
        /// it goes as "When it finishes", never typed mid-turn.
        var holdOnly: Bool

        init(state: LiveSessionState, canType: Bool, typeBlocker: String? = nil, pageId: String? = nil, pageIsDecide: Bool = false,
             pageAcceptsReply: Bool = true, pageArriving: Bool = false, ended: Bool = false, ready: Bool = true, holdOnly: Bool = false) {
            self.state = state; self.canType = canType; self.typeBlocker = typeBlocker; self.pageId = pageId
            self.pageIsDecide = pageIsDecide; self.pageAcceptsReply = pageAcceptsReply; self.pageArriving = pageArriving
            self.ended = ended; self.ready = ready; self.holdOnly = holdOnly
        }
    }

    /// The trust model in one switch. A session that is waiting (or has a
    /// decision pinned) is never typed into as text plus Enter; a written
    /// reply needs the page's own row, so Send can never do nothing quietly.
    static func resolve(_ i: Inputs) -> RoomComposerMode {
        if i.ended { return .disabled("This session has ended.") }
        if !i.ready { return .disabled("Waiting for your Mac.") }
        if i.state.isWaiting || i.pageIsDecide {
            if let page = i.pageId, i.pageAcceptsReply { return .tellInstead(pageId: page) }
            if i.pageId != nil { return .locked("Answer this prompt from its decision above.") }
            if i.pageArriving { return .locked("Its decision is still arriving. Answer on your Mac, or wait a moment.") }
            return .locked("Answer the prompt on your Mac. Page won't type over a prompt.")
        }
        if !i.canType {
            if i.holdOnly && i.state == .active { return .steer }
            return .blocked(i.typeBlocker ?? LiveSession.defaultBlocker)
        }
        return i.state == .active ? .steer : .nextTask
    }

    /// The composer takes text at all.
    var acceptsText: Bool {
        switch self {
        case .tellInstead, .steer, .nextTask: return true
        default: return false
        }
    }

    /// A written reply goes through the page (Esc, text, Return), never as session input.
    var routesThroughPage: Bool { if case .tellInstead = self { return true }; return false }

    /// Send as the session's own input (text plus Return).
    var usesSessionInput: Bool { self == .steer || self == .nextTask }

    struct Copy: Equatable {
        let placeholder: String
        /// Under the field, in words ("queues after the current step").
        let hint: String
        let sendLabel: String
    }

    /// Placeholder and hint, in the agent's own voice. Codex reads a message
    /// when its turn ends; a local model when generation stops.
    func copy(for character: AgentCharacter) -> Copy {
        let who = character.kind == .local ? "the model" : character.name
        switch self {
        case .tellInstead:
            return Copy(placeholder: "Tell it instead…", hint: "sends Esc first, then your words — never answers the menu",
                        sendLabel: "Send, after Esc")
        case .steer:
            switch character.kind {
            case .codex: return Copy(placeholder: "Message Codex…", hint: "delivered when this turn ends", sendLabel: "Send message")
            case .local: return Copy(placeholder: "Message the model…", hint: "sent when generation stops", sendLabel: "Send message")
            default: return Copy(placeholder: "Steer \(who)…", hint: "queues after the current step", sendLabel: "Send message")
            }
        case .nextTask:
            return Copy(placeholder: character.kind == .local ? "Message the model…" : "Message \(who)…",
                        hint: "typed into the session", sendLabel: "Send message")
        case .blocked(let why): return Copy(placeholder: "Can't type here", hint: why, sendLabel: "Send message")
        case .locked(let why): return Copy(placeholder: "Locked while it waits", hint: why, sendLabel: "Send message")
        case .disabled(let why): return Copy(placeholder: "Not available", hint: why, sendLabel: "Send message")
        }
    }

    /// The delivery preview: what will be typed, where, on which Mac. nil
    /// when nothing would be sent. Pure.
    func preview(character: AgentCharacter, route: String?, mac: String, pagePreview: String? = nil, holds: Bool = false) -> String? {
        switch self {
        case .tellInstead:
            // The page knows how its answer is delivered: through a hook, or Esc then your words.
            return pagePreview ?? DeliveryPreview.tellInstead(route: route, mac: mac)
        case .steer:
            // Held on the Mac: typed once the turn ends, and deletable until then.
            if holds { return DeliveryPreview.line("Your message, then Return · held until this turn ends", route: route, mac: mac) }
            let tail: String
            switch character.kind {
            case .codex: tail = "delivered when this turn ends"
            case .local: tail = "sent when generation stops"
            default: tail = "queues after this step"
            }
            return DeliveryPreview.line("Your message, then Return · \(tail)", route: route, mac: mac)
        case .nextTask:
            return DeliveryPreview.message(route: route, mac: mac)
        case .blocked(let why):
            return DeliveryPreview.cannotType(why, mac: mac)
        case .locked, .disabled:
            return nil
        }
    }

    /// A line under a Codex or local agent's story that says when a message lands.
    static func timingNote(character: AgentCharacter, busy: Bool) -> String? {
        guard busy else { return nil }
        switch character.kind {
        case .codex: return "Codex reads your message when this turn ends — or right away in a cmux pane with an empty composer."
        case .local: return "A local model reads your message when generation stops."
        default: return nil
        }
    }

    /// Standing replies that fill the composer (never send on their own).
    static let quickReplies = ["Carry on", "Run the tests, then stop", "Summarise what you did", "Stop and explain what's failing"]

    /// Quick replies belong where a message is the next thing: idle or steering.
    var offersQuickReplies: Bool { self == .steer || self == .nextTask }
}

// MARK: - Stop

/// Stop in the room: a 10 s hold, because Esc interrupts the turn. No
/// biometrics (this is one session's Esc, not Stop-all), and a mis-hold is
/// undone by letting go early.
struct SessionStopPlan: Equatable {
    let canStop: Bool
    let scope: String
    let preview: String

    /// The hold that confirms a Stop.
    static let spec = HoldRingSpec(deadZone: 0, fill: 10)

    /// Offered only mid-turn, where the Mac says Esc works, with the relay ready.
    static func build(session: LiveSession, ready: Bool, ended: Bool, macName: String) -> SessionStopPlan {
        // The folder's name, not the title: the same words the receipt and the header use.
        let project = SessionTarget(session: session, macName: macName).project
        let route = DeliveryPreview.route(host: session.host, project: project)
        return SessionStopPlan(canStop: session.isStoppable && ready && !ended,
                               scope: "Press Esc in \(project)",
                               preview: DeliveryPreview.pressEsc(route: route, mac: macName))
    }
}

// MARK: - The plan for a room

/// What a room does about the page behind its session and the composer, as
/// one pure decision: which page is pinned in the Story, which belongs to
/// Changes, what the composer may do and the preview it shows.
struct RoomPlan: Equatable {
    /// A decision or look, pinned in the Story.
    let pinned: NowRow?
    /// A finished turn: its actions live in Changes.
    let review: NowRow?
    let mode: RoomComposerMode
    let preview: String?
    /// How a message to a busy session goes: the choice offered, or the way it goes without one.
    let choice: SendChoicePlan
    /// The photo button (`images-v1`): shown, dimmed with its reason, or not at all.
    let photos: PhotoOffer

    struct Inputs {
        var session: LiveSession
        var character: AgentCharacter
        var pageRow: NowRow?
        var ended: Bool
        var ready: Bool
        var macName: String
        /// What the Mac accepts (`list` `caps`); none from an older Mac.
        var caps: Set<String> = []
        /// The choice made last time, kept per device.
        var lastChoice: SendChoice? = nil
        /// Photos already in the composer (a Mac that stopped offering them is said out loud).
        var stagedPhotos = 0
    }

    static func build(_ i: Inputs) -> RoomPlan {
        let s = i.session
        let pinned = i.pageRow.flatMap { $0.section == .review ? nil : $0 }
        let review = i.pageRow.flatMap { $0.section == .review ? $0 : nil }
        let busy = s.state == .active && !i.ended
        let choice = SendChoicePlan.build(busy: busy, canType: s.canType, canHold: s.canHold, caps: i.caps, last: i.lastChoice)
        let mode = RoomComposerMode.resolve(.init(
            state: s.state, canType: s.canType, typeBlocker: s.typeBlocker,
            pageId: pinned?.id, pageIsDecide: pinned?.section == .decide,
            pageAcceptsReply: pinned?.action(.tellInstead) != nil,
            pageArriving: s.interventionId != nil && pinned == nil,
            ended: i.ended, ready: i.ready, holdOnly: choice.mode == .holdOnly))
        let route = DeliveryPreview.route(host: s.host, project: SessionTarget(session: s, macName: i.macName).project)
        let preview = mode.preview(character: i.character, route: route, mac: i.macName,
                                   pagePreview: pinned?.action(.tellInstead)?.preview, holds: choice.holds && mode == .steer)
        let photos = PhotoOffer.build(caps: i.caps, attach: s.attach, attachBlocker: s.attachBlocker, composer: mode, ended: i.ended, staged: i.stagedPhotos)
        return RoomPlan(pinned: pinned, review: review, mode: mode, preview: preview, choice: choice, photos: photos)
    }
}

// MARK: - Banners

/// What the room says above the story when something is off.
struct RoomBanner: Equatable, Identifiable {
    enum Tone: Equatable { case info, warning, error }
    enum Action: Equatable { case retry, repair, openDecision(String) }

    let id: String
    let tone: Tone
    let symbol: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: Action?

    /// Most important first. `pageShownInStory` says the open page's
    /// decision card is already pinned in the story, so no banner repeats it.
    static func build(ended: Bool, availability: SessionAvailability, session: LiveSession, agent: String,
                      pageShownInStory: Bool) -> [RoomBanner] {
        if ended {
            return [RoomBanner(id: "ended", tone: .info, symbol: "checkmark.circle", title: "This session has ended",
                               message: "It's no longer on your Mac's list. The story below is the last one Page received.",
                               actionTitle: nil, action: nil)]
        }
        if availability != .ready {
            let c = SessionAvailabilityCopy(availability)
            return [RoomBanner(id: "availability", tone: c.tone == .error ? .error : (c.tone == .info ? .info : .warning),
                               symbol: c.systemImage, title: c.title,
                               message: c.message.isEmpty ? "Waiting for your Mac…" : c.message,
                               actionTitle: c.action == .retry ? c.actionTitle : (c.action == .repair ? c.actionTitle : nil),
                               action: c.action == .retry ? .retry : (c.action == .repair ? .repair : nil))]
        }
        guard !pageShownInStory else { return [] }
        if let page = session.openPageId {
            return [RoomBanner(id: "page", tone: .warning, symbol: "bell.badge",
                               title: session.state == .waitingOnApproval ? "\(agent) needs your approval" : "\(agent) is waiting for you",
                               message: "Answer the prompt from its decision. Page won't type over a prompt.",
                               actionTitle: "Open decision", action: .openDecision(page))]
        }
        if session.state.isWaiting {
            return [RoomBanner(id: "prompt", tone: .warning, symbol: "bell.badge", title: "\(agent) is showing a prompt",
                               message: "There's no decision for it yet. Answer it on your Mac, or wait a moment for it to arrive.",
                               actionTitle: nil, action: nil)]
        }
        return []
    }
}

// MARK: - Screen

/// How fresh the terminal mirror is. The mirror is re-read every few
/// seconds; if frames stop for 30 s while the agent is busy, the live dot
/// slows and turns amber.
struct ScreenFreshness: Equatable {
    enum Tone: Equatable { case live, slow, quiet }

    let tone: Tone
    /// "LIVE · 2s", "SLOW · 34s", "1m ago".
    let label: String

    static let liveBelow: TimeInterval = 10
    static let slowAfter: TimeInterval = 30

    static func evaluate(frameAt: Date, now: Date, busy: Bool) -> ScreenFreshness {
        let s = max(0, Int(now.timeIntervalSince(frameAt)))
        let t = RelativeTime.compact(seconds: s)
        if Double(s) < liveBelow { return ScreenFreshness(tone: .live, label: "LIVE · \(t)") }
        if busy && Double(s) >= slowAfter { return ScreenFreshness(tone: .slow, label: "SLOW · \(t)") }
        return ScreenFreshness(tone: .quiet, label: busy ? "LIVE · \(t)" : "\(t) ago")
    }
}

// MARK: - Story

/// One step of a turn, read off a tool one-liner ("Bash: npm test",
/// "Edit: Sources/App.swift"). The wire has no result for a step, so nothing
/// like "+42 -6" or an exit code is invented.
struct StoryStep: Equatable, Identifiable {
    enum Kind: String, Equatable { case read, search, edit, shell, web, plan, agent, other }

    let id: String
    let kind: Kind
    /// What the step did, as one line: "Read SessionsView.swift", "swift build".
    let title: String
    /// Shown in monospace (commands, file names).
    let mono: Bool

    var symbol: String {
        switch kind {
        case .read: return "doc.text"
        case .search: return "magnifyingglass"
        case .edit: return "square.and.pencil"
        case .shell: return "terminal"
        case .web: return "globe"
        case .plan: return "checklist"
        case .agent: return "person.2"
        case .other: return "wrench.and.screwdriver"
        }
    }

    static func kind(forTool name: String) -> Kind {
        switch name.lowercased() {
        case "read": return .read
        case "grep", "glob", "ls", "search": return .search
        case "edit", "multiedit", "write", "notebookedit", "apply_patch": return .edit
        case "bash", "shell", "container.exec", "exec_command", "local_shell", "bashoutput", "killshell": return .shell
        case "webfetch", "websearch", "web_search": return .web
        case "update_plan", "todowrite", "exitplanmode": return .plan
        case "task", "agent": return .agent
        default: return .other
        }
    }

    /// Splits "Name: rest" and picks the kind. `tool` is the wire's own
    /// tool name when it carries one.
    static func parse(id: String, text: String, tool: String?) -> StoryStep {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var head: String?
        var rest = t
        if let colon = t.firstIndex(of: ":") {
            let h = String(t[t.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let tail = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // "Bash: npm test", "Edit: Sources/App.swift", "fetch · web: url".
            if !h.isEmpty, h.count <= 40, !h.contains("/"), !h.contains("(") {
                head = h
                rest = tail.isEmpty ? h : tail
            }
        }
        let k = kind(forTool: tool ?? head ?? "")
        let label = head ?? tool ?? ""
        switch k {
        case .shell: return StoryStep(id: id, kind: k, title: rest, mono: true)
        case .read: return StoryStep(id: id, kind: k, title: head == nil ? rest : "Read \(rest)", mono: true)
        case .search: return StoryStep(id: id, kind: k, title: head == nil ? rest : "\(label) \(rest)", mono: true)
        case .edit: return StoryStep(id: id, kind: k, title: head == nil ? rest : "\(label == "Write" ? "Write" : "Edit") \(rest)", mono: true)
        case .web, .plan, .agent: return StoryStep(id: id, kind: k, title: head == nil ? rest : "\(label) \(rest)", mono: false)
        case .other: return StoryStep(id: id, kind: k, title: head == nil ? rest : "\(label) \(rest)", mono: true)
        }
    }

    static func parse(_ e: TranscriptEntry) -> StoryStep { parse(id: e.id, text: e.text, tool: e.tool) }
}

/// A block of the Story, top to bottom.
enum StoryBlock: Identifiable, Equatable {
    /// "12:04" (and "from iPhone" for a message sent from here), before a user turn.
    case divider(id: String, label: String)
    case user(entry: TranscriptEntry, delivery: SentSessionCommand?)
    case pending(SentSessionCommand)
    case assistant(TranscriptEntry)
    /// Consecutive tool calls, grouped. `live` is the trailing group of a busy session.
    case steps(id: String, steps: [StoryStep], live: Bool)
    /// "Interrupted", "Conversation compacted".
    case marker(id: String, text: String)

    var id: String {
        switch self {
        case .divider(let id, _): return "d:" + id
        case .user(let e, _): return "u:" + e.id
        case .pending(let c): return "p:" + c.clientId
        case .assistant(let e): return "a:" + e.id
        case .steps(let id, _, _): return "s:" + id
        case .marker(let id, _): return "m:" + id
        }
    }
}

enum StoryBuilder {
    /// Turns the merged transcript into blocks. Tool calls between two other
    /// entries become one steps block; a user entry starts a new turn with a
    /// time divider; `active` marks the trailing steps block as live. Pure.
    static func build(items: [TranscriptTimeline.Item], active: Bool, timeZone: TimeZone = .current) -> [StoryBlock] {
        var out: [StoryBlock] = []
        var run: [StoryStep] = []
        var runId = ""

        func flush() {
            guard !run.isEmpty else { return }
            out.append(.steps(id: runId, steps: run, live: false))
            run = []
        }
        func stamp(_ at: Date?, fromPhone: Bool) -> String? {
            guard at != nil || fromPhone else { return nil }
            let clock = at.map { NowFormat.clock($0, timeZone: timeZone) }
            return [clock, fromPhone ? "from iPhone" : nil].compactMap { $0 }.joined(separator: " · ")
        }

        for item in items {
            switch item {
            case .entry(let e, let delivery):
                switch e.role {
                case .tool:
                    if run.isEmpty { runId = e.id }
                    run.append(StoryStep.parse(e))
                case .user:
                    flush()
                    if let label = stamp(e.at, fromPhone: delivery != nil) { out.append(.divider(id: e.id, label: label)) }
                    out.append(.user(entry: e, delivery: delivery))
                case .assistant:
                    flush()
                    out.append(.assistant(e))
                case .system:
                    flush()
                    out.append(.marker(id: e.id, text: e.text))
                }
            case .pending(let c):
                flush()
                if let label = stamp(c.sentAt, fromPhone: true) { out.append(.divider(id: c.clientId, label: label)) }
                out.append(.pending(c))
            }
        }
        flush()
        if active, let last = out.indices.last, case .steps(let id, let steps, _) = out[last] {
            out[last] = .steps(id: id, steps: steps, live: true)
        }
        return out
    }

    /// The line at the foot of a busy story: what the agent is doing now.
    /// The Mac's preview is the last tool one-liner while active.
    /// When the trailing block is a live steps card, that card already names what is
    /// running, so the line only says it is still going.
    static func liveLine(session: LiveSession, character: AgentCharacter, trailingStepsAreLive: Bool = false) -> String? {
        guard session.state == .active else { return nil }
        if trailingStepsAreLive { return character.kind == .local ? "Generating…" : "Working…" }
        let p = session.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return character.kind == .local ? "Generating…" : "Working…" }
        return p
    }
}

// MARK: - Workflows

/// A workflow run drawn as a ring of agent nodes. The centre is "4/7" as the
/// footer counts it (finished over started), the nodes are the run's agents.
struct WorkflowOrbit: Equatable {
    enum NodeState: Equatable { case running, done, failed, stopped }

    struct Node: Equatable, Identifiable {
        let id: String
        let label: String
        let state: NodeState
        /// Radians, from 12 o'clock, clockwise.
        let angle: Double
    }

    let name: String
    let nodes: [Node]
    let done: Int
    let total: Int
    /// "4/7".
    let centre: String
    /// "agents done".
    let caption: String
    /// "phase Verify · 2m 10s · 184k tokens".
    let meta: String
    let statusLabel: String
    let isRunning: Bool

    /// Most nodes drawn; more would only be dots on dots.
    static let maxNodes = 24

    static func nodeState(_ agent: WorkflowRun.Agent) -> NodeState {
        if agent.running { return .running }
        switch agent.state {
        case "done": return .done
        case "failed": return .failed
        default: return .stopped
        }
    }

    static func build(run: WorkflowRun, now: Date) -> WorkflowOrbit {
        // Running agents first, so the ones to watch sit at the top of the ring.
        let ordered = run.agents.enumerated().sorted { a, b in
            let ra = a.element.running ? 0 : 1, rb = b.element.running ? 0 : 1
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element).prefix(maxNodes)
        let n = max(1, ordered.count)
        let nodes = ordered.enumerated().map { i, a in
            Node(id: a.id, label: a.label, state: nodeState(a), angle: Double(i) / Double(n) * 2 * .pi)
        }
        var meta: [String] = []
        if let phase = run.phase { meta.append("phase \(phase)") }
        if let start = run.startedAt { meta.append(WorkflowRun.duration((run.endedAt ?? now).timeIntervalSince(start))) }
        if let t = run.tokens { meta.append(WorkflowRun.tokens(t)) }
        return WorkflowOrbit(name: run.name, nodes: nodes, done: run.done, total: run.total, centre: "\(run.done)/\(run.total)",
                             caption: "agents done", meta: meta.joined(separator: " · "), statusLabel: run.statusLabel,
                             isRunning: run.isRunning)
    }

    /// "2 finished today · design-pass ✓ · port-android ✓", or nil.
    static func finishedLine(runs: [WorkflowRun], now: Date, calendar: Calendar = .current) -> String? {
        let start = calendar.startOfDay(for: now)
        let finished = runs.filter { !$0.isRunning && ($0.endedAt ?? .distantPast) >= start && $0.status == "completed" }
        guard !finished.isEmpty else { return nil }
        let names = finished.prefix(3).map { "\($0.name) ✓" }
        return (["\(finished.count) finished today"] + names).joined(separator: " · ")
    }

    /// Agents of a run, grouped as the run screen lists them: running, then
    /// failed or stopped, then done. Pure.
    static func groups(_ run: WorkflowRun) -> [(title: String, agents: [WorkflowRun.Agent])] {
        let running = run.agents.filter(\.running)
        let other = run.agents.filter { !$0.running && $0.state != "done" }
        let done = run.agents.filter { $0.state == "done" }
        return [("Running", running), ("Failed or didn't finish", other), ("Done", done)].filter { !$0.1.isEmpty }
    }
}

/// A workflow agent's room: the task it was given, then its steps and words.
/// Read-only: workflow agents are never typed into.
struct AgentRoomModel: Equatable {
    let task: String?
    let blocks: [StoryBlock]
    /// Older steps were dropped to fit the snapshot.
    let truncated: Bool

    static func build(entries: [TranscriptEntry], finished: Bool, truncated: Bool = false) -> AgentRoomModel {
        let task = entries.first { $0.role == .user }?.text
        // The task is shown once, above the story, wherever it sits in the transcript.
        let rest = entries.filter { !($0.role == .user && $0.text == task) }
        let blocks = StoryBuilder.build(items: rest.map { .entry($0, delivery: nil) }, active: !finished)
        return AgentRoomModel(task: task, blocks: blocks, truncated: truncated)
    }

    static let readOnlyNote = "Workflow agents are read-only. Steer the parent session instead."
}

// MARK: - Changes

/// The Changes lens: the files a turn (or the repository) changed, with
/// +/− counts, as rows, and the patch split into lines of a kind.
struct ChangesModel: Equatable {
    struct FileRow: Equatable, Identifiable {
        let path: String
        let added: Int?
        let removed: Int?
        let status: String
        var id: String { path }

        var symbol: String {
            switch status {
            case "added": return "plus.circle"
            case "modified": return "pencil.circle"
            default: return "circle.dashed"
            }
        }
    }

    enum LineKind: Equatable { case hunk, added, removed, context }

    /// One file's part of the patch.
    struct Section: Equatable, Identifiable {
        let path: String
        let lines: [String]
        var id: String { path.isEmpty ? "patch" : path }
    }

    /// "THIS TURN" or "UNCOMMITTED CHANGES".
    let scopeLabel: String
    let repo: String?
    let files: [FileRow]
    let sections: [Section]
    let added: Int
    let removed: Int
    /// Share of the change that is additions, 0...1 (the green part of the bar).
    let addedFraction: Double
    let truncated: Bool
    let note: String?
    let emptyText: String?

    var fileCountText: String { "\(files.count) file\(files.count == 1 ? "" : "s")" }

    /// Patch sections that no file row names (a path-less patch, a rename, a
    /// path with spaces): they are still shown, after the file list, so the
    /// diff is never shorter than what the Mac sent.
    var unmatchedSections: [Section] {
        let known = Set(files.map(\.path))
        return sections.filter { !known.contains($0.path) && !$0.lines.isEmpty }
    }

    static func build(_ d: SessionDiff) -> ChangesModel {
        let total = d.added + d.removed
        return ChangesModel(
            scopeLabel: d.scope == "turn" ? "THIS TURN" : "UNCOMMITTED CHANGES", repo: d.repo,
            files: d.files.map { FileRow(path: $0.path, added: $0.added, removed: $0.removed, status: $0.status) },
            sections: d.sections.map { Section(path: $0.path, lines: $0.lines) },
            added: d.added, removed: d.removed, addedFraction: total > 0 ? Double(d.added) / Double(total) : 1,
            truncated: d.truncated, note: d.note,
            emptyText: d.files.isEmpty && d.note == nil
                ? (d.scope == "turn" ? "This turn didn't change any files." : "No uncommitted changes.") : nil)
    }

    /// How a patch line is drawn. File headers (+++/---) are context, not changes. Pure.
    static func lineKind(_ line: String) -> LineKind {
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return .added }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return .removed }
        return .context
    }

    /// The text "Ask about this" and a long-press on a file put in the
    /// composer. It is only a draft: nothing is sent until you send it.
    static func question(about path: String?) -> String {
        guard let path, !path.isEmpty else { return "Why did you make these changes?" }
        return "Why did you change \(path)?"
    }

    /// Where the Changes lens stands while it waits for the Mac.
    enum Load: Equatable {
        case loading
        case noAnswer
        case failed(String)
        case loaded
    }

    static let noAnswerAfter: TimeInterval = 20

    static func load(hasDiff: Bool, error: String?, requestedAt: Date, now: Date) -> Load {
        if hasDiff { return .loaded }
        if let error { return .failed(error) }
        return now.timeIntervalSince(requestedAt) > noAnswerAfter ? .noAnswer : .loading
    }
}

// MARK: - Terminal mirror

/// How a line of the terminal mirror is tinted, read off Claude Code's own
/// glyphs: a finished tool call green, a spinner line amber, the footer's
/// auto-mode row violet, rules and continuations quiet. Anything else is
/// plain text. Pure.
enum TerminalTone: Equatable {
    case tool, busy, footer, prompt, quiet, plain

    static func classify(_ line: String) -> TerminalTone {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let first = t.unicodeScalars.first else { return .plain }
        if t.count >= 8, t.unicodeScalars.allSatisfy({ (0x2500...0x257F).contains($0.value) || $0 == "-" || $0 == "=" || $0 == "_" || $0 == " " }) { return .quiet }
        switch first {
        case "\u{23FA}", "\u{25CF}": return .tool          // ⏺ ●
        case "\u{273B}", "\u{2736}", "\u{2733}", "\u{2722}", "\u{00B7}", "\u{2217}": return t.contains("…") || t.contains("esc to interrupt") ? .busy : .plain
        case "\u{23F5}", "\u{25B6}", "\u{25B8}": return .footer // ⏵ ▶ ▸
        case "\u{23BF}", "\u{2514}", "\u{2502}": return .quiet   // ⎿ └ │
        case "\u{276F}", ">": return .prompt                 // ❯
        default: return .plain
        }
    }
}
