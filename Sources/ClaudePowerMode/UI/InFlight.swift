import Foundation

// The pure side of the popover's "In flight" group: sessions that are working
// right now, as cards you can click. Each card can open the session's terminal
// (the existing O path, TerminalFocus) or steer it with a typed message (the
// existing local session input path, SessionRemote.performLocal). No clock, host,
// bridge or UserDefaults.standard inside: the model, the store, the menu and
// the tests feed it values.

// MARK: - Key names

/// The keys the panel's actions answer to, in one place: the shortcut
/// catalog, the labelled buttons and the key handler all read these, so a
/// button can never name a key the catalog does not list.
enum PanelKeys {
    static let open = "O"
    /// Steer: a message to a working session, or a reply to a waiting page.
    static let steer = "T"
    /// The older name for `steer`.
    static let type = steer
    static let help = "?"
}

extension KeyHint.Action {
    /// What a button for this action says, in words. Keys are never drawn
    /// beside it: they live in `tooltip` and the shortcuts sheet.
    var title: String {
        switch self {
        case .approve: return "Approve"
        case .approveHold: return "Hold to approve"
        case .deny: return "Deny"
        case .tellInstead: return "Steer"
        case .openTerminal: return "Open"
        }
    }

    /// What the action does, for the tooltip after its key.
    var effect: String {
        switch self {
        case .approve: return "types option 1"
        case .approveHold: return "hold, then Touch ID · types option 1"
        case .deny: return "presses Esc"
        case .tellInstead: return "Esc, your words, then Return"
        case .openTerminal: return "shows its terminal pane, types nothing"
        }
    }

    /// The tooltip for a button: its name, its key and what it sends, as
    /// "Open · O · shows its terminal pane, types nothing".
    func tooltip(key: String) -> String { "\(title) · \(key) · \(effect)" }
}

/// The two things a working session's card can do.
enum InFlightAction: Equatable {
    case open, steer

    /// What the button says.
    var title: String {
        switch self {
        case .open: return "Open"
        case .steer: return "Steer"
        }
    }

    /// The key that does it, shown only in the tooltip and the shortcuts sheet.
    var key: String {
        switch self {
        case .open: return PanelKeys.open
        case .steer: return PanelKeys.steer
        }
    }

    var tooltip: String {
        switch self {
        case .open: return "Open · \(key) · shows its terminal pane, types nothing"
        case .steer: return "Steer · \(key) · a message to this session, sent with Return"
        }
    }
}

// MARK: - Where a message goes

/// The session a typed message is for, captured when the composer opens: the
/// folder and title are those this Mac listed, so the input path can refuse
/// when the session behind the id no longer matches (`SessionTargetCheck`).
struct InFlightTarget: Equatable {
    let sessionId: String
    let backend: AgentBackendID
    /// `SessionRemote.homeAbbreviated(cwd)`: the form the check compares.
    let expectCwd: String?
    let expectTitle: String?

    init(sessionId: String, backend: AgentBackendID, expectCwd: String?, expectTitle: String?) {
        self.sessionId = sessionId
        self.backend = backend
        self.expectCwd = expectCwd
        self.expectTitle = expectTitle
    }

    init(session s: AgentSession) {
        self.init(sessionId: s.sessionId, backend: s.backend,
                  expectCwd: s.cwd.map { String(SessionRemote.homeAbbreviated($0).prefix(SessionRemote.maxCwd)) },
                  expectTitle: String((s.title ?? SessionRemote.folderTitle(s.cwd) ?? s.backend.rawValue).prefix(SessionRemote.maxTitle)))
    }

    /// Pure. The command for typing `text` here: the phone's `input` op (a
    /// plain message the input gate delivers, queued behind a busy turn),
    /// never `custom` and never anything that presses Esc. `SessionRemote
    /// .performLocal` marks it local; a phone command can never claim that.
    func command(text: String, clientId: String = "mac-\(UUID().uuidString)", ts: Double) -> SessionCommand {
        var cmd = SessionCommand(op: "input", clientId: clientId, ts: ts, viewer: nil, sessionId: sessionId, text: text)
        cmd.expectCwd = expectCwd
        cmd.expectTitle = expectTitle
        return cmd
    }
}

