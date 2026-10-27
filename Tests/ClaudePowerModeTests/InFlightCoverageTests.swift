import XCTest
@testable import ClaudePowerMode

/// Coverage for the In-flight card that `InFlightCardTests` does not reach:
/// the wire's golden output (the same literals the phone's logic tests decode),
/// the cap and the order, redaction end to end through a transcript file, the
/// missing-field and clock boundaries, the orb's and the key's route to Settings,
/// and the button words.
final class InFlightCoverageTests: XCTestCase {
    /// 2026-09-21 14:13:20 UTC.
    private let base = Date(timeIntervalSince1970: 1_790_000_000)
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-inflight-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: the wire, pinned both ways

    /// The golden wire rows. The same literals are pasted into iOS/Tests/LogicTests.swift
    /// (the "In-flight audit" block), so a rename on either side fails a test.
    static let goldenStuck = #"{"busySince":"2026-09-21T14:01:20Z","health":"stuck","healthDetail":"no progress for 15 min","model":"Opus 4.7","recentSteps":["Running swift test"],"startedAt":"2026-09-21T12:03:20Z"}"#
    static let goldenRateLimited = #"{"busySince":"2026-09-21T14:01:20Z","health":"rateLimited","recentSteps":["Reading Package.swift"],"resetsAt":"2026-09-21T14:28:20Z"}"#
    static let goldenLongRunning = #"{"busySince":"2026-09-21T14:01:20Z","health":"longRunning","recentSteps":["Running make all"],"stepSince":"2026-09-21T14:06:40Z"}"#
    static let goldenSixWorkflows = #"{"health":"normal","workflows":[{"done":3,"name":"Review changes","phase":"Reviewing","running":2,"total":5},{"done":1,"name":"Lint","running":1,"total":2},{"done":0,"name":"Docs","running":0,"total":4}],"workflowsRunning":6}"#

