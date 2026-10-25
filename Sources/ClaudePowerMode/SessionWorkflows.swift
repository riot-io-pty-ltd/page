import Foundation

/// A Claude Code session's dynamic workflows, read from the files Claude
/// Code keeps beside the session transcript, for the phone's `workflows`
/// kind (SESSIONS-PROTOCOL.md §4). Read-only; never touches the terminal.
///
///   <session>.jsonl                                 the session transcript: a
///                                                   Workflow tool result says
///                                                   "Transcript dir: …/<runId>"
///                                                   and "Script file: …"
///   <session>/subagents/workflows/<runId>/
///       journal.jsonl                               {"type":"started","agentId",
///                                                   "label","phase"} / {"type":"result",…}
///       agent-<agentId>.jsonl                       each agent's transcript
///   <session>/workflows/<runId>.json                written when a run ends:
///                                                   status, workflowName, totalTokens…
///
/// The format is undocumented: every field is optional and anything
/// unexpected leaves that run with less detail, never an error.
struct WorkflowRunInfo: Equatable {
    struct Agent: Equatable {
        let id: String
        let label: String
        let phase: String?
        let done: Bool
        let lastActivityAt: Date?
    }

    let id: String
    var name: String
    var summary: String?
    /// running, completed, failed, killed, or stalled (no file written for a
    /// while and no end record: likely stopped with its session).
    var status: String
    var phase: String?
    var done: Int
    var total: Int
    var startedAt: Date?
    var endedAt: Date?
    var tokens: Int?
    var agents: [Agent]

    var isRunning: Bool { status == "running" }

    var jsonObject: [String: Any] {
        func ms(_ d: Date?) -> Any { d.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? NSNull() }
        return [
            "id": id, "name": name, "summary": summary ?? NSNull(), "status": status, "phase": phase ?? NSNull(),
            "done": done, "total": total, "startedAt": ms(startedAt), "endedAt": ms(endedAt),
            "tokens": tokens ?? NSNull(),
            "agents": agents.map { a in
                ["id": a.id, "label": a.label, "phase": a.phase ?? NSNull(), "state": a.done ? "done" : "running",
                 "lastActivityAt": ms(a.lastActivityAt)] as [String: Any]
            },
        ]
    }
}

enum SessionWorkflows {
    static let maxRuns = 12
    static let maxAgents = 100
    static let maxName = 80
    static let maxSummary = 300
    static let maxLabel = 160
    static let maxPhase = 60
    static let maxPlaintextBytes = 64 * 1024
    /// Finished runs older than this aren't listed.
    static let finishedWindow: TimeInterval = 24 * 3600
    /// A run with no end record and no file written for this long is shown
    /// as stalled rather than running.
    static let stallAfter: TimeInterval = 20 * 60
    static let interval: TimeInterval = 3

