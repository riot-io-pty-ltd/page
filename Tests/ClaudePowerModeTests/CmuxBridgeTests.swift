import XCTest
@testable import ClaudePowerMode

/// Records every cmux CLI call and answers from a script. Nothing here ever
/// spawns the real cmux (the developer's own shell may run inside it).
private final class FakeCmux {
    struct Call {
        let args: [String]
        let stdin: String?
        let env: [String: String]
    }
    typealias Rule = (match: ([String], String?) -> Bool, stdout: String, status: Int32, stderr: String)
    private let lock = NSLock()
    private(set) var calls: [Call] = []
    /// First matching rule wins.
    var rules: [Rule] = []
    /// Answers to `surface.input_state`, in order; the last one repeats.
    private var inputStateQueue: [String] = []

    var runner: CmuxBridge.Runner {
        return { [self] _, args, stdin, env, _ in
            let input = stdin.map { String(decoding: $0, as: UTF8.self) }
            lock.lock()
            defer { lock.unlock() }
            calls.append(Call(args: args, stdin: input, env: env))
            if args.first == "rpc", args.dropFirst().first == "surface.input_state", !inputStateQueue.isEmpty {
                let state = inputStateQueue.count > 1 ? inputStateQueue.removeFirst() : inputStateQueue[0]
                return ProcessRunner.Result(status: 0, stdout: #"{"state":"\#(state)","terminal":true}"#, stderr: "", timedOut: false, launched: true)
            }
            guard let rule = rules.first(where: { $0.match(args, input) }) else {
                return ProcessRunner.Result(status: 1, stdout: "", stderr: "unexpected call", timedOut: false, launched: true)
            }
            return ProcessRunner.Result(status: rule.status, stdout: rule.stdout, stderr: rule.stderr, timedOut: false, launched: true)
        }
    }

    func on(_ verb: String, method: String? = nil, stdout: String = "", status: Int32 = 0, stderr: String = "") {
        rules.append(({ args, _ in
            guard args.first == verb else { return false }
            if let method { return args.count > 1 && args[1] == method }
            return true
        }, stdout, status, stderr))
    }

    func inputStates(_ states: [String]) {
        lock.lock()
        inputStateQueue = states
        lock.unlock()
    }

    func verbs() -> [String] {
        calls.map { c in c.args.first == "rpc" ? "rpc " + (c.args.dropFirst().first ?? "") : (c.args.first ?? "") }
    }
}

private final class MemorySecrets: SecretStore {
    var value: SecretReadResult
    init(_ value: SecretReadResult) { self.value = value }
    func read(allowUI: Bool) -> SecretReadResult { value }
    func write(_ secret: String) -> String? { value = .found(secret); return nil }
    func delete() -> Bool { value = .notFound; return true }
}

final class CmuxDetectionTests: XCTestCase {
    func testBundlePathRecognisesCmuxAppsOnly() {
        XCTAssertEqual(CmuxBridge.bundlePath(fromAppCommand: "/Applications/cmux.app/Contents/MacOS/cmux"), "/Applications/cmux.app")
        XCTAssertEqual(CmuxBridge.bundlePath(fromAppCommand: "/Applications/cmux NEXT.app/Contents/MacOS/cmux --flag"),
                       "/Applications/cmux NEXT.app")
        XCTAssertNil(CmuxBridge.bundlePath(fromAppCommand: "/Applications/iTerm.app/Contents/MacOS/iTerm2"))
        XCTAssertNil(CmuxBridge.bundlePath(fromAppCommand: "/Applications/Ghostty.app/Contents/MacOS/ghostty"))
        XCTAssertNil(CmuxBridge.bundlePath(fromAppCommand: "/usr/local/bin/cmux send"))
    }

    func testHostAppCommandFindsCmuxAncestor() {
        let table = [
            ProcessRunner.ProcessInfoRow(pid: 10, ppid: 1, tty: "??", command: "/Applications/cmux.app/Contents/MacOS/cmux"),
            ProcessRunner.ProcessInfoRow(pid: 11, ppid: 10, tty: "ttys001", command: "/usr/bin/login -flp me"),
            ProcessRunner.ProcessInfoRow(pid: 12, ppid: 11, tty: "ttys001", command: "-zsh"),
            ProcessRunner.ProcessInfoRow(pid: 13, ppid: 12, tty: "ttys001", command: "claude --session-id x"),
        ]
        let cmd = InjectionExecutor.hostAppCommand(forPid: 13, processTable: table)
        XCTAssertEqual(cmd, "/Applications/cmux.app/Contents/MacOS/cmux")
        XCTAssertEqual(InjectionExecutor.hostApp(forPid: 13, processTable: table), "cmux")
        XCTAssertNotNil(CmuxBridge.bundlePath(fromAppCommand: cmd!))
    }