    private func object(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    /// Key order and whitespace never count: both sides are re-serialized with sorted keys.
    private func canonical(_ o: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), encoding: .utf8)!
    }

    private func at(_ offset: TimeInterval) -> Date { base.addingTimeInterval(offset) }

    func testWireGoldenStuckWithItsDetail() {
        let facts = InFlightFacts(steps: [InFlightStep(text: "Bash: swift test", at: at(-30))], currentStepIsNewest: true,
                                  model: "claude-opus-4-7", startedAt: at(-7800), busySince: at(-720))
        let wire = InFlightWire.fields(facts: facts, stuckDetail: "no progress for 15 min", rateLimitResetsAt: nil, now: base)
        XCTAssertEqual(canonical(wire), canonical(object(Self.goldenStuck)))
    }

    func testWireGoldenRateLimitedCarriesItsReset() {
        let facts = InFlightFacts(steps: [InFlightStep(text: "Read: /x/Package.swift", at: at(-20))], currentStepIsNewest: true,
                                  busySince: at(-720))
        let wire = InFlightWire.fields(facts: facts, stuckDetail: nil, rateLimitResetsAt: at(900), now: base)
        XCTAssertEqual(canonical(wire), canonical(object(Self.goldenRateLimited)))
    }

    func testWireGoldenLongRunningCarriesTheStepSince() {
        let facts = InFlightFacts(steps: [InFlightStep(text: "Bash: make all", at: at(-400))], currentStepIsNewest: true,
                                  busySince: at(-720))
        let wire = InFlightWire.fields(facts: facts, stuckDetail: nil, rateLimitResetsAt: nil, now: base)
        XCTAssertEqual(canonical(wire), canonical(object(Self.goldenLongRunning)))
    }

    func testWireGoldenSixWorkflowsSendsThreeAndTheCountOfSix() {
        let runs = [
            InFlightWorkflow(name: "Review changes", phase: "Reviewing", done: 3, total: 5, agentsRunning: 2),
            InFlightWorkflow(name: "Lint", phase: nil, done: 1, total: 2, agentsRunning: 1),
            InFlightWorkflow(name: "Docs", phase: nil, done: 0, total: 4, agentsRunning: 0),
            InFlightWorkflow(name: "Extra one", phase: nil, done: 0, total: 1, agentsRunning: 0),
            InFlightWorkflow(name: "Extra two", phase: nil, done: 0, total: 1, agentsRunning: 0),
            InFlightWorkflow(name: "Extra three", phase: nil, done: 0, total: 1, agentsRunning: 0),
        ]
        let wire = InFlightWire.fields(facts: InFlightFacts(workflows: runs), stuckDetail: nil, rateLimitResetsAt: nil, now: base)
        XCTAssertEqual(canonical(wire), canonical(object(Self.goldenSixWorkflows)))
    }

    func testWireDatesAreAbsoluteNotTicking() {
        let facts = InFlightFacts(steps: [InFlightStep(text: "Bash: make", at: at(-400))], currentStepIsNewest: true,
                                  busySince: at(-720))
        let a = InFlightWire.fields(facts: facts, stuckDetail: nil, rateLimitResetsAt: nil, now: base)
        let b = InFlightWire.fields(facts: facts, stuckDetail: nil, rateLimitResetsAt: nil, now: base.addingTimeInterval(3600))
        XCTAssertEqual(canonical(a), canonical(b), "an hour passing never changes the body; only a new health word does")
        XCTAssertEqual(a["busySince"] as? String, "2026-09-21T14:01:20Z")
    }

    // MARK: old phones and old Macs

    private let legacyKeys: Set<String> = ["id", "backend", "title", "state", "host", "canType", "canInterrupt", "provider"]
    private let newKeys: Set<String> = ["busySince", "startedAt", "model", "recentSteps", "workflows", "workflowsRunning",
                                        "health", "healthDetail", "resetsAt", "stepSince"]

    private func row(working: WireFields?) -> RemoteSessionRow {
        let host = SessionHostInfo(host: "cmux", canType: true, typeBlocker: nil, canInterrupt: true)
        return RemoteSessionRow(id: "s", backend: "claude", title: "page", cwd: nil, state: .active, host: host,
                                lastActivityAt: nil, interventionId: nil, preview: nil, working: working)
    }

    func testAnOldMacsRowHasExactlyTheLegacyKeys() {
        XCTAssertEqual(Set(row(working: nil).jsonObject.keys), legacyKeys, "no new key without the Mac having something to say")
    }

    func testAWorkingRowAddsOnlyNewKeysAndKeepsEveryLegacyValue() {
        let plain = row(working: nil).jsonObject
        let rich = row(working: WireFields(object(Self.goldenStuck))).jsonObject
        XCTAssertTrue(legacyKeys.isSubset(of: Set(rich.keys)))
        XCTAssertTrue(Set(rich.keys).subtracting(legacyKeys).isSubset(of: newKeys), "only the documented optional keys are added")
        for k in legacyKeys { XCTAssertEqual("\(plain[k] ?? "")", "\(rich[k] ?? "")", "legacy \(k) is unchanged") }
        XCTAssertTrue(JSONSerialization.isValidJSONObject(rich), "the row serializes for the encrypted list")
    }

    func testNothingToSayMeansNoWireFieldsAtAll() {
        XCTAssertNil(SessionRemote.workingFields(facts: nil, pending: [], sessionId: "s", rateLimitResetsAt: nil, now: base))
        XCTAssertNil(SessionRemote.workingFields(facts: InFlightFacts(), pending: [], sessionId: "s", rateLimitResetsAt: nil, now: base))
    }

    // MARK: the card's words when the Mac knows little

    func testMissingFieldsGiveWordsNotGuesses() {
        let c = InFlightCardInfo.make(facts: InFlightFacts(), backend: nil, stuckDetail: nil, rateLimitResetsAt: nil, now: base)
        XCTAssertEqual(c.now, "Working")
        XCTAssertTrue(c.earlier.isEmpty)
        XCTAssertNil(c.model)
        XCTAssertNil(c.workingFor)
        XCTAssertNil(c.sessionAge)
        XCTAssertNil(c.timeLine)
        XCTAssertNil(c.workflowsHeading)
        XCTAssertNil(c.backendName)
        XCTAssertEqual(c.health, .normal)
    }

    func testBlankStepsReadWorkingAndAModelAloneStillShows() {
        let blank = InFlightFacts(steps: [InFlightStep(text: "   ", at: nil)], model: "claude-sonnet-4-5")
        let c = InFlightCardInfo.make(facts: blank, backend: .claude, stuckDetail: nil, rateLimitResetsAt: nil, now: base)
        XCTAssertEqual(c.now, "Working")
        XCTAssertEqual(c.model, "Sonnet 4.5")
    }

    func testStepsWithNoTimesShowNoClock() {
        let f = InFlightFacts(steps: [InFlightStep(text: "Bash: ls", at: nil)], currentStepIsNewest: false)
        let c = InFlightCardInfo.make(facts: f, backend: .claude, stuckDetail: nil, rateLimitResetsAt: nil, now: base)
        XCTAssertEqual(c.now, "Running ls")
        XCTAssertNil(c.timeLine)
        XCTAssertNil(InFlightWire.fields(facts: f, stuckDetail: nil, rateLimitResetsAt: nil, now: base)["busySince"])
    }

    // MARK: redaction, end to end through a transcript file

    private func line(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), encoding: .utf8)!
    }

    func testASecretInAToolCallNeverReachesTheCardOrTheWire() throws {
        let secret = "sk-ant-api03-SECRETSECRETSECRET0123456789abcdef"
        let longCommand = "curl -H 'Authorization: Bearer \(secret)' https://example.com/" + String(repeating: "p", count: 400)
        let assistant = line(["type": "assistant", "uuid": "a1", "timestamp": "2026-10-24T12:00:01.000Z",
                              "message": ["role": "assistant", "content": [
                                ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": longCommand]]]]])
        let path = dir.appendingPathComponent("t.jsonl").path
        try (assistant + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let snap = try XCTUnwrap(SessionTranscript.read(path: path, format: .claude))
        let steps = snap.entries.filter { $0.role == .tool }.map { InFlightStep(text: $0.text, at: $0.at) }
        XCTAssertEqual(steps.count, 1)
        let facts = InFlightFacts(steps: steps, currentStepIsNewest: true, busySince: at(-60))

        let card = InFlightCardInfo.make(facts: facts, backend: .claude, stuckDetail: nil, rateLimitResetsAt: nil, now: base)
        XCTAssertFalse(card.now.contains("SECRETSECRET"), "the card's step is redacted: \(card.now)")
        XCTAssertLessThanOrEqual(card.now.count, StepPhrasing.maxChars)

        let wire = InFlightWire.fields(facts: facts, stuckDetail: nil, rateLimitResetsAt: nil, now: base)
        let recent = wire["recentSteps"] as? [String] ?? []
        XCTAssertFalse(recent.joined().contains("SECRETSECRET"), "the wire's step is redacted")
        XCTAssertTrue(recent.allSatisfy { $0.count <= InFlightWire.maxStepChars })
    }

    // MARK: cap and Show all

    private func fake(_ name: String) -> InFlightRow {
        InFlightRow(id: InFlightRow.idPrefix + name, sessionId: name, kind: .session, project: name, backend: .claude,
                    route: nil, doing: "working", since: nil, elapsed: nil, actions: .localModel, target: nil)
    }

    func testCapShowsThreeThenAllWhenExpanded() {
        let four = ["a", "b", "c", "d"].map(fake)
        let shown = InFlightLayout.visible(four, collapsed: false, expanded: false)
        XCTAssertEqual(shown.shown.map(\.sessionId), ["a", "b", "c"])
        XCTAssertEqual(shown.more, 1)
        XCTAssertEqual(InFlightLayout.showAllTitle(total: 4), "Show all 4")
        let open = InFlightLayout.visible(four, collapsed: false, expanded: true)
        XCTAssertEqual(open.shown.count, 4)
        XCTAssertEqual(open.more, 0)
    }

    func testCapEdgesCollapsedEmptyAndExactlyThree() {
        let five = ["a", "b", "c", "d", "e"].map(fake)
        XCTAssertEqual(InFlightLayout.visible(five, collapsed: false, expanded: false).more, 2)
        XCTAssertEqual(InFlightLayout.visible(five, collapsed: true, expanded: true).shown.count, 0, "collapsed draws none")
        XCTAssertEqual(InFlightLayout.visible(five, collapsed: true, expanded: true).more, 5, "and says how many")
        let three = Array(five.prefix(3))
        XCTAssertEqual(InFlightLayout.visible(three, collapsed: false, expanded: false).more, 0, "exactly the cap: no Show all")
        XCTAssertEqual(InFlightLayout.visible([], collapsed: false, expanded: false).shown.count, 0)
    }

    // MARK: order

    func testTheStackIsInProjectOrderAndNeverMovesWithTime() {
        let now = NightWatchFixtures.boardNow()
        let early = NowModel.build(NightWatchFixtures.cardsScene(now: now)).flight.map(\.project)
        let later = NowModel.build(NightWatchFixtures.cardsScene(now: now.addingTimeInterval(600))).flight.map(\.project)
        XCTAssertEqual(early, early.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, "project name, case-insensitive")
        XCTAssertEqual(early, later, "elapsed time, a stuck page and a rate limit never reorder the rows")
        XCTAssertFalse(early.isEmpty)
    }

    // MARK: clocks

    func testElapsedBoundaries() {
        XCTAssertEqual(InFlightRows.elapsed(since: at(-59), now: base), "59s")
        XCTAssertEqual(InFlightRows.elapsed(since: at(-60), now: base), "1m")
        XCTAssertEqual(InFlightRows.elapsed(since: at(-3599), now: base), "59m")
        XCTAssertEqual(InFlightRows.elapsed(since: at(-3600), now: base), "1h")
        XCTAssertEqual(InFlightRows.elapsed(since: at(-3660), now: base), "1h 1m")
        XCTAssertEqual(InFlightRows.elapsed(since: at(120), now: base), "0s", "a start in the future reads zero, never negative")
    }

    func testSessionAgeAndTurnTextOnTheCard() {
        let f = InFlightFacts(steps: [], startedAt: at(-3660), busySince: at(-59))
        let c = InFlightCardInfo.make(facts: f, backend: .claude, stuckDetail: nil, rateLimitResetsAt: nil, now: base)
        XCTAssertEqual(c.workingFor, "59s")
        XCTAssertEqual(c.sessionAge, "1h 1m")
        XCTAssertEqual(c.timeLine, "working 59s · session 1h 1m")
    }

    // MARK: health boundaries

    func testLongStepStartsAtExactlyThreeMinutes() {
        let at180 = InFlightStep(text: "Bash: make", at: at(-180))
        let at179 = InFlightStep(text: "Bash: make", at: at(-179))
        XCTAssertEqual(InFlightHealth.classify(stuckDetail: nil, rateLimitResetsAt: nil, step: at180, stepIsNewest: true, now: base),
                       .longStep(since: at(-180)))
        XCTAssertEqual(InFlightHealth.classify(stuckDetail: nil, rateLimitResetsAt: nil, step: at179, stepIsNewest: true, now: base), .normal)
    }

    func testBlankStuckDetailAndAResetThatIsNowAreNotHealth() {
        XCTAssertEqual(InFlightHealth.classify(stuckDetail: "   ", rateLimitResetsAt: nil, step: nil, stepIsNewest: false, now: base), .normal)
        XCTAssertEqual(InFlightHealth.classify(stuckDetail: nil, rateLimitResetsAt: base, step: nil, stepIsNewest: false, now: base), .normal)
    }

    // MARK: project names

    func testTheHomeFolderIsTildeWhateverTheSessionIsCalled() {
        XCTAssertEqual(InterventionDetector.projectName(forCwd: "/Users/roy", fallback: "docs", home: "/Users/roy"), "~")
        XCTAssertEqual(InterventionDetector.projectName(forCwd: "/Users/roy/", fallback: nil, home: "/Users/roy"), "~")
    }

    // MARK: the orb and the key reach Settings

    func testTheOrbEmitsThePreferencesCommand() {
        // The orb is store.command(.preferences); AppDelegate hands that to run(_:), which opens Preferences.
        let st = NowStore(model: NowModel.build(NightWatchFixtures.snapshotOnly()), prefs: .ephemeral())
        var sent: [NowCommand] = []
        st.command = { sent.append($0) }
        st.command(.preferences)
        XCTAssertEqual(sent, [.preferences])
    }

    func testCommandCommaEmitsThePreferencesEffect() {
        // ⌘, is a key effect (NowKeys → NowEffect.preferences), which AppDelegate.perform turns into openPreferences().
        let st = NowStore(model: NowModel.build(NightWatchFixtures.snapshotOnly()), prefs: .ephemeral())
        var effects: [NowEffect] = []
        st.perform = { effects.append($0) }
        XCTAssertTrue(st.handle(NowKeyPress(key: .char(","), command: true)), "⌘, is ours, not the responders'")
        XCTAssertEqual(effects, [.preferences])
        XCTAssertTrue(st.handle(NowKeyPress(key: .char(","), command: true, isRepeat: true)))
        XCTAssertEqual(effects, [.preferences], "a held key does not reopen Preferences")
    }

    // MARK: words on the buttons

    func testEveryButtonSaysAWord() {
        let actions: [KeyHint.Action] = [.approve, .approveHold, .deny, .tellInstead, .openTerminal]
        for a in actions {
            XCTAssertGreaterThan(a.title.count, 2, "\(a) reads as a word")
            XCTAssertNotEqual(a.title, a.title.uppercased(), "\(a) is not caps")
        }
        XCTAssertEqual(InFlightAction.open.title, "Open")
        XCTAssertEqual(InFlightAction.steer.title, "Steer")
        XCTAssertEqual(InFlightMenu.openTitle, "Open")
        XCTAssertEqual(InFlightMenu.typeTitle, "Steer…")
    }
}