// MARK: - What a row can do

/// Which of the two actions a working session offers, and why not.
struct InFlightActions: Equatable {
    var canOpen: Bool
    /// Why Open is unavailable (shown instead of promising a window).
    var openBlocker: String?
    var canType: Bool
    /// Why Type is unavailable.
    var typeBlocker: String?
    /// Not probed yet: Open still works (it finds the pane itself), Type waits.
    var checking = false

    static let none = InFlightActions(canOpen: false, openBlocker: nil, canType: false, typeBlocker: nil)

    /// Pure. Open needs a host Page can bring forward; Type needs one it can
    /// type into. A session with no terminal (a background run, the Codex
    /// app) has nothing to open; an unprobed one can be opened but not yet
    /// typed into.
    static func resolve(host: SessionHostInfo?) -> InFlightActions {
        guard let host else {
            return InFlightActions(canOpen: true, openBlocker: nil, canType: false,
                                   typeBlocker: SessionHostInfo.checking.typeBlocker, checking: true)
        }
        let focusable: Bool
        var openBlocker: String?
        switch host.host {
        case "background":
            focusable = false
            openBlocker = "Nothing to open · it runs in the background, with no terminal"
        case "desktop":
            focusable = false
            openBlocker = "Nothing to open · it runs in the Codex app, not a terminal"
        default:
            focusable = true
        }
        return InFlightActions(canOpen: focusable, openBlocker: openBlocker, canType: host.canType,
                               typeBlocker: host.canType ? nil : (host.typeBlocker ?? "Page can't type into this session"))
    }

    /// Local models are not terminals Page can focus or type into.
    static let localModel = InFlightActions(
        canOpen: false, openBlocker: "Page can't open a local model's window",
        canType: false, typeBlocker: "Page can't type into a local model")
}

// MARK: - The row

struct InFlightRow: Equatable, Identifiable {
    enum Kind: Equatable { case session, localModel }

    /// Row ids carry this prefix, so a selection can never be mistaken for a page id.
    static let idPrefix = "inflight-"

    let id: String
    /// The session id (or the local activity's id).
    let sessionId: String
    let kind: Kind
    let project: String
    let backend: AgentBackendID?
    /// "cmux › page"; nil when Page can't name where it runs.
    let route: String?
    /// "Bash: swift test", or "working".
    let doing: String
    let since: Date?
    /// "4m": how long it has been working, as of the model's clock.
    let elapsed: String?
    let actions: InFlightActions
    let target: InFlightTarget?
    /// False once the turn has ended while a draft or receipt kept the row
    /// (the preview then no longer says "queues after this step").
    var working = true
    /// What the card shows: the step in words, the times, workflows, health.
    var card: InFlightCardInfo = .empty
    /// Messages a phone asked to type once this turn ends, oldest first.
    var held: [InFlightHeld] = []

    /// A session's card (a local model has only a compact row).
    var hasCard: Bool { kind == .session }

    var hasActions: Bool { actions.canOpen || actions.canType || actions.checking }

    var accessibilityText: String {
        guard hasCard else {
            return [project, route, doing, elapsed.map { "working for \($0)" }].compactMap { $0 }.joined(separator: ", ")
        }
        return [project, card.backendName, route, card.model, card.now, card.timeLine,
                card.workflowsHeading, card.healthLine]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// The row as it stands once its turn has ended.
    var finished: InFlightRow {
        InFlightRow(id: id, sessionId: sessionId, kind: kind, project: project, backend: backend, route: route,
                    doing: "no longer working", since: since, elapsed: elapsed, actions: actions, target: target,
                    working: false, card: card, held: held)
    }
}

/// A message a phone asked Page to type once the session's turn ends, as
/// its card shows it, with a Delete (the phone's `retract`).
struct InFlightHeld: Equatable, Identifiable {
    let clientId: String
    /// Redacted and clipped.
    let text: String
    let heldAt: Date
    /// Being typed right now: Delete may come too late.
    var typing = false

