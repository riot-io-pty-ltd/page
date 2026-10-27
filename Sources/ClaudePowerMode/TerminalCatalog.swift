import Foundation

/// Every terminal (or terminal multiplexer) Page can type into, as plain
/// values: what Page can do in each, what it needs, and the status line the
/// Tower's Terminals page shows. Nothing here touches the machine: the facts
/// (is it installed, how many sessions run in it, is its setup done) are
/// gathered by `TerminalProbe` and handed in, so every sentence is testable.
///
/// The capabilities come from the code, not from memory:
///   - reply: every host in `InjectionExecutor.TerminalHost`;
///   - see the screen on the phone: `SessionScreen.Source` (tmux, cmux,
///     WezTerm, kitty, Herdr; Claude Squad is tmux);
///   - stop a turn with Esc: `TerminalHost.canSendLoneEscape` (not Terminal.app);
///   - start a session from the phone: `SessionStarter` (cmux only);
///   - answer a question dialog by pressing its keys: `AnswerDelivery.capabilities(of:)`, each host measured
///     end to end on Claude Code 2.1.311 (docs/SESSIONS-PROTOCOL.md). `AnswerSupport` here is the same fact in
///     words, and `AnswerDelivery.takesAnswerKeys` reads it, so the phone's list can't drift from the gate.
enum TerminalCatalog {
    enum ID: String, CaseIterable, Identifiable, Equatable {
        case terminal, iTerm, tmux, cmux, wezterm, kitty, herdr, claudeSquad
        var id: String { rawValue }
    }

    /// Whether Page can answer a question dialog from the phone in this terminal.
    enum AnswerSupport: Equatable {
        /// Measured end to end: every question shape Page offers.
        case yes
        /// Works, with a stated limit (short reason).
        case limited(String)
        /// Refused up front, with why and what to use instead (short reason).
        case notYet(String)

        /// The phone may offer its answer sheet for a session in this terminal.
        var takesKeys: Bool {
            if case .notYet = self { return false }
            return true
        }

        /// "Yes", "With limits", "Not yet".
        var label: String {
            switch self {
            case .yes: return "Yes"
            case .limited: return "With limits"
            case .notYet: return "Not yet"
            }
        }

        /// "Answer questions: yes" / "…: with limits — why" / "…: not yet — why".
        var line: String {
            switch self {
            case .yes: return "Answer questions: yes"
            case .limited(let why): return "Answer questions: with limits — \(why)"
            case .notYet(let why): return "Answer questions: not yet — \(why)"
            }
        }
    }

    struct Capabilities: Equatable {
        var reply = true
        var viewScreen = false
        var interrupt = false
        var startSessions = false
        var answer: AnswerSupport = .notYet("not measured here yet")

