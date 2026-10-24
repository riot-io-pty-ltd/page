import XCTest
import Network
@testable import ClaudePowerMode

private func battery(_ percent: Int, ac: Bool = false) -> PowerSnapshot {
    PowerSnapshot(percent: percent, onAC: ac, hasBattery: true, isCharging: ac)
}

private func settings(resume: Bool = true) -> BatteryPolicy.Settings {
    BatteryPolicy.Settings(cutoff: 10, recovery: 25, recoveryRequiresAC: true,
                           action: .pause, graceSeconds: 90, resumeAfterRecovery: resume)
}

private func session(_ id: String, at: Date) -> PausedSession {
    PausedSession(backend: .claude, sessionId: id, projectName: "proj-\(id)", cwd: "/tmp/\(id)",
                  pausedAt: at, detail: "Interrupted in tmux pane %1")
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

// MARK: - F3: no digits in typed battery messages

final class BatteryMessageDigitTests: XCTestCase {
    private func assertNoDigits(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(text.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")),
                     "digit in a message typed into a session: \(text)", file: file, line: line)
    }

    func testTypedMessagesNeverContainADigit() {
        for percent in -1...101 {
            for mode in [LowBatteryAction.pause, .afterTurn, .off] {
                assertNoDigits(BatteryPolicy.pauseMessage(percent: percent, mode: mode))
            }
        }
        assertNoDigits(BatteryPolicy.recoveryMessage)
        assertNoDigits(BatteryPolicy.manualResumeMessage)
        for decision in [BatteryPolicy.replyDecision(action: "approve", text: "", stillTripped: true),
                         BatteryPolicy.replyDecision(action: "carry_on", text: "", stillTripped: false)] {
            guard case let .resume(message) = decision else { return XCTFail("\(decision)") }
            assertNoDigits(message)
        }
    }

    func testLevelIsSpelledOut() {
        XCTAssertEqual(BatteryPolicy.spelledPercent(0), "zero percent")
        XCTAssertEqual(BatteryPolicy.spelledPercent(9), "nine percent")
        XCTAssertEqual(BatteryPolicy.spelledPercent(13), "thirteen percent")
        XCTAssertEqual(BatteryPolicy.spelledPercent(20), "twenty percent")
        XCTAssertEqual(BatteryPolicy.spelledPercent(23), "twenty-three percent")
        XCTAssertEqual(BatteryPolicy.spelledPercent(99), "ninety-nine percent")
        XCTAssertEqual(BatteryPolicy.spelledPercent(100), "one hundred percent")
        XCTAssertNil(BatteryPolicy.spelledPercent(-1))
        XCTAssertNil(BatteryPolicy.spelledPercent(101))
        XCTAssertTrue(BatteryPolicy.pauseMessage(percent: 7, mode: .afterTurn)
            .hasPrefix("Battery is at seven percent and the Mac will sleep soon. Finish the step you're on"))
        XCTAssertTrue(BatteryPolicy.pauseMessage(percent: -1, mode: .pause)
            .hasPrefix("Battery is low and the Mac is about to sleep. Pause now"), "unknown level is omitted")
        // Every message for 0...100 is distinct, so a resume filter can
        // still recognise each one.
        let all = (0...100).map { BatteryPolicy.pauseMessage(percent: $0, mode: .pause) }
        XCTAssertEqual(Set(all).count, 101)
    }

    /// Transcripts from before the upgrade carry the old digit wording.
    func testLegacyWordingIsAvailable() {
        let legacy = BatteryPolicy.legacyPauseMessages()
        XCTAssertEqual(legacy.count, 202)
        XCTAssertTrue(legacy.contains { $0.hasPrefix("Battery is at 9% and the Mac is about to sleep. Pause now") })
        XCTAssertTrue(legacy.contains { $0.hasPrefix("Battery is at 100% and the Mac will sleep soon.") })
    }
}

// MARK: - F5: automatic battery resume waits while the user is at the Mac

final class AutoResumePresenceTests: XCTestCase {
    func testDecisionTable() {
        typealias D = Coordinator.AutoResumeDecision
        XCTAssertEqual(Coordinator.autoResumeDecision(owed: false, enabled: true, inFlight: false, userPresent: false), D.nothing)
        XCTAssertEqual(Coordinator.autoResumeDecision(owed: true, enabled: true, inFlight: false, userPresent: true), D.hold,
                       "user at the Mac: keep it owed")
        XCTAssertEqual(Coordinator.autoResumeDecision(owed: true, enabled: true, inFlight: false, userPresent: false), D.run)
        XCTAssertEqual(Coordinator.autoResumeDecision(owed: true, enabled: true, inFlight: true, userPresent: false), D.nothing,
                       "a menu resume is already typing")
        XCTAssertEqual(Coordinator.autoResumeDecision(owed: true, enabled: false, inFlight: false, userPresent: true), D.cancel,
                       "turned off meanwhile")
    }

    func testPresenceWindowIsAtLeastTwoMinutes() {
        var cfg = Config()
        cfg.idlePageOnlyWhenAwaySeconds = 0
        XCTAssertEqual(Coordinator.autoResumePresenceWindow(cfg), 120)
        cfg.idlePageOnlyWhenAwaySeconds = 60
        XCTAssertEqual(Coordinator.autoResumePresenceWindow(cfg), 120)
        cfg.idlePageOnlyWhenAwaySeconds = 600
        XCTAssertEqual(Coordinator.autoResumePresenceWindow(cfg), 600)
    }

    /// Held resume: the entries survive (so it can run later or from the
    /// menu) until an attempt is made, and a new trip supersedes it.
    func testHeldResumeKeepsEntriesUntilAttemptedOrRetripped() {
        var p = BatteryPolicy()
        _ = p.observe(battery(10), settings: settings(), now: t0)
        _ = p.pauseFinished([session("a", at: t0), session("b", at: t0)], settings: settings(), now: t0)
        let effects = p.observe(battery(80, ac: true), settings: settings(), now: t0.addingTimeInterval(300))
        guard case let .recovered(sessions, resume, _, closing) = effects.first else { return XCTFail("\(effects)") }
        XCTAssertTrue(resume)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(closing.count, 2)
        XCTAssertTrue(p.awaitingAutoResume)
        // Ticks while the user is at the Mac change nothing.
        for i in 1...5 {
            XCTAssertEqual(p.observe(battery(80, ac: true), settings: settings(), now: t0.addingTimeInterval(300 + Double(i) * 15)), [])
        }
        XCTAssertTrue(p.awaitingAutoResume)
        XCTAssertEqual(p.pausedSessions.count, 2)
        // Unplugged and tripped again before the user left: the old owed
        // resume is superseded by the new pause.
        _ = p.observe(battery(10), settings: settings(), now: t0.addingTimeInterval(4000))
        XCTAssertNil(p.autoResumePending)
        XCTAssertFalse(p.awaitingAutoResume)
    }

    func testStaleEntriesDropTheOwedResume() {
        var p = BatteryPolicy()
        _ = p.observe(battery(10), settings: settings(), now: t0)
        _ = p.pauseFinished([session("a", at: t0)], settings: settings(), now: t0)
        _ = p.observe(battery(80, ac: true), settings: settings(), now: t0.addingTimeInterval(60))
        XCTAssertTrue(p.awaitingAutoResume)
        _ = p.observe(battery(80, ac: true), settings: settings(), now: t0.addingTimeInterval(BatteryPolicy.staleEntryAge + 1))
        XCTAssertTrue(p.entries.isEmpty)
        XCTAssertNil(p.autoResumePending)
    }

    func testNoResumeSettingOwesNothing() {
        var p = BatteryPolicy()
        _ = p.observe(battery(10), settings: settings(resume: false), now: t0)
        _ = p.pauseFinished([session("a", at: t0)], settings: settings(resume: false), now: t0)
        _ = p.observe(battery(80, ac: true), settings: settings(resume: false), now: t0.addingTimeInterval(60))
        XCTAssertFalse(p.awaitingAutoResume)
        XCTAssertEqual(p.pausedSessions.count, 1)
    }

    /// battery-paused.json from an older build has no autoResumePending key.
    func testOlderStoreStillDecodesAndPendingRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-seam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("battery-paused.json")
        let legacy = """
        {"entries":[{"pageId":"a-low_battery-1800000000","pageOpen":true,"session":{"backend":"claude","cwd":"/tmp/a","detail":"x","pausedAt":1800000000,"projectName":"proj-a","sessionId":"a"}}],
         "graceEndsAt":1800000090,"mode":"pause","pauseInFlight":false,"phase":"drained","trippedAt":1800000000,"trippedPercent":10}
        """
        try Data(legacy.utf8).write(to: url)
        let loaded = try XCTUnwrap(BatteryPauseStore(url: url).load(), "an older file must not be dropped as unreadable")
        XCTAssertEqual(loaded.pausedSessions.map(\.sessionId), ["a"])
        XCTAssertNil(loaded.autoResumePending)

        var p = loaded
        _ = p.observe(battery(90, ac: true), settings: settings(), now: t0.addingTimeInterval(500))
        XCTAssertTrue(p.awaitingAutoResume)
        let store = BatteryPauseStore(url: url)
        XCTAssertTrue(store.save(p))
        XCTAssertEqual(store.load(), p, "a held resume survives a relaunch")
        XCTAssertTrue(store.load()?.awaitingAutoResume == true)
    }
}

