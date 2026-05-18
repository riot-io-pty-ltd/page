import Foundation

enum InterventionKind: String, Codable {
    case permission   // Bash/Edit/Write awaiting approval — iOS decodes as .approval
    case plan         // plan-mode awaiting approval — iOS decodes as .approval (subtype=plan)
    case question     // Codex tool/requestUserInput, hook Notification — iOS decodes as .userInput
    case idle         // session was active, then went quiet — likely waiting on user
}

struct InterventionEvent: Equatable, Hashable, Codable {
    let id: String                 // sessionId + last-event-uuid (stable)
    let sessionId: String
    let cwd: String
    let projectName: String
    let kind: InterventionKind
    let openedAt: Date
    let context: String            // last meaningful line for the iOS preview
    let transcriptPath: String
    /// Which agent fired this. Defaults to `.claude` so existing call sites
    /// don't need to change.
    var backend: AgentBackendID = .claude
    var source: AgentSessionSource = .terminal
    /// Optional sub-tag — e.g. `"plan"` for plan-mode approvals.
    var subtype: String?
}

/// Periodically scans Claude transcripts for sessions that appear to be waiting
/// on the user. Emits new events through `onNewEvent` and surfaces the current
/// set via `currentlyPending`.
final class InterventionDetector {
    var onNewEvent: ((InterventionEvent) -> Void)?
    var onResolved: ((String) -> Void)?   // id of resolved intervention

    private(set) var currentlyPending: [String: InterventionEvent] = [:]
    private let queue = DispatchQueue(label: "ClaudePowerMode.InterventionDetector")
    private var pendingSettleSeconds: TimeInterval = 8       // wait this long after last write to call it "stuck"
    private var idleThresholdSeconds: TimeInterval = 90      // active → idle if no writes in N sec
    private var lookbackHours: Double = 4
    /// Cache of (path → (mtime, last-evaluation)). Skips re-reading a
    /// transcript when its mtime is unchanged. Without this we re-parse
    /// multi-MB Claude transcripts every 15s for every active session.
    private var evalCache: [String: (mtime: Date, event: InterventionEvent?)] = [:]

    func scan(transcriptDirectory: String) {
        let expanded = (transcriptDirectory as NSString).expandingTildeInPath
        let baseURL = URL(fileURLWithPath: expanded)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let liveIds = Self.liveClaudeSessionIds()
        let cutoff = Date().addingTimeInterval(-lookbackHours * 3600)
        let nowEvents: [InterventionEvent] = {
            var found: [InterventionEvent] = []
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard vals?.isRegularFile == true,
                      let mtime = vals?.contentModificationDate,
                      mtime > cutoff else { continue }
                if let evt = scanFileForPending(url, mtime: mtime, liveSessionIds: liveIds) {
                    found.append(evt)
                }
            }
            return found
        }()

