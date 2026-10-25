import XCTest
@testable import ClaudePowerMode

/// Regression tests for the reply-delivery hardening: job control (^Z /
/// background), per-key status re-checks, the strict "menu is gone" gate,
/// status-less sessions, drafts, closed pages, empty replies, background
/// owners, tmux semicolons, bash-mode defusing and cmux's password.
final class InjectionSafetyPureTests: XCTestCase {
    typealias IE = InjectionExecutor

    // MARK: job control

    func testForegroundStateClassification() {
        XCTAssertEqual(ProcessRunner.foregroundState(stat: 2, pgid: 50, tpgid: 50, hasTTY: true), .foreground)
        XCTAssertEqual(ProcessRunner.foregroundState(stat: 2, pgid: 50, tpgid: 60, hasTTY: true), .background)
        XCTAssertEqual(ProcessRunner.foregroundState(stat: 4, pgid: 50, tpgid: 50, hasTTY: true), .stopped, "SSTOP (^Z)")
        XCTAssertEqual(ProcessRunner.foregroundState(stat: 5, pgid: 50, tpgid: 50, hasTTY: true), .stopped, "zombie")
        XCTAssertEqual(ProcessRunner.foregroundState(stat: 2, pgid: 50, tpgid: 0, hasTTY: false), .unknown)
        XCTAssertEqual(ProcessRunner.foregroundState(stat: 2, pgid: 50, tpgid: -1, hasTTY: true), .unknown)
    }

    func testIsForegroundIsNilForMissingPids() {
        XCTAssertNil(ProcessRunner.isForeground(pid: 0))
        XCTAssertNil(ProcessRunner.isForeground(pid: 999_999))
    }