    var id: String { clientId }

    static let maxText = 60

    /// Pure. "Held from your phone · “Then run the linter” · 4m".
    func line(now: Date) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        let quoted = "“" + (t.count <= Self.maxText ? t : String(t.prefix(Self.maxText - 1)) + "…") + "”"
        let head = typing ? "Typing it now" : "Held from your phone"
        return [head, quoted, InFlightRows.elapsed(since: heldAt, now: now)].joined(separator: " · ")
    }

    var deleteHelp: String {
        typing ? "Delete · Page is typing it now, so this may be too late"
               : "Delete · Page won't type it when the turn ends"
    }
}

enum InFlightRows {
    static let workingText = "working"
    static let maxDoing = 72

    /// Pure. Working sessions (and busy local models) as rows, by project
    /// name (then id): a stable order, the same on the phone.
    /// `hosts`, `activity`, `busySince` and `facts` are what the Mac probed off the main thread (where each runs; its last tool step; when
    /// its turn began, only where the session file says so; the card's facts):
    /// a session with none is still listed, as "working", openable and not yet
    /// typable, with no elapsed time rather than a guessed one.
    static func build(_ s: Coordinator.Snapshot, hosts: [String: SessionHostInfo], activity: [String: String],
                      busySince: [String: Date] = [:], facts: [String: InFlightFacts] = [:], now: Date) -> [InFlightRow] {
        var rows: [InFlightRow] = s.sessions.filter { $0.state == .active }.map { a in
            let project = NowModel.projectName(of: a)
            let host = hosts[a.sessionId].map { SessionRemote.effectiveHost($0, backend: a.backend, state: a.state) }
            let f = facts[a.sessionId]
            let step = activity[a.sessionId] ?? f?.currentStep?.text
            let doing = step
                .map { InterventionDetector.clip($0.trimmingCharacters(in: .whitespacesAndNewlines), maxDoing) }
                .flatMap { $0.isEmpty ? nil : $0 } ?? workingText
            let since = f?.busySince ?? busySince[a.sessionId]
            var known = f ?? InFlightFacts()
            known.busySince = since
            let signals = signals(for: a.sessionId, in: s)
            return InFlightRow(
                id: InFlightRow.idPrefix + a.sessionId, sessionId: a.sessionId, kind: .session, project: project,
                backend: a.backend,
                route: host.flatMap { TerminalFocus.routeLabel(host: $0.host, project: project) },
                doing: doing, since: since, elapsed: since.map { elapsed(since: $0, now: now) },
                actions: .resolve(host: host), target: InFlightTarget(session: a),
                card: .make(facts: known, backend: a.backend, stuckDetail: signals.stuck, rateLimitResetsAt: signals.rateLimit,
                            fallbackStep: step, now: now),
                held: s.held.filter { $0.sessionId == a.sessionId }
                    .map { InFlightHeld(clientId: $0.clientId, text: $0.text, heldAt: $0.heldAt, typing: $0.typing) })
        }
        rows += s.localModels.filter(\.busy).map { l in
            InFlightRow(
                id: InFlightRow.idPrefix + "local-" + l.id, sessionId: l.id, kind: .localModel, project: l.displayName,
                backend: nil, route: nil,
                doing: l.detail.trimmingCharacters(in: .whitespaces).isEmpty ? workingText : l.detail,
                since: nil, elapsed: nil, actions: .localModel, target: nil)
        }
        // One stable order on every platform: project name, then id. Elapsed time
        // and activity never reorder rows, so a click lands on the row you aimed at.
        return rows.sorted { a, b in
            let c = a.project.localizedCaseInsensitiveCompare(b.project)
            return c == .orderedSame ? a.id < b.id : c == .orderedAscending
        }
    }