    private let sid = "b84356ec-c2dc-40b5-89f0-6948ea5c3815"
    private let surface = "5FA66D62-4F2B-4F19-90BE-80319216DE70"

    private func hookJSON(pid: Int = 11686, start: Int = 1792826841, active: String? = nil) -> Data {
        let activeSid = active ?? sid
        return Data("""
        {"version":1,
         "sessions":{"\(sid)":{"sessionId":"\(sid)","surfaceId":"\(surface)","workspaceId":"0A53CA2A-0000-4000-8000-000000000001",
                     "pid":\(pid),"pidStartSeconds":\(start),"pidStartMicroseconds":648034,"cwd":"/x","runtimeStatus":"idle"},
                     "bogus":{"surfaceId":"not-a-uuid"}},
         "activeSessionsBySurface":{"\(surface)":{"sessionId":"\(activeSid)","updatedAt":1792831540.5}}}
        """.utf8)
    }

    func testParseHookSessions() throws {
        let parsed = try XCTUnwrap(CmuxBridge.parseHookSessions(hookJSON()))
        let e = try XCTUnwrap(parsed.entries[sid])
        XCTAssertEqual(e.surfaceId, surface)
        XCTAssertEqual(e.pid, 11686)
        XCTAssertEqual(e.pidStartSeconds, 1792826841)
        XCTAssertNil(parsed.entries["bogus"], "entries without a UUID surface are dropped")
        XCTAssertEqual(parsed.activeBySurface[surface], sid)
        XCTAssertNil(CmuxBridge.parseHookSessions(Data("[1,2]".utf8)))
        XCTAssertNil(CmuxBridge.parseHookSessions(Data("{not json".utf8)))
    }

    func testVerifyRequiresPidAndStartTime() throws {
        let parsed = try XCTUnwrap(CmuxBridge.parseHookSessions(hookJSON()))
        let e = try XCTUnwrap(parsed.entries[sid])
        XCTAssertEqual(CmuxBridge.verify(e, pid: 11686, startSeconds: 1792826841, activeBySurface: parsed.activeBySurface), .match)
        // A recycled pid has a different start time.
        XCTAssertEqual(CmuxBridge.verify(e, pid: 11686, startSeconds: 1792826999, activeBySurface: parsed.activeBySurface), .mismatch)
        XCTAssertEqual(CmuxBridge.verify(e, pid: 4242, startSeconds: 1792826841, activeBySurface: parsed.activeBySurface), .mismatch)
        XCTAssertEqual(CmuxBridge.verify(e, pid: 11686, startSeconds: nil, activeBySurface: parsed.activeBySurface), .mismatch)
    }

    func testVerifyRefusesWhenAnotherSessionIsInFront() throws {
        let parsed = try XCTUnwrap(CmuxBridge.parseHookSessions(hookJSON(active: "455cd6af-046c-4468-9d9b-5de46c4d8194")))
        let e = try XCTUnwrap(parsed.entries[sid])
        XCTAssertEqual(CmuxBridge.verify(e, pid: 11686, startSeconds: 1792826841, activeBySurface: parsed.activeBySurface), .surfaceTaken)
    }

    func testReadHookSessionsFromStateDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try hookJSON().write(to: dir.appendingPathComponent("claude-hook-sessions.json"))
        let saved = CmuxBridge.stateDirectory
        CmuxBridge.stateDirectory = dir.path
        defer { CmuxBridge.stateDirectory = saved }
        XCTAssertEqual(CmuxBridge.readHookSessions(agent: .claude)?.entries[sid]?.surfaceId, surface)
        XCTAssertNil(CmuxBridge.readHookSessions(agent: .codex))
    }

    func testProcessStartSecondsOfSelf() throws {
        let start = try XCTUnwrap(CmuxBridge.processStartSeconds(getpid()))
        let now = Int(Date().timeIntervalSince1970)
        XCTAssertLessThanOrEqual(start, now)
        XCTAssertGreaterThan(start, now - 24 * 3600)
        XCTAssertNil(CmuxBridge.processStartSeconds(-1))
    }

