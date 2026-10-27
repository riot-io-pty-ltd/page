import XCTest
@testable import ClaudePowerMode

/// The rich In-flight card: step phrasing, model names, health, the card's
/// words, the optional wire fields, "N working" jumping to the cards, the
/// project-name fallback, and the buttons in words.
final class InFlightCardTests: XCTestCase {
    private let now = NightWatchFixtures.boardNow()
    private func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

    // MARK: step phrasing

    func testStepsReadAsPlainWords() {
        XCTAssertEqual(StepPhrasing.phrase("Bash: swift test"), "Running swift test")
        XCTAssertEqual(StepPhrasing.phrase("Shell: npm test"), "Running npm test")
        XCTAssertEqual(StepPhrasing.phrase("Edit: /Users/roy/projects/page/Sources/SessionRoom.swift"), "Editing SessionRoom.swift")
        XCTAssertEqual(StepPhrasing.phrase("MultiEdit: /a/b/C.swift (3 edits)"), "Editing C.swift (3 edits)")
        XCTAssertEqual(StepPhrasing.phrase("Edit: a.swift, b.swift and 2 more"), "Editing a.swift, b.swift and 2 more")
        XCTAssertEqual(StepPhrasing.phrase("Write: /x/docs/PROTOCOL.md"), "Writing PROTOCOL.md")
        XCTAssertEqual(StepPhrasing.phrase("Read: /x/Package.swift"), "Reading Package.swift")
        XCTAssertEqual(StepPhrasing.phrase("Grep: TODO in Sources"), "Searching for TODO")
        XCTAssertEqual(StepPhrasing.phrase("WebFetch: https://example.com/a/b"), "Fetching example.com")
        XCTAssertEqual(StepPhrasing.phrase("Task: review the diff"), "Running a subagent: review the diff")
    }

    func testUnknownStepsAreKeptAndLongOnesClipped() {
        XCTAssertEqual(StepPhrasing.phrase("Updated the plan"), "Updated the plan")
        XCTAssertEqual(StepPhrasing.phrase("send_message · slack: hello"), "send_message · slack: hello")
        XCTAssertEqual(StepPhrasing.phrase("   "), "Working")
        let long = StepPhrasing.phrase("Bash: " + String(repeating: "x", count: 200))
        XCTAssertEqual(long.count, StepPhrasing.maxChars)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertEqual(StepPhrasing.phrase("Bash: echo one\necho two"), "Running echo one", "first line only")
    }

    // MARK: model names

    func testModelNames() {
        XCTAssertEqual(ModelNaming.short("claude-opus-4-7"), "Opus 4.7")
        XCTAssertEqual(ModelNaming.short("claude-sonnet-4-5-20250929"), "Sonnet 4.5")
        XCTAssertEqual(ModelNaming.short("claude-3-5-haiku-20241022"), "Haiku 3.5")
        XCTAssertEqual(ModelNaming.short("claude-opus-4-7[1m]"), "Opus 4.7")
        XCTAssertEqual(ModelNaming.short("gpt-5-codex"), "gpt-5-codex")
        XCTAssertNil(ModelNaming.short("<synthetic>"))
        XCTAssertNil(ModelNaming.short("  "))
        XCTAssertNil(ModelNaming.short(nil))
    }

    // MARK: health

    func testHealthPriorityAndThresholds() {
        let step = InFlightStep(text: "Bash: swift test", at: ago(400))
        // Normal: a fresh step.
        XCTAssertEqual(InFlightHealth.classify(stuckDetail: nil, rateLimitResetsAt: nil,
                                               step: InFlightStep(text: "x", at: ago(20)), stepIsNewest: true, now: now), .normal)
        // A step running past the limit is long, but only if nothing was said after it.
        XCTAssertEqual(InFlightHealth.classify(stuckDetail: nil, rateLimitResetsAt: nil, step: step, stepIsNewest: true, now: now),
                       .longStep(since: ago(400)))
        XCTAssertEqual(InFlightHealth.classify(stuckDetail: nil, rateLimitResetsAt: nil, step: step, stepIsNewest: false, now: now), .normal)
        // The stuck watch's word beats a long step; a rate limit beats both.
        XCTAssertEqual(InFlightHealth.classify(stuckDetail: "no progress for 15 min", rateLimitResetsAt: nil, step: step,
                                               stepIsNewest: true, now: now), .looksStuck("no progress for 15 min"))
        let reset = now.addingTimeInterval(600)
        XCTAssertEqual(InFlightHealth.classify(stuckDetail: "x", rateLimitResetsAt: reset, step: step, stepIsNewest: true, now: now),
                       .rateLimited(resetsAt: reset))
        // A reset that has passed no longer counts.
        XCTAssertEqual(InFlightHealth.classify(stuckDetail: nil, rateLimitResetsAt: ago(5), step: nil, stepIsNewest: false, now: now), .normal)
    }