    /// Pure. What the existing detection already says about a session: the stuck
    /// watch's open page (its one-line finding), and an active rate limit's reset.
    static func signals(for sessionId: String, in s: Coordinator.Snapshot) -> (stuck: String?, rateLimit: Date?) {
        let stuck = s.pendingInterventions
            .filter { $0.sessionId == sessionId && StuckWatch.subtypes.contains($0.subtype ?? "") }
            .max { $0.openedAt < $1.openedAt }
            .map { NowModel.summaryLine(for: $0) }
        let rate = s.activeRateLimit.flatMap { $0.sessionId == sessionId ? $0.resetTime : nil }
        return (stuck, rate)
    }

    /// Pure. "42s", "4m", "1h 12m": short, for a row's trailing edge.
    static func elapsed(since: Date, now: Date) -> String {
        let t = max(0, Int(now.timeIntervalSince(since)))
        if t < 60 { return "\(t)s" }
        let m = t / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60, rest = m % 60
        return rest == 0 ? "\(h)h" : "\(h)h \(rest)m"
    }
}

extension NowModel {
    /// Pure. The name a working session goes by: its folder's project, else its title.
    static func projectName(of a: AgentSession) -> String {
        a.cwd.map { InterventionDetector.projectName(forCwd: $0, fallback: a.title) } ?? a.title ?? a.sessionId
    }
}

// MARK: - The group's layout

enum InFlightLayout {
    /// Rows shown before "+N more".
    static let cap = 3

    /// Pure. Which rows the group draws. Collapsed: none (the header names
    /// them). Otherwise the first `cap`, or all once expanded.
    static func visible(_ rows: [InFlightRow], collapsed: Bool, expanded: Bool) -> (shown: [InFlightRow], more: Int) {
        if collapsed { return ([], rows.count) }
        if expanded || rows.count <= cap { return (rows, 0) }
        return (Array(rows.prefix(cap)), rows.count - cap)
    }

    /// The id the header jump scrolls to: the top of the group.
    static let anchorId = "inflight-group"

    /// Pure. "In flight · 2".
    static func title(count: Int) -> String { "In flight · \(count)" }

    /// Pure. "Show all 5".
    static func showAllTitle(total: Int) -> String { "Show all \(total)" }

    /// Pure. One line over the cards, the holistic view in a glance:
    /// "2 working · 3 workflows running · 1 looks stuck".
    static func summary(_ rows: [InFlightRow]) -> String {
        let live = rows.filter(\.working)
        guard !live.isEmpty else { return "" }
        var parts = ["\(live.count) working"]
        let workflows = live.reduce(0) { $0 + $1.card.workflows.count }
        if workflows > 0 { parts.append("\(workflows) workflow\(workflows == 1 ? "" : "s") running") }
        let stuck = live.filter { if case .looksStuck = $0.card.health { return true } else { return false } }.count
        if stuck > 0 { parts.append("\(stuck) look\(stuck == 1 ? "s" : "") stuck") }
        let limited = live.filter { if case .rateLimited = $0.card.health { return true } else { return false } }.count
        if limited > 0 { parts.append("\(limited) rate limited") }
        return parts.joined(separator: " · ")
    }

    /// Pure. "bottle-flip · page · llm-play": the first few, for the collapsed header.
    static func names(_ rows: [InFlightRow], max: Int = 3) -> String {
        rows.prefix(max).map(\.project).joined(separator: " · ")
    }
}

// MARK: - "N working" jumps to the cards

/// The "N working" in the header: split out of the headline or subline so it
/// can be a button, and what pressing it does.
enum WorkingPhrase {
    struct Split: Equatable {
        let before: String
        /// "5 working".
        let token: String
        let after: String
    }

