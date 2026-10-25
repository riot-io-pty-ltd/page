import Foundation

/// Pages when a Claude session is busy but getting nowhere: the same call
/// failing again and again, nothing written for a long time, or a
/// background workflow that stopped making progress. Approvals and
/// questions already page; these are the agents that never ask and quietly
/// burn tokens or time.
///
/// Pages are `kind: idle` with a `subtype` (`looping`, `stuck`,
/// `workflow_stalled`), the way low-battery pages work, so older phones
/// show them as a session waiting for a reply, which is safe: a reply is
/// typed as a message (queued while the session is busy), and Approve/Deny
/// never reach a menu. A Deny on a looping/stuck page means Stop (Esc).
enum StuckWatch {
    struct Settings: Equatable {
        /// Busy with nothing written to the transcript (or a subagent's)
        /// for this long.
        var quietAfter: TimeInterval = 15 * 60
        /// The same call failing this many times in a row.
        var repeatsInARow = 3
        /// ...or this many times among the last `recentWindow` finished calls.
        var repeatsRecent = 5
        var recentWindow = 12
        /// A stalled workflow pages only if its last write is newer than
        /// this: older runs are abandoned, not stuck.
        var workflowMaxQuiet: TimeInterval = 4 * 3600
    }

    enum Finding: Equatable {
        case looping(label: String, count: Int, since: Date)
        case quiet(lastStep: String?, since: Date)
        case workflowStalled(runId: String, name: String, done: Int, total: Int, since: Date)

        var subtype: String {
            switch self {
            case .looping: return "looping"
            case .quiet: return "stuck"
            case .workflowStalled: return "workflow_stalled"
            }
        }

        var since: Date {
            switch self {
            case .looping(_, _, let d), .quiet(_, let d), .workflowStalled(_, _, _, _, let d): return d
            }
        }
    }

    /// Pure. What, if anything, is wrong with a busy session's turn.
    /// `lastProgressAt` is the newest write to its transcript or its
    /// subagents' transcripts.
    static func evaluateBusy(digest: TurnDigest?, statusUpdatedAt: Date?, lastProgressAt: Date?,
                             now: Date, settings: Settings) -> Finding? {
        if let digest, let loop = looping(digest.steps, settings: settings) { return loop }
        guard let progress = lastProgressAt,
              now.timeIntervalSince(progress) >= settings.quietAfter,
              now.timeIntervalSince(statusUpdatedAt ?? .distantPast) >= settings.quietAfter else { return nil }
        let last = digest?.steps.last { $0.failed == nil } ?? digest?.steps.last
        return .quiet(lastStep: last?.label, since: progress)
    }

    /// Pure. A call that keeps failing: `repeatsInARow` identical failing
    /// calls ending the turn so far, or one call failing `repeatsRecent`
    /// times among the last `recentWindow` finished calls (fix, retest,
    /// fail, fix, retest, fail...).
    static func looping(_ steps: [TurnDigest.Step], settings: Settings) -> Finding? {
        let finished = steps.filter { $0.failed != nil }
        guard let last = finished.last, last.failed == true else { return nil }
        var streak = finished.reversed().prefix { $0.key == last.key && $0.failed == true }.map { $0 }
        if streak.count >= settings.repeatsInARow {
            streak.reverse()
            return .looping(label: last.label, count: streak.count, since: streak.first?.at ?? last.at ?? .distantPast)
        }
        let recent = finished.suffix(settings.recentWindow).filter { $0.key == last.key && $0.failed == true }
        if recent.count >= settings.repeatsRecent {
            return .looping(label: last.label, count: recent.count, since: recent.first?.at ?? last.at ?? .distantPast)
        }
        return nil
    }

    /// Pure. The first stalled workflow worth paging about.
    static func evaluateWorkflows(_ runs: [WorkflowRunInfo], now: Date, settings: Settings) -> Finding? {
        for run in runs where run.status == "stalled" {
            let last = run.agents.compactMap(\.lastActivityAt).max() ?? run.startedAt
            guard let last, now.timeIntervalSince(last) <= settings.workflowMaxQuiet else { continue }
            return .workflowStalled(runId: run.id, name: run.name, done: run.done, total: run.total, since: last)
        }
        return nil
    }