    func testParseProcArgsKeepsOnlyRequestedKeys() {
        var bytes: [UInt8] = []
        var argc = Int32(2).littleEndian
        withUnsafeBytes(of: &argc) { bytes.append(contentsOf: $0) }
        func cstr(_ s: String) { bytes.append(contentsOf: Array(s.utf8)); bytes.append(0) }
        cstr("/usr/local/bin/claude")
        bytes.append(contentsOf: [0, 0, 0])           // padding
        cstr("claude")
        cstr("--session-id=CMUX_SURFACE_ID=fake")      // argv must not be read as env
        cstr("PATH=/usr/bin")
        cstr("CMUX_SOCKET_CAPABILITY=secret-token")
        cstr("CMUX_SURFACE_ID=5FA66D62-4F2B-4F19-90BE-80319216DE70")
        cstr("CMUX_WORKSPACE_ID=0A53CA2A-0000-4000-8000-000000000001")
        bytes.append(0)
        let env = CmuxBridge.parseProcArgsEnvironment(bytes, keys: ["CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID"])
        XCTAssertEqual(env, ["CMUX_SURFACE_ID": "5FA66D62-4F2B-4F19-90BE-80319216DE70",
                             "CMUX_WORKSPACE_ID": "0A53CA2A-0000-4000-8000-000000000001"])
        XCTAssertTrue(CmuxBridge.parseProcArgsEnvironment([1, 0], keys: ["X"]).isEmpty)
    }

    func testEnvironmentOfOwnProcessIsReadable() {
        // Our own environment always has PATH; only the requested key comes back.
        let env = CmuxBridge.environmentValues(ofPid: getpid(), keys: ["PATH"])
        XCTAssertEqual(env.keys.sorted(), ["PATH"])
    }
}

final class CmuxAccessTests: XCTestCase {
    private let statusJSON = { (mode: String) in
        """
        {"configured_mode":"\(mode)","effective_mode":"\(mode)","forced_value_status":"unmanaged",
         "live_enforcement":"not_observed","managed":false,"socket_path":"/Users/me/.local/state/cmux/cmux.sock","socket_path_state":"present"}
        """
    }

    func testParseSocketStatus() throws {
        let s = try XCTUnwrap(CmuxBridge.parseSocketStatus(statusJSON("cmuxOnly")))
        XCTAssertEqual(s.effectiveMode, .cmuxOnly)
        XCTAssertFalse(s.effectiveMode.admitsExternalClients)
        XCTAssertEqual(s.socketPath, "/Users/me/.local/state/cmux/cmux.sock")
        XCTAssertEqual(CmuxBridge.SocketMode(raw: "password"), .password)
        XCTAssertEqual(CmuxBridge.SocketMode(raw: "somethingNew"), .unknown("somethingNew"))
        XCTAssertFalse(CmuxBridge.SocketMode(raw: "somethingNew").admitsExternalClients, "unknown modes fail closed")
        XCTAssertNil(CmuxBridge.parseSocketStatus("not json"))
    }

    private func connect(mode: String, secret: SecretReadResult, cli: String = "/fake/cmux-\(UUID().uuidString)") -> (Result<CmuxBridge.Client, CmuxBridge.Failure>, FakeCmux) {
        let fake = FakeCmux()
        fake.on("socket-status", stdout: statusJSON(mode))
        return (CmuxBridge.connect(cliPath: cli, runner: fake.runner, secrets: MemorySecrets(secret), verifyCLI: { _ in true }), fake)
    }

    func testCmuxOnlyBlocksPageWithSetupHint() {
        let (r, _) = connect(mode: "cmuxOnly", secret: .found("pw"))
        guard case .failure(let f) = r else { return XCTFail("expected failure") }
        XCTAssertEqual(f.detail, "cmux blocks Page — open Page ▸ Integrations ▸ Set up cmux…")
        let (off, _) = connect(mode: "off", secret: .notFound)
        guard case .failure(let f2) = off else { return XCTFail("expected failure") }
        XCTAssertEqual(f2.detail, CmuxBridge.blockedDetail)
    }

    func testPasswordModeNeedsKeychainPassword() {
        let (r, _) = connect(mode: "password", secret: .notFound)
        guard case .failure(let f) = r else { return XCTFail("expected failure") }
        XCTAssertEqual(f.detail, CmuxBridge.needsPasswordDetail)
        let (r2, _) = connect(mode: "password", secret: .interactionRequired)
        guard case .failure = r2 else { return XCTFail("a Keychain prompt must never be waited on") }
    }

    func testPasswordGoesInEnvironmentNeverArgvAndCmuxVarsAreStripped() throws {
        let (r, fake) = connect(mode: "password", secret: .found("s3cret"))
        let client = try r.get()
        fake.on("ping", stdout: "PONG")
        _ = client.ping()
        let ping = try XCTUnwrap(fake.calls.last)
        XCTAssertEqual(ping.args, ["ping"])
        XCTAssertEqual(ping.env["CMUX_SOCKET_PASSWORD"], "s3cret")
        XCTAssertFalse(ping.args.joined(separator: " ").contains("s3cret"))
        XCTAssertFalse(ping.env.keys.contains { $0.hasPrefix("CMUX_") && $0 != "CMUX_SOCKET_PASSWORD" })
        // socket-status never gets the password.
        XCTAssertNil(fake.calls.first?.env["CMUX_SOCKET_PASSWORD"])
    }

