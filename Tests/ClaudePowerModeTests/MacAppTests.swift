import XCTest
import IOKit.ps
@testable import ClaudePowerMode

final class ConfigValidationTests: XCTestCase {
    func testDefaultsAreAlreadyValid() {
        let (c, notes) = Config().validated()
        XCTAssertEqual(c, Config())
        XCTAssertTrue(notes.isEmpty, "\(notes)")
    }

    func testCheckIntervalIsClamped() {
        var c = Config()
        c.checkIntervalSeconds = 0
        XCTAssertEqual(c.validated().config.checkIntervalSeconds, 2)
        c.checkIntervalSeconds = -10
        XCTAssertEqual(c.validated().config.checkIntervalSeconds, 2)
        c.checkIntervalSeconds = 100_000
        XCTAssertEqual(c.validated().config.checkIntervalSeconds, 600)
        c.checkIntervalSeconds = .nan
        XCTAssertEqual(c.validated().config.checkIntervalSeconds, Config().checkIntervalSeconds)
        c.checkIntervalSeconds = .infinity
        XCTAssertEqual(c.validated().config.checkIntervalSeconds, Config().checkIntervalSeconds)
    }

    func testBatteryThresholdsClampedAndOrdered() {
        var c = Config()
        c.lowBatteryCutoff = -5
        c.recoveryThreshold = 250
        var v = c.validated()
        XCTAssertEqual(v.config.lowBatteryCutoff, 0)
        XCTAssertEqual(v.config.recoveryThreshold, 100)
        XCTAssertEqual(v.adjustments.count, 2)

        c.lowBatteryCutoff = 40
        c.recoveryThreshold = 20
        v = c.validated()
        XCTAssertEqual(v.config.recoveryThreshold, 40, "recovery must never be below the cutoff")

        c.recoveryThreshold = 40
        XCTAssertTrue(c.validated().adjustments.isEmpty, "equal is a valid hysteresis")
    }

    func testStringsTrimmedAndEmptyFallBack() {
        var c = Config()
        c.carryOnPrompt = "   "
        c.claudeProcessPattern = ""
        c.relayURL = "  https://x.example.workers.dev \n"
        c.codexPath = " /opt/homebrew/bin/codex "
        c.excludePatterns = ["", " ClaudePowerMode "]
        let v = c.validated().config
        XCTAssertEqual(v.carryOnPrompt, "carry on")
        XCTAssertEqual(v.claudeProcessPattern, "claude")
        XCTAssertEqual(v.relayURL, "https://x.example.workers.dev")
        XCTAssertEqual(v.codexPath, "/opt/homebrew/bin/codex")
        XCTAssertEqual(v.excludePatterns, ["ClaudePowerMode"])
    }

    func testPagingRangesClamped() {
        var c = Config()
        c.idlePageOnlyWhenAwaySeconds = -1
        c.idlePageDelaySeconds = 99_999
        c.holdAwakeForPendingPageMinutes = 100_000
        let v = c.validated().config
        XCTAssertEqual(v.idlePageOnlyWhenAwaySeconds, 0)
        XCTAssertEqual(v.idlePageDelaySeconds, Config.Limits.idlePageDelay.upperBound)
        XCTAssertEqual(v.holdAwakeForPendingPageMinutes, Config.Limits.holdAwakeMinutes.upperBound)
    }

    func testOneMistypedKeyDoesNotDiscardTheFile() throws {
        let json = """
        {"relayEnabled": "true", "relayURL": "https://page.me.workers.dev",
         "checkIntervalSeconds": "15", "lowBatteryCutoff": 12, "interventionScanIntervalSeconds": 10}
        """
        let issues = Config.DecodeIssues()
        let decoder = JSONDecoder()
        decoder.userInfo[Config.decodeIssuesKey] = issues
        let c = try decoder.decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(c.relayURL, "https://page.me.workers.dev")
        XCTAssertEqual(c.lowBatteryCutoff, 12)
        XCTAssertEqual(c.relayEnabled, false)
        XCTAssertEqual(c.checkIntervalSeconds, 15)
        XCTAssertEqual(issues.messages.count, 2)
    }