        /// "Reply · see the screen · stop a turn · start sessions".
        var line: String {
            var parts: [String] = []
            if reply { parts.append("reply") }
            if viewScreen { parts.append("see the screen") }
            if interrupt { parts.append("stop a turn") }
            if startSessions { parts.append("start sessions") }
            guard let first = parts.first else { return "" }
            return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: " · ")
        }
    }

    /// What it takes to make a host work.
    enum SetupKind: Equatable {
        /// Run Claude inside it; Page needs nothing else.
        case none
        /// macOS Automation permission to control the app.
        case automation
        /// kitty.conf needs remote control turned on.
        case kittyConfig
        /// cmux's socket must admit Page (its own setup window).
        case cmuxSocket
    }

    struct Entry: Equatable, Identifiable {
        let id: ID
        let name: String
        /// SF Symbol that exists on macOS 12.
        let symbol: String
        let capabilities: Capabilities
        let setup: SetupKind
        /// `SessionHostInfo.host`, as `SessionRemote.claudeHostInfo` names it.
        let wireHost: String
        /// The official site.
        let downloadURL: URL
        /// Shown when the host needs nothing from Page.
        let nothingToSetUp: String
    }

    static let nothingToSetUp = "Nothing to set up — run Claude inside it"

    static let entries: [Entry] = [
        Entry(id: .terminal, name: "Terminal", symbol: "macwindow",
              capabilities: Capabilities(reply: true, viewScreen: false, interrupt: false, startSessions: false,
                                         answer: .notYet("Terminal adds a Return to every key Page types; use tmux or iTerm2")),
              setup: .automation, wireHost: "Terminal", downloadURL: URL(string: "https://support.apple.com/guide/terminal/welcome/mac")!,
              nothingToSetUp: "Built into macOS"),
        Entry(id: .iTerm, name: "iTerm2", symbol: "terminal",
              capabilities: Capabilities(reply: true, viewScreen: false, interrupt: true, startSessions: false, answer: .yes),
              setup: .automation, wireHost: "iTerm", downloadURL: URL(string: "https://iterm2.com")!,
              nothingToSetUp: nothingToSetUp),
        Entry(id: .tmux, name: "tmux", symbol: "rectangle.split.3x1",
              capabilities: Capabilities(reply: true, viewScreen: true, interrupt: true, startSessions: false, answer: .yes),
              setup: .none, wireHost: "tmux", downloadURL: URL(string: "https://github.com/tmux/tmux/wiki")!,
              nothingToSetUp: nothingToSetUp),
        Entry(id: .cmux, name: "cmux", symbol: "square.grid.2x2",
              capabilities: Capabilities(reply: true, viewScreen: true, interrupt: true, startSessions: true, answer: .yes),
              setup: .cmuxSocket, wireHost: "cmux", downloadURL: URL(string: "https://cmux.com")!,
              nothingToSetUp: nothingToSetUp),
        Entry(id: .wezterm, name: "WezTerm", symbol: "terminal.fill",
              capabilities: Capabilities(reply: true, viewScreen: true, interrupt: true, startSessions: false, answer: .yes),
              setup: .none, wireHost: "WezTerm", downloadURL: URL(string: "https://wezterm.org")!,
              nothingToSetUp: nothingToSetUp),
        Entry(id: .kitty, name: "kitty", symbol: "pawprint",
              capabilities: Capabilities(reply: true, viewScreen: true, interrupt: true, startSessions: false, answer: .yes),
              setup: .kittyConfig, wireHost: "kitty", downloadURL: URL(string: "https://sw.kovidgoyal.net/kitty/")!,
              nothingToSetUp: nothingToSetUp),
        Entry(id: .herdr, name: "Herdr", symbol: "rectangle.3.group",
              capabilities: Capabilities(reply: true, viewScreen: true, interrupt: true, startSessions: false, answer: .yes),
              setup: .none, wireHost: "Herdr", downloadURL: URL(string: "https://github.com/herdrdev/herdr")!,
              nothingToSetUp: nothingToSetUp),
        Entry(id: .claudeSquad, name: "Claude Squad", symbol: "person.3",
              capabilities: Capabilities(reply: true, viewScreen: true, interrupt: true, startSessions: false, answer: .yes),
              setup: .none, wireHost: ClaudeSquad.hostName, downloadURL: URL(string: "https://github.com/smtg-ai/claude-squad")!,
              nothingToSetUp: nothingToSetUp),
    ]

    static func entry(_ id: ID) -> Entry { entries.first { $0.id == id }! }

    /// "Terminal, iTerm2, tmux, cmux, WezTerm, kitty, Herdr and Claude Squad".
    static var namesLine: String {
        let names = entries.map(\.name)
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }

    /// Pure. The host a wire name (`SessionHostInfo.host`) belongs to; nil for
    /// hosts Page can't type into ("Ghostty", "VS Code", "unknown", …).
    static func id(forWireHost host: String) -> ID? {
        if host == "iTerm2" { return .iTerm }
        return entries.first { $0.wireHost == host }?.id
    }

    // MARK: facts

    /// What the live sessions say about one host.
    struct HostUse: Equatable {
        /// Sessions Page can type into there.
        var typable = 0
        /// Sessions it can't, and the first reason it gave.
        var blocked = 0
        var blocker: String?

        var total: Int { typable + blocked }
    }

    /// The host's own setup, as checked on this Mac.
    enum SetupState: Equatable {
        /// The host needs nothing from Page.
        case notNeeded
        case done
        case needed(String)
        /// Couldn't tell (the app isn't running, so macOS can't be asked).
        case unchecked
        /// kitty.conf has Page's settings, but the kitty that is running
        /// started before that and never read them.
        case needsRestart
    }

    struct Facts: Equatable {
        var installed: Bool
        var use = HostUse()
        var setup: SetupState = .notNeeded
    }

    /// Pure. Sessions' host info → per-host counts.
    static func hostUse(from hosts: [SessionHostInfo]) -> [ID: HostUse] {
        var out: [ID: HostUse] = [:]
        for h in hosts {
            guard let id = id(forWireHost: h.host) else { continue }
            var use = out[id] ?? HostUse()
            if h.canType {
                use.typable += 1
            } else {
                use.blocked += 1
                if use.blocker == nil { use.blocker = h.typeBlocker }
            }
            out[id] = use
        }
        return out
    }

    // MARK: status

    enum Status: Equatable {
        /// Sessions Page can type into (blocked ones are not counted).
        case inUse(Int)
        case ready
        /// Installed, but macOS Automation can't be checked until the app runs.
        case notChecked
        case needsSetup(String)
        case notInstalled(URL)

        /// The chip: "In use · 2", "Ready", "Not checked", "Needs setup", "Not installed".
        var chipText: String {
            switch self {
            case .inUse(let n): return "In use · \(n)"
            case .ready: return "Ready"
            case .notChecked: return "Not checked"
            case .needsSetup: return "Needs setup"
            case .notInstalled: return "Not installed"
            }
        }
    }

    /// Pure. In order:
    ///  1. sessions Page can type into → in use (counting only those) — except
    ///     that a confirmed missing Automation permission wins for Terminal and
    ///     iTerm2, whose sessions always look typable until macOS says no;
    ///  2. sessions it can't type into → needs setup, with the host's reason;
    ///  3. not installed (and nothing running in it) → not installed;
    ///  4. a setup problem on an installed host → needs setup;
    ///  5. Automation not checkable yet (the app isn't running) → not checked:
    ///     "Ready" is only said when macOS has said yes;
    ///  6. ready.
    static func status(_ entry: Entry, _ facts: Facts, pageAddedKittyLines: Bool = false) -> Status {
        let automationMissing: String? = {
            if entry.setup == .automation, case .needed(let why) = facts.setup { return why }
            return nil
        }()
        if facts.use.typable > 0 {
            if let why = automationMissing { return .needsSetup(why) }
            return .inUse(facts.use.typable)
        }
        if facts.use.blocked > 0 {
            return .needsSetup(blockedReason(entry, facts, pageAddedKittyLines: pageAddedKittyLines))
        }
        if !facts.installed { return .notInstalled(entry.downloadURL) }
        if case .needed(let why) = facts.setup { return .needsSetup(why) }
        if facts.setup == .needsRestart { return .needsSetup(restartKittyText(pageAdded: pageAddedKittyLines)) }
        if entry.setup == .automation, facts.setup != .done { return .notChecked }
        return .ready
    }

    /// Pure. "Restart kitty to turn on the lines Page added".
    static func restartKittyText(pageAdded: Bool) -> String {
        pageAdded ? "Restart kitty to turn on the lines Page added"
                  : "Restart kitty to turn on the remote control lines in kitty.conf"
    }

    /// Pure. Why Page can't type into a host's blocked sessions. For kitty
    /// whose kitty.conf already has the lines, the cause is that kitty hasn't
    /// been restarted: telling the user to add the lines again would be wrong.
    static func blockedReason(_ entry: Entry, _ f: Facts, pageAddedKittyLines: Bool = false) -> String {
        if entry.setup == .kittyConfig, f.setup == .done || f.setup == .needsRestart {
            return restartKittyText(pageAdded: pageAddedKittyLines)
        }
        return f.use.blocker ?? "Page can't type into it yet"
    }

    // MARK: rows

    enum Action: Equatable {
        /// Opens setup: kitty.conf, cmux's window.
        case setUp(label: String)
        /// Asks macOS for Automation permission.
        case allow
        case getIt(URL)
        /// Takes Page's own kitty.conf lines back out.
        case undo

        var title: String {
            switch self {
            case .setUp(let label): return label
            case .allow: return "Allow…"
            case .getIt: return "Get it ↗"
            case .undo: return "Undo"
            }
        }
    }

    struct Row: Equatable, Identifiable {
        let id: ID
        let name: String
        let symbol: String
        /// What Page can do there.
        let capabilityLine: String
        /// Answering a question dialog from the phone: yes, with limits, or not yet.
        let answer: AnswerSupport
        /// What is true now: the setup state, or what to do.
        let note: String
        let status: Status
        let action: Action?
        /// The note is a problem (amber), not just a description.
        var noteIsWarning = false
    }

    /// Pure. One row per host, in catalog order. `pageAddedKittyLines`: the
    /// kitty.conf holds the lines Page added (the row can offer Undo).
    static func rows(_ facts: [ID: Facts], pageAddedKittyLines: Bool = false) -> [Row] {
        entries.map { entry in
            let f = facts[entry.id] ?? Facts(installed: false)
            let status = status(entry, f, pageAddedKittyLines: pageAddedKittyLines)
            let warns: Bool = {
                if case .needsSetup = status { return true }
                if case .inUse = status { return f.use.blocked > 0 }
                return false
            }()
            return Row(id: entry.id, name: entry.name, symbol: entry.symbol,
                       capabilityLine: entry.capabilities.line,
                       answer: entry.capabilities.answer,
                       note: note(entry, f, status, pageAddedKittyLines: pageAddedKittyLines),
                       status: status,
                       action: action(entry, f, status, pageAddedKittyLines: pageAddedKittyLines),
                       noteIsWarning: warns)
        }
    }

    /// Pure.
    static func note(_ entry: Entry, _ f: Facts, _ status: Status, pageAddedKittyLines: Bool = false) -> String {
        switch status {
        case .needsSetup(let why):
            return why
        case .notInstalled:
            return "Not installed. Optional: Page works with the terminal you already use."
        case .notChecked:
            return "Open \(entry.name) or click Allow… to check"
        case .inUse, .ready:
            if f.use.typable > 0, f.use.blocked > 0 {
                let n = f.use.blocked
                return "\(n) session\(n == 1 ? "" : "s") can't be typed into: " + blockedReason(entry, f, pageAddedKittyLines: pageAddedKittyLines)
            }
            switch entry.setup {
            case .none:
                return entry.nothingToSetUp
            case .automation:
                if f.setup == .done { return "macOS lets Page control \(entry.name)" }
                return "Page asks macOS for permission the first time it types here"
            case .kittyConfig:
                return f.setup == .done ? "Remote control is on in kitty.conf" : "Run Claude inside kitty"
            case .cmuxSocket:
                return f.setup == .done ? "cmux lets Page in" : "Run Claude inside cmux"
            }
        }
    }

    /// Pure.
    static func action(_ entry: Entry, _ f: Facts, _ status: Status, pageAddedKittyLines: Bool = false) -> Action? {
        switch status {
        case .notInstalled(let url):
            return .getIt(url)
        case .notChecked:
            return .allow
        case .needsSetup:
            switch entry.setup {
            case .automation: return .allow
            case .kittyConfig:
                // The lines are in kitty.conf already: the step left is
                // restarting kitty, which Page can't do for the user.
                if f.setup == .done || f.setup == .needsRestart { return pageAddedKittyLines ? .undo : nil }
                return .setUp(label: "Set up…")
            case .cmuxSocket: return .setUp(label: "Set up…")
            case .none: return nil
            }
        case .inUse, .ready:
            switch entry.setup {
            case .automation: return f.setup == .done ? nil : .allow
            case .kittyConfig:
                if pageAddedKittyLines { return .undo }
                if case .needed = f.setup, f.use.blocked > 0 { return .setUp(label: "Set up…") }
                return nil
            case .cmuxSocket, .none: return nil
            }
        }
    }

    /// Pure. "3 of 8 hosts in use": the page's one-line summary.
    static func summary(_ rows: [Row]) -> String {
        let inUse = rows.filter { if case .inUse = $0.status { return true } else { return false } }.count
        let needs = rows.filter { if case .needsSetup = $0.status { return true } else { return false } }.count
        var parts = ["\(inUse) of \(rows.count) in use"]
        if needs > 0 { parts.append("\(needs) need\(needs == 1 ? "s" : "") setup") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - what setup says

extension TerminalCatalog {
    /// Pure. The confirmation before Page touches kitty.conf: exactly what
    /// changes, where the copy goes, and what to do afterwards.
    static func kittyConfirmText(path: String, added: [String], creating: Bool, linkTarget: String? = nil) -> String {
        let lines = added.map { "    " + $0 }.joined(separator: "\n")
        let place = linkTarget.map { "\($0) (\(path) is a link to it)" } ?? path
        let what = creating
            ? "Page will create \(place) with:"
            : "Page will add these lines to the end of \(place):"
        let backup = creating
            ? "There is no kitty.conf yet, so there is nothing to back up."
            : "A copy of your current file is saved next to it first (kitty.conf.bak-page-…), and Undo takes the lines out again."
        return "\(what)\n\n\(lines)\n\n\(backup)\n\nRestart kitty afterwards: it only reads kitty.conf when it starts. Programs running as you can then send keys to kitty windows through that local socket, the way any app can script Terminal."
    }

    /// Pure. The line under the card once kitty.conf was changed.
    static func kittyDoneText(_ outcome: KittyConfigFile.Outcome) -> TowerStatusLine {
        if outcome.added.isEmpty { return TowerStatusLine(text: "kitty already lets Page in.", tone: .good) }
        let backup = outcome.backup.map { " Your old file is saved as \($0.lastPathComponent)." } ?? ""
        return TowerStatusLine(text: "Added to \(outcome.url.path). Restart kitty to turn it on.\(backup)", tone: .good)
    }

    /// Pure. The line under the card after Allow… (macOS has answered).
    static func automationNotice(_ access: TerminalProbe.Automation, appName: String) -> TowerStatusLine {
        switch access {
        case .granted: return TowerStatusLine(text: "macOS lets Page control \(appName).", tone: .good)
        case .denied: return TowerStatusLine(text: "macOS said no to \(appName). Turn Page on under System Settings ▸ Privacy & Security ▸ Automation — opening it now.", tone: .bad)
        case .notAsked: return TowerStatusLine(text: "macOS hasn't asked yet. Click Allow… again.", tone: .quiet)
        case .appNotRunning: return TowerStatusLine(text: "\(appName) didn't start, so macOS couldn't be asked. Open it and click Allow… again.", tone: .bad)
        case .unknown: return TowerStatusLine(text: "Couldn't ask macOS about \(appName).", tone: .bad)
        }
    }
}