// MARK: - redaction at the relay choke point

final class RelayContextRedactionTests: XCTestCase {
    func testSecretsNeverReachTheOpenedPayload() {
        let key = "sk-" + String(repeating: "A", count: 24)
        let ctx = RelayClient.wireContext("Run with OPENAI_API_KEY=\(key) and Authorization: Bearer abcdefghijklmnop1234")
        XCTAssertFalse(ctx.contains(key))
        XCTAssertFalse(ctx.contains("abcdefghijklmnop1234"))
        XCTAssertTrue(ctx.contains("[redacted]"))
        // Already-redacted text is unchanged; long text is cut to 4000.
        XCTAssertEqual(RelayClient.wireContext(ctx), ctx)
        XCTAssertEqual(RelayClient.wireContext(String(repeating: "x", count: 5000)).count, 4000)
        XCTAssertEqual(RelayClient.wireContext("Battery 9% — Page paused this session."), "Battery 9% — Page paused this session.")
        // A secret straddling the cut is redacted, not left as a fragment.
        let straddle = String(repeating: "x", count: 3990) + " " + key
        XCTAssertFalse(RelayClient.wireContext(straddle).contains("sk-AAAA"))
    }
}

// MARK: - token retirement (Mac side)

final class TokenRetirementTests: XCTestCase {
    private let ws = URL(string: "wss://page-relay.example.workers.dev/ws")!
    private let token = String(repeating: "a", count: 43)

