import Foundation

/// One row of the phone's live transcript (SESSIONS-PROTOCOL.md §4
/// `transcript`).
struct SessionTranscriptEntry: Equatable {
    enum Role: String {
        case user, assistant, tool, system
    }

    /// Stable across snapshots, so the phone can diff and keep its scroll
    /// position: the record's uuid (Claude), else the line's byte offset
    /// in the file.
    let id: String
    let role: Role
    /// Redacted, then capped at `SessionTranscript.maxEntryChars`.
    let text: String
    let at: Date?
    /// Tool name, for `tool` rows.
    var tool: String? = nil

    var jsonObject: [String: Any] {
        var o: [String: Any] = ["id": id, "role": role.rawValue, "text": text]
        if let at { o["at"] = SessionTranscript.isoFormatter.string(from: at) }
        if let tool { o["tool"] = tool }
        return o
    }
}

/// Turns the end of a Claude Code transcript or a Codex rollout into the
/// phone's transcript rows: the user's prompts (including messages queued
/// mid-turn), the assistant's text, one-liners for tool calls, and markers
/// like "Interrupted". Tool output and results are never included, and
/// sidechain (sub-agent) records are skipped. Every text is redacted with
/// `ContextRedactor` before it is cut, so a cut can't leave a secret
/// fragment too short to recognise.
///
/// Files are read with `BoundedFileRead.tail` (their paths come from the
/// registry and the Codex app-server): never more than a few MB, never a
/// FIFO or device, never inside a privacy-protected folder.
enum SessionTranscript {
    static let maxEntries = 40
    static let maxEntryChars = 2000
    /// The whole `transcript` plaintext.
    static let maxPlaintextBytes = 48 * 1024
    static let previewChars = 160
    static let tailBytes = 256 * 1024
    /// Read when the first window holds fewer than `maxEntries` rows (one
    /// tool result can be hundreds of KB).
    static let extendedTailBytes = 2 * 1024 * 1024
    /// Enough for a preview line.
    static let previewTailBytes = 64 * 1024

    enum Format: Equatable {
        case claude
        case codex
    }

    struct Snapshot: Equatable {
        var entries: [SessionTranscriptEntry]
        /// Older rows exist that aren't in `entries`.
        var truncated: Bool
    }

    static let isoFormatter = ISO8601DateFormatter()

    // MARK: reading

    /// The last `maxEntries` rows of the file at `path`, or nil when it
    /// can't be read safely.
    /// `keepSidechain`: a workflow or sub-agent's own transcript, where every
    /// record is marked `isSidechain` (in the session's transcript those
    /// records are sub-agent noise and are dropped).
    static func read(path: String, format: Format, tailBytes: Int = tailBytes,
                     extendTo extended: Int? = extendedTailBytes, keepSidechain: Bool = false) -> Snapshot? {
        guard let first = BoundedFileRead.tail(path, maxBytes: tailBytes) else { return nil }
        var entries = parse(first.data, baseOffset: first.offset, dropFirstLine: first.truncated, format: format,
                            keepSidechain: keepSidechain)
        var truncated = first.truncated
        if entries.count < maxEntries, first.truncated, let extended, extended > tailBytes,
           let wider = BoundedFileRead.tail(path, maxBytes: extended) {
            entries = parse(wider.data, baseOffset: wider.offset, dropFirstLine: wider.truncated, format: format,
                            keepSidechain: keepSidechain)
            truncated = wider.truncated
        }
        if entries.count > maxEntries {
            entries = Array(entries.suffix(maxEntries))
            truncated = true
        }
        return Snapshot(entries: entries, truncated: truncated)
    }

    static func parse(_ data: Data, baseOffset: UInt64, dropFirstLine: Bool, format: Format,
                      keepSidechain: Bool = false) -> [SessionTranscriptEntry] {
        var out: [SessionTranscriptEntry] = []
        forEachLine(data, baseOffset: baseOffset, dropFirstLine: dropFirstLine) { line, offset in
            guard line.first == UInt8(ascii: "{"),
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            switch format {
            case .claude: out += claudeEntries(obj, offset: offset, keepSidechain: keepSidechain)
            case .codex: out += codexEntries(obj, offset: offset)
            }
        }
        return out
    }