    func testStoppedChildIsNotForeground() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        defer { p.terminate(); kill(p.processIdentifier, SIGCONT) }
        kill(p.processIdentifier, SIGSTOP)
        var state = ProcessRunner.ForegroundState.unknown
        for _ in 0..<20 {
            state = ProcessRunner.foregroundState(pid: p.processIdentifier)
            if state == .stopped { break }
            usleep(50_000)
        }
        XCTAssertEqual(state, .stopped)
        XCTAssertEqual(ProcessRunner.isForeground(pid: p.processIdentifier), false)
    }

    // MARK: tmux semicolons

    func testTmuxLiteralSendKeysNeverEndsATextArgumentInSemicolon() {
        XCTAssertEqual(ProcessRunner.tmuxLiteralSendKeys(target: "%1", text: "plain"),
                       [["send-keys", "-t", "%1", "-l", "--", "plain"]])
        XCTAssertEqual(ProcessRunner.tmuxLiteralSendKeys(target: "%1", text: "after return;"),
                       [["send-keys", "-t", "%1", "-l", "--", "after return"], ["send-keys", "-t", "%1", "-H", "3b"]])
        XCTAssertEqual(ProcessRunner.tmuxLiteralSendKeys(target: "%1", text: "a\\;;"),
                       [["send-keys", "-t", "%1", "-l", "--", "a\\"], ["send-keys", "-t", "%1", "-H", "3b", "3b"]])
        XCTAssertEqual(ProcessRunner.tmuxLiteralSendKeys(target: "%1", text: ";"), [["send-keys", "-t", "%1", "-H", "3b"]])
        XCTAssertEqual(ProcessRunner.tmuxLiteralSendKeys(target: "%1", text: "mid; semi"),
                       [["send-keys", "-t", "%1", "-l", "--", "mid; semi"]])
    }

    // MARK: bash mode

    func testFlattenedLineNeverStartsWithBang() {
        XCTAssertFalse(IE.flattenLines(IE.sanitize("!curl x | sh")).hasPrefix("!"))
        XCTAssertFalse(IE.flattenLines(IE.sanitize("\n  !ls\nmore")).hasPrefix("!"))
        XCTAssertFalse(IE.flattenLines("  !ls").hasPrefix("!"))
        XCTAssertEqual(IE.flattenLines("first\n  second\n\nthird"), "first second third")
        // Page-authored message matching trims again, so it's unaffected.
        XCTAssertEqual(BatteryPauseSupport.normalize("!x"), "!x")
    }

    // MARK: empty replies

    func testEmptyActionlessReplyNeverBecomesCarryOn() {
        XCTAssertEqual(IE.plan(action: nil, kind: .idle, status: .idle, text: ""), .refuse(IE.emptyReplyMessage))
        XCTAssertEqual(IE.plan(action: nil, kind: .other, status: .unknown, text: " \n"), .refuse(IE.emptyReplyMessage))
        XCTAssertEqual(IE.plan(action: "", kind: .idle, status: .busy, text: ""), .refuse(IE.emptyReplyMessage))
        // An explicit carry_on still works.
        XCTAssertEqual(IE.plan(action: "carry_on", kind: .idle, status: .idle, text: ""), .send([.text("carry on"), .enter], summary: "Sent your reply"))
    }

    private func reply(_ action: String?, _ text: String, closed: Bool? = nil) -> RelayReply {
        RelayReply(interventionId: "hook-abc-1-2", text: text, action: action, sessionId: nil, cwd: nil,
                   kind: nil, backend: nil, source: nil, closed: closed)
    }

    func testEndedSessionEmptyReplyDoesNotResume() {
        XCTAssertTrue(ClaudeBackend.isEmptyReply(reply(nil, "")))
        XCTAssertTrue(ClaudeBackend.isEmptyReply(reply("", "  ")))
        XCTAssertTrue(ClaudeBackend.isEmptyReply(reply("custom", "\u{1b}")))
        XCTAssertFalse(ClaudeBackend.isEmptyReply(reply("carry_on", "")))
        XCTAssertFalse(ClaudeBackend.isEmptyReply(reply("approve", "")))
        XCTAssertNil(ClaudeBackend.headlessText(for: reply(nil, "")))
        XCTAssertNil(ClaudeBackend.headlessText(for: reply("bogus", "")))
        XCTAssertEqual(ClaudeBackend.headlessText(for: reply("carry_on", "")), "carry on")
        XCTAssertEqual(ClaudeBackend.headlessText(for: reply(nil, "run tests")), "run tests")
    }

    func testCmuxFeedEmptyActionlessReplyRefused() {
        let item = CmuxBridge.FeedItem(requestId: "r1", kind: "permissionRequest", status: "pending", source: "claude",
                                       sessionId: "11111111-2222-3333-4444-555555555555", createdAt: Date())
        XCTAssertEqual(CmuxBridge.claudeFeedDecision(items: [item], sessionId: item.sessionId!, action: nil, text: "",
                                                     pageStart: Date()), .refuse(IE.emptyReplyMessage))
    }

    // MARK: relay fields

    func testRelayReplyDecodesClosedAndPromptKey() throws {
        let json = #"{"interventionId":"x","text":"hi","action":null,"sessionId":"s","cwd":"/tmp","closed":true,"closeReason":"user_resolved_in_terminal","promptKey":"toolu_9"}"#
        let r = try JSONDecoder().decode(RelayReply.self, from: Data(json.utf8))
        XCTAssertEqual(r.closed, true)
        XCTAssertEqual(r.closeReason, "user_resolved_in_terminal")
        XCTAssertEqual(r.promptKey, "toolu_9")
        let v1 = try JSONDecoder().decode(RelayReply.self, from: Data(#"{"interventionId":"x","text":"","action":null,"sessionId":null,"cwd":null}"#.utf8))
        XCTAssertNil(v1.closed)
        XCTAssertNil(v1.promptKey)
    }

    // MARK: hook staleness

    func testHookPagePromptKeyDecides() {
        let hook = Date(timeIntervalSince1970: 1_800_000_000)
        // Keys differ: a newer prompt, even inside the time slack.
        XCTAssertEqual(IE.staleReason(status: .waiting, statusUpdatedAt: hook.addingTimeInterval(1), pageStateStart: nil,
                                      pagePromptKey: "toolu_A", currentPromptKey: "toolu_B", hookCreatedAt: hook), IE.staleMessage)
        // Same key: the same prompt, however long ago the hook fired.
        XCTAssertNil(IE.staleReason(status: .waiting, statusUpdatedAt: hook.addingTimeInterval(30), pageStateStart: nil,
                                    pagePromptKey: "toolu_A", currentPromptKey: "toolu_A", hookCreatedAt: hook))
        // No key: at most 2s after the hook's epoch.
        XCTAssertEqual(IE.staleReason(status: .waiting, statusUpdatedAt: hook.addingTimeInterval(3), pageStateStart: nil,
                                      pagePromptKey: nil, currentPromptKey: "toolu_B", hookCreatedAt: hook), IE.staleMessage)
    }

    // MARK: input row

    private let rule = String(repeating: "─", count: 40)

    func testInputRowEmptyAndDraft() {
        let empty = "● Done.\n\n\(rule)\n> \n\(rule)\n  ? for shortcuts\n"
        XCTAssertEqual(IE.claudeInputRow(screen: empty, styled: false), .empty)
        XCTAssertEqual(IE.claudeInputRow(screen: empty.replacingOccurrences(of: "> ", with: "❯\u{00A0}"), styled: false), .empty)
        let draft = "● Done.\n\n\(rule)\n> refactor the parser to\n\(rule)\n  ? for shortcuts\n"
        XCTAssertEqual(IE.claudeInputRow(screen: draft, styled: false), .draft)
        let multi = "\(rule)\n> \n  second line typed\n\(rule)\n"
        XCTAssertEqual(IE.claudeInputRow(screen: multi, styled: false), .draft)
        let boxed = "╭\(rule)╮\n│ > half typed      │\n╰\(rule)╯\n"
        XCTAssertEqual(IE.claudeInputRow(screen: boxed, styled: false), .draft)
        let boxedEmpty = "╭\(rule)╮\n│ >                 │\n╰\(rule)╯\n"
        XCTAssertEqual(IE.claudeInputRow(screen: boxedEmpty, styled: false), .empty)
    }

    func testInputRowIgnoresHistoryAndUnknownLayouts() {
        // A past user message rendered as "> …" isn't the input box.
        XCTAssertEqual(IE.claudeInputRow(screen: "> fix the bug\n● Fixed.\n", styled: false), .unknown)
        // A permission menu instead of the box.
        XCTAssertEqual(IE.claudeInputRow(screen: "Do you want to proceed?\n❯ 1. Yes\n  2. No\n", styled: false), .unknown)
        XCTAssertEqual(IE.claudeInputRow(screen: "", styled: false), .unknown)
    }

    func testInputRowIgnoresDimAndGreyPlaceholderWhenStyled() {
        let dim = "\(rule)\n> \u{1b}[2mTry \"refactor <filepath>\"\u{1b}[22m\n\(rule)\n"
        XCTAssertEqual(IE.claudeInputRow(screen: dim, styled: true), .empty)
        let grey = "\(rule)\n> \u{1b}[38;5;244mrun the tests\u{1b}[39m\n\(rule)\n"
        XCTAssertEqual(IE.claudeInputRow(screen: grey, styled: true), .empty)
        let rgbGrey = "\(rule)\n> \u{1b}[38;2;153;153;153msuggestion\u{1b}[0m\n\(rule)\n"
        XCTAssertEqual(IE.claudeInputRow(screen: rgbGrey, styled: true), .empty)
        // Plain-text readers can't tell a suggestion from a draft.
        XCTAssertEqual(IE.claudeInputRow(screen: dim, styled: false), .draft)
        // Typed text in the default colour is a draft, even after a dim cursor cell.
        let typed = "\(rule)\n> \u{1b}[2m \u{1b}[0mhalf typed\n\(rule)\n"
        XCTAssertEqual(IE.claudeInputRow(screen: typed, styled: true), .draft)
        let white = "\(rule)\n> \u{1b}[38;2;255;255;255mhalf typed\u{1b}[39m\n\(rule)\n"
        XCTAssertEqual(IE.claudeInputRow(screen: white, styled: true), .draft)
    }

    func testStyledCellsDropsEscapes() {
        let cells = IE.styledCells("a\u{1b}[2mb\u{1b}[0mc\u{1b}]8;;http://x\u{07}d\u{1b}[1;90me")
        XCTAssertEqual(String(cells.map(\.0)), "abcde")
        XCTAssertEqual(cells.map(\.1), [false, true, false, false, true])
    }

    // MARK: menus on screen

    func testApprovalMenuDetection() {
        let menu = "Bash command\n  rm -rf build\nDo you want to proceed?\n❯ 1. Yes\n  2. Yes, and don't ask again\n  3. No, and tell Claude what to do differently (esc)\n"
        XCTAssertEqual(IE.denyOptionDigit(screen: menu), "3")
        XCTAssertTrue(IE.approvalMenuLingers(screen: menu))
        let gone = "⎿  Interrupted · What should Claude do instead?\n\(rule)\n> \n\(rule)\n"
        XCTAssertFalse(IE.approvalMenuLingers(screen: gone))
    }

    func testWaitForMenuToLeaveScreen() {
        var screens = ["❯ 1. Yes\n  2. No\n", "❯ 1. Yes\n  2. No\n", "Interrupted\n> \n"]
        XCTAssertTrue(IE.waitForMenuToLeaveScreen({ screens.count > 1 ? screens.removeFirst() : screens[0] }, timeout: 2))
        XCTAssertFalse(IE.waitForMenuToLeaveScreen({ "❯ 1. Yes\n  2. No\n" }, timeout: 0.3))
        XCTAssertFalse(IE.waitForMenuToLeaveScreen({ nil }, timeout: 0.3), "unreadable screen is not 'gone'")
    }

    // MARK: background owners

    func testBackgroundOwnerPids() {
        let sid = "11111111-2222-3333-4444-555555555555"
        let table = [
            ProcessRunner.ProcessInfoRow(pid: 10, ppid: 1, tty: "??", command: "/Users/me/.local/bin/claude"),
            ProcessRunner.ProcessInfoRow(pid: 11, ppid: 1, tty: "??", command: "python serve.py"),
        ]
        func rec(_ pid: Int32, _ kind: String?, _ s: String = sid) -> ClaudeSessionRecord {
            ClaudeSessionRecord(pid: pid, sessionId: s, cwd: nil, status: "idle", statusUpdatedAt: nil, kind: kind, entrypoint: nil)
        }
        XCTAssertEqual(ClaudeSessionRegistry.backgroundOwnerPids(records: [rec(10, "bg")], sessionId: sid, processTable: table,
                                                                 ownPid: 1, isAlive: { _ in false }), [10])
        XCTAssertEqual(ClaudeSessionRegistry.backgroundOwnerPids(records: [rec(10, "bg")], sessionId: sid.uppercased(), processTable: table,
                                                                 ownPid: 1, isAlive: { _ in false }), [10])
        // Interactive records are `liveSessions`' business; dead or non-claude pids don't count.
        XCTAssertEqual(ClaudeSessionRegistry.backgroundOwnerPids(records: [rec(10, "interactive"), rec(10, nil), rec(11, "bg"), rec(12, "bg")],
                                                                 sessionId: sid, processTable: table, ownPid: 1, isAlive: { _ in true }), [])
        XCTAssertEqual(ClaudeSessionRegistry.backgroundOwnerPids(records: [rec(10, "bg", "99999999-2222-3333-4444-555555555555")],
                                                                 sessionId: sid, processTable: table, ownPid: 1, isAlive: { _ in true }), [])
        // The interactive view still leaves the background job out.
        XCTAssertTrue(ClaudeSessionRegistry.buildLiveSessions(records: [rec(10, "bg")], processTable: table, ownPid: 1,
                                                             isAlive: { _ in true }).isEmpty)
    }

    func testHeadlessBlockedByBackgroundOwner() {
        let sid = "11111111-2222-3333-4444-555555555555"
        let table = [ProcessRunner.ProcessInfoRow(pid: 10, ppid: 1, tty: "??", command: "/Users/me/.local/bin/claude")]
        XCTAssertEqual(IE.headlessBlocker(sessionId: sid, processTable: table, transcript: nil, backgroundOwnerPids: [10]),
                       IE.backgroundJobMessage)
        XCTAssertNil(IE.headlessBlocker(sessionId: sid, processTable: table, transcript: nil, backgroundOwnerPids: []))
    }

    // MARK: cmux

    func testSurfaceTakenByAnotherSession() {
        let surface = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let me = "11111111-2222-3333-4444-555555555555"
        XCTAssertTrue(CmuxBridge.surfaceTaken(surface: surface.lowercased(), by: me,
                                              activeBySurface: [surface: "99999999-2222-3333-4444-555555555555"]))
        XCTAssertFalse(CmuxBridge.surfaceTaken(surface: surface, by: me, activeBySurface: [surface: me.uppercased()]))
        XCTAssertFalse(CmuxBridge.surfaceTaken(surface: surface, by: me, activeBySurface: [:]))
        XCTAssertFalse(CmuxBridge.surfaceTaken(surface: surface, by: nil, activeBySurface: [surface: me]))
    }

    private final class CountingSecrets: SecretStore {
        var reads = 0
        func read(allowUI: Bool) -> SecretReadResult { reads += 1; return .found("s3cret") }
        func write(_ secret: String) -> String? { nil }
        func delete() -> Bool { true }
    }

    func testPasswordNeverGoesToAnUnverifiedCLI() {
        let secrets = CountingSecrets()
        var calls: [[String: String]] = []
        let runner: CmuxBridge.Runner = { _, args, _, env, _ in
            calls.append(env)
            let out = args.first == "socket-status" ? #"{"effective_mode":"password"}"# : "PONG"
            return ProcessRunner.Result(status: 0, stdout: out, stderr: "", timedOut: false, launched: true)
        }
        let cli = "/tmp/evil-\(UUID().uuidString)/cmux.app/Contents/Resources/bin/cmux"
        let r = CmuxBridge.connect(cliPath: cli, runner: runner, secrets: secrets, verifyCLI: { _ in false })
        guard case .failure(let f) = r else { return XCTFail("an unverified CLI must not get the password") }
        XCTAssertEqual(f.detail, CmuxBridge.unverifiedCLIDetail)
        XCTAssertEqual(secrets.reads, 0, "the Keychain isn't even read")
        XCTAssertFalse(calls.contains { $0["CMUX_SOCKET_PASSWORD"] != nil })
    }

    func testCodeSignatureCheckRejectsUnsignedAndForeignCode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pagetest-sig-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("cmux").path
        try "#!/bin/sh\necho '{\"effective_mode\":\"password\"}'\n".write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
        XCTAssertFalse(CmuxBridge.isTrustedCLI(fake))
        // Apple-signed, but not cmux's developer.
        XCTAssertFalse(CmuxBridge.isTrustedCLI("/bin/ls"))
        XCTAssertFalse(CmuxBridge.isTrustedCLI("/nonexistent/cmux"))
        let real = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        if FileManager.default.isExecutableFile(atPath: real) {
            XCTAssertTrue(CmuxBridge.isTrustedCLI(real), "the installed, signed cmux CLI is trusted")
        }
    }
}