    /// Pure. The first "<n> working" in a line, with the text either side;
    /// nil when the line has none ("All quiet", "Paused at 10%").
    static func split(_ text: String) -> Split? {
        guard let r = text.range(of: #"\b\d+ working\b"#, options: .regularExpression) else { return nil }
        return Split(before: String(text[..<r.lowerBound]), token: String(text[r]), after: String(text[r.upperBound...]))
    }
}

enum InFlightJump {
    struct Plan: Equatable {
        /// The group was collapsed: open it.
        var uncollapse: Bool
        /// The shortcuts sheet is covering the rows: close it.
        var closeShortcuts: Bool
        /// The card to select (the first), so it shows it was the target.
        var selectId: String
        /// What to scroll into view.
        var scrollTo: String
    }

    /// Pure. What a press on "N working" does: bring the cards into view
    /// (uncollapsed, the sheet closed), select the first, scroll to the group.
    /// nil when nothing is in flight.
    static func plan(rows: [InFlightRow], state: NowPanelState) -> Plan? {
        guard let first = rows.first else { return nil }
        return Plan(uncollapse: state.inFlightCollapsed, closeShortcuts: state.showShortcuts, selectId: first.id,
                    scrollTo: InFlightLayout.anchorId)
    }
}

// MARK: - The composer's live preview

enum InFlightPreview {
    struct Line: Equatable {
        let text: String
        /// False when the message would be refused (drawn in amber).
        let ok: Bool
    }

    static let queuesText = "queues after this step"

    /// Pure. What pressing Return would do, as the person types. The same
    /// rules the input gate applies, so the preview never promises a send
    /// the gate will refuse.
    static func line(for row: InFlightRow, text: String, macName: String) -> Line {
        guard row.actions.canType else {
            return Line(text: "Can't steer here · \(row.actions.typeBlocker ?? "Page can't type into this session")", ok: false)
        }
        let place = row.route ?? row.project
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let tail = row.working ? queuesText : macName
            return Line(text: "Type a message · Return sends · \(place) · \(tail)", ok: true)
        }
        if trimmed.count > SessionInputGate.maxTextLength {
            return Line(text: "Too long · \(SessionInputGate.maxTextLength) characters at most", ok: false)
        }
        if row.working, row.backend == .claude, SessionInputGate.startsWithDigit(trimmed) {
            return Line(text: SessionInputGate.digitWhileBusyMessage, ok: false)
        }
        let tail = row.working ? queuesText : macName
        return Line(text: "Will type · Return · \(place) · \(tail)", ok: true)
    }
}

// MARK: - The receipt in the row

/// What happened to a message typed from a row: shown in the row itself.
struct InFlightReceipt: Equatable {
    enum Outcome: Equatable {
        case sending
        case typed
        case queued
        case refused(String)
        /// No answer from the input path in time. The text may still land, so this
        /// is not a refusal: a late result replaces it.
        case unconfirmed
    }

    let outcome: Outcome
    let route: String?
    let at: Date

    /// Drawn in amber: a refusal, or no answer yet.
    var failed: Bool {
        switch outcome {
        case .refused, .unconfirmed: return true
        default: return false
        }
    }

    /// Pure. "Typed · cmux › page · 23:47:12", "Queued · …", "Refused · why".
    func line(timeZone: TimeZone = .current) -> String {
        let clock = NowModel.clock(at, seconds: true, timeZone: timeZone)
        switch outcome {
        case .sending: return "Typing…"
        case .typed: return ["Typed", route, clock].compactMap { $0 }.joined(separator: " · ")
        case .queued: return ["Queued", route, "read after the current step"].compactMap { $0 }.joined(separator: " · ")
        case .refused(let why): return "Refused · " + (why.isEmpty ? "Couldn't type into the session" : why)
        case .unconfirmed: return "No answer yet · check the terminal before retyping"
        }
    }