    func testAutomationModeConnectsWithoutPassword() throws {
        let (r, fake) = connect(mode: "automation", secret: .found("unused"))
        let client = try r.get()
        fake.on("ping", stdout: "PONG")
        _ = client.ping()
        XCTAssertNil(fake.calls.last?.env["CMUX_SOCKET_PASSWORD"])
    }

    func testCliEnvironmentStripsInheritedCmuxVariables() {
        setenv("CMUX_SURFACE_ID", "5FA66D62-4F2B-4F19-90BE-80319216DE70", 1)
        setenv("CMUX_SOCKET_CAPABILITY", "token", 1)
        defer { unsetenv("CMUX_SURFACE_ID"); unsetenv("CMUX_SOCKET_CAPABILITY") }
        let env = CmuxBridge.cliEnvironment(password: nil)
        XCTAssertNil(env["CMUX_SURFACE_ID"])
        XCTAssertNil(env["CMUX_SOCKET_CAPABILITY"])
        XCTAssertNotNil(env["PATH"])
    }

    func testClassifyMapsSocketRefusals() {
        func r(_ stderr: String) -> ProcessRunner.Result {
            ProcessRunner.Result(status: 1, stdout: "", stderr: stderr, timedOut: false, launched: true)
        }
        XCTAssertEqual(CmuxBridge.classify(r("Access denied - only processes started inside cmux can connect"), fallback: "x").detail,
                       CmuxBridge.blockedDetail)
        XCTAssertEqual(CmuxBridge.classify(r("write: Broken pipe"), fallback: "x").detail, CmuxBridge.blockedDetail)
        XCTAssertEqual(CmuxBridge.classify(r("Authentication required. Send auth <password> first."), fallback: "x").detail,
                       CmuxBridge.passwordRejectedDetail)
        XCTAssertEqual(CmuxBridge.classify(r("connect: Connection refused"), fallback: "x").detail, CmuxBridge.notRunningDetail)
        XCTAssertEqual(CmuxBridge.classify(r("something else"), fallback: "Couldn't type").detail, "Couldn't type")
        XCTAssertEqual(CmuxBridge.classify(.notLaunched, fallback: "x").detail, "Couldn't run cmux's command-line tool")
    }