/// Delivery decisions that are made before any terminal is touched, plus
/// the strict post-Esc gate, against a throwaway sessions / projects dir.
final class InjectionSafetyDeliveryTests: XCTestCase {
    typealias IE = InjectionExecutor
    private var dir: URL!
    private var sessionsDir: URL!
    private var projectsDir: URL!
    private let sid = "11111111-2222-3333-4444-555555555555"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pagetest-inj-\(UUID().uuidString.prefix(8))")
        sessionsDir = dir.appendingPathComponent("sessions")
        projectsDir = dir.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectsDir.appendingPathComponent("-proj"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private var registry: ClaudeSessionRegistry {
        ClaudeSessionRegistry(projectsDirectory: projectsDir.path, sessionsDirectory: sessionsDir.path)
    }

    private func writeTranscript(_ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: projectsDir.appendingPathComponent("-proj/\(sid).jsonl"),
                                                        atomically: true, encoding: .utf8)
    }

    private func writeSession(pid: Int32, status: String, updatedAt: Date) throws {
        let obj: [String: Any] = ["pid": pid, "sessionId": sid, "status": status,
                                  "statusUpdatedAt": updatedAt.timeIntervalSince1970 * 1000, "kind": "interactive"]
        try JSONSerialization.data(withJSONObject: obj).write(to: sessionsDir.appendingPathComponent("\(pid).json"))
    }