    func testEncodingRoundTrips() throws {
        var c = Config()
        c.relayEnabled = true
        c.relayURL = "https://page.me.workers.dev"
        c.codexBackendEnabled = true
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: data), c)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(obj?["interventionScanIntervalSeconds"], "dead key is no longer written")
    }
}

final class ConfigFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingFileCreatesDefaults() throws {
        let url = dir.appendingPathComponent("config.json")
        let r = Config.loadResult(from: url)
        XCTAssertEqual(r.config, Config())
        XCTAssertNil(r.problem)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testMalformedFileIsBackedUpAndNotOverwritten() throws {
        let url = dir.appendingPathComponent("config.json")
        // Smart quotes from a pasted snippet (Foundation tolerates trailing
        // commas, so that's not a useful "broken" example).
        let broken = Data("{\u{201C}relayEnabled\u{201D}: true, \"relayURL\": \"https://mine.workers.dev\"}".utf8)
        try broken.write(to: url)
        let r = Config.loadResult(from: url)
        XCTAssertNil(r.config)
        XCTAssertTrue(r.isUnreadable)
        XCTAssertNotNil(r.problem)
        XCTAssertEqual(try Data(contentsOf: url), broken, "the user's file must be left alone")
        let backup = try XCTUnwrap(r.backupURL)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("config.json.bad-"))
        XCTAssertEqual(try Data(contentsOf: backup), broken)
    }

    func testOutOfRangeValuesAreReportedAndClamped() throws {
        let url = dir.appendingPathComponent("config.json")
        try Data(#"{"checkIntervalSeconds": 0, "recoveryThreshold": 5, "lowBatteryCutoff": 20}"#.utf8).write(to: url)
        let r = Config.loadResult(from: url)
        XCTAssertEqual(r.config?.checkIntervalSeconds, 2)
        XCTAssertEqual(r.config?.recoveryThreshold, 20)
        XCTAssertNotNil(r.problem)
    }

    func testWriteIsAtomicAndReadable() throws {
        let url = dir.appendingPathComponent("config.json")
        var c = Config()
        c.relayEnabled = true
        try c.write(to: url)
        XCTAssertEqual(Config.loadResult(from: url).config, c)
    }
}

final class RelayURLTests: XCTestCase {
    private func ok(_ s: String) -> String? { try? Config.validatedRelayURL(s).get().absoluteString }
    private func problem(_ s: String) -> Config.RelayURLProblem? {
        if case .failure(let p) = Config.validatedRelayURL(s) { return p }
        return nil
    }

    func testNormalisation() {
        XCTAssertEqual(ok("page.me.workers.dev"), "https://page.me.workers.dev")
        XCTAssertEqual(ok("https://page.me.workers.dev/"), "https://page.me.workers.dev")
        XCTAssertEqual(ok("wss://page.me.workers.dev/ws"), "https://page.me.workers.dev")
        XCTAssertEqual(ok("HTTPS://Page.Me.Workers.Dev/ws/"), "https://page.me.workers.dev")
        XCTAssertEqual(ok("https://example.com/relay/?x=1#frag"), "https://example.com/relay")
        XCTAssertEqual(ok("  https://page.me.workers.dev  "), "https://page.me.workers.dev")
        XCTAssertEqual(ok("http://localhost:8787"), "http://localhost:8787")
        XCTAssertEqual(ok("ws://127.0.0.1:8787/ws"), "http://127.0.0.1:8787")
    }

    func testRejections() {
        XCTAssertEqual(problem(""), .empty)
        XCTAssertEqual(problem("   "), .empty)
        XCTAssertEqual(problem(Config.placeholderRelayURL), .placeholder)
        XCTAssertEqual(problem("your-page-relay.workers.dev/ws"), .placeholder)
        XCTAssertEqual(problem("http://page.me.workers.dev"), .insecure)
        XCTAssertEqual(problem("ftp://page.me.workers.dev"), .invalid)
        XCTAssertEqual(problem("not a url"), .invalid)
        XCTAssertEqual(problem("https://nodots"), .invalid)
    }

