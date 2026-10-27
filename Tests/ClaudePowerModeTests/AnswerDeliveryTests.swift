import XCTest
@testable import ClaudePowerMode

/// The Mac side of answering a question dialog: the gate (`AnswerDelivery`),
/// the host key mappings, and the `answer` op / `ask` row field of the
/// sessions protocol, with the terminal and the relay faked.
final class AnswerDeliveryTests: XCTestCase {

    // MARK: fixtures

    private let toolId = "toolu_ask1"

    private var asked: AskedQuestionSet {
        AskedQuestionSet(toolUseId: toolId, questions: [
            AskedQuestion(question: "Pick a color", header: "Color", multi: false,
                          options: [AskedOption(label: "Red", description: ""), AskedOption(label: "Green", description: ""),
                                    AskedOption(label: "Blue", description: "")], hasPreview: false),
            AskedQuestion(question: "Pick toppings", header: "Toppings", multi: true,
                          options: [AskedOption(label: "Cheese", description: ""), AskedOption(label: "Ham", description: "")], hasPreview: false)])
    }

    private let request = AnswerRequest(promptKey: "toolu_ask1", answers: [AnswerPick(question: 0, picks: [1], other: nil),
                                                                          AnswerPick(question: 1, picks: [0, 1], other: nil)])

    private let live = ClaudeLiveSession(pid: 4242, sessionId: "11111111-2222-3333-4444-555555555555", cwd: "/tmp/p", status: .waiting,
                                         statusUpdatedAt: Date(timeIntervalSince1970: 1_761_300_000), tty: "ttys009", hasSessionFile: true)

    private final class Fake {
        var host: InjectionExecutor.TerminalHost = .tmux(tmuxPath: "/fake/tmux", paneId: "%1", inMode: false)
        var status = "waiting"
        var statusAt: Date? = Date(timeIntervalSince1970: 1_761_300_000)
        var pending: [PendingToolUse]?
        var held = false
        var foreground: Bool? = true
        var target: InjectionExecutor.ClaudeTarget
        var dialog: FakeQuestionDialog?
        var keys: [Keystroke] = []
        var transcript: String? = nil
        var sendFailure: String?
        var clock = Date(timeIntervalSince1970: 5_000)

        init(live: ClaudeLiveSession) { target = .live(live, []) }

        func io() -> AnswerDelivery.IO {
            AnswerDelivery.IO(
                resolve: { _ in self.target },
                currentRecord: { _ in ClaudeSessionRecord(pid: 4242, sessionId: nil, cwd: nil, status: self.status, statusUpdatedAt: self.statusAt, kind: nil, entrypoint: nil) },
                pendingTools: { _ in self.pending },
                holdsSession: { _ in self.held },
                resolveHost: { _, _ in self.host },
                isForeground: { _ in self.foreground },
                screenReader: { _ in { self.dialog?.render() } },
                sendKey: { _, key in
                    if let f = self.sendFailure { return f }
                    self.keys.append(key); self.dialog?.send(key); return nil
                },
                transcriptText: { _ in self.transcript },
                sleep: { self.clock = self.clock.addingTimeInterval($0) },
                now: { self.clock })
        }
    }

    private func fake(withDialog: Bool = true) -> Fake {
        let f = Fake(live: live)
        f.pending = [PendingToolUse(id: toolId, name: "AskUserQuestion", summary: "", asked: asked)]
        if withDialog { f.dialog = FakeQuestionDialog(asked) }
        return f
    }