    private func session(_ status: ClaudeSessionStatus, updatedAt: Date? = nil, hasFile: Bool = true) -> ClaudeLiveSession {
        ClaudeLiveSession(pid: 999_999, sessionId: sid, cwd: "/proj", status: status, statusUpdatedAt: updatedAt,
                          tty: "ttys999", hasSessionFile: hasFile)
    }

    private func request(action: String?, text: String = "", kind: ReplyPromptKind?, promptKey: String? = nil,
                         closed: Bool = false) -> IE.ClaudeReplyRequest {
        IE.ClaudeReplyRequest(interventionId: "x", sessionId: sid, action: action, text: text, kind: kind,
                              pagePid: nil, pageStateStart: nil, pagePromptKey: promptKey, hookCreatedAt: nil,
                              closedPage: closed)
    }

    private func deliver(_ req: IE.ClaudeReplyRequest, _ s: ClaudeLiveSession) -> InjectionResult {
        IE.deliverToLiveSession(req, session: s, processTable: [], registry: registry)
    }

    // contract F6: free text to an already-closed prompt page.
    func testClosedPageTextNeverAnswersAPrompt() {
        for status in [ClaudeSessionStatus.waiting, .unknown] {
            let r = deliver(request(action: "custom", text: "use pnpm", kind: .approval, closed: true),
                            session(status, updatedAt: Date()))
            XCTAssertFalse(r.success)
            XCTAssertEqual(r.method, .none)
            XCTAssertEqual(r.detail, IE.closedPageMessage, "\(status)")
        }
        let r = deliver(request(action: "approve", kind: .approval, closed: true), session(.busy))
        XCTAssertEqual(r.detail, IE.promptGoneMessage)
    }

