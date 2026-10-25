import Foundation

/// The current turn of a Claude session, read from the end of its
/// transcript: when it started and every tool call made since, with whether
/// each one failed. Shared by the stuck watch (a command failing over and
/// over) and the turn summary on idle pages (files changed, tests run).
struct TurnDigest: Equatable {
    struct Step: Equatable {
        let id: String
        let name: String
        /// Identity for "the same call again": the tool and its input
        /// (Bash: the command alone, since its description varies).
        let key: String
        /// One line for the phone, already redacted ("[Bash] swift test").
        let label: String
        /// nil while the call has no result yet.
        var failed: Bool?
        let at: Date?
        /// Edit / MultiEdit / Write / NotebookEdit target.
        let filePath: String?
        /// Bash command, unredacted (matched against test runners, never sent).
        let command: String?
    }

    /// Timestamp of the user message that started the turn; nil when that
    /// message is older than the window read.
    var turnStartedAt: Date?
    var steps: [Step] = []
    /// The window began mid-turn, so earlier steps aren't in `steps`.
    var truncated = true

    static let maxLabel = 160

    /// Parses JSONL transcript text (typically its last few hundred KB).
    /// Sidechain (subagent) records and meta records are ignored, as in
    /// `InterventionDetector.parseTranscriptTail`.
    static func parse(_ text: String) -> TurnDigest {
        var d = TurnDigest()
        var index: [String: Int] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.first == "{",
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if obj["isSidechain"] as? Bool == true || obj["isMeta"] as? Bool == true { continue }
            guard let type = obj["type"] as? String, type == "assistant" || type == "user",
                  let message = obj["message"] as? [String: Any] else { continue }
            let at = (obj["timestamp"] as? String).flatMap(TranscriptParser.parseISODate)
            let items = message["content"] as? [[String: Any]] ?? []
            if type == "assistant" {
                for item in items where item["type"] as? String == "tool_use" {
                    guard let id = item["id"] as? String, let name = item["name"] as? String, index[id] == nil else { continue }
                    let input = item["input"] as? [String: Any] ?? [:]
                    index[id] = d.steps.count
                    d.steps.append(step(id: id, name: name, input: input, at: at))
                }
            } else {
                let results = items.filter { $0["type"] as? String == "tool_result" }
                if results.isEmpty {
                    // A real user message starts a new turn.
                    d = TurnDigest(turnStartedAt: at, steps: [], truncated: false)
                    index.removeAll()
                    continue
                }
                for r in results {
                    guard let id = r["tool_use_id"] as? String, let i = index[id] else { continue }
                    d.steps[i].failed = r["is_error"] as? Bool == true
                }
            }
        }
        return d
    }

    static func step(id: String, name: String, input: [String: Any], at: Date?) -> Step {
        let command = name == "Bash" ? input["command"] as? String : nil
        let key: String
        if let command {
            key = "Bash:" + command.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        } else {
            let json = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            key = name + ":" + json
        }
        let first = InterventionDetector.describeToolUse(name: name, input: input)
            .split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "[\(name)]"
        let path: String?
        switch name {
        case "Edit", "MultiEdit", "Write": path = input["file_path"] as? String
        case "NotebookEdit": path = input["notebook_path"] as? String
        default: path = nil
        }
        return Step(id: id, name: name, key: key, label: InterventionDetector.clip(first, maxLabel),
                    failed: nil, at: at, filePath: path, command: command)
    }

    /// Files this turn wrote, first-touched order, no duplicates.
    var filesTouched: [String] {
        var seen = Set<String>()
        return steps.compactMap(\.filePath).filter { seen.insert($0).inserted }
    }

    /// The last finished test run this turn: (passed, label), or nil if no
    /// step looked like one.
    var lastTestRun: (passed: Bool, label: String)? {
        for s in steps.reversed() {
            guard let cmd = s.command, let failed = s.failed, Self.looksLikeTests(cmd) else { continue }
            return (!failed, s.label)
        }
        return nil
    }

    /// Whether a shell command runs a test suite.
    static func looksLikeTests(_ command: String) -> Bool {
        let c = " " + command.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") + " "
        // xcodebuild takes its action anywhere among its flags.
        if c.contains(" xcodebuild ") { return c.contains(" test ") || c.contains(" test-without-building ") }
        let markers = [" swift test", " pytest", " py.test", "python -m pytest", "python3 -m pytest",
                       " npm test", " npm run test", " pnpm test", " pnpm run test", " yarn test", " bun test",
                       " jest ", " vitest", " go test", " cargo test", "gradlew test", " mvn test", " rspec",
                       " rake test", " mix test", " dotnet test", " ctest", " make test", " make check",
                       "run-logic-tests", " phpunit", " tox ", " nox "]
        return markers.contains { c.contains($0) }
    }
}