    func testOverloadedIsRetriedOnce() throws {
        let fake = FakeCmux()
        fake.on("socket-status", stdout: statusJSON("automation"))
        var pings = 0
        fake.rules.append(({ args, _ in
            guard args.first == "ping" else { return false }
            pings += 1
            return pings == 1
        }, "", 1, #"{"error":"overloaded","retry_after_ms":10}"#))
        fake.on("ping", stdout: "PONG")
        let client = try CmuxBridge.connect(cliPath: "/fake/\(UUID().uuidString)", runner: fake.runner, secrets: MemorySecrets(.notFound)).get()
        XCTAssertNoThrow(try client.ping().get())
        XCTAssertEqual(fake.calls.filter { $0.args.first == "ping" }.count, 2)
    }

    func testUnwrapRPCAcceptsEnvelopeAndBareResult() throws {
        let env = try CmuxBridge.unwrapRPC(#"{"id":"1","ok":true,"result":{"state":"empty"}}"#).get()
        XCTAssertEqual(env["state"] as? String, "empty")
        let bare = try CmuxBridge.unwrapRPC(#"{"state":"draft","draft_length":3}"#).get()
        XCTAssertEqual(CmuxBridge.parseInputState(bare), .draft)
        guard case .failure = CmuxBridge.unwrapRPC(#"{"ok":false,"error":{"code":"x","message":"nope"}}"#) else { return XCTFail() }
        guard case .failure = CmuxBridge.unwrapRPC("garbage") else { return XCTFail() }
    }

    func testInputStateParsingAndTypingGate() {
        XCTAssertEqual(CmuxBridge.parseInputState(["state": "dialog"]), .dialog)
        XCTAssertEqual(CmuxBridge.parseInputState(["state": "weird"]), .unknown)
        XCTAssertEqual(CmuxBridge.parseInputState([:]), .unknown)
        XCTAssertNil(CmuxBridge.refusalForTyping(.empty))
        XCTAssertEqual(CmuxBridge.refusalForTyping(.draft), "You have a half-typed message in that pane")
        XCTAssertNotNil(CmuxBridge.refusalForTyping(.dialog))
        XCTAssertNotNil(CmuxBridge.refusalForTyping(.unknown), "unknown fails closed")
    }

    func testRealRunnerRefusesSocketCommandsUnderXCTest() {
        let r = CmuxBridge.defaultRunner("/bin/echo", ["send", "--surface", "x", "--", "hi"], nil, [:], 1)
        XCTAssertFalse(r.launched, "a test must never reach the live cmux")
        let offline = CmuxBridge.defaultRunner("/bin/echo", ["socket-status", "--json"], nil, [:], 1)
        XCTAssertTrue(offline.launched)
    }
}

final class CmuxFeedTests: XCTestCase {
    private let sid = "d0abd528-7aba-468b-828e-a153fef21a02"
    private let page = Date(timeIntervalSince1970: 1_800_000_000)

    private func workstream(_ sessionId: String, source: String = "claude") -> String {
        "cmux-feed-v1:" + Data(source.utf8).base64EncodedString() + ":" + Data(sessionId.utf8).base64EncodedString()
    }

    private func item(kind: String = "permissionRequest", status: String = "pending", session: String? = nil,
                      created: Date? = nil, request: String = "49AB2908-3310-4B3B-9111-31A7EB3407B2") -> CmuxBridge.FeedItem {
        CmuxBridge.FeedItem(requestId: request, kind: kind, status: status, source: "claude",
                            sessionId: session ?? sid, createdAt: created ?? page)
    }

    func testDecodeWorkstreamId() throws {
        let d = try XCTUnwrap(CmuxBridge.decodeWorkstreamId(workstream(sid)))
        XCTAssertEqual(d.source, "claude")
        XCTAssertEqual(d.sessionId, sid)
        // Unpadded base64, as cmux writes it.
        let unpadded = "cmux-feed-v1:Y2xhdWRl:" + Data(sid.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(CmuxBridge.decodeWorkstreamId(unpadded)?.sessionId, sid)
        XCTAssertNil(CmuxBridge.decodeWorkstreamId("other:Y2xhdWRl:eA"))
        XCTAssertNil(CmuxBridge.decodeWorkstreamId("cmux-feed-v1:Y2xhdWRl"))
    }

    func testParseFeedItems() throws {
        let json = """
        {"items":[{"id":"a","request_id":"R1","workstream_id":"\(workstream(sid))","source":"claude","kind":"permissionRequest",
                   "status":"pending","created_at":"2027-01-15T08:00:00.250Z"},
                  {"id":"b","workstream_id":"\(workstream(sid))","source":"claude","kind":"toolUse","status":"pending"}]}
        """
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let items = CmuxBridge.parseFeedItems(obj)
        XCTAssertEqual(items.count, 1, "items without a request id are informational")
        XCTAssertEqual(items[0].sessionId, sid)
        XCTAssertEqual(items[0].kind, "permissionRequest")
        XCTAssertNotNil(items[0].createdAt)
    }

    func testNothingHeldMeansUseTheScreen() {
        XCTAssertEqual(CmuxBridge.claudeFeedDecision(items: [], sessionId: sid, action: "approve", text: "", pageStart: page), .none)
        let other = item(session: "455cd6af-046c-4468-9d9b-5de46c4d8194")
        XCTAssertEqual(CmuxBridge.claudeFeedDecision(items: [other], sessionId: sid, action: "approve", text: "", pageStart: page), .none)
        let done = item(status: "resolved")
        XCTAssertEqual(CmuxBridge.claudeFeedDecision(items: [done], sessionId: sid, action: "approve", text: "", pageStart: page), .none)
    }

    func testPermissionMapping() {
        let it = item()
        XCTAssertEqual(CmuxBridge.claudeFeedDecision(items: [it], sessionId: sid, action: "approve", text: "", pageStart: page),
                       .permission(requestId: it.requestId, mode: "once", thenType: nil))
        XCTAssertEqual(CmuxBridge.claudeFeedDecision(items: [it], sessionId: sid, action: "deny", text: "", pageStart: page),
                       .permission(requestId: it.requestId, mode: "deny", thenType: nil))
        XCTAssertEqual(CmuxBridge.claudeFeedDecision(items: [it], sessionId: sid.uppercased(), action: "custom", text: "use pnpm", pageStart: page),
                       .permission(requestId: it.requestId, mode: "deny", thenType: "use pnpm"))
        if case .refuse = CmuxBridge.claudeFeedDecision(items: [it], sessionId: sid, action: "carry_on", text: "", pageStart: page) {} else { XCTFail() }
    }

    func testPlanMapping() {
        let it = item(kind: "exitPlan")
        XCTAssertEqual(CmuxBridge.claudeFeedDecision(items: [it], sessionId: sid, action: "approve", text: "", pageStart: page),
                       .exitPlan(requestId: it.requestId, mode: "manual", feedback: nil))
        XCTAssertEqual(CmuxBridge.claudeFeedDecision(items: [it], sessionId: sid, action: nil, text: "smaller steps", pageStart: page),
                       .exitPlan(requestId: it.requestId, mode: "deny", feedback: "smaller steps"))
    }

    func testQuestionsAndAmbiguityAreRefused() {
        if case .refuse = CmuxBridge.claudeFeedDecision(items: [item(kind: "question")], sessionId: sid, action: "custom", text: "B", pageStart: page) {} else { XCTFail() }
        let two = [item(request: "R1"), item(request: "R2")]
        XCTAssertEqual(CmuxBridge.claudeFeedDecision(items: two, sessionId: sid, action: "approve", text: "", pageStart: page),
                       .refuse(CmuxBridge.feedAmbiguousDetail))
    }

    func testNewerRequestThanThePageIsStale() {
        let newer = item(created: page.addingTimeInterval(30))
        XCTAssertEqual(CmuxBridge.claudeFeedDecision(items: [newer], sessionId: sid, action: "approve", text: "", pageStart: page),
                       .refuse(InjectionExecutor.staleMessage))
        let slightlyLater = item(created: page.addingTimeInterval(3))
        XCTAssertEqual(CmuxBridge.claudeFeedDecision(items: [slightlyLater], sessionId: sid, action: "approve", text: "", pageStart: page),
                       .permission(requestId: slightlyLater.requestId, mode: "once", thenType: nil))
        // No way to match → refuse rather than guess.
        XCTAssertEqual(CmuxBridge.claudeFeedDecision(items: [item()], sessionId: sid, action: "approve", text: "", pageStart: nil),
                       .refuse(CmuxBridge.feedUnmatchedDetail))
        let undated = CmuxBridge.FeedItem(requestId: "R", kind: "permissionRequest", status: "pending", source: "claude", sessionId: sid, createdAt: nil)
        XCTAssertEqual(CmuxBridge.claudeFeedDecision(items: [undated], sessionId: sid, action: "approve", text: "", pageStart: page),
                       .refuse(CmuxBridge.feedUnmatchedDetail))
    }

    func testNeverPicksAlwaysAllOrBypass() {
        for action in ["approve", "deny", "custom", "carry_on", nil] as [String?] {
            let d = CmuxBridge.claudeFeedDecision(items: [item()], sessionId: sid, action: action, text: "x", pageStart: page)
            if case .permission(_, let mode, _) = d { XCTAssertTrue(["once", "deny"].contains(mode)) }
        }
    }
}

/// The cmux transport, end to end against a fake CLI.
final class CmuxTransportTests: XCTestCase {
    private let surface = "5FA66D62-4F2B-4F19-90BE-80319216DE70"
    private let sid = "d0abd528-7aba-468b-828e-a153fef21a02"

    private func client(_ fake: FakeCmux) -> CmuxBridge.Client {
        CmuxBridge.Client(cliPath: "/fake/cmux", password: nil, runner: fake.runner)
    }

    func testApproveSendsDigitOnlyIntoDialog() {
        let fake = FakeCmux()
        fake.inputStates(["dialog"])
        fake.on("send")
        let r = InjectionExecutor.sendViaCmux([.text("1")], client: client(fake), surface: surface, awaitClosed: { true })
        XCTAssertTrue(r.success)
        let send = fake.calls.first { $0.args.first == "send" }
        XCTAssertEqual(send?.args, ["send", "--surface", surface, "--force", "--", "1"])
    }

    func testApproveRefusedWhenNoDialogOnScreen() {
        let fake = FakeCmux()
        fake.inputStates(["empty"])
        let r = InjectionExecutor.sendViaCmux([.text("1")], client: client(fake), surface: surface, awaitClosed: { true })
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.detail, InjectionExecutor.promptGoneMessage)
        XCTAssertFalse(fake.calls.contains { $0.args.first == "send" }, "a digit must never land in the input box")
    }

    func testTextIsPastedOnlyIntoEmptyPromptViaStdin() {
        let fake = FakeCmux()
        fake.inputStates(["empty"])
        fake.on("paste")
        let r = InjectionExecutor.sendViaCmux([.text("ship it\nthen tests"), .enter], client: client(fake), surface: surface, awaitClosed: { true })
        XCTAssertTrue(r.success)
        let paste = fake.calls.first { $0.args.first == "paste" }
        XCTAssertEqual(paste?.args, ["paste", "--surface", surface, "--submit", "-"])
        XCTAssertEqual(paste?.stdin, "ship it\nthen tests")
        XCTAssertFalse(paste?.args.contains("--force") ?? true, "paste keeps cmux's own draft guard")
        XCTAssertFalse(fake.calls.contains { $0.args.first == "send-key" && $0.args.contains("enter") }, "--submit presses Enter")
    }

    func testDraftRefusesWithHalfTypedMessage() {
        let fake = FakeCmux()
        fake.inputStates(["draft"])
        let r = InjectionExecutor.sendViaCmux([.text("hello"), .enter], client: client(fake), surface: surface, awaitClosed: { true })
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.detail, "You have a half-typed message in that pane")
        XCTAssertFalse(fake.calls.contains { $0.args.first == "paste" })
    }

    func testDenyWithTextEscapesWaitsForMenuToClearThenPastes() {
        let fake = FakeCmux()
        fake.inputStates(["dialog", "dialog", "empty"])
        fake.on("send-key")
        fake.on("paste")
        var awaited = false
        let steps: [Keystroke] = [.escape, .awaitPromptClosed, .text("use pnpm"), .enter]
        let r = InjectionExecutor.sendViaCmux(steps, client: client(fake), surface: surface, awaitClosed: { awaited = true; return true })
        XCTAssertTrue(r.success, r.detail)
        XCTAssertTrue(awaited)
        XCTAssertEqual(fake.calls.first { $0.args.first == "send-key" }?.args, ["send-key", "--surface", surface, "--force", "--", "escape"])
        XCTAssertEqual(fake.verbs().filter { $0 == "paste" }.count, 1)
    }

    func testDenyWithTextStopsIfPromptDoesNotClose() {
        let fake = FakeCmux()
        fake.inputStates(["dialog"])
        fake.on("send-key")
        let steps: [Keystroke] = [.escape, .awaitPromptClosed, .text("x"), .enter]
        let r = InjectionExecutor.sendViaCmux(steps, client: client(fake), surface: surface, awaitClosed: { false })
        XCTAssertFalse(r.success)
        XCTAssertFalse(fake.calls.contains { $0.args.first == "paste" })
    }

    func testBareEnterIsNeverSent() {
        let fake = FakeCmux()
        fake.inputStates(["empty"])
        let r = InjectionExecutor.sendViaCmux([.enter], client: client(fake), surface: surface, awaitClosed: { true })
        XCTAssertFalse(r.success)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testInvalidSurfaceNeverReachesCLI() {
        let fake = FakeCmux()
        let c = client(fake)
        guard case .failure = c.pasteAndSubmit(surface: "surface:2", text: "x") else { return XCTFail() }
        guard case .failure = c.sendKey(surface: "", key: "escape", force: false) else { return XCTFail() }
        XCTAssertTrue(fake.calls.isEmpty)
    }

    // MARK: Feed path

    private func feedList(_ items: String) -> String { #"{"ok":true,"result":{"items":["# + items + "]}}" }

    private func request(action: String?, text: String = "", pageStart: Date?) -> InjectionExecutor.ClaudeReplyRequest {
        InjectionExecutor.ClaudeReplyRequest(interventionId: "x", sessionId: sid, action: action, text: text, kind: .approval,
                                             pagePid: 1, pageStateStart: pageStart, pagePromptKey: nil, hookCreatedAt: nil)
    }

    private var session: ClaudeLiveSession {
        ClaudeLiveSession(pid: 1, sessionId: sid, cwd: "/x", status: .busy, statusUpdatedAt: nil, tty: "ttys001", hasSessionFile: true)
    }

    private func pendingItem(created: String = "2027-01-15T08:00:00Z") -> String {
        let ws = "cmux-feed-v1:" + Data("claude".utf8).base64EncodedString() + ":" + Data(sid.utf8).base64EncodedString()
        return #"{"request_id":"R1","workstream_id":"\#(ws)","source":"claude","kind":"permissionRequest","status":"pending","created_at":"\#(created)"}"#
    }

    private let pageStart = ISO8601DateFormatter().date(from: "2027-01-15T08:00:01Z")!

    func testFeedApproveRepliesOnceAndConfirms() {
        let fake = FakeCmux()
        var lists = 0
        fake.rules.append(({ args, _ in
            guard args.first == "rpc", args.dropFirst().first == "feed.list" else { return false }
            lists += 1
            return lists == 1
        }, feedList(pendingItem()), 0, ""))
        fake.on("rpc", method: "feed.list", stdout: feedList(""))
        fake.on("rpc", method: "feed.permission.reply", stdout: #"{"ok":true,"result":{}}"#)
        let r = InjectionExecutor.answerViaCmuxFeed(request(action: "approve", pageStart: pageStart), session: session,
                                                    kind: .approval, client: client(fake), surface: surface, confirmClosed: { true })
        XCTAssertEqual(r?.success, true, r?.detail ?? "")
        XCTAssertEqual(r?.method, .cmuxFeed)
        let reply = fake.calls.first { $0.args.dropFirst().first == "feed.permission.reply" }
        let params = reply?.stdin.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }
        XCTAssertEqual(params, ["request_id": "R1", "mode": "once"])
        XCTAssertEqual(reply?.args, ["rpc", "feed.permission.reply", "-"], "params travel on stdin")
    }

    func testFeedReplyWhileClaudesMenuStaysOpenIsFailure() {
        let fake = FakeCmux()
        var lists = 0
        fake.rules.append(({ args, _ in
            guard args.first == "rpc", args.dropFirst().first == "feed.list" else { return false }
            lists += 1
            return lists == 1
        }, feedList(pendingItem()), 0, ""))
        fake.on("rpc", method: "feed.list", stdout: feedList(""))
        fake.on("rpc", method: "feed.permission.reply", stdout: "{}")
        let r = InjectionExecutor.answerViaCmuxFeed(request(action: "approve", pageStart: pageStart), session: session,
                                                    kind: .approval, client: client(fake), surface: surface, confirmClosed: { false })
        XCTAssertEqual(r?.success, false, "a resolved Feed item doesn't prove Claude's own menu took the answer")
    }

    func testFeedNothingPendingFallsThroughToScreen() {
        let fake = FakeCmux()
        fake.on("rpc", method: "feed.list", stdout: feedList(""))
        let r = InjectionExecutor.answerViaCmuxFeed(request(action: "approve", pageStart: pageStart), session: session,
                                                    kind: .approval, client: client(fake), surface: surface, confirmClosed: { true })
        XCTAssertNil(r)
    }

    func testFeedUnavailableFallsThroughToScreen() {
        let fake = FakeCmux()
        fake.on("rpc", method: "feed.list", status: 1, stderr: "Unknown method")
        XCTAssertNil(InjectionExecutor.answerViaCmuxFeed(request(action: "approve", pageStart: pageStart), session: session,
                                                         kind: .approval, client: client(fake), surface: surface, confirmClosed: { true }))
    }

    func testFeedDenyWithTextRefusesOverDraft() {
        let fake = FakeCmux()
        var lists = 0
        fake.rules.append(({ args, _ in
            guard args.first == "rpc", args.dropFirst().first == "feed.list" else { return false }
            lists += 1
            return lists == 1
        }, feedList(pendingItem()), 0, ""))
        fake.on("rpc", method: "feed.list", stdout: feedList(""))
        fake.on("rpc", method: "feed.permission.reply", stdout: "{}")
        fake.inputStates(["draft"])
        let r = InjectionExecutor.answerViaCmuxFeed(request(action: "custom", text: "use pnpm", pageStart: pageStart), session: session,
                                                    kind: .approval, client: client(fake), surface: surface, confirmClosed: { true })
        XCTAssertEqual(r?.success, false)
        XCTAssertEqual(r?.detail, "Denied in cmux, but your message wasn't sent — You have a half-typed message in that pane")
        XCTAssertFalse(fake.calls.contains { $0.args.first == "paste" })
    }

    func testFeedReplyNotConfirmedIsFailure() {
        let fake = FakeCmux()
        fake.on("rpc", method: "feed.list", stdout: feedList(pendingItem()))   // stays pending
        fake.on("rpc", method: "feed.permission.reply", stdout: "{}")
        let r = InjectionExecutor.answerViaCmuxFeed(request(action: "deny", pageStart: pageStart), session: session,
                                                    kind: .approval, client: client(fake), surface: surface, confirmClosed: { true })
        XCTAssertEqual(r?.success, false)
    }

    func testIdleReplyDoesNotConsultFeed() {
        let fake = FakeCmux()
        let req = InjectionExecutor.ClaudeReplyRequest(interventionId: "x", sessionId: sid, action: "custom", text: "hi", kind: .idle,
                                                       pagePid: 1, pageStateStart: nil, pagePromptKey: nil, hookCreatedAt: nil)
        XCTAssertNil(InjectionExecutor.answerViaCmuxFeed(req, session: session, kind: .idle, client: client(fake), surface: surface, confirmClosed: { true }))
        XCTAssertTrue(fake.calls.isEmpty)
    }
}

final class KeychainHelperTests: XCTestCase {
    func testLegacyAuthenticationUIConstantsMatchSecurityFramework() {
        XCTAssertEqual(KeychainSecretStore.legacyAuthenticationUIKey, kSecUseAuthenticationUI as String)
    }

    func testDisallowUISetsBothSwitches() {
        var q: [String: Any] = [:]
        KeychainSecretStore.disallowUI(&q)
        XCTAssertEqual(q["u_AuthUI"] as? String, "u_AuthUIF")
        XCTAssertNotNil(q[kSecUseAuthenticationContext as String])
    }
}