    /// Run and agent ids come from the phone (watch op) and become path
    /// components: only plain ids are accepted.
    static func isSafeId(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-"
        }
    }

    static func sessionDir(transcript: String) -> String {
        transcript.hasSuffix(".jsonl") ? String(transcript.dropLast(6)) : transcript
    }

    static func runsDir(transcript: String) -> String {
        sessionDir(transcript: transcript) + "/subagents/workflows"
    }

    /// The agent's transcript, or nil for unsafe ids.
    static func agentTranscript(transcript: String, runId: String, agentId: String) -> String? {
        guard isSafeId(runId), isSafeId(agentId) else { return nil }
        return runsDir(transcript: transcript) + "/\(runId)/agent-\(agentId).jsonl"
    }

    // MARK: pure parsing

    struct Launch: Equatable {
        let runId: String
        var summary: String?
        var scriptPath: String?
        var at: Date?
    }

    /// A Workflow tool result: "Workflow launched in background. Task ID: …
    /// Summary: … Transcript dir: …/<runId> Script file: … (Edit this…".
    static func launch(fromToolResult text: String, at: Date?) -> Launch? {
        guard text.contains("Workflow launched"),
              let dirRange = text.range(of: "Transcript dir: ") else { return nil }
        let afterDir = text[dirRange.upperBound...]
        let dir = afterDir.prefix { !$0.isWhitespace }
        let runId = (String(dir) as NSString).lastPathComponent
        guard runId.hasPrefix("wf_"), isSafeId(runId) else { return nil }
        var out = Launch(runId: runId, at: at)
        if let s = text.range(of: "Summary: ") {
            let summary = text[s.upperBound..<dirRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            out.summary = summary.isEmpty ? nil : summary
        }
        if let f = text.range(of: "Script file: ") {
            let path = text[f.upperBound...].prefix { !$0.isNewline && $0 != " " }
            out.scriptPath = path.isEmpty ? nil : String(path)
        }
        return out
    }

    /// Launches recorded in a chunk of session transcript lines.
    static func launches(inTranscriptLines data: Data) -> [Launch] {
        var out: [Launch] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where line.count < 4 << 20 {
            // Cheap filter before parsing JSON.
            guard line.range(of: Data("Workflow launched".utf8)) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let at = (obj["timestamp"] as? String).flatMap(parseDate)
            let content = (obj["message"] as? [String: Any])?["content"]
            for item in (content as? [[String: Any]]) ?? [] where item["type"] as? String == "tool_result" {
                var texts: [String] = []
                if let s = item["content"] as? String { texts.append(s) }
                for part in (item["content"] as? [[String: Any]]) ?? [] { if let s = part["text"] as? String { texts.append(s) } }
                for t in texts { if let l = launch(fromToolResult: t, at: at) { out.append(l) } }
            }
        }
        return out
    }

    struct Journal: Equatable {
        /// In start order.
        var agents: [(id: String, label: String, phase: String?)] = []
        var finished = Set<String>()

        static func == (a: Journal, b: Journal) -> Bool {
            a.agents.map(\.id) == b.agents.map(\.id) && a.finished == b.finished
        }
    }

    static func journal(_ data: Data) -> Journal {
        var j = Journal()
        var seen = Set<String>()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = obj["type"] as? String, let id = obj["agentId"] as? String, isSafeId(id) else { continue }
            switch type {
            case "started":
                guard seen.insert(id).inserted else { continue }
                j.agents.append((id, (obj["label"] as? String) ?? "agent", obj["phase"] as? String))
            case "result":
                j.finished.insert(id)
            default:
                continue
            }
        }
        return j
    }

    /// `name: '…'` from the script's `export const meta = { … }`.
    static func scriptName(_ script: String) -> String? {
        guard let meta = script.range(of: "export const meta") else { return nil }
        let head = script[meta.upperBound...].prefix(4000)
        guard let m = head.range(of: #"name\s*:\s*['"`]([^'"`\n]{1,120})['"`]"#, options: .regularExpression) else { return nil }
        let match = String(head[m])
        guard let q = match.firstIndex(where: { $0 == "'" || $0 == "\"" || $0 == "`" }) else { return nil }
        return String(match[match.index(after: q)..<match.index(before: match.endIndex)])
    }

    struct EndRecord: Equatable {
        var status: String?
        var name: String?
        var summary: String?
        var tokens: Int?
        var startedAt: Date?
        var endedAt: Date?
    }

    static func endRecord(_ data: Data) -> EndRecord? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var r = EndRecord()
        r.status = obj["status"] as? String
        r.name = obj["workflowName"] as? String
        r.summary = obj["summary"] as? String
        r.tokens = (obj["totalTokens"] as? NSNumber)?.intValue
        if let start = (obj["startTime"] as? NSNumber)?.doubleValue { r.startedAt = Date(timeIntervalSince1970: start / 1000) }
        if let s = r.startedAt, let d = (obj["durationMs"] as? NSNumber)?.doubleValue {
            r.endedAt = s.addingTimeInterval(d / 1000)
        } else if let ts = (obj["timestamp"] as? String).flatMap(parseDate) {
            r.endedAt = ts
        }
        return r
    }

    /// One run from what was read. Pure.
    static func run(id: String, launch: Launch?, scriptName: String?, journal: Journal, end: EndRecord?,
                    agentActivity: [String: Date], runStartedAt: Date?, now: Date) -> WorkflowRunInfo {
        let lastWrite = agentActivity.values.max()
        var status = end?.status ?? "running"
        if end == nil, let last = lastWrite ?? runStartedAt, now.timeIntervalSince(last) > stallAfter { status = "stalled" }
        let agents = journal.agents.map { a in
            WorkflowRunInfo.Agent(id: a.id, label: clip(ContextRedactor.redact(a.label), maxLabel),
                                  phase: a.phase.map { clip($0, maxPhase) },
                                  done: journal.finished.contains(a.id), lastActivityAt: agentActivity[a.id])
        }
        // Running first (newest first), then finished (most recent first).
        let ordered = agents.filter { !$0.done }.reversed() + agents.filter(\.done).sorted {
            ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
        }
        let name = end?.name ?? scriptName ?? id
        let summary = (end?.summary ?? launch?.summary).map { clip(ContextRedactor.redact($0), maxSummary) }
        return WorkflowRunInfo(
            id: id, name: clip(name, maxName), summary: summary, status: status,
            phase: journal.agents.last?.phase.map { clip($0, maxPhase) },
            done: journal.finished.intersection(journal.agents.map(\.id)).count, total: journal.agents.count,
            startedAt: end?.startedAt ?? launch?.at ?? runStartedAt,
            endedAt: end?.endedAt, tokens: end?.tokens,
            agents: Array(ordered.prefix(maxAgents)))
    }

    /// Which runs the phone sees: running and stalled ones, then finished
    /// ones from the last day; newest first; capped.
    static func listed(_ runs: [WorkflowRunInfo], now: Date) -> [WorkflowRunInfo] {
        let recent = runs.filter { r in
            if r.isRunning || r.status == "stalled" { return true }
            guard let end = r.endedAt ?? r.startedAt else { return false }
            return now.timeIntervalSince(end) <= finishedWindow
        }
        let sorted = recent.sorted { a, b in
            if a.isRunning != b.isRunning { return a.isRunning }
            return (a.startedAt ?? .distantPast) > (b.startedAt ?? .distantPast)
        }
        return Array(sorted.prefix(maxRuns))
    }

    /// The `workflows` plaintext; agents are dropped from the largest runs
    /// until it fits.
    static func plaintext(header: [String: Any], runs: [WorkflowRunInfo]) -> Data? {
        var runs = runs
        while true {
            var obj = header
            obj["runs"] = runs.map(\.jsonObject)
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
            if data.count <= maxPlaintextBytes { return data }
            guard let i = runs.indices.max(by: { runs[$0].agents.count < runs[$1].agents.count }),
                  !runs[i].agents.isEmpty else { return nil }
            runs[i].agents.removeLast(max(1, runs[i].agents.count / 4))
        }
    }

    static func clip(_ s: String, _ max: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > max ? String(t.prefix(max - 1)) + "…" : t
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

/// Reads a session's workflows from disk, caching what didn't change.
/// Session transcripts run to hundreds of MB, so launches are found by
/// reading appended bytes forward and, only while some run still lacks its
/// launch record, earlier bytes backwards from the end (running workflows
/// were launched recently). Journals and end records are re-read only when
/// their size or mtime moves. Not thread-safe: used from one queue.
final class SessionWorkflowScanner {
    private struct Stamp: Equatable { let size: UInt64; let mtime: Date }

    /// Everything before `tail` and at or after `head` has been scanned.
    private var tail: [String: UInt64] = [:]
    private var head: [String: UInt64] = [:]
    private var launches: [String: [String: SessionWorkflows.Launch]] = [:]
    private var journals: [String: (Stamp, SessionWorkflows.Journal)] = [:]
    private var ends: [String: (Stamp, SessionWorkflows.EndRecord?)] = [:]
    private var scriptNames: [String: String?] = [:]

    /// Bytes of session transcript read per chunk, and per call in all, so
    /// a huge transcript is searched over a few calls rather than one stall.
    static let chunk: UInt64 = 8 << 20
    static let maxScanPerCall: UInt64 = 32 << 20

    func runs(transcript: String, now: Date = Date()) -> [WorkflowRunInfo] {
        let fm = FileManager.default
        let runsDir = SessionWorkflows.runsDir(transcript: transcript)
        let endDir = SessionWorkflows.sessionDir(transcript: transcript) + "/workflows"
        guard let all = try? fm.contentsOfDirectory(atPath: runsDir) else { return [] }
        let ids = all.filter { SessionWorkflows.isSafeId($0) && $0.hasPrefix("wf_") }
        let endRecords = Dictionary(uniqueKeysWithValues: ids.map { ($0, cachedEnd(endDir + "/\($0).json")) })
        // A run's name comes from its end record, else its launch record.
        scanLaunches(transcript, needed: Set(ids.filter { endRecords[$0] ?? nil == nil }))
        var out: [WorkflowRunInfo] = []
        for id in ids {
            let dir = runsDir + "/" + id
            let journal = cachedJournal(dir + "/journal.jsonl")
            let end = endRecords[id] ?? nil
            var activity: [String: Date] = [:]
            for a in journal.agents {
                if let st = stamp(dir + "/agent-\(a.id).jsonl") { activity[a.id] = st.mtime }
            }
            let launch = launches[transcript]?[id]
            let name = launch?.scriptPath.flatMap(cachedScriptName)
            let started = (try? fm.attributesOfItem(atPath: dir))?[.creationDate] as? Date
            out.append(SessionWorkflows.run(id: id, launch: launch, scriptName: name, journal: journal, end: end,
                                            agentActivity: activity, runStartedAt: started, now: now))
        }
        return SessionWorkflows.listed(out, now: now)
    }

    private func scanLaunches(_ transcript: String, needed: Set<String>) {
        guard let st = stamp(transcript), let fh = FileHandle(forReadingAtPath: transcript) else { return }
        defer { try? fh.close() }
        if let t = tail[transcript], st.size < t {   // rewritten: start over
            tail[transcript] = nil; head[transcript] = nil; launches[transcript] = nil
        }
        if tail[transcript] == nil { tail[transcript] = st.size; head[transcript] = st.size }
        var found = launches[transcript] ?? [:]
        var budget = Self.maxScanPerCall

        // Forward: what was appended since the last call.
        while var t = tail[transcript], t < st.size, budget > 0 {
            let length = min(st.size - t, Self.chunk)
            guard (try? fh.seek(toOffset: t)) != nil, let data = try? fh.read(upToCount: Int(length)), !data.isEmpty else { break }
            budget -= min(budget, length)
            guard let nl = data.lastIndex(of: UInt8(ascii: "\n")) else {
                if length == Self.chunk { tail[transcript] = t + length }   // one giant line: skip it
                break
            }
            let whole = data[data.startIndex...nl]
            for l in SessionWorkflows.launches(inTranscriptLines: Data(whole)) { found[l.runId] = l }
            t += UInt64(whole.count)
            tail[transcript] = t
        }

        // Backward: only while a run still has no launch record.
        while var h = head[transcript], h > 0, budget > 0, !needed.subtracting(found.keys).isEmpty {
            let start = h > Self.chunk ? h - Self.chunk : 0
            guard (try? fh.seek(toOffset: start)) != nil, let data = try? fh.read(upToCount: Int(h - start)), !data.isEmpty else { break }
            budget -= min(budget, h - start)
            var body = data[data.startIndex...]
            if start > 0 {
                // The first line may begin before `start`: leave it for the next chunk.
                guard let nl = data.firstIndex(of: UInt8(ascii: "\n")) else { head[transcript] = start; continue }
                body = data[data.index(after: nl)...]
                h = start + UInt64(data.distance(from: data.startIndex, to: data.index(after: nl)))
            } else {
                h = 0
            }
            for l in SessionWorkflows.launches(inTranscriptLines: Data(body)) where found[l.runId] == nil { found[l.runId] = l }
            head[transcript] = h
        }
        launches[transcript] = found
    }

    private func cachedJournal(_ path: String) -> SessionWorkflows.Journal {
        guard let st = stamp(path) else { return SessionWorkflows.Journal() }
        if let c = journals[path], c.0 == st { return c.1 }
        let j = BoundedFileRead.read(path, maxBytes: 16 << 20).map(SessionWorkflows.journal) ?? SessionWorkflows.Journal()
        journals[path] = (st, j)
        return j
    }

    private func cachedEnd(_ path: String) -> SessionWorkflows.EndRecord? {
        guard let st = stamp(path) else { return nil }
        if let c = ends[path], c.0 == st { return c.1 }
        let r = BoundedFileRead.read(path, maxBytes: 1 << 20).flatMap(SessionWorkflows.endRecord)
        ends[path] = (st, r)
        return r
    }

    private func cachedScriptName(_ path: String) -> String? {
        if let c = scriptNames[path] { return c }
        let name = BoundedFileRead.read(path, maxBytes: 256 << 10)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(SessionWorkflows.scriptName)
        scriptNames[path] = name
        return name
    }

    private func stamp(_ path: String) -> Stamp? {
        guard let s = SessionRemote.fileStamp(path) else { return nil }
        return Stamp(size: s.size, mtime: s.mtime)
    }

    /// Forget a session no one watches any more.
    func forget(transcript: String) {
        tail[transcript] = nil
        head[transcript] = nil
        launches[transcript] = nil
        let prefix = SessionWorkflows.sessionDir(transcript: transcript) + "/"
        journals = journals.filter { !$0.key.hasPrefix(prefix) }
        ends = ends.filter { !$0.key.hasPrefix(prefix) }
    }
}
