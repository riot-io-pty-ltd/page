import Foundation

/// One piece of local inference Page can see right now: a model server
/// (Ollama, llama.cpp), an app (LM Studio) or a terminal tool (llama-cli, a
/// terminal agent). Power-only: Page keeps the Mac awake while one is
/// `busy`, and a loaded-but-idle model must never count as busy.
struct LocalActivity: Equatable {
    enum Kind: String, Equatable {
        case server, app, terminalTool
    }

    /// Where `busy` came from, best first.
    enum Signal: String, Equatable {
        /// The server said so (llama.cpp `/slots` `is_processing`).
        case exact
        /// The process's Apple-GPU time grew (IOKit AGX user clients).
        case gpu
        /// Its terminal was written to recently.
        case terminalOutput
        /// Nothing to go on (sampler unavailable, no model loaded, no tty).
        case none
    }

    /// Stable while the processes live: "ollama", "lmstudio",
    /// "llamacpp:8080", "mlx:<pid>", "llamacli:<pid>", "agent:opencode:<pid>".
    let id: String
    /// "Ollama", "LM Studio", "llama.cpp server :8080", "MLX", "opencode", "ollama run", …
    let displayName: String
    let kind: Kind
    let busy: Bool
    let signal: Signal
    /// Short reason for the menu: "generating · exact", "idle", "GPU 65%",
    /// "capped after 3 h". Never prompt text, argv or environment values.
    let detail: String
    /// Last positive observation. Not part of equality, so a list that only
    /// moved in time doesn't fire `onChange`.
    let lastBusyAt: Date?

    init(id: String, displayName: String, kind: Kind, busy: Bool, signal: Signal, detail: String, lastBusyAt: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.busy = busy
        self.signal = signal
        self.detail = detail
        self.lastBusyAt = lastBusyAt
    }

    static func == (a: LocalActivity, b: LocalActivity) -> Bool {
        a.id == b.id && a.displayName == b.displayName && a.kind == b.kind
            && a.busy == b.busy && a.signal == b.signal && a.detail == b.detail
    }
}

extension LocalActivity {
    /// One line per activity for the menu and Preferences, busy first:
    /// "Ollama — generating · exact", "LM Studio — idle".
    static func menuLines(_ list: [LocalActivity]) -> [String] {
        let sorted = list.enumerated().sorted { a, b in
            a.element.busy != b.element.busy ? a.element.busy : a.offset < b.offset
        }.map(\.element)
        return sorted.map { "\($0.displayName) — \($0.detail)" }
    }
}
