import XCTest
@testable import ClaudePowerMode

/// Herdr support: request and reply framing, finding and re-checking the
/// session's pane, the socket trust rules, and the wiring into injection,
/// the screen mirror and the phone's host names. Pure functions, and a fake
/// NDJSON server on a short socket in /tmp. No real Herdr is ever contacted.
final class HerdrBridgeTests: XCTestCase {

    // MARK: request framing

    func testPingRequestIsOneSortedLine() {
        XCTAssertEqual(HerdrBridge.request(id: "1", method: "ping", params: [:]),
                       "{\"id\":\"1\",\"method\":\"ping\",\"params\":{}}\n")
    }

    func testRequestEscapesTextSoItStaysOneLine() {
        let text = "a\nb \"q\" x/y"
        let line = HerdrBridge.request(id: "2", method: "pane.send_input", params: ["pane_id": "w1:p2", "text": text])
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "one newline, the framing one")
        XCTAssertTrue(line.hasSuffix("\n"), "the framing newline ends the line")
        XCTAssertTrue(line.contains("x/y"), "slashes are not escaped")
        let params = json(line)["params"] as? [String: Any]
        XCTAssertEqual(params?["text"] as? String, text, "the text survives the round trip")
    }

    func testSendRequestPicksTheMethodPerKey() throws {
        let typed = json(HerdrBridge.sendRequest(id: "7", paneId: "w1:p2", key: .text("1")))
        XCTAssertEqual(typed["id"] as? String, "7")
        XCTAssertEqual(typed["method"] as? String, "pane.send_text", "one line of text is typed, not pasted")
        XCTAssertEqual((typed["params"] as? [String: Any])?["pane_id"] as? String, "w1:p2")
        XCTAssertEqual((typed["params"] as? [String: Any])?["text"] as? String, "1")

        let multi = json(HerdrBridge.sendRequest(id: "7", paneId: "w1:p2", key: .text("a\nb")))
        XCTAssertEqual(multi["method"] as? String, "pane.send_input", "multi-line text goes through send_input")
        XCTAssertEqual((multi["params"] as? [String: Any])?["text"] as? String, "a\nb")
        XCTAssertNil((multi["params"] as? [String: Any])?["keys"], "no keys with multi-line text")

        let enter = json(HerdrBridge.sendRequest(id: "7", paneId: "w1:p2", key: .enter))
        XCTAssertEqual(enter["method"] as? String, "pane.send_keys")
        XCTAssertEqual((enter["params"] as? [String: Any])?["keys"] as? [String], ["enter"])

        let escape = json(HerdrBridge.sendRequest(id: "7", paneId: "w1:p2", key: .escape))
        XCTAssertEqual((escape["params"] as? [String: Any])?["keys"] as? [String], ["esc"])
    }

    func testSendRequestPassesDashesAndSemicolonsVerbatim() {
        for text in ["-rm -rf ~", "1;"] {
            let params = json(HerdrBridge.sendRequest(id: "7", paneId: "w1:p2", key: .text(text)))["params"] as? [String: Any]
            XCTAssertEqual(params?["text"] as? String, text, "text is never read as a flag or a command")
        }
    }

    func testPauseAndPromptWaitSendNothing() {
        XCTAssertNil(HerdrBridge.sendRequest(id: "7", paneId: "w1:p2", key: .pause(1)))
        XCTAssertNil(HerdrBridge.sendRequest(id: "7", paneId: "w1:p2", key: .awaitPromptClosed))
    }

    func testReadRequestStyledAndPlain() {
        let styled = json(HerdrBridge.readRequest(id: "3", paneId: "w1:p2", styled: true))
        XCTAssertEqual(styled["method"] as? String, "pane.read")
        let styledParams = styled["params"] as? [String: Any]
        XCTAssertEqual(styledParams?["pane_id"] as? String, "w1:p2")
        XCTAssertEqual(styledParams?["source"] as? String, "visible")
        XCTAssertEqual(styledParams?["format"] as? String, "ansi")
        XCTAssertEqual(styledParams?["strip_ansi"] as? Bool, false, "colours are kept, so escapes are not stripped")

        let plain = json(HerdrBridge.readRequest(id: "3", paneId: "w1:p2", styled: false))
        let plainParams = plain["params"] as? [String: Any]
        XCTAssertEqual(plainParams?["format"] as? String, "text")
        XCTAssertEqual(plainParams?["strip_ansi"] as? Bool, true)
    }

    // MARK: reply framing

    private let pingOk = #"{"id":"1","result":{"type":"ok"}}"#

    func testMatchingReplyReturnsItsResultAndIgnoresUnknownFields() {
        let line = #"{"id":"1","result":{"type":"ok","extra":true},"unknown":{"x":1}}"#
        guard case .success(let result) = HerdrBridge.result(from: line, id: "1", type: "ok") else {
            XCTFail("a matching reply should succeed")
            return
        }
        XCTAssertEqual(result["type"] as? String, "ok")
        XCTAssertEqual(result["extra"] as? Bool, true)
    }

    func testBadRepliesAreClassified() {
        XCTAssertEqual(failureKind(HerdrBridge.result(from: "not json", id: "1", type: "ok")), "malformed", "not JSON")
        XCTAssertEqual(failureKind(HerdrBridge.result(from: "[1,2]", id: "1", type: "ok")), "malformed", "JSON, but not an object")
        XCTAssertEqual(failureKind(HerdrBridge.result(from: #"{"id":"1"}"#, id: "1", type: "ok")), "malformed", "success without a result")
        XCTAssertEqual(failureKind(HerdrBridge.result(from: #"{"id":"1","result":{}}"#, id: "1", type: "ok")), "malformed", "result without a type")
        XCTAssertEqual(failureKind(HerdrBridge.result(from: #"{"result":{"type":"ok"}}"#, id: "1", type: "ok")), "malformed", "reply without an id")
    }

    func testReplyToAnotherRequestIsAnIdMismatch() {
        XCTAssertEqual(failureKind(HerdrBridge.result(from: #"{"id":"2","result":{"type":"ok"}}"#, id: "1", type: "ok")), "idMismatch")
    }

    func testOtherReplyTypeIsWrongType() {
        XCTAssertEqual(failureKind(HerdrBridge.result(from: #"{"id":"1","result":{"type":"pane_info"}}"#, id: "1", type: "ok")),
                       "wrongType(pane_info)")
    }

    func testErrorReplyCarriesHerdrsCodeAndMessage() {
        let line = #"{"id":"1","error":{"code":"pane_not_found","message":"no such pane"}}"#
        guard case .failure(let e) = HerdrBridge.result(from: line, id: "1", type: "ok") else {
            XCTFail("an error reply should fail")
            return
        }
        XCTAssertEqual(e, .server(code: "pane_not_found", message: "no such pane"))
    }

    func testErrorReplyWithEmptyIdIsStillAServerError() {
        // Herdr can't echo an id for a request that wasn't valid JSON.
        let line = #"{"id":"","error":{"code":"invalid_request","message":"bad json"}}"#
        XCTAssertEqual(failureKind(HerdrBridge.result(from: line, id: "1", type: "ok")), "server(invalid_request)")
    }

    func testErrorReplyWithAnotherIdIsAnIdMismatch() {
        let line = #"{"id":"9","error":{"code":"pane_not_found","message":"x"}}"#
        XCTAssertEqual(failureKind(HerdrBridge.result(from: line, id: "1", type: "ok")), "idMismatch")
    }

    func testParsePaneInfoReadsThePaneFields() {
        let line = #"{"id":"1","result":{"type":"pane_info","pane":{"pane_id":"w1:p2","terminal_id":"term_abc","workspace_id":"w1","tab_id":"w1:t1"}}}"#
        guard case .success(let pane) = HerdrBridge.parsePaneInfo(line, id: "1") else {
            XCTFail("a pane_info reply should parse")
            return
        }
        XCTAssertEqual(pane, HerdrBridge.PaneInfo(paneId: "w1:p2", terminalId: "term_abc", workspaceId: "w1"))
    }

    func testParsePaneInfoNeedsPaneAndTerminalIds() {
        let noTerminal = #"{"id":"1","result":{"type":"pane_info","pane":{"pane_id":"w1:p2"}}}"#
        XCTAssertEqual(failureKind(HerdrBridge.parsePaneInfo(noTerminal, id: "1")), "malformed")
        let emptyTerminal = #"{"id":"1","result":{"type":"pane_info","pane":{"pane_id":"w1:p2","terminal_id":""}}}"#
        XCTAssertEqual(failureKind(HerdrBridge.parsePaneInfo(emptyTerminal, id: "1")), "malformed")
        let emptyPane = #"{"id":"1","result":{"type":"pane_info","pane":{"pane_id":"","terminal_id":"term_abc"}}}"#
        XCTAssertEqual(failureKind(HerdrBridge.parsePaneInfo(emptyPane, id: "1")), "malformed")
        let wrongType = #"{"id":"1","result":{"type":"ok"}}"#
        XCTAssertEqual(failureKind(HerdrBridge.parsePaneInfo(wrongType, id: "1")), "wrongType(ok)")
    }

    func testParsePaneInfoWithoutWorkspaceIsNil() {
        let line = #"{"id":"1","result":{"type":"pane_info","pane":{"pane_id":"w1:p2","terminal_id":"term_abc"}}}"#
        guard case .success(let pane) = HerdrBridge.parsePaneInfo(line, id: "1") else {
            XCTFail("a pane without a workspace still parses")
            return
        }
        XCTAssertNil(pane.workspaceId)
    }

    func testParseProcessInfoReadsTheForegroundPids() {
        let line = #"{"id":"1","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":100,"foreground_processes":[{"pid":4242,"name":"claude"}]}}}"#
        guard case .success(let info) = HerdrBridge.parseProcessInfo(line, id: "1") else {
            XCTFail("a process_info reply should parse")
            return
        }
        XCTAssertEqual(info, HerdrBridge.ProcessInfo(paneId: "w1:p2", shellPid: 100, foregroundPids: [4242]))
    }

    func testParseProcessInfoToleratesMissingAndOddFields() {
        let noForeground = #"{"id":"1","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":100}}}"#
        guard case .success(let bare) = HerdrBridge.parseProcessInfo(noForeground, id: "1") else {
            XCTFail("no foreground_processes still parses")
            return
        }
        XCTAssertEqual(bare.foregroundPids, [])

        let nullShell = #"{"id":"1","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":null,"foreground_processes":[]}}}"#
        guard case .success(let noShell) = HerdrBridge.parseProcessInfo(nullShell, id: "1") else {
            XCTFail("a null shell_pid still parses")
            return
        }
        XCTAssertNil(noShell.shellPid)

        let mixed = #"{"id":"1","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":100,"foreground_processes":[{"name":"vim"},{"pid":"x"},{"pid":7}]}}}"#
        guard case .success(let kept) = HerdrBridge.parseProcessInfo(mixed, id: "1") else {
            XCTFail("entries without a numeric pid are dropped, not fatal")
            return
        }
        XCTAssertEqual(kept.foregroundPids, [7])
    }

    func testParseProcessInfoNeedsProcessInfo() {
        let missing = #"{"id":"1","result":{"type":"pane_process_info"}}"#
        XCTAssertEqual(failureKind(HerdrBridge.parseProcessInfo(missing, id: "1")), "malformed")
    }

    func testParseReadNormalisesLineEndings() {
        let line = #"{"id":"1","result":{"type":"pane_read","read":{"text":"a\r\nb\r\n"}}}"#
        guard case .success(let text) = HerdrBridge.parseRead(line, id: "1") else {
            XCTFail("a pane_read reply should parse")
            return
        }
        XCTAssertEqual(text, "a\nb\n", "CRLF becomes LF for the input-box reader")
    }

    func testParseReadNeedsTextAndTheRightType() {
        XCTAssertEqual(failureKind(HerdrBridge.parseRead(#"{"id":"1","result":{"type":"pane_read"}}"#, id: "1")), "malformed")
        XCTAssertEqual(failureKind(HerdrBridge.parseRead(#"{"id":"1","result":{"type":"pane_read","read":{}}}"#, id: "1")), "malformed")
        XCTAssertEqual(failureKind(HerdrBridge.parseRead(#"{"id":"1","result":{"type":"ok"}}"#, id: "1")), "wrongType(ok)")
    }

    func testParseAckAcceptsOkAndNamesErrors() {
        guard case .success = HerdrBridge.parseAck(pingOk, id: "1") else {
            XCTFail("an ok reply is a successful send")
            return
        }
        let notFound = #"{"id":"1","error":{"code":"pane_not_found","message":"gone"}}"#
        guard case .failure(let e) = HerdrBridge.parseAck(notFound, id: "1") else {
            XCTFail("pane_not_found must not count as sent")
            return
        }
        XCTAssertEqual(e, .server(code: "pane_not_found", message: "gone"))
        XCTAssertEqual(failureKind(HerdrBridge.parseAck(pingOk, id: "2")), "idMismatch")
    }

    func testFirstLineStopsAtTheNewline() {
        XCTAssertNil(HerdrBridge.firstLine(in: Data("abc".utf8)), "no newline yet")
        XCTAssertEqual(HerdrBridge.firstLine(in: Data("abc\ndef".utf8)), "abc")
        XCTAssertEqual(HerdrBridge.firstLine(in: Data("\n".utf8)), "")
        XCTAssertNil(HerdrBridge.firstLine(in: Data()), "empty buffer")
        XCTAssertEqual(HerdrBridge.firstLine(in: Data("héllo\nx".utf8)), "héllo", "multi-byte text before the newline is kept")
    }

    // MARK: finding the pane

    func testPlanTargetsTheNamedPaneAndSocket() {
        let env = ["HERDR_ENV": "1", "HERDR_SOCKET_PATH": "/Users/x/.config/herdr/herdr.sock",
                   "HERDR_PANE_ID": "w1:p2", "HERDR_WORKSPACE_ID": "w1"]
        XCTAssertEqual(HerdrBridge.plan(env: env, ancestorCommands: []),
                       .target(socketPath: "/Users/x/.config/herdr/herdr.sock", paneId: "w1:p2", workspaceId: "w1"))
        var noWorkspace = env
        noWorkspace["HERDR_WORKSPACE_ID"] = ""
        XCTAssertEqual(HerdrBridge.plan(env: noWorkspace, ancestorCommands: []),
                       .target(socketPath: "/Users/x/.config/herdr/herdr.sock", paneId: "w1:p2", workspaceId: nil),
                       "an empty workspace id is no workspace")
    }

    func testPlanIsNotHerdrWithoutAnySign() {
        XCTAssertEqual(HerdrBridge.plan(env: [:], ancestorCommands: []), .notHerdr)
        XCTAssertEqual(HerdrBridge.plan(env: ["TERM": "xterm"], ancestorCommands: ["-zsh"]), .notHerdr)
    }

    func testPlanRefusesWithoutSocketOrPane() {
        let socketOnly = ["HERDR_ENV": "1", "HERDR_SOCKET_PATH": "/Users/x/herdr.sock"]
        XCTAssertEqual(HerdrBridge.plan(env: socketOnly, ancestorCommands: []), .refuse(HerdrBridge.missingPaneReason))
        let paneOnly = ["HERDR_ENV": "1", "HERDR_PANE_ID": "w1:p2"]
        XCTAssertEqual(HerdrBridge.plan(env: paneOnly, ancestorCommands: []), .refuse(HerdrBridge.missingPaneReason))
    }

    func testHerdrByAncestorOnlyNeverFallsBackToTheDefaultSocket() {
        // The environment was scrubbed on the way: no pane, no socket.
        let plan = HerdrBridge.plan(env: [:], ancestorCommands: ["/opt/homebrew/bin/herdr server", "/sbin/launchd"])
        XCTAssertEqual(plan, .refuse(HerdrBridge.missingPaneReason))
        if case .target = plan { XCTFail("the default socket must never be guessed") }
    }

    func testOddSocketOrPaneRefuses() {
        let relative = ["HERDR_ENV": "1", "HERDR_SOCKET_PATH": "herdr.sock", "HERDR_PANE_ID": "w1:p2"]
        XCTAssertEqual(refusal(HerdrBridge.plan(env: relative, ancestorCommands: []))?.contains("Herdr"), true, "relative socket")

        let long = "/" + String(repeating: "a", count: 103)
        let tooLong = ["HERDR_ENV": "1", "HERDR_SOCKET_PATH": long, "HERDR_PANE_ID": "w1:p2"]
        XCTAssertNotNil(refusal(HerdrBridge.plan(env: tooLong, ancestorCommands: [])), "path over 103 bytes")

        for pane in ["w1 p2", "..;rm", ""] {
            let env = ["HERDR_ENV": "1", "HERDR_SOCKET_PATH": "/Users/x/herdr.sock", "HERDR_PANE_ID": pane]
            XCTAssertEqual(HerdrBridge.plan(env: env, ancestorCommands: []), .refuse(HerdrBridge.missingPaneReason),
                           "pane id \(pane.debugDescription) refuses")
        }
    }

    func testEveryRefusalSaysHerdr() {
        let cases: [[String: String]] = [
            ["HERDR_ENV": "1"],
            ["HERDR_ENV": "1", "HERDR_SOCKET_PATH": "herdr.sock", "HERDR_PANE_ID": "w1:p2"],
            ["HERDR_ENV": "1", "HERDR_SOCKET_PATH": "/Users/x/herdr.sock", "HERDR_PANE_ID": "bad pane"],
        ]
        for env in cases {
            let why = refusal(HerdrBridge.plan(env: env, ancestorCommands: []))
            XCTAssertNotNil(why, "refused: \(env)")
            XCTAssertTrue(why?.contains("Herdr") ?? false, "the phone reads this, so it names Herdr: \(why ?? "nil")")
        }
    }

    func testIsHerdrBySignAndByAncestor() {
        XCTAssertTrue(HerdrBridge.isHerdr(env: ["HERDR_ENV": "1"], ancestorCommands: []))
        XCTAssertTrue(HerdrBridge.isHerdr(env: [:], ancestorCommands: ["/opt/homebrew/bin/herdr server"]))
        XCTAssertTrue(HerdrBridge.isHerdr(env: [:], ancestorCommands: ["herdr"]))
        XCTAssertFalse(HerdrBridge.isHerdr(env: [:], ancestorCommands: ["-zsh", "/Applications/WezTerm.app/Contents/MacOS/wezterm-gui"]))
    }

    func testIsHerdrNeedsTheExactExecutableName() {
        XCTAssertFalse(HerdrBridge.isHerdr(env: [:], ancestorCommands: ["/usr/bin/herdr-helper"]))
        XCTAssertFalse(HerdrBridge.isHerdr(env: [:], ancestorCommands: ["herdrish"]))
    }

    func testValidPaneIds() {
        for ok in ["w1:p2", "w12:p3", "w1_p-2.x", String(repeating: "a", count: 64)] {
            XCTAssertTrue(HerdrBridge.isValidPaneId(ok), "\(ok) is a pane id")
        }
        for bad in ["", "w1 p2", "w1:p2\n", "p;rm", "pané", String(repeating: "a", count: 65)] {
            XCTAssertFalse(HerdrBridge.isValidPaneId(bad), "\(bad.debugDescription) is not a pane id")
        }
    }

    func testUsableSocketPaths() {
        let exact = "/" + String(repeating: "a", count: 102)
        XCTAssertEqual(exact.utf8.count, 103)
        XCTAssertTrue(HerdrBridge.isUsableSocketPath(exact), "103 bytes fits sun_path with its terminator")
        XCTAssertFalse(HerdrBridge.isUsableSocketPath(exact + "a"), "104 bytes does not")
        XCTAssertFalse(HerdrBridge.isUsableSocketPath("relative.sock"))
        XCTAssertFalse(HerdrBridge.isUsableSocketPath(""))
        XCTAssertFalse(HerdrBridge.isUsableSocketPath("/tmp/a\u{0}b"), "an embedded NUL ends the path early")
    }

    func testSocketTrustNeedsOwnerAndNoOtherWriters() {
        let me = getuid()
        let sock = mode_t(S_IFSOCK)
        XCTAssertTrue(HerdrBridge.isTrustedSocket(mode: sock | 0o600, ownerUid: me, currentUid: me))
        XCTAssertTrue(HerdrBridge.isTrustedSocket(mode: sock | 0o644, ownerUid: me, currentUid: me), "readable by others, not writable")
        XCTAssertFalse(HerdrBridge.isTrustedSocket(mode: sock | 0o660, ownerUid: me, currentUid: me), "group writable")
        XCTAssertFalse(HerdrBridge.isTrustedSocket(mode: sock | 0o602, ownerUid: me, currentUid: me), "other writable")
        XCTAssertFalse(HerdrBridge.isTrustedSocket(mode: sock | 0o600, ownerUid: me + 1, currentUid: me), "owned by another user")
        XCTAssertFalse(HerdrBridge.isTrustedSocket(mode: mode_t(S_IFREG) | 0o600, ownerUid: me, currentUid: me), "a regular file")
        XCTAssertFalse(HerdrBridge.isTrustedSocket(mode: mode_t(S_IFLNK) | 0o600, ownerUid: me, currentUid: me), "a symlink")
        XCTAssertFalse(HerdrBridge.isTrustedSocket(mode: mode_t(S_IFDIR) | 0o600, ownerUid: me, currentUid: me), "a directory")
    }

    func testSocketTrustFailureForMissingFileAndSymlink() throws {
        XCTAssertNotNil(HerdrBridge.socketTrustFailure(path: "/tmp/hd-missing-\(UUID().uuidString.prefix(8)).sock"))
        XCTAssertTrue(HerdrBridge.socketTrustFailure(path: "/tmp/hd-missing-\(UUID().uuidString.prefix(8)).sock")?.contains("Herdr") ?? false,
                      "the phone reads this, so it names Herdr")

        let dir = try makeTempDir()
        let file = dir + "/plain.sock"
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: Data()))
        XCTAssertNotNil(HerdrBridge.socketTrustFailure(path: file), "a regular file is not a socket")

        let server = try makeServer(path: dir + "/real.sock")
        let link = dir + "/link.sock"
        XCTAssertEqual(symlink(server.path, link), 0)
        XCTAssertNotNil(HerdrBridge.socketTrustFailure(path: link), "a symlink to a real socket is refused, not followed")
    }

    func testSocketTrustFailureAcceptsOwnerOnlySocket() throws {
        let dir = try makeTempDir()
        let server = try makeServer(path: dir + "/owner.sock")
        XCTAssertNil(HerdrBridge.socketTrustFailure(path: server.path), "a 0600 socket owned by us is fine")
        XCTAssertEqual(chmod(server.path, 0o666), 0)
        XCTAssertNotNil(HerdrBridge.socketTrustFailure(path: server.path), "a socket anyone can write to is refused")
    }

    // MARK: verifying the pane

    private func verify(pane: HerdrBridge.PaneInfo = HerdrBridge.PaneInfo(paneId: "w1:p2", terminalId: "term_abc", workspaceId: "w1"),
                        processes: HerdrBridge.ProcessInfo = HerdrBridge.ProcessInfo(paneId: "w1:p2", shellPid: 100, foregroundPids: [4242]),
                        paneId: String = "w1:p2", workspaceId: String? = "w1",
                        expectTerminalId: String? = "term_abc", pid: Int32 = 4242) -> String? {
        HerdrBridge.verification(pane: pane, processes: processes, paneId: paneId, workspaceId: workspaceId,
                                 expectTerminalId: expectTerminalId, pid: pid)
    }

    func testVerificationPassesWhenEverythingMatches() {
        XCTAssertNil(verify(), "the session is the foreground job of the named pane")
    }

    func testSessionMustBeAForegroundProcessNotJustAnAncestor() {
        let shellOnly = HerdrBridge.ProcessInfo(paneId: "w1:p2", shellPid: 4242, foregroundPids: [])
        XCTAssertNotNil(verify(processes: shellOnly), "a pid seen only as the shell is not enough")
        let ancestor = HerdrBridge.ProcessInfo(paneId: "w1:p2", shellPid: 100, foregroundPids: [4242])
        XCTAssertNotNil(verify(processes: ancestor, pid: 100), "the shell is an ancestor, not the session")
        XCTAssertNotNil(verify(processes: HerdrBridge.ProcessInfo(paneId: "w1:p2", shellPid: 100, foregroundPids: []), pid: 4242),
                        "no foreground processes")
    }

    func testNonPositivePidRefuses() {
        XCTAssertNotNil(verify(processes: HerdrBridge.ProcessInfo(paneId: "w1:p2", shellPid: 100, foregroundPids: [0]), pid: 0))
        XCTAssertNotNil(verify(processes: HerdrBridge.ProcessInfo(paneId: "w1:p2", shellPid: 100, foregroundPids: [-1]), pid: -1))
    }

    func testPaneIdMustBeTheRequestedOne() {
        XCTAssertNotNil(verify(paneId: "w1:p9"), "Herdr answered for another pane")
    }

    func testWorkspaceIsCheckedOnlyWhenKnown() {
        XCTAssertNotNil(verify(workspaceId: "w2"), "the pane moved to another workspace")
        XCTAssertNil(verify(workspaceId: nil), "no expected workspace, nothing to compare")
        XCTAssertNil(verify(pane: HerdrBridge.PaneInfo(paneId: "w1:p2", terminalId: "term_abc", workspaceId: nil), workspaceId: "w1"),
                     "Herdr gave no workspace, so none is compared")
    }

    func testTerminalIsCheckedOnceKnown() {
        XCTAssertNotNil(verify(expectTerminalId: "term_other"), "the pane id now holds another terminal")
        XCTAssertNil(verify(expectTerminalId: nil), "first locate accepts any terminal")
    }

    func testProcessPaneMustBeTheRequestedOne() {
        XCTAssertNotNil(verify(processes: HerdrBridge.ProcessInfo(paneId: "w1:p9", shellPid: 100, foregroundPids: [4242])))
        XCTAssertNil(verify(processes: HerdrBridge.ProcessInfo(paneId: nil, shellPid: 100, foregroundPids: [4242])),
                     "no pane in the process reply is not a mismatch")
    }

    func testEveryVerificationReasonNamesHerdrOrThePane() {
        let reasons = [
            verify(paneId: "w1:p9"),
            verify(workspaceId: "w2"),
            verify(expectTerminalId: "term_other"),
            verify(processes: HerdrBridge.ProcessInfo(paneId: "w1:p9", shellPid: 100, foregroundPids: [4242])),
            verify(pid: 999),
        ]
        for reason in reasons {
            let text = try? XCTUnwrap(reason)
            XCTAssertTrue(text?.contains("Herdr") == true || text?.contains("pane") == true, "\(text ?? "nil")")
        }
    }

    // MARK: transport against a fake server

    func testExchangeReturnsTheReplyLine() throws {
        let server = try makeServer(behaviour: .fixed(pingOk + "\n"))
        let reply = HerdrBridge.exchange(socketPath: server.path, line: HerdrBridge.request(id: "1", method: "ping", params: [:]))
        XCTAssertEqual(try reply.get(), pingOk)
    }

    func testReplyWithoutAFinalNewlineIsReturnedWhenTheServerCloses() throws {
        let server = try makeServer(behaviour: .fixed(pingOk))
        let reply = HerdrBridge.exchange(socketPath: server.path, line: HerdrBridge.request(id: "1", method: "ping", params: [:]))
        XCTAssertEqual(try reply.get(), pingOk)
    }

    func testServerThatClosesWithoutAnswerIsTransport() throws {
        let server = try makeServer(behaviour: .closeSilently)
        let reply = HerdrBridge.exchange(socketPath: server.path, line: HerdrBridge.request(id: "1", method: "ping", params: [:]))
        XCTAssertEqual(transportKind(reply), "closed without a reply")
    }

    func testServerThatNeverAnswersTimesOutQuickly() throws {
        let server = try makeServer(behaviour: .hang)
        let started = Date()
        let reply = HerdrBridge.exchange(socketPath: server.path, line: HerdrBridge.request(id: "1", method: "ping", params: [:]),
                                         timeout: 0.3)
        XCTAssertEqual(transportKind(reply), "timed out")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "gives up near the timeout, not later")
    }

    func testMissingSocketIsTransport() {
        let reply = HerdrBridge.exchange(socketPath: "/tmp/hd-missing-\(UUID().uuidString.prefix(8)).sock",
                                         line: HerdrBridge.request(id: "1", method: "ping", params: [:]))
        XCTAssertNotNil(transportKind(reply), "nothing listening is a transport failure")
    }

    func testReplyOverFourMiBIsRefused() throws {
        let server = try makeServer(behaviour: .oversized)
        // A long timeout: the debug build needs several seconds to pull 4 MiB
        // through the reader, and the size limit is what this test checks.
        let reply = HerdrBridge.exchange(socketPath: server.path, line: HerdrBridge.request(id: "1", method: "ping", params: [:]),
                                         timeout: 60)
        XCTAssertEqual(transportKind(reply), "reply too large", "a huge reply is refused, not buffered")
    }

    func testCallRoundTripsOneRequestOnAFreshConnection() throws {
        let server = try makeServer()
        let pane = try HerdrBridge.call(server.path, method: "pane.get", params: ["pane_id": "w1:p2"],
                                        parse: HerdrBridge.parsePaneInfo).get()
        XCTAssertEqual(pane, HerdrBridge.PaneInfo(paneId: "w1:p2", terminalId: "term_1", workspaceId: "w1"))
        XCTAssertEqual(server.received.last?["method"] as? String, "pane.get")
        XCTAssertEqual((server.received.last?["params"] as? [String: Any])?["pane_id"] as? String, "w1:p2")
    }

    func testCallRejectsAReplyForAnotherId() throws {
        let server = try makeServer(behaviour: .fixed(#"{"id":"zzz","result":{"type":"ok"}}"# + "\n"))
        let result = HerdrBridge.call(server.path, method: "ping", params: [:], parse: HerdrBridge.parseAck)
        XCTAssertEqual(failureKind(result), "idMismatch")
    }

    // MARK: locate, recheck, send, screen

    private func target(_ server: FakeHerdrServer, terminal: String = "term_1", pid: Int32 = 4242) -> HerdrBridge.Target {
        HerdrBridge.Target(socketPath: server.path, paneId: "w1:p2", terminalId: terminal, sessionPid: pid)
    }

    func testLocateFindsThePaneHoldingTheSession() throws {
        let server = try makeServer()
        guard case .success(let found) = HerdrBridge.locate(socketPath: server.path, paneId: "w1:p2", workspaceId: "w1", pid: 4242) else {
            XCTFail("the session is in front in its pane")
            return
        }
        XCTAssertEqual(found, target(server))
        XCTAssertEqual(found.label, "Herdr pane w1:p2")
    }

    func testLocateRefusesAPidThatIsNotInFront() throws {
        let server = try makeServer()
        guard case .failure(let f) = HerdrBridge.locate(socketPath: server.path, paneId: "w1:p2", workspaceId: "w1", pid: 999) else {
            XCTFail("pid 999 is not in the pane")
            return
        }
        XCTAssertTrue(f.detail.contains("Herdr"), f.detail)
    }

    func testLocateRefusesAnUntrustedSocket() throws {
        let server = try makeServer()
        XCTAssertEqual(chmod(server.path, 0o666), 0)
        guard case .failure(let f) = HerdrBridge.locate(socketPath: server.path, paneId: "w1:p2", workspaceId: "w1", pid: 4242) else {
            XCTFail("a socket anyone can write to is never used")
            return
        }
        XCTAssertTrue(f.detail.contains("Herdr"), f.detail)
    }

    func testRecheckPassesUntilThePaneChanges() throws {
        let server = try makeServer()
        let t = target(server)
        XCTAssertNil(HerdrBridge.recheck(t), "same terminal, session in front")

        server.update { $0.terminalId = "term_2" }
        XCTAssertNotNil(HerdrBridge.recheck(t), "the pane id now holds another terminal")
        server.update { $0.terminalId = "term_1" }

        server.update { $0.foregroundPids = [] }
        XCTAssertNotNil(HerdrBridge.recheck(t), "the session left the foreground")
        server.update { $0.foregroundPids = [4242] }

        server.stop()
        XCTAssertNotNil(HerdrBridge.recheck(t), "Herdr is gone")
    }

    func testSendTypesOneKeyThroughTheSocket() throws {
        let server = try makeServer()
        let result = try XCTUnwrap(HerdrBridge.send(target(server), key: .text("1")))
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(server.received.last?["method"] as? String, "pane.send_text")
        XCTAssertEqual((server.received.last?["params"] as? [String: Any])?["text"] as? String, "1")
    }

    func testSendEnterAndEscapeUseKeys() throws {
        let server = try makeServer()
        _ = HerdrBridge.send(target(server), key: .enter)
        XCTAssertEqual((server.received.last?["params"] as? [String: Any])?["keys"] as? [String], ["enter"])
        _ = HerdrBridge.send(target(server), key: .escape)
        XCTAssertEqual((server.received.last?["params"] as? [String: Any])?["keys"] as? [String], ["esc"])
    }

    func testSendReportsHerdrsErrorAsStatusOne() throws {
        let server = try makeServer()
        server.update { $0.sendErrorCode = "pane_not_found" }
        let result = try XCTUnwrap(HerdrBridge.send(target(server), key: .text("1")))
        XCTAssertEqual(result.status, 1)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.stderr.contains("pane_not_found"), result.stderr)
    }

    func testPauseSendsNothing() throws {
        let server = try makeServer()
        XCTAssertNil(HerdrBridge.send(target(server), key: .pause(1)))
        XCTAssertNil(HerdrBridge.send(target(server), key: .awaitPromptClosed))
        XCTAssertTrue(server.received.isEmpty, "no request for a pause")
    }

    func testTypingStopsWhenThePaneNowHoldsAnotherTerminal() throws {
        let server = try makeServer()
        let t = target(server)
        server.update { $0.terminalId = "term_2" }
        let result = InjectionExecutor.sendViaControlCLI([.text("1")], method: .herdr, label: t.label, awaitClosed: { true },
                                                         precheck: { _ in HerdrBridge.recheck(t) }) { key in
            HerdrBridge.send(t, key: key)
        }
        XCTAssertFalse(result.success, "the key must not go to another terminal")
        XCTAssertFalse(server.received.contains { ($0["method"] as? String) == "pane.send_text" }, "nothing was typed")
    }

    func testScreenReturnsLFTextAndAsksForTheRightFormat() throws {
        let server = try makeServer()
        server.update { $0.screenText = "a\r\nb\r\n" }

        XCTAssertEqual(HerdrBridge.screen(target(server), styled: true), "a\nb\n")
        let styled = server.received.last?["params"] as? [String: Any]
        XCTAssertEqual(styled?["format"] as? String, "ansi")
        XCTAssertEqual(styled?["strip_ansi"] as? Bool, false)

        XCTAssertEqual(HerdrBridge.screen(target(server), styled: false), "a\nb\n")
        let plain = server.received.last?["params"] as? [String: Any]
        XCTAssertEqual(plain?["format"] as? String, "text")
        XCTAssertEqual(plain?["strip_ansi"] as? Bool, true)
    }

    func testScreenIsNilWhenThePaneHoldsAnotherTerminal() throws {
        let server = try makeServer()
        server.update { $0.terminalId = "term_2" }
        XCTAssertNil(HerdrBridge.screen(target(server), styled: true), "another pane is never read as this one")
    }

    func testScreenIsNilWhenHerdrIsGone() throws {
        let server = try makeServer()
        let t = target(server)
        server.stop()
        XCTAssertNil(HerdrBridge.screen(t, styled: false))
    }

    // MARK: injection wiring

    func testHostLabelEscapeAndEquality() {
        let t = HerdrBridge.Target(socketPath: "/tmp/hd.sock", paneId: "w1:p2", terminalId: "t", sessionPid: 1)
        let host = InjectionExecutor.TerminalHost.herdr(t)
        XCTAssertEqual(host.label, "Herdr pane w1:p2")
        XCTAssertTrue(host.canSendLoneEscape, "Esc can be pressed through the socket")
        XCTAssertEqual(host, .herdr(t))
        XCTAssertNotEqual(host, .herdr(HerdrBridge.Target(socketPath: "/tmp/hd.sock", paneId: "w1:p2", terminalId: "t2", sessionPid: 1)))
        XCTAssertNotEqual(host, .herdr(HerdrBridge.Target(socketPath: "/tmp/hd.sock", paneId: "w1:p2", terminalId: "t", sessionPid: 2)))
        XCTAssertNotEqual(host, .herdr(HerdrBridge.Target(socketPath: "/tmp/other.sock", paneId: "w1:p2", terminalId: "t", sessionPid: 1)))
        XCTAssertNotEqual(host, .herdr(HerdrBridge.Target(socketPath: "/tmp/hd.sock", paneId: "w1:p3", terminalId: "t", sessionPid: 1)))
    }

    func testInjectionMethodWireValue() {
        XCTAssertEqual(InjectionMethod.herdr.rawValue, "herdr")
    }

    func testNestedMultiplexerLeavesHerdrAloneAndStillRefusesOthers() {
        XCTAssertNil(InjectionExecutor.nestedMultiplexer(env: ["HERDR_ENV": "1"],
                                                         ancestorCommands: ["/opt/homebrew/bin/herdr server"]),
                     "Herdr is handled earlier, through its socket")
        XCTAssertNil(InjectionExecutor.nestedMultiplexer(env: [:], ancestorCommands: ["herdr"]))
        XCTAssertEqual(InjectionExecutor.nestedMultiplexer(env: [:], ancestorCommands: ["/opt/homebrew/bin/zellij --server"]), "zellij")
        XCTAssertEqual(InjectionExecutor.nestedMultiplexer(env: [:], ancestorCommands: ["screen -S work"]), "screen")
        XCTAssertNil(InjectionExecutor.nestedMultiplexer(env: [:], ancestorCommands: ["/usr/bin/herdr-helper"]))
    }

    func testControlCLISenderStopsAtAHerdrPrecheckAndReportsWhatWasTyped() {
        var sent: [Keystroke] = []
        let reason = "The Herdr pane now holds a different terminal — answer at the Mac"
        let result = InjectionExecutor.sendViaControlCLI([.text("1"), .enter], method: .herdr, label: "Herdr pane w1:p2",
                                                         awaitClosed: { true },
                                                         precheck: { k in k == .enter ? reason : nil }) { key in
            sent.append(key)
            return ProcessRunner.Result(status: 0, stdout: "", stderr: "", timedOut: false, launched: true)
        }
        XCTAssertFalse(result.success)
        XCTAssertEqual(sent, [.text("1")], "the Enter never went out")
        XCTAssertEqual(result.detail, reason + " (part of the reply was typed)")
        XCTAssertEqual(result.method, .herdr)
    }

    func testControlCLISenderSendsNothingWhenTheFirstPrecheckFails() {
        var sent = 0
        let result = InjectionExecutor.sendViaControlCLI([.text("1")], method: .herdr, label: "Herdr pane w1:p2",
                                                         awaitClosed: { true }, precheck: { _ in "Couldn't confirm the session is in front in its Herdr pane" }) { _ in
            sent += 1
            return ProcessRunner.Result(status: 0, stdout: "", stderr: "", timedOut: false, launched: true)
        }
        XCTAssertFalse(result.success)
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(result.detail, "Couldn't confirm the session is in front in its Herdr pane", "nothing typed, so no partial note")
    }

    func testControlCLISenderSucceedsWithHerdrLabel() {
        var sent = 0
        let result = InjectionExecutor.sendViaControlCLI([.text("1"), .enter], method: .herdr, label: "Herdr pane w1:p2",
                                                         awaitClosed: { true }) { _ in
            sent += 1
            return ProcessRunner.Result(status: 0, stdout: "", stderr: "", timedOut: false, launched: true)
        }
        XCTAssertTrue(result.success)
        XCTAssertEqual(sent, 2)
        XCTAssertEqual(result.output, "ok Herdr pane w1:p2")
        XCTAssertEqual(result.method, .herdr)
    }

    func testControlCLISenderReportsASendFailure() {
        let result = InjectionExecutor.sendViaControlCLI([.text("1")], method: .herdr, label: "Herdr pane w1:p2",
                                                         awaitClosed: { true }) { _ in
            ProcessRunner.Result(status: 1, stdout: "", stderr: "", timedOut: false, launched: true)
        }
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.output, "herdr send failed")
        XCTAssertEqual(result.detail, "Couldn't type into Herdr pane w1:p2")
    }

    func testScreenReaderExistsForHerdr() throws {
        let server = try makeServer()
        let reader = try XCTUnwrap(InjectionExecutor.screenReader(for: .herdr(target(server))))
        server.update { $0.screenText = "hello" }
        XCTAssertEqual(reader(), "hello")
    }

    func testDraftRefusalReadsTheStyledScreen() throws {
        let rule = String(repeating: "─", count: 40)
        let server = try makeServer()
        let host = InjectionExecutor.TerminalHost.herdr(target(server))

        server.update { $0.screenText = "\(rule)\n> \n\(rule)\n" }
        XCTAssertNil(InjectionExecutor.draftRefusal(host: host, requireEmpty: true), "an empty box")

        server.update { $0.screenText = "\(rule)\n> half typed\n\(rule)\n" }
        XCTAssertEqual(InjectionExecutor.draftRefusal(host: host, requireEmpty: false), CmuxBridge.draftDetail, "typed text is a draft")

        server.update { $0.screenText = "\(rule)\n> \u{1b}[2mTry \"refactor\"\u{1b}[22m\n\(rule)\n" }
        XCTAssertNil(InjectionExecutor.draftRefusal(host: host, requireEmpty: true), "dim placeholder text is not a draft")
        XCTAssertEqual((server.received.last?["params"] as? [String: Any])?["format"] as? String, "ansi", "the box is read with colours")
    }

    func testUnreadableScreenBlocksOnlyWhenEmptinessMustBeProven() throws {
        let server = try makeServer()
        let host = InjectionExecutor.TerminalHost.herdr(target(server))
        server.update { $0.readErrorCode = "internal" }
        XCTAssertNil(InjectionExecutor.draftRefusal(host: host, requireEmpty: false))
        XCTAssertEqual(InjectionExecutor.draftRefusal(host: host, requireEmpty: true), InjectionExecutor.inputUnverifiedMessage)
    }

    // MARK: phone host name and gating

    func testHostInfoNamesHerdrAndCanTypeAndInterrupt() {
        let t = HerdrBridge.Target(socketPath: "/tmp/hd.sock", paneId: "w1:p2", terminalId: "t", sessionPid: 1)
        let info = LiveSessionBackends.claudeHostInfo(.herdr(t), provider: .anthropic)
        XCTAssertEqual(info.host, "Herdr")
        XCTAssertTrue(info.canType)
        XCTAssertTrue(info.canInterrupt)
        XCTAssertNil(info.typeBlocker)
    }

    func testUnreachableHerdrPaneShowsHerdrAndItsReason() {
        let reason = "Couldn't confirm the session is in front in its Herdr pane"
        let info = LiveSessionBackends.claudeHostInfo(.unreachable(reason), provider: .anthropic)
        XCTAssertEqual(info.host, "Herdr")
        XCTAssertFalse(info.canType)
        XCTAssertEqual(info.typeBlocker, reason)
    }

    func testUnreachableReasonsStillMapToTheirOwnApps() {
        XCTAssertEqual(LiveSessionBackends.claudeHostInfo(.unreachable("Couldn't reach kitty"), provider: .anthropic).host, "kitty")
        XCTAssertEqual(LiveSessionBackends.claudeHostInfo(.unreachable("WezTerm pane is gone"), provider: .anthropic).host, "WezTerm")
        XCTAssertEqual(LiveSessionBackends.claudeHostInfo(.unreachable("Couldn't find the cmux surface"), provider: .anthropic).host, "cmux")
    }

    func testClaudePlanDeliversToAnIdleHerdrSession() {
        let t = HerdrBridge.Target(socketPath: "/tmp/hd.sock", paneId: "w1:p2", terminalId: "t", sessionPid: 1)
        XCTAssertEqual(plan(status: .idle, host: .herdr(t), text: "hi"), .deliver(queued: false))
        XCTAssertEqual(plan(status: .busy, host: .herdr(t), text: "hi"), .deliver(queued: true), "a busy session queues the message")
        XCTAssertEqual(plan(status: .idle, host: .herdr(t), text: "2 things"), .deliver(queued: false),
                       "a digit is only refused while busy")
    }

    func testClaudePlanRefusesWaitingAndBusyDigits() {
        let t = HerdrBridge.Target(socketPath: "/tmp/hd.sock", paneId: "w1:p2", terminalId: "t", sessionPid: 1)
        guard case .refuse(let waiting) = plan(status: .waiting, host: .herdr(t), text: "hi") else {
            XCTFail("a prompt on screen must not be typed into")
            return
        }
        XCTAssertEqual(waiting.reason, .waiting)

        guard case .refuse(let digit) = plan(status: .busy, host: .herdr(t), text: "2 things") else {
            XCTFail("a busy session with a leading digit must be refused")
            return
        }
        XCTAssertEqual(digit.reason, .digitWhileBusy)
    }

    func testClaudePlanRefusesAnUnreachableHerdrPaneWithItsReason() {
        let reason = "Couldn't confirm the session is in front in its Herdr pane"
        guard case .refuse(let r) = plan(status: .idle, host: .unreachable(reason), text: "hi") else {
            XCTFail("an unreachable pane is not typable")
            return
        }
        XCTAssertEqual(r.reason, .notTypable)
        XCTAssertEqual(r.detail, reason)
    }

    func testPauseStrategyInterruptsBusyHerdrSessionOnlyWhenAskedTo() {
        let t = HerdrBridge.Target(socketPath: "/tmp/hd.sock", paneId: "w1:p2", terminalId: "t", sessionPid: 1)
        XCTAssertEqual(ClaudeBackend.pauseStrategy(status: .busy, host: .herdr(t), mode: .pause), .interrupt, "a lone Esc is allowed")
        guard case .queue = ClaudeBackend.pauseStrategy(status: .busy, host: .herdr(t), mode: .afterTurn) else {
            XCTFail("after the current step queues the message instead of pressing Esc")
            return
        }
        guard case .skip = ClaudeBackend.pauseStrategy(status: .busy, host: .herdr(t), mode: .afterTurn, isLocal: true) else {
            XCTFail("a local model is never sent a summary request on battery")
            return
        }
        XCTAssertEqual(ClaudeBackend.pauseStrategy(status: .busy, host: .herdr(t), mode: .pause, isLocal: true), .interrupt)
    }

    func testPauseStrategySkipsUnreachableIdleAndOffSessions() {
        let t = HerdrBridge.Target(socketPath: "/tmp/hd.sock", paneId: "w1:p2", terminalId: "t", sessionPid: 1)
        let reason = "Couldn't confirm the session is in front in its Herdr pane"
        XCTAssertEqual(ClaudeBackend.pauseStrategy(status: .busy, host: .unreachable(reason), mode: .pause), .skip(reason))
        guard case .skip = ClaudeBackend.pauseStrategy(status: .idle, host: .herdr(t), mode: .pause) else {
            XCTFail("an idle session is left alone")
            return
        }
        guard case .skip = ClaudeBackend.pauseStrategy(status: .busy, host: .herdr(t), mode: .off) else {
            XCTFail("with the action off nothing is sent")
            return
        }
    }

    func testSessionScreenMirrorsHerdrAndNothingElseNew() {
        let t = HerdrBridge.Target(socketPath: "/tmp/hd.sock", paneId: "w1:p2", terminalId: "t", sessionPid: 1)
        // Typed as TerminalHost: the name also exists on the Codex terminal enum.
        typealias Host = InjectionExecutor.TerminalHost
        XCTAssertEqual(SessionScreen.source(for: Host.herdr(t)), .herdr(t))
        XCTAssertNil(SessionScreen.source(for: Host.terminalApp(tty: "/dev/ttys001")))
        XCTAssertNil(SessionScreen.source(for: Host.iTerm(tty: "/dev/ttys001")))
        XCTAssertNil(SessionScreen.source(for: Host.unreachable("Couldn't reach Herdr")))
        XCTAssertNil(SessionScreen.source(for: Host.unsupported("Ghostty")))
        XCTAssertNil(SessionScreen.source(for: Host.unknown))
    }

    // MARK: helpers

    /// The parsed JSON object of a request line, or [:].
    private func json(_ line: String?) -> [String: Any] {
        guard let line = line, let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return [:]
        }
        return object
    }

    /// The failure as a short label, or nil for a success.
    private func failureKind<T>(_ result: Swift.Result<T, HerdrBridge.RPCError>) -> String? {
        guard case .failure(let e) = result else { return nil }
        switch e {
        case .transport: return "transport"
        case .malformed: return "malformed"
        case .idMismatch: return "idMismatch"
        case .wrongType(let t): return "wrongType(\(t))"
        case .server(let code, _): return "server(\(code))"
        }
    }

    /// The transport message of a failed exchange, or nil.
    private func transportKind(_ result: Swift.Result<String, HerdrBridge.RPCError>) -> String? {
        guard case .failure(.transport(let message)) = result else { return nil }
        return message
    }

    private func refusal(_ plan: HerdrBridge.Plan) -> String? {
        if case .refuse(let why) = plan { return why }
        return nil
    }

    /// `SessionInputGate.claudePlan` for a live session with a session file.
    private func plan(status: ClaudeSessionStatus, host: InjectionExecutor.TerminalHost, text: String) -> SessionInputGate.ClaudeStep {
        SessionInputGate.claudePlan(target: .live, status: status, hasSessionFile: true, host: host,
                                    text: text, interventionId: nil)
    }

    private func makeTempDir() throws -> String {
        let dir = "/tmp/hd-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    /// A fake Herdr listening on a socket, stopped (and its socket removed)
    /// when the test ends.
    private func makeServer(behaviour: FakeHerdrServer.Behaviour = .herdr, path: String? = nil) throws -> FakeHerdrServer {
        let server = try FakeHerdrServer(behaviour: behaviour, path: path)
        addTeardownBlock { server.stop() }
        return server
    }

}

// MARK: fake Herdr

/// The pane state a fake Herdr answers from.
fileprivate struct FakePane {
    var terminalId = "term_1"
    var workspaceId: String? = "w1"
    var foregroundPids: [Int32] = [4242]
    var screenText = ""
    /// The error code every send answers with, when set.
    var sendErrorCode: String?
    /// The error code `pane.read` answers with, when set.
    var readErrorCode: String?
}

fileprivate enum FakeError: Error {
    case setup(String)
}

/// An NDJSON server on a Unix socket: one request line per connection, one
/// reply. Runs in this process only, on a short path under /tmp. The
/// requests it has seen are kept for the test to inspect.
fileprivate final class FakeHerdrServer {
    enum Behaviour {
        /// Answers the way Herdr does, from `pane`.
        case herdr
        /// Writes these bytes after the request, with nothing added.
        case fixed(String)
        /// Closes without answering.
        case closeSilently
        /// Never answers; waits until the client gives up.
        case hang
        /// Writes more than the client accepts, with no newline until its end.
        case oversized
    }

    let path: String
    private let behaviour: Behaviour
    private let lock = NSLock()
    private var pane = FakePane()
    private var requests: [[String: Any]] = []
    private var running = true

    init(behaviour: Behaviour = .herdr, path: String? = nil) throws {
        self.behaviour = behaviour
        self.path = path ?? "/tmp/hd-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FakeError.setup("socket") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(self.path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw FakeError.setup("bind")
        }
        // Owner-only, as a real Herdr socket is, so the trust check passes.
        chmod(self.path, 0o600)
        DispatchQueue.global().async { self.acceptLoop(fd) }
    }

    /// The requests received so far, parsed.
    var received: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    /// Changes the pane the server answers from.
    func update(_ change: (inout FakePane) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&pane)
    }

    /// Stops accepting and removes the socket. Safe to call twice.
    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        unlink(path)
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func acceptLoop(_ fd: Int32) {
        defer { close(fd) }
        while isRunning() {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, 50)
            if ready < 0 && errno != EINTR { return }
            guard ready > 0 else { continue }
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { continue }
            DispatchQueue.global().async { self.serve(conn) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let line = FakeHerdrServer.readRequestLine(fd) else { return }
        let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
        lock.lock()
        requests.append(request)
        let snapshot = pane
        lock.unlock()

        switch behaviour {
        case .herdr:
            FakeHerdrServer.writeAll(fd, FakeHerdrServer.encode(FakeHerdrServer.answer(request, pane: snapshot)) + "\n")
        case .fixed(let bytes):
            FakeHerdrServer.writeAll(fd, bytes)
        case .closeSilently:
            return
        case .hang:
            var chunk = [UInt8](repeating: 0, count: 256)
            while read(fd, &chunk, chunk.count) > 0 {}
        case .oversized:
            FakeHerdrServer.writeAll(fd, String(repeating: "a", count: HerdrBridge.maxReplyBytes + 4096) + "\n")
        }
    }

    private static func readRequestLine(_ fd: Int32) -> String? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !buffer.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(chunk, count: n)
        }
        return String(decoding: buffer.prefix { $0 != 0x0A }, as: UTF8.self)
    }

    private static func writeAll(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + sent, bytes.count - sent) }
            if n <= 0 { return }
            sent += n
        }
    }

    private static func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The reply Herdr gives for `request`, from `pane`.
    private static func answer(_ request: [String: Any], pane: FakePane) -> [String: Any] {
        let id = request["id"] as? String ?? ""
        let method = request["method"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]
        let paneId = params["pane_id"] as? String ?? ""

        func ok(_ result: [String: Any]) -> [String: Any] {
            ["id": id, "result": result]
        }
        func fail(_ code: String) -> [String: Any] {
            ["id": id, "error": ["code": code, "message": "no such pane"] as [String: Any]]
        }

        switch method {
        case "pane.get":
            var info: [String: Any] = ["pane_id": paneId, "terminal_id": pane.terminalId]
            if let workspace = pane.workspaceId { info["workspace_id"] = workspace }
            return ok(["type": "pane_info", "pane": info])
        case "pane.process_info":
            let foreground = pane.foregroundPids.map { ["pid": Int($0), "name": "claude"] as [String: Any] }
            let info: [String: Any] = ["pane_id": paneId, "shell_pid": 100, "foreground_processes": foreground]
            return ok(["type": "pane_process_info", "process_info": info])
        case "pane.send_text", "pane.send_input", "pane.send_keys":
            if let code = pane.sendErrorCode { return fail(code) }
            return ok(["type": "ok"])
        case "pane.read":
            if let code = pane.readErrorCode { return fail(code) }
            return ok(["type": "pane_read", "read": ["text": pane.screenText] as [String: Any]])
        default:
            return ["id": id, "error": ["code": "unknown_method", "message": method] as [String: Any]]
        }
    }
}