    func testConfigHelpers() {
        var c = Config()
        XCTAssertTrue(c.isRelayURLPlaceholder)
        XCTAssertNil(c.relayBaseURL)
        XCTAssertFalse(c.relayIsUsable)
        c.relayURL = "page.me.workers.dev"
        c.relayEnabled = true
        XCTAssertFalse(c.isRelayURLPlaceholder)
        XCTAssertTrue(c.relayIsUsable)
        XCTAssertEqual(c.relayBaseURL?.absoluteString, "https://page.me.workers.dev")
    }

    func testWebSocketURL() {
        XCTAssertEqual(RelayClient.wsURL(from: "https://page.me.workers.dev")?.absoluteString, "wss://page.me.workers.dev/ws")
        XCTAssertEqual(RelayClient.wsURL(from: "https://example.com/relay/")?.absoluteString, "wss://example.com/relay/ws")
        XCTAssertEqual(RelayClient.wsURL(from: "http://localhost:8787")?.absoluteString, "ws://localhost:8787/ws")
        XCTAssertNil(RelayClient.wsURL(from: Config.placeholderRelayURL))
    }

    func testUserAgentIdentifiesTheMac() {
        // The Worker routes replies to sockets whose UA contains "page-mac".
        XCTAssertTrue(RelayClient.userAgent.hasPrefix("page-mac/"))
    }
}

