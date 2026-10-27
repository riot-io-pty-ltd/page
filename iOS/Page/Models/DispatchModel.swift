import Foundation

// Dispatch: the sheet that rises from the pulse to start new work. Where (a
// folder from the Mac's known list), who (Claude: the only agent the phone
// can start), what (an optional prompt) and when (now: there is no queue yet).
// Pure values; the sheet draws them and the live container sends through
// `SessionStore.startSession`, the existing path.

/// The agents Dispatch shows. The `start` request has no agent field, so only
/// Claude can be started from the phone; the others are shown plainly as
/// unavailable here rather than hidden or faked.
enum DispatchAgent: String, CaseIterable, Identifiable, Equatable {
    case claude, codex, ollama

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .ollama: return "Ollama"
        }
    }

    /// Under the name.
    var note: String {
        switch self {
        case .claude: return "runs claude in cmux"
        case .codex, .ollama: return "start it on your Mac"
        }
    }

    /// Whether the phone can start it.
    var canStartFromPhone: Bool { self == .claude }

    /// SF Symbol.
    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "hexagon"
        case .ollama: return "cpu"
        }
    }
}

/// One project chip.
struct DispatchFolder: Equatable, Identifiable {
    let path: String
    let name: String
    let hue: ProjectHue
    /// "2 h ago", or nil.
    let lastUsed: String?
    var id: String { path }
}

/// Whether Dispatch can start anything yet, from what the Mac said.
enum DispatchAvailability: Equatable {
    case loading
    /// "Let my phone start new Claude sessions" is off on the Mac.
    case disabledOnMac
    case noFolders
    case failed(String)
    case ready

    static func from(folders: StartFolders?, error: String?) -> DispatchAvailability {
        if let f = folders {
            if !f.enabled { return .disabledOnMac }
            return f.folders.isEmpty ? .noFolders : .ready
        }
        if let error { return .failed(error) }
        return .loading
    }
}

/// What the person has chosen so far.
struct DispatchDraft: Equatable {
    var search = ""
    var selectedPath: String?
    var prompt = ""
    var agent: DispatchAgent = .claude

    /// Chips most recently used first, narrowed by the search. Pure.
    func visibleFolders(_ folders: [StartFolders.Folder], now: Date) -> [DispatchFolder] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return folders
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
            .sorted { a, b in
                switch (a.lastUsedAt, b.lastUsedAt) {
                case let (x?, y?) where x != y: return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.name.lowercased() < b.name.lowercased()
                }
            }
            .map { DispatchFolder(path: $0.path, name: $0.name, hue: ProjectHue(key: $0.path),
                                  lastUsed: $0.lastUsedAt.map { RelativeTime.ago(since: $0, now: now) }) }
    }

    /// Picks the most recent folder when nothing is chosen, or when the choice has gone.
    mutating func ensureSelection(in folders: [StartFolders.Folder], now: Date) {
        if let p = selectedPath, folders.contains(where: { $0.path == p }) { return }
        selectedPath = visibleFolders(folders, now: now).first?.path
    }

    var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The prompt is optional (a session can start empty). Too long is not
    /// allowed, the same limit as a message. Pure.
    var promptProblem: String? {
        trimmedPrompt.count > SessionComposer.maxCharacters
            ? SessionComposer.Problem.tooLong(count: trimmedPrompt.count).message : nil
    }

    /// Ready to start: a folder, an agent the phone can start, a prompt that fits, and not already sending.
    func canStart(availability: DispatchAvailability, sending: Bool) -> Bool {
        availability == .ready && selectedPath != nil && agent.canStartFromPhone && promptProblem == nil && !sending
    }

    /// "Start on Studio MBP": always names the Mac.
    func startTitle(mac: String) -> String { "Start on \(DeliveryPreview.macLabel(mac))" }

    /// Under the button.
    static func footer(mac: String) -> String {
        "Opens a new cmux workspace on \(DeliveryPreview.macLabel(mac)) and runs claude there. Starting from the phone is off until you allow it on the Mac."
    }
}

/// Where a start stands, in words.
struct DispatchStatus: Equatable {
    enum Tone: Equatable { case working, good, problem, warn }
    let text: String
    let tone: Tone
    /// The spinner is still going.
    let waiting: Bool

    static func from(state: SessionDeliveryState?, startWaitExpired: Bool) -> DispatchStatus? {
        guard let state else { return nil }
        switch state {
        case .sending: return DispatchStatus(text: "Asking your Mac to start it…", tone: .working, waiting: true)
        case .typed(let detail), .queued(let detail):
            if startWaitExpired {
                return DispatchStatus(text: "Started, but it hasn't shown up here yet. Look for it in Lanes, or in cmux on your Mac.", tone: .warn, waiting: false)
            }
            return DispatchStatus(text: (detail ?? "Started") + ". Opening it here as soon as it appears. On your Mac it's a new cmux workspace.", tone: .good, waiting: true)
        case .refused(_, let message), .failed(let message):
            return DispatchStatus(text: message, tone: .problem, waiting: false)
        case .noAnswer:
            return DispatchStatus(text: "No answer from your Mac", tone: .warn, waiting: false)
        }
    }
}