    func testHealthLinesAndWireNames() {
        let tz = TimeZone(identifier: "UTC")!
        XCTAssertEqual(InFlightHealth.normal.line(now: now), "Running normally")
        XCTAssertEqual(InFlightHealth.longStep(since: ago(260)).line(now: now), "Long step · 4m")
        XCTAssertEqual(InFlightHealth.looksStuck("cargo test failed 6×").line(now: now), "Looks stuck · cargo test failed 6×")
        let reset = Date(timeIntervalSince1970: 3 * 3600 + 120)
        XCTAssertEqual(InFlightHealth.rateLimited(resetsAt: reset).line(now: now, timeZone: tz), "Rate limited · resets 03:02")
        XCTAssertEqual([InFlightHealth.normal, .longStep(since: now), .looksStuck("x"), .rateLimited(resetsAt: now)].map(\.wireName),
                       ["normal", "longRunning", "stuck", "rateLimited"])
        XCTAssertFalse(InFlightHealth.normal.needsAttention)
        XCTAssertTrue(InFlightHealth.looksStuck("x").needsAttention)
    }

    // MARK: workflows

    private func run(_ name: String, status: String = "running", phase: String? = "Reviewing", done: Int = 3, total: Int = 5,
                     started: TimeInterval = 100, running: Int = 2) -> WorkflowRunInfo {
        let agents = (0..<total).map { i in
            WorkflowRunInfo.Agent(id: "a\(i)", label: "agent \(i)", phase: nil, state: i < running ? "running" : "done", lastActivityAt: nil)
        }
        return WorkflowRunInfo(id: "wf_\(name)", name: name, summary: nil, status: status, phase: phase, done: done, total: total,
                               startedAt: ago(started), endedAt: nil, tokens: nil, agents: agents)
    }