final class OutboundQueueTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func frame(_ type: String, _ key: String?, at offset: TimeInterval = 0, tag: String = "") -> OutboundQueue.Frame {
        OutboundQueue.Frame(type: type, key: key, data: Data("\(type)|\(key ?? "")|\(tag)".utf8),
                            enqueuedAt: t0.addingTimeInterval(offset))
    }

    private func types(_ frames: [OutboundQueue.Frame]) -> [String] {
        frames.map { "\($0.type):\($0.key ?? "-")" }
    }

    func testCloseCancelsQueuedOpen() {
        var q = OutboundQueue()
        q.enqueue(frame("intervention.opened", "A", at: 0))
        q.enqueue(frame("intervention.opened", "B", at: 1))
        q.enqueue(frame("intervention.closed", "A", at: 2))
        XCTAssertEqual(types(q.drain(now: t0.addingTimeInterval(3))),
                       ["intervention.opened:B", "intervention.closed:A"])
        XCTAssertTrue(q.isEmpty)
    }

    func testCloseForPageSentBeforeOutageIsKept() {
        var q = OutboundQueue()
        q.enqueue(frame("intervention.closed", "X", at: 0))
        q.enqueue(frame("intervention.closed", "X", at: 1))
        XCTAssertEqual(types(q.drain(now: t0)), ["intervention.closed:X"])
    }

    func testOnlyLatestHeartbeatAndSyncPerBackend() {
        var q = OutboundQueue()
        q.enqueue(frame("heartbeat", nil, at: 0, tag: "1"))
        q.enqueue(frame("sync", "claude", at: 1, tag: "1"))
        q.enqueue(frame("sync", "codex", at: 2))
        q.enqueue(frame("heartbeat", nil, at: 3, tag: "2"))
        q.enqueue(frame("sync", "claude", at: 4, tag: "2"))
        let out = q.drain(now: t0.addingTimeInterval(5))
        XCTAssertEqual(types(out), ["sync:codex", "heartbeat:-", "sync:claude"])
        XCTAssertEqual(String(data: out[1].data, encoding: .utf8), "heartbeat||2")
        XCTAssertEqual(String(data: out[2].data, encoding: .utf8), "sync|claude|2")
    }

    func testReplyInjectedPassesThrough() {
        var q = OutboundQueue()
        q.enqueue(frame("reply.injected", "A", at: 0))
        q.enqueue(frame("reply.injected", "A", at: 1))
        XCTAssertEqual(q.count, 2)
    }

    func testTTLDropsOnlyStaleStatusFrames() {
        var q = OutboundQueue(capacity: 100, ttl: 600)
        q.enqueue(frame("heartbeat", nil, at: 0))
        q.enqueue(frame("sync", "claude", at: 0))
        q.enqueue(frame("sync", "codex", at: 500))
        XCTAssertEqual(types(q.drain(now: t0.addingTimeInterval(700))), ["sync:codex"])
    }

    func testStillOpenPageSurvivesALongOutage() {
        // A page queued at minute 0 that never closed is still waiting for
        // the user after a 30-minute outage — it must still be delivered.
        var q = OutboundQueue(capacity: 100, ttl: 600)
        q.enqueue(frame("intervention.opened", "A", at: 0))
        q.enqueue(frame("intervention.closed", "hook-X", at: 1))
        q.enqueue(frame("reply.injected", "R", at: 2))
        q.enqueue(frame("heartbeat", nil, at: 1700))
        XCTAssertEqual(types(q.drain(now: t0.addingTimeInterval(1800))),
                       ["intervention.opened:A", "intervention.closed:hook-X", "reply.injected:R", "heartbeat:-"])
    }

    func testCapacityEvictsLeastValuableFirst() {
        var q = OutboundQueue(capacity: 3, ttl: 600)
        q.enqueue(frame("reply.injected", "R", at: 0))
        q.enqueue(frame("intervention.opened", "A", at: 1))
        q.enqueue(frame("heartbeat", nil, at: 2))
        q.enqueue(frame("intervention.closed", "Z", at: 3))   // evicts heartbeat
        XCTAssertEqual(types(q.frames), ["reply.injected:R", "intervention.opened:A", "intervention.closed:Z"])
        q.enqueue(frame("intervention.opened", "B", at: 4))   // evicts the close
        XCTAssertEqual(types(q.frames), ["reply.injected:R", "intervention.opened:A", "intervention.opened:B"])
        q.enqueue(frame("intervention.opened", "C", at: 5))   // evicts the oldest open
        XCTAssertEqual(types(q.frames), ["reply.injected:R", "intervention.opened:B", "intervention.opened:C"])
    }

    func testRequeueKeepsOrderAndRespectsSupersession() {
        var q = OutboundQueue()
        q.enqueue(frame("intervention.closed", "A", at: 10))
        q.enqueue(frame("intervention.opened", "C", at: 12))
        // Sends that failed after the socket died, older than what's queued.
        q.requeueFailed(frame("intervention.opened", "A", at: 1), now: t0.addingTimeInterval(13))
        q.requeueFailed(frame("intervention.opened", "B", at: 2), now: t0.addingTimeInterval(13))
        q.requeueFailed(frame("reply.injected", "B", at: 3), now: t0.addingTimeInterval(13))
        XCTAssertEqual(types(q.drain(now: t0.addingTimeInterval(14))),
                       ["intervention.opened:B", "reply.injected:B", "intervention.closed:A", "intervention.opened:C"])
    }

    func testBackoffIsBoundedAndJittered() {
        XCTAssertEqual(RelayClient.backoffDelay(attempt: 0, random: 1), 1)
        XCTAssertEqual(RelayClient.backoffDelay(attempt: 0, random: 0), 0.5)
        XCTAssertEqual(RelayClient.backoffDelay(attempt: 3, random: 1), 8)
        XCTAssertEqual(RelayClient.backoffDelay(attempt: 50, random: 1), 60)
        XCTAssertEqual(RelayClient.backoffDelay(attempt: 50, random: 0), 30)
        XCTAssertEqual(RelayClient.backoffDelay(attempt: -3, random: 2), 1)
        for attempt in 0..<30 {
            let d = RelayClient.backoffDelay(attempt: attempt, random: Double.random(in: 0...1))
            XCTAssertGreaterThanOrEqual(d, 0.5)
            XCTAssertLessThanOrEqual(d, 60)
        }
    }
}

final class PowerTests: XCTestCase {
    private func source(_ type: String, current: Int, max: Int = 100, ac: Bool, charging: Bool = false) -> [String: Any] {
        [
            kIOPSTypeKey as String: type,
            kIOPSCurrentCapacityKey as String: current,
            kIOPSMaxCapacityKey as String: max,
            kIOPSPowerSourceStateKey as String: ac ? kIOPSACPowerValue : kIOPSBatteryPowerValue,
            kIOPSIsChargingKey as String: charging,
            kIOPSIsPresentKey as String: true
        ]
    }

