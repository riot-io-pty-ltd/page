import XCTest
@testable import ClaudePowerMode

/// Agents (Claude Code / Codex) running on local models: the provider
/// store, the background-resume gate, rate-limit walls, the Esc-only
/// battery pause and the Codex stall threshold.
final class LocalModelAgentTests: XCTestCase {
    private let sid = "0b5c2d0e-3f0a-4d3e-9a7c-1c2b3d4e5f60"
    private var savedStoreURL: URL!
    private var dir: URL!

    override func setUp() {
        savedStoreURL = SessionProviderStore.fileURL
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lma-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        SessionProviderStore.fileURL = dir.appendingPathComponent("session-providers.json")
    }

    override func tearDown() {
        SessionProviderStore.fileURL = savedStoreURL
        try? FileManager.default.removeItem(at: dir)
    }

    private func transcript(model: String?) throws -> URL {
        let url = dir.appendingPathComponent("\(UUID().uuidString).jsonl")
        var lines = [#"{"type":"user","message":{"content":"hi"},"cwd":"/tmp"}"#]
        if let model { lines.append(#"{"type":"assistant","message":{"model":"\#(model)","content":[]}}"#) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: SessionProviderStore

    func testStoreRoundTripIsOwnerOnlyAndHoldsNoSecrets() throws {
        SessionProviderStore.record(sessionId: sid.uppercased(), provider: .ollama)
        XCTAssertEqual(SessionProviderStore.provider(for: sid), .ollama, "keys are case-insensitive")
        let perms = try FileManager.default.attributesOfItem(atPath: SessionProviderStore.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        let raw = try String(contentsOf: SessionProviderStore.fileURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("http"), "no URLs")

        SessionProviderStore.record(sessionId: sid, provider: .anthropic)
        XCTAssertEqual(SessionProviderStore.provider(for: sid), .anthropic, "the latest provider wins")
        SessionProviderStore.record(sessionId: sid, provider: .unknown)
        XCTAssertEqual(SessionProviderStore.provider(for: sid), .anthropic, "unknown is never recorded")
        SessionProviderStore.record(sessionId: "not-a-session", provider: .ollama)
        XCTAssertEqual(SessionProviderStore.all().count, 1)
        XCTAssertNil(SessionProviderStore.provider(for: "1b5c2d0e-3f0a-4d3e-9a7c-1c2b3d4e5f60"))
    }

    func testStoreExpiry() {
        let old = Date().addingTimeInterval(-31 * 24 * 3600)
        SessionProviderStore.record(sessionId: sid, provider: .lmStudio, now: old)
        XCTAssertEqual(SessionProviderStore.provider(for: sid, now: old.addingTimeInterval(60)), .lmStudio)
        XCTAssertNil(SessionProviderStore.provider(for: sid), "expired after 30 days")
        // The next write prunes it from the file.
        SessionProviderStore.record(sessionId: "1b5c2d0e-3f0a-4d3e-9a7c-1c2b3d4e5f60", provider: .ollama)
        XCTAssertEqual(Array(SessionProviderStore.all().keys), ["1b5c2d0e-3f0a-4d3e-9a7c-1c2b3d4e5f60"])
    }

    func testStoreCapKeepsNewest() {
        let now = Date()
        var entries: [String: SessionProviderStore.Entry] = [:]
        for i in 0..<(SessionProviderStore.maxEntries + 20) {
            entries[String(format: "%08x-0000-0000-0000-000000000000", i)] =
                .init(provider: .ollama, seenAt: now.addingTimeInterval(TimeInterval(-i)))
        }
        let kept = SessionProviderStore.pruned(entries, now: now)
        XCTAssertEqual(kept.count, SessionProviderStore.maxEntries)
        XCTAssertNotNil(kept["00000000-0000-0000-0000-000000000000"], "newest kept")
        XCTAssertNil(kept[String(format: "%08x-0000-0000-0000-000000000000", SessionProviderStore.maxEntries + 19)], "oldest dropped")
    }

    func testStoreWritesOnlyWhenChangedOrStale() {
        let now = Date()
        XCTAssertTrue(SessionProviderStore.needsWrite(existing: nil, provider: .ollama, now: now))
        let e = SessionProviderStore.Entry(provider: .ollama, seenAt: now.addingTimeInterval(-60))
        XCTAssertFalse(SessionProviderStore.needsWrite(existing: e, provider: .ollama, now: now))
        XCTAssertTrue(SessionProviderStore.needsWrite(existing: e, provider: .anthropic, now: now))
        XCTAssertTrue(SessionProviderStore.needsWrite(existing: e, provider: .ollama, now: now.addingTimeInterval(25 * 3600)))
    }

    // MARK: Registry provider cache

    func testRegistryClassifiesEachProcessOnceAndRecords() {
        var resolved: [Int32] = []
        var recorded: [(String, ModelProvider)] = []
        var start = 1000
        let reg = ClaudeSessionRegistry(
            projectsDirectory: dir.path, sessionsDirectory: dir.path,
            resolveProvider: { pid, _ in resolved.append(pid); return pid == 10 ? .ollama : .anthropic },
            startSeconds: { _ in start },
            recordProvider: { recorded.append(($0, $1)) })
        func live(_ pid: Int32, _ session: String) -> ClaudeLiveSession {
            ClaudeLiveSession(pid: pid, sessionId: session, cwd: "/p", status: .busy, statusUpdatedAt: nil,
                              tty: "ttys001", hasSessionFile: true)
        }
        let other = "1b5c2d0e-3f0a-4d3e-9a7c-1c2b3d4e5f60"
        let first = reg.annotateProviders([live(10, sid), live(11, other)], prune: true)
        XCTAssertEqual(first.map(\.provider), [.ollama, .anthropic])
        XCTAssertTrue(first[0].provider.isLocal)
        _ = reg.annotateProviders([live(10, sid), live(11, other)], prune: true)
        XCTAssertEqual(resolved, [10, 11], "cached per (pid, start)")
        XCTAssertEqual(recorded.map(\.0), [sid, other], "recorded once per session")

        // /resume inside the same process: same provider, new session recorded.
        let third = "2b5c2d0e-3f0a-4d3e-9a7c-1c2b3d4e5f60"
        _ = reg.annotateProviders([live(10, third)])
        XCTAssertEqual(resolved, [10, 11])
        XCTAssertEqual(recorded.last?.0, third)

        // A recycled pid (new start time) is classified again.
        start = 2000
        _ = reg.annotateProviders([live(10, third)])
        XCTAssertEqual(resolved, [10, 11, 10])
    }

    func testUnknownProviderIsNotRecorded() {
        var recorded = 0
        let reg = ClaudeSessionRegistry(projectsDirectory: dir.path, sessionsDirectory: dir.path,
                                        resolveProvider: { _, _ in .unknown }, startSeconds: { _ in 1 },
                                        recordProvider: { _, _ in recorded += 1 })
        let s = ClaudeLiveSession(pid: 10, sessionId: sid, cwd: nil, status: .busy, statusUpdatedAt: nil,
                                  tty: nil, hasSessionFile: true)
        XCTAssertEqual(reg.annotateProviders([s]).first?.provider, .unknown)
        XCTAssertEqual(recorded, 0)
    }

    // MARK: Headless resume gate

    func testHeadlessAllowedBlockedMatrix() {
        typealias E = ResumeProviderGate.Evidence
        XCTAssertNil(ResumeProviderGate.refusal(E(stored: .anthropic, lastAssistantModel: nil)), "store anthropic")
        XCTAssertNil(ResumeProviderGate.refusal(E(stored: .anthropic, lastAssistantModel: "qwen3")), "the store is authoritative")
        XCTAssertNotNil(ResumeProviderGate.refusal(E(stored: .ollama, lastAssistantModel: nil)), "store ollama")
        XCTAssertNotNil(ResumeProviderGate.refusal(E(stored: .ollama, lastAssistantModel: "claude-opus-4-1")))
        XCTAssertNotNil(ResumeProviderGate.refusal(E(stored: .cloudGateway, lastAssistantModel: nil)))
        XCTAssertNotNil(ResumeProviderGate.refusal(E(stored: .otherLocal, lastAssistantModel: nil)))
        XCTAssertNil(ResumeProviderGate.refusal(E(stored: nil, lastAssistantModel: "claude-sonnet-4-5")), "nothing + claude model")
        XCTAssertNotNil(ResumeProviderGate.refusal(E(stored: nil, lastAssistantModel: "qwen3-coder:30b")), "nothing + qwen model")
        XCTAssertNotNil(ResumeProviderGate.refusal(E(stored: nil, lastAssistantModel: nil)), "nothing + nil model")
        XCTAssertNotNil(ResumeProviderGate.refusal(E(stored: nil, lastAssistantModel: "<synthetic>")))
    }

    func testRefusalMessageNamesProviderAndModel() {
        let msg = ResumeProviderGate.refusal(.init(stored: .ollama, lastAssistantModel: "qwen3:8b"))
        XCTAssertEqual(msg, "This session ran on a non-Anthropic model (Ollama / qwen3:8b). Page can't restart it in the "
                       + "background — that would run on your Anthropic account. Reply at the Mac.")
        XCTAssertTrue(ResumeProviderGate.message(.init(stored: nil, lastAssistantModel: nil)).contains("(model unknown)"))
        XCTAssertTrue(ResumeProviderGate.message(.init(stored: .lmStudio, lastAssistantModel: nil)).contains("(LM Studio)"))
        XCTAssertFalse(ResumeProviderGate.message(.init(stored: nil, lastAssistantModel: "a\u{1B}[2Jb")).contains("\u{1B}"))
    }

    func testHeadlessBlockerAppliesProviderEvidence() throws {
        let table = [ProcessRunner.ProcessInfoRow(pid: 1, ppid: 0, tty: "??", command: "/sbin/launchd")]
        XCTAssertNil(InjectionExecutor.headlessBlocker(sessionId: sid, processTable: table, transcript: nil,
                                                       providerEvidence: .init(stored: .anthropic, lastAssistantModel: nil)))
        let why = InjectionExecutor.headlessBlocker(sessionId: sid, processTable: table, transcript: nil,
                                                    providerEvidence: .init(stored: nil, lastAssistantModel: "qwen3"))
        XCTAssertEqual(why?.hasPrefix("This session ran on a non-Anthropic model (qwen3)"), true)

        // Evidence read from disk: store + transcript tail.
        let claude = try transcript(model: "claude-opus-4-1")
        XCTAssertNil(ResumeProviderGate.refusal(ResumeProviderGate.evidence(sessionId: sid, transcript: claude)))
        let local = try transcript(model: "gpt-oss:20b")
        XCTAssertNotNil(ResumeProviderGate.refusal(ResumeProviderGate.evidence(sessionId: sid, transcript: local)))
        SessionProviderStore.record(sessionId: sid, provider: .ollama)
        XCTAssertNotNil(ResumeProviderGate.refusal(ResumeProviderGate.evidence(sessionId: sid, transcript: claude)),
                        "seen live on Ollama: blocked whatever the transcript says")
    }

    // MARK: canResume / scheduled resume

    func testCanResumeRequiresAnthropicEvidence() throws {
        func event(_ path: String) -> RateLimitEvent {
            RateLimitEvent(sessionId: sid, cwd: "/p", projectName: "p", eventTime: Date(), resetTime: Date(),
                           resetTimeText: "", transcriptPath: path)
        }
        XCTAssertTrue(Coordinator.canResume(event(try transcript(model: "claude-opus-4-1").path)))
        XCTAssertFalse(Coordinator.canResume(event(try transcript(model: "qwen3:8b").path)))
        XCTAssertFalse(Coordinator.canResume(event(try transcript(model: nil).path)))
        XCTAssertFalse(Coordinator.canResume(event("")), "no transcript, nothing stored")
        SessionProviderStore.record(sessionId: sid, provider: .anthropic)
        XCTAssertTrue(Coordinator.canResume(event("")), "seen live on Anthropic")
        XCTAssertFalse(Coordinator.canResume(event(""), providerRefusal: { _ in "no" }))
        XCTAssertNil(ResumeProviderGate.refusal(for: event("")))
    }

    // MARK: Rate limits

    private func limitRecord(_ extra: [String: Any] = [:]) -> [String: Any] {
        var obj: [String: Any] = [
            "type": "assistant", "timestamp": "2026-10-07T12:10:23.368Z", "error": "rate_limit",
            "isApiErrorMessage": true, "apiErrorStatus": 429, "sessionId": sid,
            "message": ["model": "<synthetic>", "content": [["type": "text", "text": "You've hit your usage limit."]]],
        ]
        for (k, v) in extra { obj[k] = v }
        return obj
    }

    func testEstimatedWallIsTransientForNonAnthropic() {
        for provider in [ModelProvider.ollama, .lmStudio, .otherLocal, .cloudGateway] {
            guard case .transient = TranscriptParser.classifyRateLimitRecord(limitRecord(), transcriptPath: "/x/-p/s.jsonl",
                                                                             providerFor: { _ in provider }) else {
                return XCTFail("\(provider): expected transient")
            }
        }
        for provider in [ModelProvider.anthropic, .unknown] {
            guard case .event(let e) = TranscriptParser.classifyRateLimitRecord(limitRecord(), transcriptPath: "/x/-p/s.jsonl",
                                                                                providerFor: { _ in provider }) else {
                return XCTFail("\(provider): expected an estimated wall")
            }
            XCTAssertTrue(e.resetTimeIsEstimated)
        }
    }

    func testStructuredWallKeptForNonAnthropic() {
        let obj = limitRecord(["quotaLimits": ["status": "rejected", "resetsAt": 1_791_390_000]])
        guard case .event(let e) = TranscriptParser.classifyRateLimitRecord(obj, transcriptPath: "/x/-p/s.jsonl",
                                                                            providerFor: { _ in .ollama }) else {
            return XCTFail("expected event")
        }
        XCTAssertFalse(e.resetTimeIsEstimated)
        XCTAssertEqual(e.resetTime, Date(timeIntervalSince1970: 1_791_390_000))
    }

    func testIndexPassesProviderThrough() throws {
        let root = dir.appendingPathComponent("projects")
        let proj = root.appendingPathComponent("-p")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        var obj = limitRecord()
        obj["timestamp"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let line = String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        try (line + "\n").write(to: proj.appendingPathComponent("\(sid).jsonl"), atomically: true, encoding: .utf8)
        XCTAssertEqual(RateLimitTranscriptIndex().scan(directory: root.path, lookbackHours: 6).events.count, 1)
        XCTAssertTrue(RateLimitTranscriptIndex(providerFor: { _ in .ollama })
            .scan(directory: root.path, lookbackHours: 6).events.isEmpty)
    }

    // MARK: Battery pause

    func testLocalPauseDetail() {
        XCTAssertEqual(BatteryPauseSupport.localModelPauseDetail(stopped: true),
                       "Interrupted (local model — no summary requested, to save battery)")
        XCTAssertTrue(BatteryPauseSupport.localModelPauseDetail(stopped: false).contains("no summary requested"))
    }

    func testClaudeLocalPauseIsEscOnly() {
        let tmux = InjectionExecutor.TerminalHost.tmux(tmuxPath: "/usr/bin/tmux", paneId: "%1", inMode: false)
        let terminal = InjectionExecutor.TerminalHost.terminalApp(tty: "/dev/ttys004")
        XCTAssertEqual(ClaudeBackend.pauseStrategy(status: .busy, host: tmux, mode: .pause, isLocal: true), .interrupt)
        XCTAssertEqual(ClaudeBackend.pauseStrategy(status: .busy, host: .iTerm(tty: "/dev/ttys1"), mode: .pause, isLocal: true),
                       .interrupt)
        guard case .skip = ClaudeBackend.pauseStrategy(status: .busy, host: terminal, mode: .pause, isLocal: true) else {
            return XCTFail("Terminal.app can't press Esc: a local session is left alone, not queued a summary")
        }
        guard case .skip = ClaudeBackend.pauseStrategy(status: .busy, host: tmux, mode: .afterTurn, isLocal: true) else {
            return XCTFail("after-turn would queue a summary request")
        }
        guard case .skip = ClaudeBackend.pauseStrategy(status: .idle, host: tmux, mode: .pause, isLocal: true) else {
            return XCTFail("idle sessions are left alone")
        }
        guard case .skip = ClaudeBackend.pauseStrategy(status: .busy, host: tmux, mode: .off, isLocal: true) else {
            return XCTFail()
        }
        // Hosted sessions unchanged.
        guard case .queue = ClaudeBackend.pauseStrategy(status: .busy, host: terminal, mode: .pause) else { return XCTFail() }
    }

    func testCodexLocalPauseStrategy() {
        let terminal = CodexInjector.Terminal.terminalApp(tty: "/dev/ttys004")
        guard case .skip = CodexBackend.pauseStrategy(terminal: terminal, mode: .pause, isLocal: true) else {
            return XCTFail("local + Terminal.app → skip")
        }
        guard case .skip = CodexBackend.pauseStrategy(terminal: terminal, mode: .afterTurn, isLocal: true) else {
            return XCTFail()
        }
        XCTAssertEqual(CodexBackend.pauseStrategy(terminal: .tmux(pane: "%3"), mode: .pause, isLocal: true), .interrupt)
        guard case .skip = CodexBackend.pauseStrategy(terminal: .tmux(pane: "%3"), mode: .afterTurn, isLocal: true) else {
            return XCTFail()
        }
        let cmux = CodexInjector.Terminal.cmux(CmuxBridge.Target(surfaceId: "5FA66D62-4F2B-4F19-90BE-80319216DE70",
                                                                 workspaceId: nil, cliPath: "/x/cmux", source: "environment"))
        guard case .skip = CodexBackend.pauseStrategy(terminal: cmux, mode: .afterTurn, isLocal: true) else {
            return XCTFail("local + after-turn must not queue a typed message")
        }
        guard case .queue = CodexBackend.pauseStrategy(terminal: cmux, mode: .afterTurn) else { return XCTFail("hosted unchanged") }
        guard case .skip = CodexBackend.pauseStrategy(terminal: .tmux(pane: "%3"), mode: .off, isLocal: true) else {
            return XCTFail()
        }
    }

    // MARK: Codex stall threshold

    func testCodexStallThresholdLocalVsHosted() {
        var s = CodexRollout.Summary()
        s.phase = .inTurn
        let twentyMinutes: TimeInterval = 20 * 60
        XCTAssertEqual(CodexBackend.deriveState(summary: s, rolloutAge: twentyMinutes, activeWindow: 90), .interrupted)
        XCTAssertEqual(CodexBackend.deriveState(summary: s, rolloutAge: twentyMinutes, activeWindow: 90, isLocal: true), .active)
        XCTAssertEqual(CodexBackend.deriveState(summary: s, rolloutAge: 61 * 60, activeWindow: 90, isLocal: true), .interrupted)
        XCTAssertEqual(CodexBackend.stalledTurnSeconds(isLocal: false), 15 * 60)
        XCTAssertEqual(CodexBackend.stalledTurnSeconds(isLocal: true), 60 * 60)
    }

    func testThreadSummaryDecodesModelProviderLeniently() throws {
        let ok = try JSONDecoder().decode(AppServerProtocol.ThreadSummary.self,
                                          from: Data(#"{"id":"t1","modelProvider":"ollama"}"#.utf8))
        XCTAssertEqual(ok.modelProvider, "ollama")
        let wrongType = try JSONDecoder().decode(AppServerProtocol.ThreadSummary.self,
                                                 from: Data(#"{"id":"t1","modelProvider":{"x":1}}"#.utf8))
        XCTAssertNil(wrongType.modelProvider)
        let absent = try JSONDecoder().decode(AppServerProtocol.ThreadSummary.self, from: Data(#"{"id":"t1"}"#.utf8))
        XCTAssertNil(absent.modelProvider)
    }

    func testThreadIsLocalFromThreadOrOwningProcess() {
        let rollout = "/Users/me/.codex/sessions/rollout-2026-10-24-abc.jsonl"
        let hosted = AppServerProtocol.ThreadSummary(id: "t1", cwd: "/p", path: rollout, updatedAt: nil, modelProvider: "openai")
        let owner = CodexProcess(pid: 42, ppid: 1, tty: "ttys001", cwd: "/p", openRollouts: [rollout], command: "codex")
        let bystander = CodexProcess(pid: 43, ppid: 1, tty: "ttys002", cwd: "/p", openRollouts: [], command: "codex")
        XCTAssertTrue(CodexBackend.threadIsLocal(hosted, rolloutPath: rollout, processes: [owner],
                                                 providerOf: { $0 == 42 ? .ollama : .unknown }))
        XCTAssertFalse(CodexBackend.threadIsLocal(hosted, rolloutPath: rollout, processes: [owner, bystander],
                                                  providerOf: { $0 == 43 ? .ollama : .unknown }),
                       "a local codex that doesn't hold this rollout doesn't count")
        let local = AppServerProtocol.ThreadSummary(id: "t2", cwd: "/p", path: rollout, updatedAt: nil, modelProvider: "lmstudio")
        XCTAssertTrue(CodexBackend.threadIsLocal(local, rolloutPath: rollout, processes: [], providerOf: { _ in .unknown }))
    }
}
