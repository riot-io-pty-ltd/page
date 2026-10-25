import Foundation

/// The bottom of a watched session's terminal, mirrored to the phone as the
/// `screen` kind (SESSIONS-PROTOCOL.md §4). It shows what the transcript
/// can't: Claude Code's footer (background workflows and their progress,
/// shells, sub-agents, todo lists) and whatever is on screen right now.
///
/// Read-only and only for a session a phone is watching, at most every
/// `interval`. tmux and cmux only: both read the visible viewport cheaply.
/// Terminal.app and iTerm2 would need AppleScript every few seconds (on the
/// main thread) and return the whole scrollback, so they aren't mirrored.
///
/// Privacy: unlike the transcript (one line per tool call, no output) the
/// screen can show tool output. Every line is redacted before sealing, and
/// like everything else it reaches the phone end-to-end encrypted.
enum SessionScreen {
    static let maxLines = 80
    static let maxLineChars = 300
    static let maxPlaintextBytes = 32 * 1024
    /// How often a watched session's screen is re-read.
    static let interval: TimeInterval = 2.5
    /// How long a resolved screen source is trusted before resolving again.
    static let sourceTTL: TimeInterval = 30

    enum Source: Equatable {
        /// `serverArgs`: tmux server selection (Codex tests use a private
        /// socket; normally empty).
        case tmux(tmuxPath: String, pane: String, serverArgs: [String])
        case cmux(CmuxBridge.Target)
    }

    /// Where a Claude session's screen can be read, from its resolved host.
    static func source(for host: InjectionExecutor.TerminalHost) -> Source? {
        switch host {
        case .tmux(let tmux, let pane, _): return .tmux(tmuxPath: tmux, pane: pane, serverArgs: [])
        case .cmux(let target): return .cmux(target)
        case .terminalApp, .iTerm, .unreachable, .unsupported, .unknown: return nil
        }
    }

    /// The same for a Codex session's terminal.
    static func source(for terminal: CodexInjector.Terminal) -> Source? {
        switch terminal {
        case .tmux(let pane):
            guard let tmux = ProcessRunner.findExecutable("tmux") else { return nil }
            return .tmux(tmuxPath: tmux, pane: pane, serverArgs: CodexInjector.tmuxServerArgs)
        case .cmux(let target): return .cmux(target)
        case .terminalApp, .unavailable: return nil
        }
    }

    /// The visible screen as plain text, or nil. Blocking (spawns tmux or
    /// the cmux CLI); call off the sessions queue.
    static func read(_ source: Source, runner: @escaping CmuxBridge.Runner = CmuxBridge.defaultRunner) -> String? {
        switch source {
        case .tmux(let tmux, let pane, let serverArgs):
            let r = ProcessRunner.run(tmux, serverArgs + ["capture-pane", "-p", "-t", pane], timeout: 3)
            return r.succeeded ? r.stdout : nil
        case .cmux(let target):
            guard case .success(let client) = CmuxBridge.connect(cliPath: target.cliPath, runner: runner) else { return nil }
            // Always name the surface (and its workspace when known): with
            // no flags cmux would read the caller's own surface.
            var args = ["read-screen", "--surface", target.surfaceId]
            if let ws = target.workspaceId { args += ["--workspace", ws] }
            guard case .success(let text) = client.run(args, timeout: 4, fallback: "cmux didn't return the screen") else { return nil }
            return text
        }
    }

    /// Pure. Escape codes stripped, trailing spaces and blank lines dropped,
    /// the last `maxLines` lines kept, each capped and redacted, then lines
    /// dropped from the top until the JSON fits `maxPlaintextBytes`.
    static func lines(from raw: String) -> [String] {
        var lines = stripEscapes(raw)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var s = String(line)
                while let last = s.unicodeScalars.last, CharacterSet.whitespaces.contains(last) { s.unicodeScalars.removeLast() }
                return s
            }
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        lines = lines.suffix(maxLines).map { line in
            let capped = line.count > maxLineChars ? String(line.prefix(maxLineChars - 1)) + "…" : line
            return ContextRedactor.redact(capped)
        }
        while !lines.isEmpty, bodySize(lines) > maxPlaintextBytes - 512 { lines.removeFirst() }
        return lines
    }

    /// CSI (`ESC [ … final`), OSC (`ESC ] … BEL|ESC \`) and lone two-byte
    /// escapes, plus other C0 controls except tab.
    static func stripEscapes(_ s: String) -> String {
        var out = s
        // ICU regex syntax (\x1B), not Swift's \u{1B}.
        for pattern in [#"\x1B\][^\x07\x1B]*(\x07|\x1B\\)"#, #"\x1B\[[0-?]*[ -/]*[@-~]"#, #"\x1B[@-Z\\-_]"#] {
            out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return out.replacingOccurrences(of: #"[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]"#, with: "", options: .regularExpression)
    }

    private static func bodySize(_ lines: [String]) -> Int {
        (try? JSONSerialization.data(withJSONObject: lines))?.count ?? Int.max
    }

    /// The sealed `screen` plaintext, or nil if it somehow doesn't fit.
    static func plaintext(header: [String: Any], lines: [String]) -> Data? {
        var obj = header
        obj["lines"] = lines
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              data.count <= maxPlaintextBytes else { return nil }
        return data
    }
}