    /// Calls `body` with each complete line and its absolute byte offset.
    /// When the data starts mid-file the partial first line is skipped.
    static func forEachLine(_ data: Data, baseOffset: UInt64, dropFirstLine: Bool,
                            _ body: (Data, UInt64) -> Void) {
        var start = data.startIndex
        if dropFirstLine {
            guard let nl = data.firstIndex(of: 0x0A) else { return }
            start = data.index(after: nl)
        }
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            if end > start {
                body(data[start..<end], baseOffset + UInt64(start - data.startIndex))
            }
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
        }
    }

    // MARK: Claude Code

    static func claudeEntries(_ obj: [String: Any], offset: UInt64, keepSidechain: Bool = false) -> [SessionTranscriptEntry] {
        if (!keepSidechain && obj["isSidechain"] as? Bool == true) || obj["isMeta"] as? Bool == true
            || obj["isCompactSummary"] as? Bool == true { return [] }
        let base = (obj["uuid"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "o\(offset)"
        let at = (obj["timestamp"] as? String).flatMap(TranscriptParser.parseISODate)
        let message = obj["message"] as? [String: Any]
        let content = message?["content"]

        switch obj["type"] as? String {
        case "user":
            var texts: [String] = []
            if let s = content as? String {
                texts = [s]
            } else if let parts = content as? [[String: Any]] {
                // Tool results are the tool's output: never shown.
                texts = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            }
            let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty else { return [] }
            if joined.hasPrefix("[Request interrupted by user") {
                return [SessionTranscriptEntry(id: base, role: .system, text: "Interrupted", at: at)]
            }
            guard let prompt = userPromptText(joined) else { return [] }
            return [SessionTranscriptEntry(id: base, role: .user, text: clean(prompt), at: at)]

        case "assistant":
            let isError = obj["isApiErrorMessage"] as? Bool == true
            if let s = content as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? [] : [SessionTranscriptEntry(id: base, role: isError ? .system : .assistant, text: clean(t), at: at)]
            }
            var out: [SessionTranscriptEntry] = []
            for (i, item) in ((content as? [[String: Any]]) ?? []).enumerated() {
                switch item["type"] as? String {
                case "text":
                    guard let t = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { continue }
                    out.append(SessionTranscriptEntry(id: "\(base)#\(i)", role: isError ? .system : .assistant, text: clean(t), at: at))
                case "tool_use":
                    guard let name = item["name"] as? String else { continue }
                    let line = toolLine(name: name, input: item["input"] as? [String: Any] ?? [:])
                    out.append(SessionTranscriptEntry(id: "\(base)#\(i)", role: .tool, text: line, at: at, tool: name))
                default:
                    continue   // thinking, images, …
                }
            }
            return out

        case "attachment":
            // A message typed while Claude was busy. Only a human origin
            // (or none, from builds that didn't record one): sub-agent
            // hand-backs and task notifications use this shape too.
            guard let a = obj["attachment"] as? [String: Any], a["type"] as? String == "queued_command",
                  (a["commandMode"] as? String).map({ $0 == "prompt" }) ?? true else { return [] }
            let origin = (a["origin"] as? [String: Any])?["kind"] as? String
            guard origin == nil || origin == "human",
                  let prompt = (a["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !prompt.isEmpty else { return [] }
            return [SessionTranscriptEntry(id: base, role: .user, text: clean(prompt), at: at)]

        case "system":
            if obj["subtype"] as? String == "compact_boundary" {
                return [SessionTranscriptEntry(id: base, role: .system, text: "Conversation compacted", at: at)]
            }
            return []

        default:
            return []
        }
    }

    /// What the user typed, from a user record's text. Slash commands are
    /// shown as the command; command and shell output (also stored as user
    /// records) is output, so it is dropped.
    static func userPromptText(_ text: String) -> String? {
        for outputTag in ["<local-command-stdout>", "<local-command-stderr>", "<bash-stdout>", "<bash-stderr>"]
        where text.hasPrefix(outputTag) {
            return nil
        }
        if let name = tagContent("command-name", in: text) {
            let args = tagContent("command-args", in: text) ?? ""
            return args.isEmpty ? name : "\(name) \(args)"
        }
        if let input = tagContent("bash-input", in: text) { return "!" + input }
        return text
    }

    private static func tagContent(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else { return nil }
        let inner = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    /// Tools the page detector describes by name; anything else (MCP tools,
    /// Workflow, new tools) would come out as raw input JSON.
    static let describedTools: Set<String> = [
        "Bash", "Edit", "MultiEdit", "Write", "NotebookEdit", "Read", "Glob", "Grep",
        "WebFetch", "WebSearch", "Task", "Agent", "ExitPlanMode", "AskUserQuestion",
    ]

    /// Input keys worth showing for an unfamiliar tool, best first. Paths
    /// show their last component.
    static let briefKeys = ["description", "title", "name", "query", "prompt", "command", "url",
                            "file_path", "path", "scriptPath", "pattern"]

    /// One line for a tool call in the session view: the detector's summary
    /// for known tools; for others the tool's name (an MCP tool as "tool ·
    /// server") and its most telling input, never a JSON dump.
    static func toolLine(name: String, input: [String: Any]) -> String {
        if describedTools.contains(name) {
            return toolLine(InterventionDetector.describeToolUse(name: name, input: input))
        }
        var label = name
        let parts = name.components(separatedBy: "__")
        if parts.count >= 3, parts[0] == "mcp" {
            label = parts[2...].joined(separator: "__") + " · " + parts[1]
        }
        for key in briefKeys {
            guard let raw = (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            let value = key.lowercased().hasSuffix("path") ? (raw as NSString).lastPathComponent : raw
            return clean("\(label): \(ContextRedactor.redactedPrefix(value, 300))")
        }
        return clean(label)
    }

    /// The first line of a page detector summary as a one-liner:
    /// "[Bash] npm test\n…" → "Bash: npm test". The summary was already
    /// redacted per input value; this redacts again (idempotent) and caps.
    static func toolLine(_ summary: String) -> String {
        var line = summary.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? summary
        if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
            let name = line[line.index(after: line.startIndex)..<close]
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            line = rest.isEmpty ? String(name) : "\(name): \(rest)"
        }
        return clean(line)
    }

    // MARK: Codex

    static func codexEntries(_ obj: [String: Any], offset: UInt64) -> [SessionTranscriptEntry] {
        guard let payload = obj["payload"] as? [String: Any] else { return [] }
        let id = "o\(offset)"
        let at = (obj["timestamp"] as? String).flatMap(CodexRollout.parseTimestamp)
        switch (obj["type"] as? String, payload["type"] as? String) {
        case ("response_item", "message"):
            let role = payload["role"] as? String
            guard role == "user" || role == "assistant" else { return [] }
            let texts = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                // Context Codex injects itself (<environment_context>, …).
                .filter { !$0.isEmpty && !(role == "user" && $0.hasPrefix("<")) }
            guard !texts.isEmpty else { return [] }
            return [SessionTranscriptEntry(id: id, role: role == "user" ? .user : .assistant,
                                           text: clean(texts.joined(separator: "\n\n")), at: at)]
        case ("response_item", "function_call"):
            let name = payload["name"] as? String ?? "tool"
            let args = (payload["arguments"] as? String).flatMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            } ?? [:]
            return [SessionTranscriptEntry(id: id, role: .tool, text: codexToolLine(name: name, args: args), at: at, tool: name)]
        case ("response_item", "local_shell_call"):
            let action = payload["action"] as? [String: Any] ?? [:]
            return [SessionTranscriptEntry(id: id, role: .tool, text: codexToolLine(name: "shell", args: action), at: at, tool: "shell")]
        case ("response_item", "custom_tool_call"):
            let name = payload["name"] as? String ?? "tool"
            let input = payload["input"] as? String ?? ""
            let text: String
            if name == "apply_patch" {
                text = clean("Edit: " + patchedFiles(input))
            } else {
                text = clean(name)
            }
            return [SessionTranscriptEntry(id: id, role: .tool, text: text, at: at, tool: name)]
        case ("response_item", "web_search_call"):
            let query = (payload["action"] as? [String: Any])?["query"] as? String
            return [SessionTranscriptEntry(id: id, role: .tool, text: clean("Search: " + (query ?? "the web")), at: at, tool: "web_search")]
        case ("event_msg", "turn_aborted"):
            return [SessionTranscriptEntry(id: id, role: .system, text: "Interrupted", at: at)]
        default:
            // Tool outputs, reasoning, token counts, duplicated event copies.
            return []
        }
    }

    /// "Shell: npm test", "Edit: Sources/App.swift", or the tool's name.
    static func codexToolLine(name: String, args: [String: Any]) -> String {
        func commandText(_ v: Any?) -> String? {
            if let s = v as? String { return s }
            guard let argv = v as? [String], !argv.isEmpty else { return nil }
            // ["bash", "-lc", "npm test"] → the script itself.
            if argv.count >= 3, ["bash", "sh", "zsh"].contains((argv[0] as NSString).lastPathComponent),
               argv[1].hasPrefix("-"), argv[1].contains("c") {
                return argv[2]
            }
            return argv.joined(separator: " ")
        }
        switch name {
        case "shell", "container.exec", "exec_command", "local_shell":
            let cmd = commandText(args["command"]) ?? commandText(args["cmd"]) ?? "(command)"
            return clean("Shell: " + firstLine(cmd))
        case "apply_patch":
            return clean("Edit: " + patchedFiles(args["input"] as? String ?? ""))
        case "update_plan":
            return "Updated the plan"
        default:
            if let path = args["path"] as? String ?? args["file_path"] as? String { return clean("\(name): \(path)") }
            return clean(name)
        }
    }

    /// Files named by an apply_patch body ("*** Update File: x").
    static func patchedFiles(_ patch: String) -> String {
        var files: [String] = []
        for line in patch.split(separator: "\n") {
            for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(marker) {
                files.append(String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
            }
        }
        if files.isEmpty { return "files" }
        return files.count <= 3 ? files.joined(separator: ", ") : files.prefix(3).joined(separator: ", ") + " and \(files.count - 3) more"
    }

    private static func firstLine(_ s: String) -> String {
        s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? s
    }

    // MARK: text

    /// Redacts, then caps at `max` characters — in that order.
    static func clean(_ text: String, max: Int = maxEntryChars) -> String {
        InterventionDetector.clip(ContextRedactor.redactedPrefix(text, max), max)
    }

    /// The list's `preview`: the last tool one-liner while the session is
    /// working, otherwise the last line of the assistant's last message.
    static func preview(_ entries: [SessionTranscriptEntry], active: Bool) -> String? {
        if active, let tool = entries.last(where: { $0.role == .tool }) {
            return InterventionDetector.clip(tool.text, previewChars)
        }
        guard let text = entries.last(where: { $0.role == .assistant })?.text else { return nil }
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.isEmpty ? nil : InterventionDetector.clip(line, previewChars)
    }

    // MARK: plaintext

    /// The `transcript` plaintext: `header` (kind, boot, seq, ts,
    /// sessionId) plus the entries, dropping the oldest until it fits in
    /// `maxPlaintextBytes` (then `truncated` is true).
    static func plaintext(header: [String: Any], snapshot: Snapshot, maxBytes: Int = maxPlaintextBytes) -> Data? {
        var entries = snapshot.entries
        var truncated = snapshot.truncated
        while true {
            var obj = header
            obj["entries"] = entries.map(\.jsonObject)
            obj["truncated"] = truncated
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
            if data.count <= maxBytes || entries.isEmpty { return data.count <= maxBytes ? data : nil }
            // Drop a share proportional to the overshoot (at least one row),
            // so a list of 40 near-cap rows doesn't re-encode 40 times.
            let excess = Double(data.count - maxBytes) / Double(data.count)
            entries.removeFirst(max(1, min(entries.count, Int((Double(entries.count) * excess).rounded(.up)))))
            truncated = true
        }
    }
}