        queue.sync {
            let nowIds = Set(nowEvents.map { $0.id })
            let previousIds = Set(currentlyPending.keys)

            // New
            for e in nowEvents where currentlyPending[e.id] == nil {
                currentlyPending[e.id] = e
                onNewEvent?(e)
                Logger.shared.log("Intervention OPENED: \(e.kind.rawValue) in \(e.projectName) (session \(e.sessionId.prefix(8)))")
            }
            // Resolved (previously pending, now gone)
            for id in previousIds.subtracting(nowIds) {
                if let e = currentlyPending.removeValue(forKey: id) {
                    onResolved?(id)
                    Logger.shared.log("Intervention RESOLVED: \(e.kind.rawValue) in \(e.projectName)")
                }
            }
        }
    }

    /// Returns an intervention if the tail of this transcript looks like the
    /// session is waiting on the user. Heuristics:
    /// - Most recent event of type `permission-mode` with no subsequent assistant/user activity → permission
    /// - Most recent event is plan-mode awaiting acceptance → plan
    /// - Latest event was assistant generating, then no writes for > idleThresholdSeconds → idle
    private func scanFileForPending(_ url: URL, mtime: Date, liveSessionIds: Set<String>) -> InterventionEvent? {
        // If the file was just written, give it time to settle.
        if Date().timeIntervalSince(mtime) < pendingSettleSeconds { return nil }

        // mtime cache — if this file is past the idle threshold AND
        // hasn't been touched since our last evaluation, the answer
        // can't change. Skip the file read entirely.
        let path = url.path
        if let cached = evalCache[path],
           cached.mtime == mtime,
           Date().timeIntervalSince(mtime) >= idleThresholdSeconds {
            return cached.event
        }

        // Tail-read: only the last 32 KB is needed for the suffix(15)
        // logic below. Claude transcripts grow into the multi-MB range
        // for long sessions; reading the whole file every 15s eats CPU.
        let text = Self.readTail(of: url, maxBytes: 32_768) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else {
            evalCache[path] = (mtime, nil)
            return nil
        }

        // Walk backwards from the tail; we only care about the last few events.
        let tail = lines.suffix(15)
        var latestType: String?
        /// `latestMeaningfulType` ignores noise events (system/attachment/
        /// permission-mode/turn_duration) and tracks only `assistant` / `user`.
        /// This is what tells us "what's the conversation waiting on right
        /// now" — after a turn ends, the JSONL trailing event is a `system`
        /// `turn_duration` record, not the assistant message, so checking
        /// `latestType` alone never fires the idle heuristic.
        var latestMeaningfulType: String?
        var latestTimestamp: Date?
        var sessionId: String = url.deletingPathExtension().lastPathComponent
        var cwd: String = decodeProjectPath(from: url.deletingLastPathComponent().lastPathComponent)
        var context: String = ""
        var isSidechain = false
        var permissionMode: String?

        for line in tail {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let sid = obj["sessionId"] as? String { sessionId = sid }
            if let c = obj["cwd"] as? String { cwd = c }
            if obj["isSidechain"] as? Bool == true { isSidechain = true }
            if let t = obj["type"] as? String {
                latestType = t
                if t == "assistant" || t == "user" { latestMeaningfulType = t }
            }
            if let ts = obj["timestamp"] as? String, let parsed = TranscriptParser.parseISODate(ts) {
                latestTimestamp = parsed
            }
            if let t = obj["type"] as? String, t == "permission-mode",
               let mode = obj["permissionMode"] as? String {
                permissionMode = mode
            }
            // Pick up any user-visible text for the context preview
            if let msg = obj["message"] as? [String: Any],
               let content = msg["content"] {
                let cArr: [[String: Any]] = (content as? [[String: Any]]) ?? []
                for item in cArr {
                    if let txt = item["text"] as? String, !txt.isEmpty {
                        context = String(txt.prefix(280))
                    } else if let toolName = item["name"] as? String, item["type"] as? String == "tool_use" {
                        let inp = item["input"] as? [String: Any] ?? [:]
                        let desc = inp["description"] as? String ?? inp["command"] as? String ?? ""
                        context = "[\(toolName)] \(desc)".trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }

        // ─── Cache-write rules ─────────────────────────────────────────
        // We only cache (mtime, result) when the result is STABLE for as
        // long as mtime doesn't change. Two reasons not to cache:
        //   1. liveSessionIds can change between scans (user restarts
        //      claude with the same session uuid).
        //   2. The idle event is time-dependent: at age=15s we say "not
        //      yet idle", but at age=95s the same parse means "idle".
        //      Caching the early nil would suppress the eventual idle.
        // Anything else (sidechain; non-assistant tail; firing events) is
        // structurally fixed by the file's content and is safe to cache.

        if isSidechain {
            evalCache[path] = (mtime, nil)
            return nil  // subagent transcripts never directly trigger interventions
        }

        // Hard filter: only fire pages for sessions whose `claude` process is
        // currently running. Otherwise we'd spam the inbox with stale
        // events from sessions the user closed hours/days ago — they can't
        // act on them anyway because the process is dead.
        // Don't cache: liveSessionIds is time-dependent.
        if !liveSessionIds.contains(sessionId) {
            return nil
        }

        let openedAt = latestTimestamp ?? mtime

        // Permission heuristic
        if permissionMode == "ask" {
            let evt = makeEvent(kind: .permission, sessionId: sessionId, cwd: cwd,
                                openedAt: openedAt, context: context, url: url)
            evalCache[path] = (mtime, evt)
            return evt
        }

        // Idle heuristic: the conversation's last *meaningful* event is from
        // the assistant (Claude has spoken, no follow-up from the user) and
        // no transcript writes have happened for the threshold window. This
        // is "Claude finished its turn and is waiting on you."
        _ = latestType  // (kept for future heuristics; not used here)
        if latestMeaningfulType == "assistant" {
            if Date().timeIntervalSince(mtime) > idleThresholdSeconds {
                let evt = makeEvent(kind: .idle, sessionId: sessionId, cwd: cwd,
                                    openedAt: openedAt, context: context, url: url)
                evalCache[path] = (mtime, evt)
                return evt
            }
            // Assistant is the latest meaningful event but we're not yet
            // past the idle threshold. Don't cache — more time will tip
            // this into firing an idle event.
            return nil
        }

        // The conversation isn't waiting on the user (latest meaningful
        // event isn't from the assistant). Stable for this mtime.
        evalCache[path] = (mtime, nil)
        return nil
    }

    /// Reads the last `maxBytes` of a file. If the file is smaller, reads
    /// the whole file. Drops the first (possibly partial) line when the
    /// seek lands mid-line, so the caller can split-by-newline safely.
    private static func readTail(of url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let seekedFromStart = size <= UInt64(maxBytes)
        let offset = seekedFromStart ? 0 : size - UInt64(maxBytes)
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              var text = String(data: data, encoding: .utf8) else { return nil }
        // Drop the first incomplete line when we seeked into the middle.
        if !seekedFromStart, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        return text
    }

    private func makeEvent(kind: InterventionKind, sessionId: String, cwd: String,
                           openedAt: Date, context: String, url: URL) -> InterventionEvent {
        let project = Self.projectName(forCwd: cwd)
        let id = "\(sessionId)-\(kind.rawValue)-\(Int(openedAt.timeIntervalSince1970))"
        let source = InjectionExecutor.source(forSessionId: sessionId)
        return InterventionEvent(
            id: id,
            sessionId: sessionId,
            cwd: cwd,
            projectName: project,
            kind: kind,
            openedAt: openedAt,
            context: context.isEmpty ? "Session waiting for input" : context,
            transcriptPath: url.path,
            backend: .claude,
            source: source
        )
    }

    private func decodeProjectPath(from encoded: String) -> String {
        var s = encoded
        if s.hasPrefix("-") { s.removeFirst() }
        return "/" + s.replacingOccurrences(of: "-", with: "/")
    }

    /// Walks up from `cwd` looking for any common project marker (`.git`,
    /// `Package.swift`, `package.json`, etc.) and returns that folder's name.
    /// If nothing matches and the cwd's basename looks like a generic
    /// subdirectory (`iOS`, `src`, ...), backs up one level. Otherwise
    /// returns the basename as-is.
    static func projectName(forCwd cwd: String) -> String {
        let markers = [".git", "Package.swift", "package.json", "Cargo.toml",
                       "pyproject.toml", "go.mod", "pom.xml", "platformio.ini",
                       "Gemfile", "build.gradle", "build.gradle.kts", "wrangler.toml"]
        let genericSubdirs: Set<String> = [
            "iOS", "android", "src", "test", "tests", "app", "lib",
            "Sources", "Cloudflare", "frontend", "backend",
            "hooks", "Tools", "Resources", "Designs"
        ]
        let fm = FileManager.default
        var current = URL(fileURLWithPath: cwd)
        for _ in 0..<32 where current.path != "/" {
            for marker in markers {
                if fm.fileExists(atPath: current.appendingPathComponent(marker).path) {
                    return current.lastPathComponent
                }
            }
            current = current.deletingLastPathComponent()
        }
        let base = URL(fileURLWithPath: cwd)
        if genericSubdirs.contains(base.lastPathComponent) {
            return base.deletingLastPathComponent().lastPathComponent
        }
        return base.lastPathComponent
    }

    /// Scans currently-running processes for `claude` and pulls UUIDs from
    /// their command lines (e.g. `claude --resume <UUID>`). These are the
    /// only sessions for which we should emit idle / permission interventions.
    /// Processes started bare (`claude` without `--resume`) won't have a UUID
    /// in argv and will be missed — that's an accepted trade-off for v1.
    static func liveClaudeSessionIds() -> Set<String> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-fl", "claude"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return []
        }
        // Drain pipes BEFORE waitUntilExit to avoid the classic deadlock.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""

        let uuidPattern = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        guard let regex = try? NSRegularExpression(pattern: uuidPattern) else { return [] }
        let myPid = ProcessInfo.processInfo.processIdentifier
        var ids = Set<String>()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let pidStr = parts.first, let pid = Int32(pidStr), pid != myPid else { continue }
            let cmd = parts.count > 1 ? String(parts[1]) : ""
            if cmd.contains("ClaudePowerMode") || cmd.contains("page-notify") { continue }
            let nsCmd = cmd as NSString
            let range = NSRange(location: 0, length: nsCmd.length)
            regex.enumerateMatches(in: cmd, options: [], range: range) { match, _, _ in
                guard let r = match?.range else { return }
                ids.insert(nsCmd.substring(with: r))
            }
        }
        return ids
    }
}

extension TranscriptParser {
    /// Public ISO8601 date helper reused by InterventionDetector.
    static func parseISODate(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}