    func testHTTPURLFromSocketURL() {
        XCTAssertEqual(RelayClient.httpURL(fromWS: ws, path: "/intervention")?.absoluteString,
                       "https://page-relay.example.workers.dev/intervention")
        XCTAssertEqual(RelayClient.httpURL(fromWS: URL(string: "ws://127.0.0.1:8787/ws")!, path: "intervention")?.absoluteString,
                       "http://127.0.0.1:8787/intervention")
        XCTAssertEqual(RelayClient.httpURL(fromWS: URL(string: "wss://h.example/ws/")!, path: "/intervention")?.absoluteString,
                       "https://h.example/intervention")
        // Round trip with the base → ws mapping.
        let base = URL(string: "https://page-relay.example.workers.dev")!
        XCTAssertEqual(RelayClient.httpURL(fromWS: RelayClient.wsURL(fromBase: base)!, path: "/intervention")?.absoluteString,
                       "https://page-relay.example.workers.dev/intervention")
        XCTAssertNil(RelayClient.httpURL(fromWS: URL(string: "ftp://h/ws")!, path: "/intervention"))
    }

    func testRetireFrameAndRequest() throws {
        let env = try XCTUnwrap(JSONSerialization.jsonObject(with: RelayClient.retireEnvelope(reason: "token_regenerated")) as? [String: Any])
        XCTAssertEqual(env["type"] as? String, "relay.retire")
        XCTAssertEqual((env["payload"] as? [String: Any])?["reason"] as? String, "token_regenerated")

        let req = try XCTUnwrap(RelayClient.retireRequest(wsURL: ws, token: token, reason: "token_regenerated", timeout: 2))
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://page-relay.example.workers.dev/intervention")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertTrue(req.value(forHTTPHeaderField: "User-Agent")?.contains("page-mac") == true)
        XCTAssertEqual(req.httpBody, RelayClient.retireEnvelope(reason: "token_regenerated"))
        XCTAssertLessThanOrEqual(req.timeoutInterval, 2)

        XCTAssertTrue(RelayClient.retireAccepted(status: 200))
        XCTAssertTrue(RelayClient.retireAccepted(status: 410), "already retired")
        XCTAssertFalse(RelayClient.retireAccepted(status: 400), "an older Worker refuses the unknown frame")
        XCTAssertFalse(RelayClient.retireAccepted(status: 0))
    }

