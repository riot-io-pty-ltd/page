import Foundation

// The In flight section of Now: one card per working session, each with two
// plain ways in, in words (Open: watch the terminal, Steer: type to it). Pure
// values, no clock inside, so the logic tests can feed any situation.

/// How a session's room opens. A tap on the card is Story; its two buttons
/// say "Open" (the Screen lens) and "Steer" (the composer); the long-press
/// menu's Stop opens the room where the existing 10 s hold-to-stop lives.
/// Nothing here sends anything: Steer only brings up the composer, and Return
/// still goes through `RoomSend`.
enum RoomEntry: String, Equatable, CaseIterable {
    case story, screen, type, stop

    /// The lens the room starts on. Screen falls back to Story until the Mac
    /// has sent a mirror (`RoomLens.resolve`).
    var lens: RoomLens { self == .screen ? .screen : .story }
    /// The composer takes the keyboard when the room opens.
    var focusesComposer: Bool { self == .type }
    /// The room says what the Stop hold will do while it is being found.
    var showsStopHint: Bool { self == .stop }

    /// What the button says. The cases keep their names; the words are the Mac's.
    var buttonTitle: String {
        switch self {
        case .story: return "Story"
        case .screen: return "Open"
        case .type: return "Steer"
        case .stop: return "Stop"
        }
    }
}

/// A session working right now, as one row.
struct InFlightRow: Equatable, Identifiable {
    let id: String
    let project: String
    /// "Claude", "Codex", "Ollama".
    let character: String
    let characterKind: AgentCharacter.Kind
    /// "cmux › page": the terminal and the project; nil when neither is known.
    let route: String?
    /// "cmux": the terminal alone, for the row's small print (the project is already its title).
    let host: String?
    /// What it is doing, clipped: "[Bash] vitest · 212 passed".
    let step: String
    /// "4m": how long since it last did something. The Mac does not send a
    /// start time, so this is the time since its last step, never "elapsed".
    let age: String?
    /// "4 of 7", for a session running a workflow.
    let progress: String?
    let seed: UInt64
    let hue: ProjectHue
    /// Page can type in this terminal (the Mac's word).
    let canType: Bool
    /// Page can press Esc in this terminal mid-turn (the Mac's word).
    let canStop: Bool
    /// This terminal can send a screen mirror (tmux, cmux, WezTerm, kitty, Herdr).
    let canMirror: Bool
    /// The step in words, the steps before it, the clocks, workflows and health.
    var card: InFlightCard = InFlightCard(now: "Working")

    /// The spoken line: "relay, Claude in tmux, Running vitest, working 4m, 1 workflow running".
    var spoken: String {
        var parts = [project, route.map { "\(character) in \($0)" } ?? character, card.now]
        if let health = card.health.label { parts.append(health) }
        if let t = card.timeText { parts.append(t) }
        if let w = card.workflowHeading { parts.append(w) }
        else if let progress { parts.append(progress) }
        return parts.joined(separator: ", ")
    }
}

/// The section as drawn: the visible rows, how many there are in all and how
/// many a cap hides.
struct InFlightSection: Equatable {
    var rows: [InFlightRow]
    var total: Int
    var hidden: Int { max(0, total - rows.count) }
    var isExpanded: Bool
    /// Every working session, in the same order: the side-scroll strip above the
    /// cards, which stays whole when a cap hides some cards.
    var strip: [InFlightRow] = []

    static let empty = InFlightSection(rows: [], total: 0, isExpanded: false)
    /// Rows shown before "Show all N".
    static let collapsedLimit = 3
    /// Hosts the Mac can mirror the screen of.
    static let mirrorHosts: Set<String> = ["tmux", "cmux", "wezterm", "kitty", "herdr", "claude squad"]

    var isCapped: Bool { total > Self.collapsedLimit }
    /// The strip is a summary of two or more; one session is just its card.
    var showsStrip: Bool { strip.count > 1 }
    var showAllLabel: String { "Show all \(total)" }

    /// Working sessions in a steady order (project, then title, then id), so a
    /// row never swaps places under a finger between two refreshes: a Type tap
    /// always lands on the session it was drawn beside. Only once the Mac's
    /// session list has arrived. Pure.
    static func build(sessions: [LiveSession], hasSessionList: Bool, workflows: [String: [WorkflowRun]] = [:], stuck: Set<String> = [], now: Date,
                      expanded: Bool = false, limit: Int = collapsedLimit) -> InFlightSection {
        guard hasSessionList else { return .empty }
        let active = sessions.filter { $0.state == .active }.map { s -> (InFlightRow, String) in
            let project = SkyModel.projectName(cwd: s.cwd, fallback: s.title)
            let run = workflows[s.id]?.first { $0.isRunning }
            let host = s.host.trimmingCharacters(in: .whitespaces).lowercased()
            let who = AgentCharacter.from(backend: s.backend, provider: s.provider)
            let row = InFlightRow(
                id: s.id, project: project, character: who.name, characterKind: who.kind,
                route: DeliveryPreview.route(host: s.host, project: project), host: DeliveryPreview.route(host: s.host, project: nil),
                step: s.preview.isEmpty ? "working" : SkyModel.clip(s.preview, 80),
                age: s.lastActivityAt.map { RelativeTime.compact(seconds: Int(max(0, now.timeIntervalSince($0)))) },
                progress: run.map { "\($0.done) of \($0.total)" },
                seed: StableHash.fnv1a(s.cwd.isEmpty ? s.id : s.cwd + "|" + s.id),
                hue: ProjectHue(key: s.cwd.isEmpty ? s.title : s.cwd),
                canType: s.canType, canStop: s.canInterrupt, canMirror: mirrorHosts.contains(host),
                card: InFlightCard.build(session: s, runs: workflows[s.id] ?? [], hasStuckPage: stuck.contains(s.id), now: now))
            return (row, s.title)
        }
        .sorted { a, b in
            let p = a.0.project.localizedCaseInsensitiveCompare(b.0.project)
            if p != .orderedSame { return p == .orderedAscending }
            let t = a.1.localizedCaseInsensitiveCompare(b.1)
            if t != .orderedSame { return t == .orderedAscending }
            return a.0.id < b.0.id
        }
        .map(\.0)
        let capped = !expanded && active.count > limit
        return InFlightSection(rows: capped ? Array(active.prefix(limit)) : active, total: active.count, isExpanded: expanded && active.count > limit,
                               strip: active)
    }
}