    /// Pure. The input path's result as a receipt.
    static func from(_ r: SessionCommandResult, route: String?, at: Date) -> InFlightReceipt {
        switch r.code {
        case .delivered: return InFlightReceipt(outcome: .typed, route: route, at: at)
        case .queued: return InFlightReceipt(outcome: .queued, route: route, at: at)
        case .refused, .failed, .cancelled:
            return InFlightReceipt(outcome: .refused(r.detail.trimmingCharacters(in: .whitespacesAndNewlines)), route: route, at: at)
        }
    }
}

// MARK: - The classic menu

/// One working session in the classic right-click menu: a submenu titled
/// with the project and route, holding "Open" and "Steer…".
struct InFlightMenuEntry: Equatable {
    let sessionId: String
    /// "page — cmux › page · 4m".
    let title: String
    /// "Bash: swift test".
    let doing: String
    let openEnabled: Bool
    let openNote: String?
    let typeEnabled: Bool
    let typeNote: String?
    let backend: AgentBackendID
}

enum InFlightMenu {
    static let sectionTitle = "In flight"
    static let openTitle = "Open"
    static let typeTitle = "Steer…"

    /// Pure. One entry per working session (local models have no terminal to
    /// open or type into, so they are not listed). Type… stays enabled while
    /// the host is unprobed: it opens the panel, which finishes the check.
    /// `fresh` false: the step and elapsed time were read a while ago (the panel
    /// has not been open), so they are left out rather than shown stale.
    static func entries(_ rows: [InFlightRow], fresh: Bool = true) -> [InFlightMenuEntry] {
        rows.compactMap { r in
            guard r.kind == .session, let backend = r.backend else { return nil }
            let head = r.route.map { "\(r.project) — \($0)" } ?? r.project
            return InFlightMenuEntry(
                sessionId: r.sessionId, title: [head, fresh ? r.elapsed : nil].compactMap { $0 }.joined(separator: " · "),
                doing: fresh ? r.doing : "working", openEnabled: r.actions.canOpen, openNote: r.actions.openBlocker,
                typeEnabled: r.actions.canType || r.actions.checking,
                typeNote: r.actions.canType || r.actions.checking ? nil : r.actions.typeBlocker, backend: backend)
        }
    }
}

// MARK: - Remembered choices

/// What the panel remembers between launches: the first-run tip, and whether
/// the In-flight group is collapsed. Kept in UserDefaults (never config.json).
/// The defaults object is injected so tests and the render harness never touch
/// the real app's.
struct NowPrefs {
    private let read: (String) -> Bool
    private let write: (String, Bool) -> Void

    static let tipKey = "nowPanel.rowActionsTipDismissed"
    static let collapsedKey = "nowPanel.inFlightCollapsed"

    init(defaults: UserDefaults) {
        read = { defaults.bool(forKey: $0) }
        write = { defaults.set($1, forKey: $0) }
    }

    private init(read: @escaping (String) -> Bool, write: @escaping (String, Bool) -> Void) {
        self.read = read
        self.write = write
    }

    static var standard: NowPrefs { NowPrefs(defaults: .standard) }

    private final class Flags { var values: [String: Bool] = [:] }

    /// A throwaway store (render harness and tests): kept in memory, so it
    /// never reaches the real app's defaults and never leaves a file behind.
    /// Copies of one value share it, as copies of the real store do.
    static func ephemeral() -> NowPrefs {
        let flags = Flags()
        return NowPrefs(read: { flags.values[$0] ?? false }, write: { flags.values[$0] = $1 })
    }

    /// This store with the first-run tip already dismissed (harness fixtures).
    func dismissingTip() -> NowPrefs {
        tipDismissed = true
        return self
    }

    var tipDismissed: Bool {
        get { read(Self.tipKey) }
        nonmutating set { write(Self.tipKey, newValue) }
    }

    var inFlightCollapsed: Bool {
        get { read(Self.collapsedKey) }
        nonmutating set { write(Self.collapsedKey, newValue) }
    }
}

enum PanelTip {
    static let text = "Click a row for actions · \(PanelKeys.help) shows every shortcut"

    /// Pure. The tip shows the first time the panel has a decision or an
    /// in-flight row to act on, and never again once dismissed.
    static func shouldShow(dismissed: Bool, hasDecisionRows: Bool, hasInFlightRows: Bool) -> Bool {
        !dismissed && (hasDecisionRows || hasInFlightRows)
    }
}