    func testDesktopWithoutBattery() {
        let p = PowerSnapshot.from(descriptions: [])
        XCTAssertFalse(p.hasBattery)
        XCTAssertEqual(p.percent, -1)
        XCTAssertTrue(p.onAC)
    }

    func testInternalBatteryWinsOverUPS() {
        let p = PowerSnapshot.from(descriptions: [
            source(kIOPSUPSType, current: 15, ac: false),
            source(kIOPSInternalBatteryType, current: 80, ac: true, charging: true)
        ])
        XCTAssertEqual(p.percent, 80)
        XCTAssertTrue(p.onAC)
        XCTAssertTrue(p.isCharging)
    }

    func testUPSUsedWhenNoInternalBattery() {
        let p = PowerSnapshot.from(descriptions: [source(kIOPSUPSType, current: 40, max: 50, ac: false)])
        XCTAssertTrue(p.hasBattery)
        XCTAssertEqual(p.percent, 80)
        XCTAssertFalse(p.onAC)
    }

    func testLockoutPolicy() {
        let desktop = PowerSnapshot.noBattery
        XCTAssertFalse(LockoutPolicy.nextTripped(current: false, power: desktop, cutoff: 10, recovery: 25, recoveryRequiresAC: true))
        XCTAssertFalse(LockoutPolicy.nextTripped(current: true, power: desktop, cutoff: 10, recovery: 25, recoveryRequiresAC: true))

        let lowOnAC = PowerSnapshot(percent: 5, onAC: true, hasBattery: true, isCharging: true)
        XCTAssertFalse(LockoutPolicy.nextTripped(current: false, power: lowOnAC, cutoff: 10, recovery: 25, recoveryRequiresAC: true),
                       "plugged in and charging must not trip")

        let lowOnBattery = PowerSnapshot(percent: 5, onAC: false, hasBattery: true, isCharging: false)
        XCTAssertTrue(LockoutPolicy.nextTripped(current: false, power: lowOnBattery, cutoff: 10, recovery: 25, recoveryRequiresAC: true))

        let recoveredOnBattery = PowerSnapshot(percent: 30, onAC: false, hasBattery: true, isCharging: false)
        XCTAssertTrue(LockoutPolicy.nextTripped(current: true, power: recoveredOnBattery, cutoff: 10, recovery: 25, recoveryRequiresAC: true))
        XCTAssertFalse(LockoutPolicy.nextTripped(current: true, power: recoveredOnBattery, cutoff: 10, recovery: 25, recoveryRequiresAC: false))

        let recoveredOnAC = PowerSnapshot(percent: 25, onAC: true, hasBattery: true, isCharging: true)
        XCTAssertFalse(LockoutPolicy.nextTripped(current: true, power: recoveredOnAC, cutoff: 10, recovery: 25, recoveryRequiresAC: true))
    }
}

final class MacAppMiscTests: XCTestCase {
    func testRateLimitUserInfoRoundTrip() {
        let e = RateLimitEvent(
            sessionId: "0b5c2d0e-3f0a-4d3e-9a7c-1c2b3d4e5f60", cwd: "/Users/me/proj", projectName: "proj",
            eventTime: Date(timeIntervalSince1970: 1_700_000_123), resetTime: Date(timeIntervalSince1970: 1_700_003_600),
            resetTimeText: "7pm (Europe/London)", transcriptPath: "/x.jsonl", backend: .codex)
        let info: [AnyHashable: Any] = RateLimitUserInfo.encode(e).reduce(into: [:]) { $0[$1.key] = $1.value }
        let back = RateLimitUserInfo.decode(info)
        XCTAssertEqual(back, e)
        XCTAssertEqual(back?.uniqueId, e.uniqueId)
        XCTAssertNil(RateLimitUserInfo.decode(["eventId": "legacy"]))
    }