    static func context(for finding: Finding, now: Date) -> String {
        switch finding {
        case .looping(let label, let count, _):
            return InterventionDetector.clip("Looks stuck in a loop: this has failed \(count) times.\n\(label)",
                                             InterventionDetector.contextLimit)
        case .quiet(let last, let since):
            let mins = max(1, Int(now.timeIntervalSince(since) / 60))
            var s = "No progress for \(mins) min — it may be hung."
            if let last { s += "\nLast step: \(last)" }
            return InterventionDetector.clip(s, InterventionDetector.contextLimit)
        case .workflowStalled(_, let name, let done, let total, let since):
            let mins = max(1, Int(now.timeIntervalSince(since) / 60))
            return InterventionDetector.clip(
                "Workflow \(name) stopped making progress: nothing written for \(mins) min (\(done)/\(total) agents done).",
                InterventionDetector.contextLimit)
        }
    }

    /// The page for a finding. The id's kind token is the subtype, so a new
    /// finding (or the same one starting again later) is a new page, while
    /// the same ongoing finding keeps its id across ticks.
    static func page(for finding: Finding, session: ClaudeLiveSession, cwd: String, transcriptPath: String,
                     now: Date) -> InterventionEvent {
        let epoch = Int(finding.since.timeIntervalSince1970)
        return InterventionEvent(
            id: "\(session.sessionId)-\(finding.subtype)-\(epoch)",
            sessionId: session.sessionId,
            cwd: cwd,
            projectName: InterventionDetector.projectName(forCwd: cwd),
            kind: .idle,
            openedAt: now,
            context: context(for: finding, now: now),
            transcriptPath: transcriptPath,
            backend: .claude,
            source: .terminal,
            subtype: finding.subtype,
            pid: session.pid,
            stateStartedAt: session.statusUpdatedAt
        )
    }

    static let subtypes: Set<String> = ["looping", "stuck", "workflow_stalled"]

    /// Whether a page id belongs to the stuck watch (kind token is a subtype).
    static func isStuckId(_ id: String) -> Bool {
        InterventionDetector.parseInterventionId(id).map { subtypes.contains($0.kind) } ?? false
    }
}

/// The stateful side: which sessions have an open stuck page, throttled
/// reads, and the workflow scanner. Tick queue only.
final class StuckMonitor {
    /// Open pages by session id.
    private(set) var pages: [String: InterventionEvent] = [:]
    private var lastWorkflowCheck: [String: Date] = [:]
    private var workflowFindings: [String: StuckWatch.Finding] = [:]
    private let scanner = SessionWorkflowScanner()
    /// Workflows are re-read at most this often per session.
    static let workflowInterval: TimeInterval = 60

    struct Update {
        var opened: [InterventionEvent] = []
        var resolved: [InterventionEvent] = []
    }

    /// `blocked`: sessions with another open page (approval, question,
    /// idle). A stuck page would supersede it on the relay, so none opens.
    func scan(sessions: [ClaudeLiveSession], transcripts: [String: URL], blocked: Set<String>,
              settings: StuckWatch.Settings, now: Date = Date()) -> Update {
        var desired: [String: InterventionEvent] = [:]
        let live = Set(sessions.map(\.sessionId))
        for session in sessions where !blocked.contains(session.sessionId) {
            guard let url = transcripts[session.sessionId] else { continue }
            let cwd = session.cwd ?? ""
            var finding: StuckWatch.Finding?
            if session.status == .busy {
                let progress = Self.lastProgress(transcript: url)
                // Only read the tail when it could matter: a loop needs new
                // writes, which `cachedDigest` keys on.
                let digest = cachedDigest(url)
                finding = StuckWatch.evaluateBusy(digest: digest, statusUpdatedAt: session.statusUpdatedAt,
                                                  lastProgressAt: progress, now: now, settings: settings)
            }
            if finding == nil {
                finding = workflowFinding(session: session, transcript: url, now: now, settings: settings)
            }
            guard let finding else { continue }
            let page = StuckWatch.page(for: finding, session: session, cwd: cwd, transcriptPath: url.path, now: now)
            // Keep the open page (and its original context) while the same
            // finding lasts.
            if let open = pages[session.sessionId], open.id == page.id {
                desired[session.sessionId] = open
            } else {
                desired[session.sessionId] = page
            }
        }
        var update = Update()
        for (sid, page) in desired where pages[sid]?.id != page.id { update.opened.append(page) }
        for (sid, page) in pages where desired[sid]?.id != page.id { update.resolved.append(page) }
        pages = desired
        for sid in lastWorkflowCheck.keys where !live.contains(sid) {
            lastWorkflowCheck.removeValue(forKey: sid)
            workflowFindings.removeValue(forKey: sid)
        }
        for path in digests.keys where !transcripts.values.contains(where: { $0.path == path }) {
            digests.removeValue(forKey: path)
        }
        for e in update.opened {
            Logger.shared.log("Stuck watch OPENED: \(e.subtype ?? "?") in \(e.projectName) (session \(e.sessionId.prefix(8)))")
        }
        return update
    }