    func testWorkflowSummaryIsNamePhaseAndProgress() {
        let w = InFlightWorkflow(run: run("Review changes"))
        XCTAssertEqual(w.name, "Review changes")
        XCTAssertEqual(w.detail, "Reviewing · 3/5 agents")
        XCTAssertEqual(w.agentsRunning, 2)
        XCTAssertEqual(w.fraction ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(InFlightWorkflow(run: run("X", phase: nil, done: 0, total: 0)).detail, "")
        XCTAssertNil(InFlightWorkflow(run: run("X", phase: nil, done: 0, total: 0)).fraction)
    }

    func testOnlyRunningWorkflowsCountOldestFirst() {
        let runs = [run("late", started: 10), run("done", status: "completed"), run("early", started: 500), run("stalled", status: "stalled")]
        XCTAssertEqual(InFlightWorkflow.running(from: runs).map(\.name), ["early", "late"])
    }

    func testWorkflowTextIsRedactedAndClipped() {
        let w = InFlightWorkflow(run: run(String(repeating: "n", count: 300), phase: "key sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789"))
        XCTAssertLessThanOrEqual(w.name.count, InFlightWorkflow.maxName)
        XCTAssertFalse((w.phase ?? "").contains("abcdefghijklmnopqrstuvwxyz0123456789"))
    }

    // MARK: the card's words

    private func facts() -> InFlightFacts {
        InFlightFacts(
            steps: [InFlightStep(text: "Edit: /a/StuckWatch.swift", at: ago(500)),
                    InFlightStep(text: "Read: /a/Package.swift", at: ago(200)),
                    InFlightStep(text: "Grep: TODO in Sources", at: ago(100)),
                    InFlightStep(text: "Bash: swift test", at: ago(30))],
            currentStepIsNewest: true, model: "claude-opus-4-7", startedAt: ago(2 * 3600 + 600), busySince: ago(12 * 60),
            workflows: [InFlightWorkflow(name: "Review changes", phase: "Reviewing", done: 3, total: 5, agentsRunning: 2)])
    }

    func testCardSaysNowAndTheStepsBeforeNewestFirst() {
        let c = InFlightCardInfo.make(facts: facts(), backend: .claude, stuckDetail: nil, rateLimitResetsAt: nil, now: now)
        XCTAssertEqual(c.now, "Running swift test")
        XCTAssertEqual(c.earlier, ["Searching for TODO", "Reading Package.swift", "Editing StuckWatch.swift"])
        XCTAssertEqual(c.backendName, "Claude")
        XCTAssertEqual(c.model, "Opus 4.7")
        XCTAssertEqual(c.workingFor, "12m")
        XCTAssertEqual(c.sessionAge, "2h 10m")
        XCTAssertEqual(c.timeLine, "working 12m · session 2h 10m")
        XCTAssertEqual(c.workflowsHeading, "1 workflow running")
        XCTAssertEqual(c.workflows.first?.detail, "Reviewing · 3/5 agents")
        XCTAssertEqual(c.health, .normal)
    }

    func testCardWithNoFactsStillSaysSomethingHonest() {
        let c = InFlightCardInfo.make(facts: nil, backend: .codex, stuckDetail: nil, rateLimitResetsAt: nil, fallbackStep: "Bash: ls", now: now)
        XCTAssertEqual(c.now, "Running ls")
        XCTAssertTrue(c.earlier.isEmpty)
        XCTAssertNil(c.timeLine, "no times are guessed")
        XCTAssertNil(c.workflowsHeading)
        XCTAssertEqual(InFlightCardInfo.make(facts: nil, backend: .claude, stuckDetail: nil, rateLimitResetsAt: nil, now: now).now, "Working")
    }

    func testTimeLineWithOnlyOneHalf() {
        var f = facts(); f.startedAt = nil
        XCTAssertEqual(InFlightCardInfo.make(facts: f, backend: .claude, stuckDetail: nil, rateLimitResetsAt: nil, now: now).timeLine, "working 12m")
        f = facts(); f.busySince = nil
        XCTAssertEqual(InFlightCardInfo.make(facts: f, backend: .claude, stuckDetail: nil, rateLimitResetsAt: nil, now: now).timeLine, "session 2h 10m")
    }

    // MARK: rows carry the card

    private func scene(working: Int = 4) -> (rows: [InFlightRow], inputs: NowInputs) {
        let i = NightWatchFixtures.cardsScene(working: working)
        return (NowModel.build(i).flight, i)
    }

    func testRowsCarryWorkflowsStuckAndRateLimitFromWhatTheMacAlreadyKnows() {
        let (rows, _) = scene()
        let by = Dictionary(uniqueKeysWithValues: rows.map { ($0.project, $0) })
        XCTAssertEqual(by["page"]?.card.workflows.count, 2)
        XCTAssertEqual(by["page"]?.card.health, .normal)
        XCTAssertEqual(by["page"]?.elapsed, "12m", "elapsed still comes from the busy-since")
        if case .looksStuck(let why)? = by["llm-play"]?.card.health { XCTAssertEqual(why, "no progress for 15 min") } else { XCTFail("stuck page → looks stuck") }
        if case .rateLimited? = by["docs"]?.card.health {} else { XCTFail("rate limit → rate limited") }
        if case .longStep? = by["payments-api"]?.card.health {} else { XCTFail("6 min step → long step") }
        XCTAssertTrue(rows.allSatisfy(\.hasCard))
    }

    func testSummaryLineCountsWorkingWorkflowsAndTroubles() {
        let (rows, _) = scene()
        XCTAssertEqual(InFlightLayout.summary(rows), "4 working · 2 workflows running · 1 looks stuck · 1 rate limited")
        XCTAssertEqual(InFlightLayout.summary([]), "")
        XCTAssertEqual(InFlightLayout.showAllTitle(total: 5), "Show all 5")
    }

    func testAFinishedRowKeepsItsCard() {
        let (rows, _) = scene(working: 2)
        let r = rows.first { $0.project == "page" }!
        XCTAssertEqual(r.finished.card, r.card)
        XCTAssertFalse(r.finished.working)
    }

    // MARK: the wire

    func testWireFieldsAreAbsoluteDatesAndOmitWhatIsUnknown() {
        let iso = SessionTranscript.isoFormatter
        let o = InFlightWire.fields(facts: facts(), stuckDetail: nil, rateLimitResetsAt: nil, now: now)
        XCTAssertEqual(o["busySince"] as? String, iso.string(from: ago(12 * 60)))
        XCTAssertEqual(o["startedAt"] as? String, iso.string(from: ago(2 * 3600 + 600)))
        XCTAssertEqual(o["model"] as? String, "Opus 4.7")
        XCTAssertEqual(o["recentSteps"] as? [String], ["Editing StuckWatch.swift", "Reading Package.swift", "Searching for TODO", "Running swift test"], "four, oldest first, the last is the current step")
        XCTAssertEqual(o["workflowsRunning"] as? Int, 1)
        let w = (o["workflows"] as? [[String: Any]])?.first
        XCTAssertEqual(w?["name"] as? String, "Review changes")
        XCTAssertEqual(w?["phase"] as? String, "Reviewing")
        XCTAssertEqual(w?["done"] as? Int, 3)
        XCTAssertEqual(w?["total"] as? Int, 5)
        XCTAssertEqual(o["health"] as? String, "normal", "a Mac with facts says normal, so a phone never guesses its own")
        XCTAssertNil(InFlightWire.fields(facts: nil, stuckDetail: nil, rateLimitResetsAt: nil, now: now)["recentSteps"])
        XCTAssertTrue(InFlightWire.fields(facts: nil, stuckDetail: nil, rateLimitResetsAt: nil, now: now).isEmpty)
        XCTAssertNil(WireFields(InFlightWire.fields(facts: nil, stuckDetail: nil, rateLimitResetsAt: nil, now: now)))
    }

    func testWireHealthCarriesItsDetailAndNoTickingText() {
        let stuck = InFlightWire.fields(facts: facts(), stuckDetail: "cargo test failed 6×", rateLimitResetsAt: nil, now: now)
        XCTAssertEqual(stuck["health"] as? String, "stuck")
        XCTAssertEqual(stuck["healthDetail"] as? String, "cargo test failed 6×")
        let reset = now.addingTimeInterval(900)
        let limited = InFlightWire.fields(facts: facts(), stuckDetail: nil, rateLimitResetsAt: reset, now: now)
        XCTAssertEqual(limited["health"] as? String, "rateLimited")
        XCTAssertEqual(limited["resetsAt"] as? String, SessionTranscript.isoFormatter.string(from: reset))
        var f = facts(); f.steps = [InFlightStep(text: "Bash: make", at: ago(400))]
        let long = InFlightWire.fields(facts: f, stuckDetail: nil, rateLimitResetsAt: nil, now: now)
        XCTAssertEqual(long["health"] as? String, "longRunning")
        XCTAssertEqual(long["stepSince"] as? String, SessionTranscript.isoFormatter.string(from: ago(400)))
        // Nothing in any value reads "12m": a minute passing never changes the body.
        let a = InFlightWire.fields(facts: facts(), stuckDetail: nil, rateLimitResetsAt: nil, now: now)
        let b = InFlightWire.fields(facts: facts(), stuckDetail: nil, rateLimitResetsAt: nil, now: now.addingTimeInterval(60))
        XCTAssertEqual(WireFields(a), WireFields(b))
    }

    func testRepeatedStepsFoldIntoOneWithACount() {
        XCTAssertEqual(StepPhrasing.collapse(["Reading a", "Running cargo test", "Running cargo test", "Running cargo test"]),
                       ["Reading a", "Running cargo test ×3"])
        XCTAssertEqual(StepPhrasing.collapse(["A", "B", "A"]), ["A", "B", "A"], "only back-to-back repeats fold")
        XCTAssertLessThanOrEqual(StepPhrasing.collapse([String(repeating: "x", count: 100), String(repeating: "x", count: 100)], max: 100)[0].count, 100)
        var f = facts()
        f.steps = [InFlightStep(text: "Read: /a/Package.swift", at: nil)] + (0..<3).map { _ in InFlightStep(text: "Bash: cargo test", at: ago(5)) }
        let card = InFlightCardInfo.make(facts: f, backend: .claude, stuckDetail: nil, rateLimitResetsAt: nil, now: now)
        XCTAssertEqual(card.now, "Running cargo test ×3")
        XCTAssertEqual(card.earlier, ["Reading Package.swift"], "the current step is not listed again")
        let wire = InFlightWire.fields(facts: f, stuckDetail: nil, rateLimitResetsAt: nil, now: now)
        XCTAssertEqual(wire["recentSteps"] as? [String], ["Reading Package.swift", "Running cargo test ×3"])
    }

    func testHealthLineIsWordedWhenTheCardIsBuilt() {
        let calm = InFlightCardInfo.make(facts: facts(), backend: .claude, stuckDetail: nil, rateLimitResetsAt: nil, now: now)
        XCTAssertNil(calm.healthLine)
        let stuck = InFlightCardInfo.make(facts: facts(), backend: .claude, stuckDetail: "no progress for 15 min", rateLimitResetsAt: nil, now: now)
        XCTAssertEqual(stuck.healthLine, "Looks stuck · no progress for 15 min")
    }

    func testWireIsBounded() {
        var f = facts()
        f.steps = (0..<6).map { InFlightStep(text: "Bash: step\($0) " + String(repeating: "y", count: 400), at: nil) }
        f.workflows = (0..<6).map { InFlightWorkflow(name: "wf\($0)", phase: nil, done: 0, total: 2, agentsRunning: 1) }
        let o = InFlightWire.fields(facts: f, stuckDetail: nil, rateLimitResetsAt: nil, now: now)
        let steps = o["recentSteps"] as? [String] ?? []
        XCTAssertEqual(steps.count, InFlightWire.maxSteps)
        XCTAssertTrue(steps.allSatisfy { $0.count <= InFlightWire.maxStepChars })
        XCTAssertEqual((o["workflows"] as? [Any])?.count, InFlightWire.maxWorkflows)
        XCTAssertEqual(o["workflowsRunning"] as? Int, 6)
    }

    func testListRowMergesWorkingFieldsWithoutReplacingItsOwn() {
        let host = SessionHostInfo(host: "cmux", canType: true, typeBlocker: nil, canInterrupt: true)
        let fields = WireFields(["model": "SHOULD NOT WIN", "busySince": "2026-01-01T00:00:00Z", "recentSteps": ["Running x"]])
        let row = RemoteSessionRow(id: "s", backend: "claude", title: "t", cwd: nil, state: .active, host: host, lastActivityAt: nil,
                                   interventionId: nil, preview: nil, working: fields)
        let o = row.jsonObject
        XCTAssertEqual(o["busySince"] as? String, "2026-01-01T00:00:00Z")
        XCTAssertEqual(o["recentSteps"] as? [String], ["Running x"])
        XCTAssertEqual(o["state"] as? String, "active")
        let plain = RemoteSessionRow(id: "s", backend: "claude", title: "t", cwd: nil, state: .active, host: host, lastActivityAt: nil,
                                     interventionId: nil, preview: nil)
        XCTAssertNil(plain.jsonObject["busySince"], "an old list row is unchanged")
        XCTAssertNil(plain.jsonObject["recentSteps"])
    }

    func testWorkingFieldsUseTheStuckWatchPage() {
        let stuck = NightWatchFixtures.event("llm-play", kind: .idle, context: "No progress for 15 min — it may be hung.\nLast step: cargo test",
                                             openedAt: ago(60), subtype: "stuck")
        let f = SessionRemote.workingFields(facts: facts(), pending: [stuck], sessionId: "sess-llm-play", rateLimitResetsAt: nil, now: now)
        XCTAssertEqual(f?.object["health"] as? String, "stuck")
        XCTAssertEqual(f?.object["healthDetail"] as? String, "no progress for 15 min")
        let other = SessionRemote.workingFields(facts: facts(), pending: [stuck], sessionId: "sess-page", rateLimitResetsAt: nil, now: now)
        XCTAssertEqual(other?.object["health"] as? String, "normal", "another session's page says nothing about this one")
        XCTAssertNil(other?.object["healthDetail"])
    }

    // MARK: sessions file

    func testSessionFileGivesStartedAtAndName() {
        let json = #"{"pid":42,"sessionId":"s","cwd":"/","status":"busy","startedAt":1700000000000,"statusUpdatedAt":1700000100000,"name":"  page  "}"#
        let r = ClaudeSessionRegistry.parseSessionFile(Data(json.utf8))
        XCTAssertEqual(r?.startedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(r?.name, "page")
        let bare = ClaudeSessionRegistry.parseSessionFile(Data(#"{"pid":1,"startedAt":true,"name":""}"#.utf8))
        XCTAssertNil(bare?.startedAt)
        XCTAssertNil(bare?.name)
    }

    // MARK: "N working" jumps to the cards

    func testWorkingPhraseSplitsOutOfTheHeadline() {
        XCTAssertEqual(WorkingPhrase.split("2 need you · 5 working"),
                       WorkingPhrase.Split(before: "2 need you · ", token: "5 working", after: ""))
        XCTAssertEqual(WorkingPhrase.split("2 working · nothing needs you"),
                       WorkingPhrase.Split(before: "", token: "2 working", after: " · nothing needs you"))
        XCTAssertEqual(WorkingPhrase.split("1 working · resuming the rest")?.token, "1 working")
        XCTAssertNil(WorkingPhrase.split("All quiet"))
        XCTAssertNil(WorkingPhrase.split("Paused at 10%"))
        XCTAssertNil(WorkingPhrase.split("no agents running · nothing needs you"))
    }

    func testJumpPlanOpensTheGroupSelectsTheFirstCardAndClosesTheSheet() {
        let (rows, _) = scene(working: 2)
        var state = NowPanelState()
        state.inFlightCollapsed = true
        state.showShortcuts = true
        let plan = InFlightJump.plan(rows: rows, state: state)
        XCTAssertEqual(plan, InFlightJump.Plan(uncollapse: true, closeShortcuts: true, selectId: rows[0].id, scrollTo: InFlightLayout.anchorId))
        XCTAssertEqual(InFlightJump.plan(rows: rows, state: NowPanelState())?.uncollapse, false)
        XCTAssertNil(InFlightJump.plan(rows: [], state: state), "nothing in flight, nothing to jump to")
    }

    func testStoreJumpExpandsSelectsAndNeverSendsAnything() {
        let inputs = NightWatchFixtures.cardsScene()
        let st = NowStore(model: NowModel.build(inputs), prefs: .ephemeral())
        st.now = { inputs.now }
        var effects: [NowEffect] = []
        st.perform = { effects.append($0) }
        st.setInFlightCollapsed(true)
        st.toggleShortcuts()
        let token = st.flightJumpToken
        st.jumpToInFlight()
        XCTAssertFalse(st.state.inFlightCollapsed)
        XCTAssertFalse(st.prefs.inFlightCollapsed, "the remembered choice follows")
        XCTAssertFalse(st.state.showShortcuts)
        XCTAssertEqual(st.selectedId, st.flightRows.first?.id)
        XCTAssertEqual(st.flightJumpToken, token + 1)
        XCTAssertTrue(effects.isEmpty)
    }

    func testJumpNeverMovesAHalfTypedMessageOffItsCard() {
        let inputs = NightWatchFixtures.cardsScene()
        let st = NowStore(model: NowModel.build(inputs), prefs: .ephemeral())
        st.now = { inputs.now }
        let page = InFlightRow.idPrefix + "sess-page"
        st.hoverFlight(page)
        st.handle(NowKeyPress(key: .char("t")))
        st.composerText = "keep this"
        st.jumpToInFlight()
        XCTAssertEqual(st.selectedId, page)
        XCTAssertEqual(st.composerText, "keep this")
    }

    func testJumpWithNothingInFlightDoesNothing() {
        let st = NowStore(model: NowModel.build(NightWatchFixtures.snapshotOnly()), prefs: .ephemeral())
        let token = st.flightJumpToken
        st.jumpToInFlight()
        XCTAssertEqual(st.flightJumpToken, token)
    }

    // MARK: project names

    func testProjectNameNeverComesBackAsABareSlash() {
        XCTAssertEqual(InterventionDetector.projectName(forCwd: "/", fallback: "refactor-auth"), "refactor-auth")
        XCTAssertEqual(InterventionDetector.projectName(forCwd: "/", fallback: nil), "root")
        XCTAssertEqual(InterventionDetector.projectName(forCwd: "/", fallback: "/"), "root")
        XCTAssertEqual(InterventionDetector.projectName(forCwd: "", fallback: " "), "root")
        XCTAssertEqual(InterventionDetector.projectName(forCwd: "/Users/roy", home: "/Users/roy"), "~")
        XCTAssertEqual(InterventionDetector.projectName(forCwd: "/Users/roy/", home: "/Users/roy"), "~")
        // A generic folder straight under the root backs up to "/": its own name instead.
        XCTAssertEqual(InterventionDetector.projectName(forCwd: "/src"), "src")
        XCTAssertEqual(CodexInjector.projectName(forCwd: "/"), "Codex")
        XCTAssertEqual(CodexInjector.projectName(forCwd: "/Users/roy", home: "/Users/roy"), "~")
        XCTAssertEqual(CodexInjector.projectName(forCwd: "/Users/roy/projects/page"), "page")
    }

    func testRowsNeverShowASlashProject() {
        XCTAssertEqual(NowModel.displayProject("/", cwd: "/"), "root")
        XCTAssertEqual(NowModel.displayProject("", cwd: "/"), "root")
        XCTAssertEqual(NowModel.displayProject("page", cwd: "/x"), "page")
        let ev = InterventionEvent(id: "s-idle-1", sessionId: "s", cwd: "/", projectName: "/", kind: .idle, openedAt: now, context: "Finished",
                                   transcriptPath: "", backend: .claude, source: .terminal)
        XCTAssertEqual(NowModel.row(for: ev, macName: "Mac", route: nil)?.projectName, "root")
        // A working session in the root folder goes by its title.
        let s = AgentSession(backend: .claude, sessionId: "s", cwd: "/", title: "refactor-auth", source: .terminal, state: .active,
                             lastActivityAt: nil, activeFlags: [], supportsRemoteReply: true)
        XCTAssertEqual(NowModel.projectName(of: s), "refactor-auth")
    }

    // MARK: buttons in words

    func testRowsOfferWordsNotLetters() {
        let m = NowModel.build(NightWatchFixtures.cardsScene(irreversible: true))
        let decision = m.rows.first { $0.section == .decide }!
        XCTAssertEqual((decision.keys + decision.moreKeys).map { decision.buttonTitle(for: $0.action) },
                       ["Hold to approve", "Deny", "Steer", "Open"])
        let review = m.rows.first { $0.section == .review }!
        XCTAssertEqual((review.keys + review.moreKeys).map { review.buttonTitle(for: $0.action) }, ["Open", "Steer"])
        for r in m.rows {
            for k in r.keys + r.moreKeys {
                XCTAssertGreaterThan(r.buttonTitle(for: k.action).count, 2, "no button is a key alone")
            }
        }
    }

    func testEscOnAQuestionReadsDismiss() {
        let ev = NightWatchFixtures.event("page", kind: .question, context: "Which database?\n1. SQLite\n2. Postgres", openedAt: now)
        let row = NowModel.row(for: ev, macName: "Mac", route: "cmux › page")!
        XCTAssertEqual(row.buttonTitle(for: .deny), "Dismiss")
        XCTAssertEqual(row.buttonTitle(for: .tellInstead), "Steer")
    }

    func testTooltipsCarryTheKeys() {
        XCTAssertEqual(KeyHint.Action.openTerminal.tooltip(key: "O"), "Open · O · shows its terminal pane, types nothing")
        XCTAssertEqual(KeyHint.Action.tellInstead.tooltip(key: "T"), "Steer · T · Esc, your words, then Return")
        XCTAssertTrue(KeyHint.Action.deny.tooltip(key: "esc").hasPrefix("Deny · esc"))
    }

    func testTheCatalogMentionsSteerAndTheClicks() {
        let items = ShortcutCatalog.groups.flatMap(\.items)
        XCTAssertTrue(items.first { $0.keys == [PanelKeys.steer] }?.title.hasPrefix("Steer") == true)
        XCTAssertTrue(items.contains { $0.keys == ["click"] })
    }
}