    // F4 / SEC-6: no status → only the page's own, provably pending prompt.
    func testUnknownStatusPromptActionsNeedTheMatchingPendingTool() throws {
        try writeTranscript([TranscriptFixture.user("go"), TranscriptFixture.toolUse("toolu_B", "Bash", ["command": "rm -rf x"])])
        for action in ["approve", "deny", "custom"] {
            // Late reply (page already resolved → no key) and a stale key are both refused.
            XCTAssertEqual(deliver(request(action: action, text: "no", kind: .approval), session(.unknown, hasFile: false)).detail,
                           IE.unverifiedPromptMessage, action)
            XCTAssertEqual(deliver(request(action: action, text: "no", kind: .approval, promptKey: "toolu_A"),
                                   session(.unknown, hasFile: false)).detail, IE.unverifiedPromptMessage, action)
        }
        // Questions can't be verified on screen at all.
        XCTAssertFalse(deliver(request(action: "deny", kind: .question, promptKey: "toolu_B"), session(.unknown, hasFile: false)).success)
    }

    func testUnknownStatusRefusesWhenSeveralPromptsQueued() throws {
        try writeTranscript([TranscriptFixture.user("go"),
                             TranscriptFixture.toolUse("toolu_B", "Bash", ["command": "a"]),
                             TranscriptFixture.toolUse("toolu_C", "Bash", ["command": "b"])])
        let r = deliver(request(action: "approve", kind: .approval, promptKey: "toolu_B"), session(.unknown, hasFile: false))
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.detail.contains("Several prompts"), r.detail)
    }

    // F7: the gate before typing text after Esc.
    func testDismissGateRejectsANewMenu() throws {
        let pid = ProcessInfo.processInfo.processIdentifier   // alive
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        try writeSession(pid: pid, status: "waiting", updatedAt: opened.addingTimeInterval(3))
        let start = Date()
        XCTAssertFalse(IE.waitForPromptDismissed(pid: pid, openSince: opened, registry: registry, timeout: 2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "a new menu fails at once, without waiting out the timeout")
        // The loose confirmation still counts it as "the answer landed".
        XCTAssertTrue(IE.waitForPromptToClose(pid: pid, openSince: opened, registry: registry, timeout: 0.5))
    }

    func testDismissGateWaitsWhileStillWaitingAndPassesOnIdle() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        try writeSession(pid: pid, status: "waiting", updatedAt: opened)
        XCTAssertFalse(IE.waitForPromptDismissed(pid: pid, openSince: opened, registry: registry, timeout: 0.3))
        try writeSession(pid: pid, status: "idle", updatedAt: opened.addingTimeInterval(1))
        XCTAssertTrue(IE.waitForPromptDismissed(pid: pid, openSince: opened, registry: registry, timeout: 0.5))
    }

    func testDismissGateRequiresThePromptsToolCallAnswered() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        try writeSession(pid: pid, status: "idle", updatedAt: opened.addingTimeInterval(1))
        let transcript = projectsDir.appendingPathComponent("-proj/\(sid).jsonl")
        try writeTranscript([TranscriptFixture.user("go"), TranscriptFixture.toolUse("toolu_A", "Bash", ["command": "x"])])
        XCTAssertFalse(IE.waitForPromptDismissed(pid: pid, openSince: opened, registry: registry,
                                                 transcript: transcript, promptKey: "toolu_A", timeout: 0.3))
        try writeTranscript([TranscriptFixture.user("go"), TranscriptFixture.toolUse("toolu_A", "Bash", ["command": "x"]),
                             TranscriptFixture.toolResult("toolu_A")])
        XCTAssertTrue(IE.waitForPromptDismissed(pid: pid, openSince: opened, registry: registry,
                                                transcript: transcript, promptKey: "toolu_A", timeout: 0.5))
    }

    func testDismissGateFailsForAnExitedProcess() {
        XCTAssertFalse(IE.waitForPromptDismissed(pid: 999_999, openSince: nil, registry: registry, timeout: 0.3))
    }
}

