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
        case wezterm(WezTermBridge.Target)
        case kitty(KittyBridge.Target)
        case herdr(HerdrBridge.Target)
    }

    /// Where a Claude session's screen can be read, from its resolved host.
    static func source(for host: InjectionExecutor.TerminalHost) -> Source? {
        switch host {
        case .tmux(let tmux, let pane, _, _): return .tmux(tmuxPath: tmux, pane: pane, serverArgs: [])
        case .cmux(let target): return .cmux(target)
        case .wezterm(let target): return .wezterm(target)
        case .kitty(let target): return .kitty(target)
        case .herdr(let target): return .herdr(target)
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
            // -J: wrapped lines arrive joined, so a long token is redacted whole.
            let r = ProcessRunner.run(tmux, serverArgs + ["capture-pane", "-p", "-J", "-t", pane], timeout: 3)
            return r.succeeded ? r.stdout : nil
        case .cmux(let target):
            guard case .success(let client) = CmuxBridge.connect(cliPath: target.cliPath, runner: runner) else { return nil }
            // Always name the surface (and its workspace when known): with
            // no flags cmux would read the caller's own surface.
            var args = ["read-screen", "--surface", target.surfaceId]
            if let ws = target.workspaceId { args += ["--workspace", ws] }
            guard case .success(let text) = client.run(args, timeout: 4, fallback: "cmux didn't return the screen") else { return nil }
            return text
        case .wezterm(let target):
            return WezTermBridge.screen(target, styled: false)
        case .kitty(let target):
            return KittyBridge.screen(target, styled: false)
        case .herdr(let target):
            return HerdrBridge.screen(target, styled: false)
        }
    }

    /// Pure. Escape codes stripped, lines the terminal wrapped rejoined, the
    /// whole text redacted (before any cut, so no cut leaves a fragment too
    /// short for its pattern), private-key blocks blanked, trailing spaces
    /// and blank lines dropped, the last `maxLines` kept, each capped and
    /// redacted again, then lines dropped from the top until the JSON fits
    /// `maxPlaintextBytes`.
    static func lines(from raw: String) -> [String] {
        let split = stripEscapes(raw)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var s = String(line)
                while let last = s.unicodeScalars.last, CharacterSet.whitespaces.contains(last) { s.unicodeScalars.removeLast() }
                return s
            }
        // Key rows are blanked on the rows as shown, before any rejoining.
        let redacted = ContextRedactor.redact(unwrapped(blankingKeyBlocks(split)).joined(separator: "\n"))
        var lines = carryingRedaction(redacted.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        lines = lines.suffix(maxLines).map { line in
            let capped = line.count > maxLineChars ? String(line.prefix(maxLineChars - 1)) + "…" : line
            return ContextRedactor.redact(capped)
        }
        while !lines.isEmpty, bodySize(lines) > maxPlaintextBytes - 512 { lines.removeFirst() }
        return lines
    }

    /// Rejoins lines the terminal soft-wrapped, so a long token split across
    /// rows is redacted whole (tmux is read with `-J` and arrives joined;
    /// cmux's read-screen can't join). A row is treated as wrapped when it
    /// fills the screen width (the longest row) and both it and the next row
    /// break mid-token; box rules and padded rows never qualify.
    static func unwrapped(_ rows: [String]) -> [String] {
        let width = rows.map(\.count).max() ?? 0
        guard width >= 40 else { return rows }
        func tokenChar(_ c: Character?) -> Bool {
            guard let c else { return false }
            return c.isLetter || c.isNumber || "_-+/=.".contains(c)
        }
        var out: [String] = []
        var previousWrapped = false
        for row in rows {
            if previousWrapped, tokenChar(row.first), let last = out.popLast() {
                out.append(last + row)
            } else {
                out.append(row)
            }
            previousWrapped = row.count == width && tokenChar(row.last)
        }
        return out
    }

    /// A private key whose BEGIN line scrolled off the top: the redactor
    /// (which collapses BEGIN…END, or BEGIN…end of text) can't see it, so the
    /// base64 rows above a visible `-----END … PRIVATE KEY(-BLOCK)-----`
    /// become "[redacted]". Rows may carry the TUI's indent, gutter (│ ⎿ >)
    /// or a line number, which are kept. The row right above END may be
    /// short (the last base64 row, or a PGP `=XXXX` checksum); every other
    /// row needs 16+ base64 characters.
    static func blankingKeyBlocks(_ lines: [String]) -> [String] {
        let prefix = #"^([\s│┃|⎿>]*(?:\d+\s+)?)"#
        let long = try! NSRegularExpression(pattern: prefix + #"[A-Za-z0-9+/=]{16,}([\s│┃|]*)$"#)
        let short = try! NSRegularExpression(pattern: prefix + #"=?[A-Za-z0-9+/=]{2,}([\s│┃|]*)$"#)
        var out = lines
        for (i, line) in lines.enumerated() where line.contains("-----END") && line.contains("PRIVATE KEY") {
            var j = i - 1
            var first = true
            while j >= 0 {
                let row = out[j]
                let range = NSRange(row.startIndex..., in: row)
                // A PGP block ends "<last row>\n=XXXX": both may be short.
                let re = (first || j == i - 2) ? short : long
                guard re.firstMatch(in: row, range: range) != nil else { break }
                out[j] = re.stringByReplacingMatches(in: row, range: range, withTemplate: "$1[redacted]$2")
                j -= 1
                first = false
            }
        }
        return out
    }

    /// A token Claude Code's renderer wrapped itself (hard newline, padded
    /// continuation row) reaches the redactor in pieces, and only the piece
    /// with the recognisable prefix is masked. A row ending in a redaction
    /// therefore masks the credential-looking run that starts the next row,
    /// and so on while each next row is only that run.
    static func carryingRedaction(_ lines: [String]) -> [String] {
        // Claude Code pads its continuation rows: an unindented row, or one
        // starting with "--" (an END line, a flag), is not a continuation.
        let continuation = try! NSRegularExpression(pattern: #"^(\s+)(?!--)[A-Za-z0-9._~+/=-]{6,}"#)
        var out = lines
        // A masked row ends in "[redacted]" only if the run was the whole
        // row, so a forward pass continues the chain exactly that far.
        for i in out.indices.dropLast() where out[i].hasSuffix("[redacted]") {
            let next = out[i + 1]
            out[i + 1] = continuation.stringByReplacingMatches(in: next, range: NSRange(next.startIndex..., in: next),
                                                               withTemplate: "$1[redacted]")
        }
        return out
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