    func testOnlyRealClaudeSessionsCanResume() throws {
        // A transcript whose last reply came from a Claude model: the
        // positive Anthropic evidence a background resume now requires.
        let transcript = FileManager.default.temporaryDirectory.appendingPathComponent("canresume-\(UUID().uuidString).jsonl")
        try #"{"type":"assistant","message":{"model":"claude-opus-4-1","content":[]}}"#.appending("\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: transcript) }
        func event(_ sid: String, cwd: String = "/p", backend: AgentBackendID = .claude) -> RateLimitEvent {
            RateLimitEvent(sessionId: sid, cwd: cwd, projectName: "p", eventTime: Date(), resetTime: Date(),
                           resetTimeText: "", transcriptPath: transcript.path, backend: backend)
        }
        let uuid = "0b5c2d0e-3f0a-4d3e-9a7c-1c2b3d4e5f60"
        XCTAssertTrue(Coordinator.canResume(event(uuid)))
        XCTAssertFalse(Coordinator.canResume(event(uuid, backend: .codex)))
        XCTAssertFalse(Coordinator.canResume(event("codex")))
        XCTAssertFalse(Coordinator.canResume(event(uuid, cwd: "")))
    }

    func testPreferencesMergeWritesOnlyChangedFields() {
        var onDisk = Config()
        onDisk.relayEnabled = true
        onDisk.relayURL = "https://page.me.workers.dev"
        onDisk.lowBatteryCutoff = 12
        let baseline = PreferencesForm(onDisk)

        // While the window was open the user hand-edited the cutoff on disk.
        var fresh = onDisk
        fresh.lowBatteryCutoff = 30
        fresh.excludePatterns = ["custom"]

        var form = baseline
        form.checkIntervalSeconds = 30
        form.relayURL = "other.me.workers.dev/ws"
        let merged = form.merged(onto: fresh, changedFrom: baseline)
        XCTAssertEqual(merged.checkIntervalSeconds, 30)
        XCTAssertEqual(merged.relayURL, "https://other.me.workers.dev", "stored normalised")
        XCTAssertEqual(merged.lowBatteryCutoff, 30, "untouched control must not clobber a hand edit")
        XCTAssertEqual(merged.excludePatterns, ["custom"])
        XCTAssertTrue(merged.relayEnabled)
    }

    func testPreferencesFormHidesPlaceholderAndValidates() {
        var c = Config()
        XCTAssertEqual(PreferencesForm(c).relayURL, "")
        var form = PreferencesForm(c)
        form.relayEnabled = true
        XCTAssertNotNil(form.validationError(isExecutable: { _ in true }))
        form.relayURL = "page.me.workers.dev"
        XCTAssertNil(form.validationError(isExecutable: { _ in true }))
        form.relayURL = Config.placeholderRelayURL
        XCTAssertNotNil(form.validationError(isExecutable: { _ in true }))
        form.relayURL = ""
        form.relayEnabled = false
        form.codexPath = "/nope/codex"
        XCTAssertNotNil(form.validationError(isExecutable: { _ in false }))
        XCTAssertNil(form.validationError(isExecutable: { _ in true }))
        c.relayURL = "https://page.me.workers.dev"
        XCTAssertEqual(PreferencesForm(c).relayURL, "https://page.me.workers.dev")
    }

    func testTokenFileIsWrittenOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("relay_token.txt")
        XCTAssertTrue(PairingTokenManager.store("abc123", at: url))
        XCTAssertTrue(PairingTokenManager.store("def456", at: url))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "def456\n")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testPairingPayloadUsesNormalisedRelay() throws {
        let base = try Config.validatedRelayURL("wss://page.me.workers.dev/ws").get()
        let json = PairingTokenManager.pairingPayloadJSON(relayBaseURL: base, token: "t0k3n")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["relay"] as? String, "https://page.me.workers.dev")
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["token"] as? String, "t0k3n")
    }

    func testLoggerRedactsCredentials() {
        XCTAssertEqual(Logger.redact("Authorization: Bearer abcDEF123-_x"), "Authorization: Bearer <redacted>")
        XCTAssertEqual(Logger.redact(#"{"token":"abcdefghijkl"}"#), #"{"token":"<redacted>"}"#)
        XCTAssertEqual(Logger.redact("Pairing token regenerated"), "Pairing token regenerated")
        XCTAssertEqual(Logger.redact("plain line"), "plain line")
    }
}