/// Real tmux, on a private server (`-L pagetest-safety-*`) whose panes run
/// `cat -v` or `sleep`; never the user's tmux. Skipped without tmux.
final class InjectionSafetyTmuxTests: XCTestCase {
    private var socket = ""
    private var dir: URL!
    private var wrapper = ""

    override func setUpWithError() throws {
        guard let tmux = ProcessRunner.findExecutable("tmux") else { throw XCTSkip("tmux not installed") }
        socket = "pagetest-safety-\(UUID().uuidString.prefix(8))"
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(socket)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        wrapper = dir.appendingPathComponent("tmux").path
        try "#!/bin/bash\nexec \(ProcessRunner.shellQuote(tmux)) -L \(socket) \"$@\"\n".write(toFile: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
    }

    override func tearDown() {
        if !wrapper.isEmpty {
            let socketPath = ProcessRunner.run(wrapper, ["display-message", "-p", "#{socket_path}"], timeout: 3).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ProcessRunner.run(wrapper, ["kill-server"], timeout: 5)
            if socketPath.contains("pagetest-safety-") { try? FileManager.default.removeItem(atPath: socketPath) }
        }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func start(_ command: String) throws -> (pane: String, pid: Int32) {
        let r = ProcessRunner.run(wrapper, ["-f", "/dev/null", "new-session", "-d", "-s", "t", "-x", "200", "-y", "20", command], timeout: 5)
        guard r.succeeded else { throw XCTSkip("couldn't start private tmux server: \(r.stderr)") }
        usleep(400_000)
        let out = ProcessRunner.run(wrapper, ["list-panes", "-F", "#{pane_id}\t#{pane_pid}"], timeout: 3).stdout
        let cols = try XCTUnwrap(out.split(separator: "\n").first).split(separator: "\t").map(String.init)
        return (cols[0], try XCTUnwrap(Int32(cols[1])))
    }

    /// Waits (up to 5 s) for the pane to show `text`: a fixed sleep loses
    /// the race when the machine is busy.
    private func waitForPane(_ pane: String, toShow text: String) {
        for _ in 0..<50 {
            if ProcessRunner.run(wrapper, ["capture-pane", "-p", "-t", pane], timeout: 3).stdout.contains(text) { return }
            usleep(100_000)
        }
        XCTFail("pane never showed \(text)")
    }

    private func screen(_ pane: String) -> String {
        usleep(300_000)
        return ProcessRunner.run(wrapper, ["capture-pane", "-p", "-t", pane], timeout: 3).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // F10
    func testTrailingSemicolonsAndBackslashesAreTypedExactly() throws {
        let p = try start("sh -c 'stty raw -echo; exec cat -v'")
        for text in ["use a semicolon after return;", "a\\;", ";", "x;;"] {
            let r = InjectionExecutor.sendViaTmux([.text(text)], tmuxPath: wrapper, paneId: p.pane, inMode: false, awaitClosed: { true })
            XCTAssertTrue(r.success, r.output)
            _ = InjectionExecutor.sendViaTmux([.text("|")], tmuxPath: wrapper, paneId: p.pane, inMode: false, awaitClosed: { true })
        }
        XCTAssertEqual(screen(p.pane), "use a semicolon after return;|a\\;|;|x;;|")
    }

    // F3: the status re-check before Enter stops a reply when a menu opened.
    func testPrecheckStopsBeforeEnter() throws {
        let p = try start("sh -c 'stty raw -echo; exec cat -v'")
        var seen: [Keystroke] = []
        let r = InjectionExecutor.sendViaTmux([.text("queued"), .enter], tmuxPath: wrapper, paneId: p.pane, inMode: false,
                                              awaitClosed: { true },
                                              precheck: { step in seen.append(step); return step == .enter ? InjectionExecutor.newPageMessage : nil })
        XCTAssertFalse(r.success)
        XCTAssertEqual(seen, [.text("queued"), .enter])
        XCTAssertTrue(r.detail.hasPrefix(InjectionExecutor.newPageMessage), r.detail)
        XCTAssertTrue(r.detail.contains("part of the reply was typed"))
        XCTAssertEqual(screen(p.pane), "queued", "no Enter reached the pane")
    }

    func testPrecheckRefusalBeforeFirstKeySendsNothing() throws {
        let p = try start("sh -c 'stty raw -echo; exec cat -v'")
        let r = InjectionExecutor.sendViaTmux([.escape, .awaitPromptClosed, .text("x"), .enter], tmuxPath: wrapper, paneId: p.pane,
                                              inMode: false, awaitClosed: { true },
                                              precheck: { _ in InjectionExecutor.notForegroundMessage })
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.detail, InjectionExecutor.notForegroundMessage)
        XCTAssertEqual(screen(p.pane), "")
    }

    // F2 / SEC-2: job control on a real terminal.
    func testForegroundStoppedAndBackgroundJobs() throws {
        let p = try start("exec sleep 60")
        XCTAssertEqual(ProcessRunner.foregroundState(pid: p.pid), .foreground)
        XCTAssertEqual(ProcessRunner.isForeground(pid: p.pid), true)
        kill(p.pid, SIGSTOP)
        defer { kill(p.pid, SIGCONT) }
        var state = ProcessRunner.ForegroundState.unknown
        for _ in 0..<20 {
            state = ProcessRunner.foregroundState(pid: p.pid)
            if state == .stopped { break }
            usleep(50_000)
        }
        XCTAssertEqual(state, .stopped, "^Z'd: keys would go to the shell")
    }

    func testBackgroundJobIsNotForeground() throws {
        let pidFile = dir.appendingPathComponent("bg.pid").path
        _ = try start("bash -c 'set -m; sleep 60 & echo $! > \(pidFile); wait'")
        usleep(200_000)
        let text = try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let bg = try XCTUnwrap(Int32(text))
        XCTAssertEqual(ProcessRunner.foregroundState(pid: bg), .background)
        XCTAssertEqual(ProcessRunner.isForeground(pid: bg), false)
    }

    // F5: the draft check reads the real tmux pane (colours included).
    func testDraftRefusalReadsThePane() throws {
        let rule = String(repeating: "─", count: 40)
        let script = dir.appendingPathComponent("screen.sh").path
        try "#!/bin/sh\nprintf '%s\\n' '\(rule)' '> half typed' '\(rule)'\nexec sleep 60\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let p = try start(script)
        waitForPane(p.pane, toShow: "half typed")
        let host = InjectionExecutor.TerminalHost.tmux(tmuxPath: wrapper, paneId: p.pane, inMode: false)
        XCTAssertEqual(InjectionExecutor.draftRefusal(host: host, requireEmpty: false), CmuxBridge.draftDetail)
    }

    func testEmptyBoxWithDimSuggestionIsNotADraft() throws {
        let rule = String(repeating: "─", count: 40)
        let script = dir.appendingPathComponent("screen.sh").path
        try "#!/bin/sh\nprintf '%s\\n' '\(rule)'\nprintf '> \\033[2mTry something\\033[0m\\n'\nprintf '%s\\n' '\(rule)'\nexec sleep 60\n"
            .write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        let p = try start(script)
        waitForPane(p.pane, toShow: "Try something")
        let host = InjectionExecutor.TerminalHost.tmux(tmuxPath: wrapper, paneId: p.pane, inMode: false)
        XCTAssertNil(InjectionExecutor.draftRefusal(host: host, requireEmpty: true))
    }

    func testUnrecognisedScreenOnlyBlocksWhenEmptinessMustBeProven() throws {
        let p = try start("sh -c 'echo some output; exec sleep 60'")
        waitForPane(p.pane, toShow: "some output")
        let host = InjectionExecutor.TerminalHost.tmux(tmuxPath: wrapper, paneId: p.pane, inMode: false)
        XCTAssertNil(InjectionExecutor.draftRefusal(host: host, requireEmpty: false))
        XCTAssertEqual(InjectionExecutor.draftRefusal(host: host, requireEmpty: true), InjectionExecutor.inputUnverifiedMessage)
    }
}

final class StyledCellsBackgroundColourTests: XCTestCase {
    func testBackgroundTrueColourDoesNotReadAsDim() {
        // tmux reports a coloured input box as 48;2;r;g;b — the "2" must not set dim.
        let cells = InjectionExecutor.styledCells("\u{1B}[48;2;40;40;40mhello")
        XCTAssertEqual(String(cells.map(\.0)), "hello")
        XCTAssertTrue(cells.allSatisfy { !$0.1 }, "a draft on a coloured background is real text, not placeholder")
    }

    func testBackground256ColourDoesNotReadAsDim() {
        let cells = InjectionExecutor.styledCells("\u{1B}[48;5;2mdraft")
        XCTAssertTrue(cells.allSatisfy { !$0.1 })
    }

    func testForegroundGreyStillReadsAsPlaceholder() {
        let cells = InjectionExecutor.styledCells("\u{1B}[38;5;244mTry \"refactor\"")
        XCTAssertTrue(cells.allSatisfy { $0.1 })
    }
}

final class BangWithCombiningMarkTests: XCTestCase {
    /// "!" followed by a combining mark is a single grapheme cluster, but the
    /// terminal still receives "!" first — bash mode must still be defused.
    func testCombiningMarkAfterBangIsStillDefused() {
        for raw in ["!\u{0301};curl x|sh", "!\u{FE0F}ls", "!\u{200D}rm -rf build"] {
            let s = InjectionExecutor.sanitize(raw)
            XCTAssertNotEqual(s.unicodeScalars.first, "!", "sanitize: \(raw.debugDescription)")
            let flat = InjectionExecutor.flattenLines(s)
            XCTAssertNotEqual(flat.unicodeScalars.first, "!", "flattenLines: \(raw.debugDescription)")
        }
    }
}