    func testRegenerateReportsThePreviousTokenOnlyWhenItChanged() {
        XCTAssertEqual(PairingTokenManager.changeUserInfo(previous: "old", fresh: "new", stored: true),
                       [PairingTokenManager.previousTokenKey: "old"])
        XCTAssertNil(PairingTokenManager.changeUserInfo(previous: "old", fresh: "new", stored: false),
                     "a failed write leaves the old token in use: never retire it")
        XCTAssertNil(PairingTokenManager.changeUserInfo(previous: nil, fresh: "new", stored: true))
        XCTAssertNil(PairingTokenManager.changeUserInfo(previous: "same", fresh: "same", stored: true))
    }

    func testShouldRetireOnlyTheReplacedTokenOnTheSameWorker() {
        typealias I = Coordinator.RelayIdentity
        let other = URL(string: "wss://other.example/ws")!
        let old = I(url: ws, token: "old"), new = I(url: ws, token: "new")
        XCTAssertTrue(Coordinator.shouldRetire(current: old, desired: new, tokenToRetire: "old"))
        XCTAssertFalse(Coordinator.shouldRetire(current: old, desired: new, tokenToRetire: nil), "no regenerate")
        XCTAssertFalse(Coordinator.shouldRetire(current: old, desired: old, tokenToRetire: "old"), "token write failed")
        XCTAssertFalse(Coordinator.shouldRetire(current: old, desired: nil, tokenToRetire: "old"), "relay turned off")
        XCTAssertFalse(Coordinator.shouldRetire(current: old, desired: I(url: other, token: "new"), tokenToRetire: "old"),
                       "Worker URL changed too")
        XCTAssertFalse(Coordinator.shouldRetire(current: new, desired: I(url: ws, token: "newer"), tokenToRetire: "old"),
                       "the connected client isn't on the replaced token")
        XCTAssertFalse(Coordinator.shouldRetire(current: nil, desired: new, tokenToRetire: "old"))
    }

    // MARK: HTTP fallback (stubbed; no network)