    func reset() -> [InterventionEvent] {
        let all = Array(pages.values)
        pages.removeAll()
        workflowFindings.removeAll()
        lastWorkflowCheck.removeAll()
        return all
    }

    func page(id: String) -> InterventionEvent? { pages.values.first { $0.id == id } }

    // MARK: IO

    private var digests: [String: (size: UInt64, mtime: Date, digest: TurnDigest)] = [:]

    private func cachedDigest(_ url: URL) -> TurnDigest? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        if let c = digests[url.path], c.size == size, c.mtime == mtime { return c.digest }
        guard let tail = InterventionDetector.readTail(of: url, maxBytes: 512 * 1024) else { return nil }
        let digest = TurnDigest.parse(tail.text)
        digests[url.path] = (size, mtime, digest)
        return digest
    }

    private func workflowFinding(session: ClaudeLiveSession, transcript: URL, now: Date,
                                 settings: StuckWatch.Settings) -> StuckWatch.Finding? {
        let sid = session.sessionId
        if let at = lastWorkflowCheck[sid], now.timeIntervalSince(at) < Self.workflowInterval {
            return workflowFindings[sid]
        }
        lastWorkflowCheck[sid] = now
        // Cheap pre-check: any run without an end record? The scanner (which
        // may read the transcript for names) runs only then.
        var finding: StuckWatch.Finding?
        if Self.hasUnfinishedRun(transcript: transcript.path) {
            finding = StuckWatch.evaluateWorkflows(scanner.runs(transcript: transcript.path, now: now),
                                                   now: now, settings: settings)
        }
        workflowFindings[sid] = finding
        return finding
    }

    static func hasUnfinishedRun(transcript: String) -> Bool {
        let fm = FileManager.default
        let endDir = SessionWorkflows.sessionDir(transcript: transcript) + "/workflows"
        guard let ids = try? fm.contentsOfDirectory(atPath: SessionWorkflows.runsDir(transcript: transcript)) else { return false }
        return ids.contains { $0.hasPrefix("wf_") && !fm.fileExists(atPath: endDir + "/\($0).json") }
    }

    /// Newest write to the transcript or to any subagent transcript (a
    /// Task/Agent call or a workflow writes there, not to the session's own
    /// file). The subagent directory is listed only when the transcript
    /// itself has been quiet for a while.
    static func lastProgress(transcript: URL) -> Date? {
        let fm = FileManager.default
        func mtime(_ path: String) -> Date? { (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date }
        guard var newest = mtime(transcript.path) else { return nil }
        guard Date().timeIntervalSince(newest) > 60 else { return newest }
        let sub = SessionWorkflows.sessionDir(transcript: transcript.path) + "/subagents"
        for name in (try? fm.contentsOfDirectory(atPath: sub)) ?? [] {
            if name.hasSuffix(".jsonl"), let m = mtime(sub + "/" + name), m > newest { newest = m }
        }
        let runs = sub + "/workflows"
        let ended = SessionWorkflows.sessionDir(transcript: transcript.path) + "/workflows"
        for run in (try? fm.contentsOfDirectory(atPath: runs)) ?? []
        where run.hasPrefix("wf_") && !fm.fileExists(atPath: ended + "/\(run).json") {
            for name in (try? fm.contentsOfDirectory(atPath: runs + "/" + run)) ?? [] where name.hasSuffix(".jsonl") {
                if let m = mtime(runs + "/" + run + "/" + name), m > newest { newest = m }
            }
        }
        return newest
    }
}