    private func transcriptLine(_ answers: [String: String]) -> String {
        let obj: [String: Any] = ["type": "user",
                                  "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": toolId, "content": "ok"]]],
                                  "toolUseResult": ["answers": answers]]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    // MARK: the gate

    func testAnswersTheDialogAndConfirmsWhatClaudeReceived() {
        let f = fake()
        f.transcript = transcriptLine(["Pick a color": "Green", "Pick toppings": "Cheese, Ham"])
        let r = AnswerDelivery.run(sessionId: live.sessionId, request: request, io: f.io())
        XCTAssertEqual(r.code, .delivered, r.detail)
        XCTAssertEqual(r.detail, "Answered 2 questions in tmux pane %1")
        XCTAssertEqual(f.keys.first, .text("2"))
        XCTAssertFalse(f.keys.contains(.escape))
        XCTAssertEqual(f.dialog?.submitted, ["Pick a color": "Green", "Pick toppings": "Cheese, Ham"])
    }

    func testSaysSoWhenClaudeReceivedSomethingElse() {
        let f = fake()
        f.transcript = transcriptLine(["Pick a color": "Green", "Pick toppings": "Cheese"])
        let r = AnswerDelivery.run(sessionId: live.sessionId, request: request, io: f.io())
        XCTAssertEqual(r.code, .failed)
        XCTAssertTrue(r.detail.contains("different answers"))
    }

    func testDeliveredButUnconfirmedIsStillDeliveredWithANote() {
        let f = fake()
        f.transcript = nil
        // The dialog closed and the session moved on: no transcript record yet, but the status says it went in.
        let g = f
        let base = f.io()
        var io = base
        io.sendKey = { host, key in
            let r = base.sendKey(host, key)
            if g.dialog?.submitted != nil { g.status = "idle" }
            return r
        }
        let r = AnswerDelivery.run(sessionId: live.sessionId, request: request, io: io)
        XCTAssertEqual(r.code, .delivered)
        XCTAssertTrue(r.detail.contains("couldn't confirm"))
    }

    func testRefusesWhenTheSessionIsNoLongerWaiting() {
        let f = fake()
        f.status = "idle"
        let r = AnswerDelivery.run(sessionId: live.sessionId, request: request, io: f.io())
        XCTAssertEqual(r.reason, .questionChanged)
        XCTAssertTrue(f.keys.isEmpty)
    }

    func testRefusesAnotherQuestion() {
        let f = fake()
        let wrong = AnswerRequest(promptKey: "toolu_other", answers: request.answers)
        let r = AnswerDelivery.run(sessionId: live.sessionId, request: wrong, io: f.io())
        XCTAssertEqual(r.reason, .questionChanged)
        XCTAssertEqual(r.detail, AnswerDelivery.questionChangedMessage)
        XCTAssertTrue(f.keys.isEmpty)
    }

    func testRefusesWhenSeveralPromptsAreQueuedOrNonePending() {
        let f = fake()
        f.pending = [f.pending![0], PendingToolUse(id: "toolu_b", name: "Bash", summary: "")]
        XCTAssertEqual(AnswerDelivery.run(sessionId: live.sessionId, request: request, io: f.io()).detail, AnswerDelivery.severalMessage)
        f.pending = []
        XCTAssertEqual(AnswerDelivery.run(sessionId: live.sessionId, request: request, io: f.io()).reason, .questionChanged)
        f.pending = [PendingToolUse(id: toolId, name: "Bash", summary: "")]
        XCTAssertEqual(AnswerDelivery.run(sessionId: live.sessionId, request: request, io: f.io()).reason, .questionChanged)
        XCTAssertTrue(f.keys.isEmpty)
    }

    func testRefusesWhilePagesHookHoldsThePrompt() {
        let f = fake()
        f.held = true
        let r = AnswerDelivery.run(sessionId: live.sessionId, request: request, io: f.io())
        XCTAssertEqual(r.reason, .answerUnsupported)
        XCTAssertEqual(r.detail, AnswerDelivery.holdMessage)
        XCTAssertTrue(f.keys.isEmpty)
    }

    func testRefusesIncompleteAnswersPreviewsAndBackgroundedProcesses() {
        var f = fake()
        let partial = AnswerRequest(promptKey: toolId, answers: [request.answers[0]])
        XCTAssertEqual(AnswerDelivery.run(sessionId: live.sessionId, request: partial, io: f.io()).detail, AnswerPlan.incompleteMessage)
        f = fake()
        f.foreground = false
        XCTAssertEqual(AnswerDelivery.run(sessionId: live.sessionId, request: request, io: f.io()).detail, InjectionExecutor.notForegroundMessage)
        f = fake()
        let preview = AskedQuestionSet(toolUseId: toolId, questions: [AskedQuestion(question: "Q?", header: "", multi: false,
            options: [AskedOption(label: "a", description: ""), AskedOption(label: "b", description: "")], hasPreview: true)])
        f.pending = [PendingToolUse(id: toolId, name: "AskUserQuestion", summary: "", asked: preview)]
        let r = AnswerDelivery.run(sessionId: live.sessionId, request: AnswerRequest(promptKey: toolId, answers: [AnswerPick(question: 0, picks: [0], other: nil)]), io: f.io())
        XCTAssertEqual(r.detail, AnswerPlan.previewMessage)
        XCTAssertTrue(f.keys.isEmpty)
    }

    func testTerminalAppAndCmuxAreRefusedCleanly() {
        for host in [InjectionExecutor.TerminalHost.terminalApp(tty: "/dev/ttys009")] {
            let f = fake()
            f.host = host
            let r = AnswerDelivery.run(sessionId: live.sessionId, request: request, io: f.io())
            XCTAssertEqual(r.reason, .answerUnsupported)
            XCTAssertEqual(r.detail, AnswerDelivery.terminalAppMessage)
            XCTAssertTrue(f.keys.isEmpty)
        }
        XCTAssertEqual(AnswerDelivery.capabilities(of: .unknown), .failure(AnswerPlanError("Couldn't find the session's terminal")))
        XCTAssertEqual(AnswerDelivery.capabilities(of: .tmux(tmuxPath: "t", paneId: "%1", inMode: false)), .success(.tmux))
        // Only tmux's keys are measured; the other terminals with a key path stay refused until probed.
        for host in [InjectionExecutor.TerminalHost.iTerm(tty: "/dev/ttys1")] {
            XCTAssertEqual(AnswerDelivery.capabilities(of: host), .failure(AnswerPlanError(String(format: AnswerDelivery.unverifiedHostMessage, host.label))))
        }
    }

    func testOnlyTmuxPanesTakeAnswerKeysOnThePhonesList() {
        XCTAssertTrue(AnswerDelivery.takesAnswerKeys(SessionHostInfo(host: "tmux", canType: true, canInterrupt: true)))
        XCTAssertTrue(AnswerDelivery.takesAnswerKeys(SessionHostInfo(host: ClaudeSquad.hostName, canType: true, canInterrupt: true)))
        XCTAssertFalse(AnswerDelivery.takesAnswerKeys(.blocked(ClaudeSquad.hostName, ClaudeSquad.pausedMessage)))
        XCTAssertFalse(AnswerDelivery.takesAnswerKeys(.checking))
        for host in ["cmux", "Terminal", "iTerm", "WezTerm", "kitty", "Herdr"] {
            XCTAssertFalse(AnswerDelivery.takesAnswerKeys(SessionHostInfo(host: host, canType: true, canInterrupt: true)), host)
        }
    }

    func testRefusesAPausedSquadInstance() {
        let f = fake()
        var io = f.io()
        io.squadPaused = { _, _ in true }
        let r = AnswerDelivery.run(sessionId: live.sessionId, request: request, io: io)
        XCTAssertEqual(r.reason, .notTypable)
        XCTAssertEqual(r.detail, ClaudeSquad.pausedMessage)
        XCTAssertTrue(f.keys.isEmpty)
    }

    func testAHostThatFailsTheFirstKeyIsNotTypableNotQuestionChanged() {
        let f = fake()
        f.sendFailure = "Couldn't type into tmux pane %1"
        let r = AnswerDelivery.run(sessionId: live.sessionId, request: request, io: f.io())
        XCTAssertEqual(r.code, .refused)
        XCTAssertEqual(r.reason, .notTypable)
        XCTAssertTrue(f.keys.isEmpty)
    }

    func testAnUnconfirmedAnswerWhileTheSessionStillWaitsIsNotReportedAsDelivered() {
        let f = fake()
        f.transcript = nil
        let r = AnswerDelivery.run(sessionId: live.sessionId, request: request, io: f.io())
        XCTAssertEqual(r.code, .failed)
        XCTAssertTrue(r.detail.contains("may still be open"), r.detail)
    }

    func testOtherTerminalsAreRefusedBeforeAnyKey() {
        let f = fake()
        f.host = .iTerm(tty: "/dev/ttys009")
        let r = AnswerDelivery.run(sessionId: live.sessionId, request: request, io: f.io())
        XCTAssertEqual(r.reason, .answerUnsupported)
        XCTAssertTrue(r.detail.contains("hasn't verified"), r.detail)
        XCTAssertTrue(f.keys.isEmpty)
    }

    func testStopsMidWayWhenTheSessionStopsWaitingAndSaysSo() {
        let f = fake()
        let g = f
        var sends = 0
        let base = f.io()
        var io = base
        io.sendKey = { host, key in
            sends += 1
            let r = base.sendKey(host, key)
            if sends == 1 { g.status = "idle" }   // answered at the Mac after our first key
            return r
        }
        let r = AnswerDelivery.run(sessionId: live.sessionId, request: request, io: io)
        XCTAssertEqual(r.code, .failed)
        XCTAssertTrue(r.detail.contains("part-filled"), r.detail)
        XCTAssertEqual(f.keys.count, 1, "no key after the status changed")
    }

    func testStopsWhenTheStatusStartMoves() {
        // A different waiting state began: statusUpdatedAt moved more than 0.5 s.
        let f = fake()
        let base = f.io()
        var io = base
        io.sendKey = { host, key in let r = base.sendKey(host, key); f.statusAt = Date(timeIntervalSince1970: 1_761_300_010); return r }
        let r = AnswerDelivery.run(sessionId: live.sessionId, request: request, io: io)
        XCTAssertEqual(r.code, .failed)
        XCTAssertEqual(f.keys.count, 1)
    }

    func testReportsAKeyThatCouldNotBeTyped() {
        let f = fake()
        f.sendFailure = "Couldn't type into tmux pane %1"
        let r = AnswerDelivery.run(sessionId: live.sessionId, request: request, io: f.io())
        XCTAssertEqual(r.code, .refused, "nothing was typed, so it is a refusal")
        XCTAssertEqual(r.reason, .notTypable, "the terminal refused, the question did not change")
        XCTAssertEqual(r.detail, "Couldn't type into tmux pane %1")
    }

    func testEndedSessionAndUnreadableScreen() {
        var f = fake()
        f.target = .ended
        XCTAssertEqual(AnswerDelivery.run(sessionId: live.sessionId, request: request, io: f.io()).reason, .ended)
        f = fake(withDialog: false)
        let r = AnswerDelivery.run(sessionId: live.sessionId, request: request, io: f.io())
        XCTAssertEqual(r.code, .refused, "a blank screen is never typed into: \(r.detail)")
        XCTAssertTrue(f.keys.isEmpty)
    }

    // MARK: the host key mappings

    func testTmuxNamesAndTerminalBytes() {
        XCTAssertEqual(NavKey.right.tmuxName, "Right")
        XCTAssertEqual(NavKey.tab.tmuxName, "Tab")
        XCTAssertEqual(NavKey.down.bytes, "\u{1B}[B")
        XCTAssertEqual(NavKey.tab.bytes, "\t")
        XCTAssertNil(NavKey.tab.csiFinal)
        XCTAssertEqual(NavKey.left.csiFinal, "D")
    }

    func testWezTermSendsTheWholeArrowSequenceInOneWrite() {
        let k = WezTermBridge.sendArgs(paneId: "7", key: .key(.right))
        XCTAssertEqual(k?.args, ["send-text", "--pane-id", "7", "--no-paste"])
        XCTAssertEqual(k?.stdin, Data("\u{1B}[C".utf8))
        XCTAssertEqual(WezTermBridge.sendArgs(paneId: "7", key: .key(.tab))?.stdin, Data("\t".utf8))
    }

    func testKittyAndHerdrNameTheKeys() {
        let target = KittyBridge.Target(kittenPath: "/k", socket: "unix:/s", windowId: "3")
        XCTAssertEqual(KittyBridge.sendArgs(target: target, key: .key(.down))?.args,
                       ["@", "--to", "unix:/s", "send-key", "--match", "id:3", "down"])
        let line = HerdrBridge.sendRequest(id: "i", paneId: "p1", key: .key(.tab))
        let obj = (try? JSONSerialization.jsonObject(with: Data((line ?? "{}").utf8))) as? [String: Any]
        XCTAssertEqual(obj?["method"] as? String, "pane.send_keys")
        XCTAssertEqual((obj?["params"] as? [String: Any])?["keys"] as? [String], ["tab"])
    }

    func testTerminalAppAndCmuxRefuseNavigationKeys() {
        let t = InjectionExecutor.sendViaTerminalApp([.key(.tab)], tty: "/dev/ttys009", awaitClosed: { true })
        XCTAssertFalse(t.success)
        XCTAssertTrue(t.detail.contains("arrow or Tab"))
        XCTAssertNotNil(InjectionExecutor.sendOneKey(.key(.tab), to: .terminalApp(tty: "/dev/ttys009")))
    }

    // MARK: the wire

    func testCommandParsesPromptKeyAndAnswers() throws {
        let json = #"{"op":"answer","clientId":"c1","ts":1761300000000,"sessionId":"s1","promptKey":"toolu_1","answers":[{"i":0,"picks":[1]},{"i":1,"picks":[],"other":"x"}]}"#
        let cmd = try XCTUnwrap(SessionCommand.parse(Data(json.utf8)))
        XCTAssertEqual(cmd.op, "answer")
        XCTAssertEqual(cmd.promptKey, "toolu_1")
        XCTAssertEqual(cmd.answers, [AnswerPick(question: 0, picks: [1], other: nil), AnswerPick(question: 1, picks: [], other: "x")])
        let bad = #"{"op":"answer","clientId":"c1","ts":1761300000000,"sessionId":"s1","promptKey":"t","answers":"nope"}"#
        XCTAssertNil(try XCTUnwrap(SessionCommand.parse(Data(bad.utf8))).answers)
    }

    func testRowCarriesAskOnlyWhenThereIsOne() throws {
        let row = RemoteSessionRow(id: "s1", backend: "claude", title: "t", cwd: nil, state: .waitingOnUser,
                                   host: SessionHostInfo(host: "tmux", canType: true, canInterrupt: true), lastActivityAt: nil,
                                   interventionId: "p1", preview: nil, ask: asked)
        let ask = try XCTUnwrap(row.jsonObject["ask"] as? [String: Any])
        XCTAssertEqual(ask["id"] as? String, toolId)
        XCTAssertEqual((ask["questions"] as? [[String: Any]])?.count, 2)
        let plain = RemoteSessionRow(id: "s1", backend: "claude", title: "t", cwd: nil, state: .idle,
                                     host: SessionHostInfo(host: "tmux", canType: true, canInterrupt: true), lastActivityAt: nil,
                                     interventionId: nil, preview: nil)
        XCTAssertNil(plain.jsonObject["ask"])
    }

    // MARK: transcript parsing keeps the structured question

    func testTranscriptTailKeepsTheAskedQuestions() throws {
        let line: [String: Any] = ["type": "assistant", "message": ["role": "assistant", "content": [
            ["type": "tool_use", "id": "toolu_zz", "name": "AskUserQuestion",
             "input": ["questions": [["question": "Which?", "header": "H", "multiSelect": true,
                                      "options": [["label": "A", "description": "a"], ["label": "B", "description": "b"]]]]]]]]]
        let text = String(data: try JSONSerialization.data(withJSONObject: line), encoding: .utf8)!
        let tail = InterventionDetector.parseTranscriptTail(text)
        let asked = try XCTUnwrap(tail.pendingToolUses.first?.asked)
        XCTAssertEqual(asked.toolUseId, "toolu_zz")
        XCTAssertEqual(asked.questions[0].multi, true)
        XCTAssertEqual(asked.questions[0].options.map(\.label), ["A", "B"])
        XCTAssertEqual(asked.questions[0].options[0].description, "a")
    }
}