    private func stubbedClient(_ handler: @escaping RetireStubProtocol.Handler) -> RelayClient {
        RetireStubProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RetireStubProtocol.self]
        return RelayClient(url: ws, token: token, configuration: config)
    }

    func testRetireWithoutASocketPostsWithTheOldToken() throws {
        var seen: URLRequest?
        var body = Data()
        let client = stubbedClient { req, data in
            seen = req
            body = data
            return (410, Data(#"{"error":"token_retired"}"#.utf8))
        }
        defer { client.stop() }
        let done = expectation(description: "retire completes")
        var result: Bool?
        client.retire(reason: "token_regenerated", timeout: 2) { ok in
            result = ok
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(result, true)
        XCTAssertEqual(seen?.httpMethod, "POST")
        XCTAssertEqual(seen?.url?.path, "/intervention")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        let env = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(env["type"] as? String, "relay.retire")
    }

    func testOlderWorkerRefusalIsReportedNotRetried() {
        var calls = 0
        let client = stubbedClient { _, _ in
            calls += 1
            return (400, Data(#"{"error":"bad_request"}"#.utf8))
        }
        defer { client.stop() }
        let done = expectation(description: "retire completes")
        var result: Bool?
        client.retire(reason: "token_regenerated", timeout: 2) { ok in
            result = ok
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(result, false)
        XCTAssertEqual(calls, 1)
    }

    func testRetireGivesUpAfterTheTimeoutAndCompletesOnce() {
        let client = stubbedClient { _, _ in nil } // never answers
        defer { client.stop() }
        let done = expectation(description: "retire completes")
        done.assertForOverFulfill = true
        let started = Date()
        var result: Bool?
        client.retire(reason: "token_regenerated", timeout: 0.4) { ok in
            result = ok
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(result, false)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testStoppedClientCompletesImmediately() {
        let client = stubbedClient { _, _ in (200, Data()) }
        client.stop()
        let done = expectation(description: "retire completes")
        var result: Bool?
        client.retire(reason: "token_regenerated") { ok in
            result = ok
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(result, false)
    }

    // MARK: over a real local WebSocket (127.0.0.1 only)

    func testRetireGoesOutOnTheOpenSocket() throws {
        let server = try LocalWebSocketServer()
        defer { server.stop() }
        let port = try XCTUnwrap(server.waitForPort(timeout: 5))
        let client = RelayClient(url: URL(string: "ws://127.0.0.1:\(port)/ws")!, token: token)
        defer { client.stop() }
        client.start()
        let deadline = Date().addingTimeInterval(5)
        while !client.isConnected && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(client.isConnected, "local socket didn't connect")

        let done = expectation(description: "retire completes")
        var result: Bool?
        client.retire(reason: "token_regenerated") { ok in
            result = ok
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(result, true)
        let frame = try XCTUnwrap(server.waitForMessage(timeout: 3))
        let env = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
        XCTAssertEqual(env["type"] as? String, "relay.retire")
        XCTAssertEqual((env["payload"] as? [String: Any])?["reason"] as? String, "token_regenerated")
    }
}

/// Answers every request with the handler's (status, body); nil never answers.
final class RetireStubProtocol: URLProtocol {
    typealias Handler = (URLRequest, Data) -> (Int, Data)?
    static var handler: Handler?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        guard let (status, data) = Self.handler?(request, body) else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A minimal WebSocket server on 127.0.0.1 (Network.framework) that records
/// the messages it receives.
final class LocalWebSocketServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "page.test.ws-server")
    private let lock = NSLock()
    private var messages: [Data] = []
    private var connections: [NWConnection] = []

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.lock.lock(); self.connections.append(conn); self.lock.unlock()
            conn.start(queue: self.queue)
            self.receive(on: conn)
        }
        listener.start(queue: queue)
    }

    func waitForPort(timeout: TimeInterval) -> UInt16? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let port = listener.port?.rawValue, port != 0 { return port }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    func waitForMessage(timeout: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock(); let first = messages.first; lock.unlock()
            if let first { return first }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            if let data, !data.isEmpty,
               let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               meta.opcode == .binary || meta.opcode == .text {
                self.lock.lock(); self.messages.append(data); self.lock.unlock()
            }
            self.receive(on: conn)
        }
    }

    func stop() {
        lock.lock(); let conns = connections; connections.removeAll(); lock.unlock()
        conns.forEach { $0.cancel() }
        listener.cancel()
    }
}
