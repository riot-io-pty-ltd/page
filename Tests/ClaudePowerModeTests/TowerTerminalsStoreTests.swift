import XCTest
@testable import ClaudePowerMode

/// The Tower's Terminals page in the store: one probe at a time, stale
/// results dropped, the kitty and Automation flows, the row buttons, and the
/// control map's Terminals entries. Every outside call is a recorded fake: no
/// kitty.conf, no macOS prompt, no process table.
final class TowerTerminalsStoreTests: XCTestCase {
    private typealias C = TerminalCatalog

    private final class Recorder {
        var probes: [(sessions: [AgentSession], done: (TerminalProbe.Snapshot?) -> Void)] = []
        var previewResult: Result<KittyConfigFile.Preview, KittyConfigFile.Failure> = .failure(.unreadable)
        var enableResult: Result<KittyConfigFile.Outcome, KittyConfigFile.Failure> = .failure(.unreadable)
        var enableCalls = 0
        var confirmAnswer = false
        var confirms: [(title: String, text: String, ok: String)] = []
        var undoResult = false
        var undoCalls = 0
        var alerts: [(title: String, text: String)] = []
        var automationCalls: [C.ID] = []
        var automationDone: [(TerminalProbe.Automation) -> Void] = []
        var opened: [URL] = []
        var visible = true
    }

    private let kittyURL = URL(fileURLWithPath: "/k/kitty.conf")

    private func makeStore() -> (TowerStore, Recorder) {
        let r = Recorder()
        var env = TowerEnvironment()
        env.probeTerminals = { sessions, done in r.probes.append((sessions: sessions, done: done)) }
        env.previewKitty = { r.previewResult }
        env.enableKitty = {
            r.enableCalls += 1
            return r.enableResult
        }
        env.undoKitty = {
            r.undoCalls += 1
            return r.undoResult
        }
        env.requestAutomation = { id, done in
            r.automationCalls.append(id)
            r.automationDone.append(done)
        }
        env.confirm = { title, text, ok, done in
            r.confirms.append((title: title, text: text, ok: ok))
            done(r.confirmAnswer)
        }
        env.showAlert = { r.alerts.append((title: $0, text: $1)) }
        env.openURL = { r.opened.append($0) }
        env.windowVisible = { r.visible }
        return (TowerStore(config: Config(), macName: "Studio", env: env), r)
    }

    private func snapshot(kitty: Bool = false) -> TerminalProbe.Snapshot {
        TerminalProbe.Snapshot(facts: [.wezterm: C.Facts(installed: true)], pageAddedKittyLines: kitty)
    }

    private func preview(_ plan: KittyConfigFile.Plan) -> KittyConfigFile.Preview {
        KittyConfigFile.Preview(url: kittyURL, plan: plan, creating: false)
    }

    private var writePlan: KittyConfigFile.Plan {
        .write(text: "x", added: [KittyConfigFile.allowLine, KittyConfigFile.listenLine])
    }

    private func session(_ id: String, state: AgentSessionState = .active) -> AgentSession {
        AgentSession(backend: .claude, sessionId: id, cwd: "/tmp/\(id)", title: id, source: .terminal, state: state,
                     lastActivityAt: nil, activeFlags: [], supportsRemoteReply: true)
    }

    private func coordinatorSnapshot(_ sessions: [AgentSession]) -> Coordinator.Snapshot {
        Coordinator.Snapshot(
            sessions: sessions,
            power: PowerSnapshot(percent: 80, onAC: true, hasBattery: true, isCharging: false),
            awake: .none, lidClosedOnBattery: false, lidClosedOnBatteryBlocker: nil,
            battery: Coordinator.BatteryStatus(phase: .normal, paused: [], graceEndsAt: nil, mode: nil),
            activeRateLimit: nil, scheduledResumes: [], pendingInterventions: [],
            relayState: .off, backends: [], configProblem: nil)
    }

    // MARK: refreshing

    func testASessionStartingOrEndingRefreshesTheVisibleTerminalsPageAtOnce() {
        let (s, r) = makeStore()
        s.selection = .terminals
        s.update(snapshot: coordinatorSnapshot([session("a")]), model: nil)
        XCTAssertEqual(r.probes.count, 1, "a new session is looked at straight away")
        r.probes[0].done(nil)
        s.update(snapshot: coordinatorSnapshot([session("a", state: .idle)]), model: nil)
        XCTAssertEqual(r.probes.count, 1, "a state change alone is not a new session")
        s.update(snapshot: coordinatorSnapshot([session("a"), session("b")]), model: nil)
        XCTAssertEqual(r.probes.count, 2)
        r.probes[1].done(nil)
        s.update(snapshot: coordinatorSnapshot([session("a"), session("b", state: .offline)]), model: nil)
        XCTAssertEqual(r.probes.count, 3, "an ended session changes the counts too")
    }

    func testSessionChangesAreIgnoredOffThePageOrWithTheWindowHidden() {
        let (s, r) = makeStore()
        s.selection = .power
        s.update(snapshot: coordinatorSnapshot([session("a")]), model: nil)
        s.selection = .terminals
        r.visible = false
        s.update(snapshot: coordinatorSnapshot([session("a"), session("b")]), model: nil)
        XCTAssertEqual(r.probes.count, 0)
    }

    func testOnlyOneProbeRunsAtATimeUnlessForced() {
        let (s, r) = makeStore()
        s.refreshTerminals()
        s.refreshTerminals()
        XCTAssertEqual(r.probes.count, 1)
        s.refreshTerminals(force: true)
        XCTAssertEqual(r.probes.count, 2)
    }

    func testAResultFromAnOlderProbeIsDropped() {
        let (s, r) = makeStore()
        s.refreshTerminals()
        s.refreshTerminals(force: true)
        r.probes[0].done(snapshot(kitty: false))
        XCTAssertNil(s.terminals)
        r.probes[1].done(snapshot(kitty: true))
        XCTAssertEqual(s.terminals, snapshot(kitty: true))
    }

    func testANilResultKeepsTheRowsWeHad() {
        let (s, r) = makeStore()
        s.refreshTerminals()
        r.probes[0].done(snapshot())
        s.refreshTerminals(force: true)
        r.probes[1].done(nil)
        XCTAssertEqual(s.terminals, snapshot())
    }

    func testTheLightTimerProbesOnlyOnTheTerminalsPageInAVisibleWindow() {
        let (s, r) = makeStore()
        s.refreshTerminalsIfVisible()
        XCTAssertEqual(r.probes.count, 0, "the page is not on screen")
        s.selection = .terminals
        r.visible = false
        s.refreshTerminalsIfVisible()
        XCTAssertEqual(r.probes.count, 0, "the window is hidden")
        r.visible = true
        s.refreshTerminalsIfVisible()
        XCTAssertEqual(r.probes.count, 1)
    }

    func testTerminalRowsAreEmptyUntilTheFirstSnapshot() {
        let (s, r) = makeStore()
        XCTAssertTrue(s.terminalRows.isEmpty)
        s.refreshTerminals()
        r.probes[0].done(snapshot())
        XCTAssertEqual(s.terminalRows.count, 8)
        XCTAssertEqual(s.terminalRows.first { $0.id == .wezterm }?.status, .ready)
    }

    func testLoadingTheTerminalsSectionStartsAProbe() {
        let (s, r) = makeStore()
        s.preview(terminalNotice: TowerStatusLine(text: "old", tone: .bad))
        s.load(section: .terminals)
        XCTAssertEqual(s.selection, .terminals)
        XCTAssertEqual(r.probes.count, 1)
        XCTAssertNil(s.terminalNotice)
    }

    func testLoadClearsTheTerminalNotice() {
        let (s, _) = makeStore()
        s.preview(terminalNotice: TowerStatusLine(text: "old", tone: .bad))
        s.load()
        XCTAssertNil(s.terminalNotice)
    }

    // MARK: kitty

    func testDecliningTheConfirmationChangesNothing() {
        let (s, r) = makeStore()
        r.previewResult = .success(preview(writePlan))
        r.confirmAnswer = false
        s.setUpKitty()
        XCTAssertEqual(r.confirms.count, 1)
        XCTAssertEqual(r.confirms.first?.title, "Turn on kitty remote control?")
        XCTAssertEqual(r.confirms.first?.ok, "Add the lines")
        XCTAssertTrue(r.confirms.first?.text.contains(KittyConfigFile.allowLine) == true)
        XCTAssertEqual(r.enableCalls, 0)
        XCTAssertNil(s.terminalNotice)
        XCTAssertTrue(r.alerts.isEmpty)
    }

    func testConfirmingWritesAndSaysWhatChanged() {
        let (s, r) = makeStore()
        let outcome = KittyConfigFile.Outcome(url: kittyURL, backup: URL(fileURLWithPath: "/k/kitty.conf.bak-page-x"),
                                              added: [KittyConfigFile.allowLine, KittyConfigFile.listenLine])
        r.previewResult = .success(preview(writePlan))
        r.confirmAnswer = true
        r.enableResult = .success(outcome)
        s.setUpKitty()
        XCTAssertEqual(r.enableCalls, 1)
        XCTAssertEqual(s.terminalNotice, C.kittyDoneText(outcome))
    }

    func testAConflictIsAnAlertAndNoQuestion() {
        let (s, r) = makeStore()
        let why = "kitty.conf line 1 says “allow_remote_control no”."
        r.previewResult = .success(preview(.conflict(why)))
        s.setUpKitty()
        XCTAssertEqual(r.alerts.first?.title, "kitty.conf already says something else")
        XCTAssertEqual(r.alerts.first?.text, why)
        XCTAssertTrue(r.confirms.isEmpty)
        XCTAssertEqual(r.enableCalls, 0)
    }

    func testAlreadyDoneIsAGoodNoticeAndAsksNothing() {
        let (s, r) = makeStore()
        r.previewResult = .success(preview(.alreadyDone))
        s.setUpKitty()
        XCTAssertEqual(s.terminalNotice?.tone, .good)
        XCTAssertTrue(r.confirms.isEmpty)
        XCTAssertEqual(r.enableCalls, 0)
    }

    func testASymlinkedKittyConfShowsTheReason() {
        let (s, r) = makeStore()
        r.previewResult = .failure(.symlink)
        s.setUpKitty()
        XCTAssertEqual(r.alerts.first?.title, "Couldn’t set up kitty")
        XCTAssertEqual(r.alerts.first?.text, KittyConfigFile.Failure.symlink.message)
    }

    // MARK: Automation

    func testADeniedAnswerOpensSystemSettingsWithABadNotice() {
        let (s, r) = makeStore()
        s.allowAutomation(.iTerm)
        XCTAssertEqual(r.automationCalls, [.iTerm])
        r.automationDone[0](.denied)
        XCTAssertEqual(r.opened, [TerminalProbe.automationSettingsURL])
        XCTAssertEqual(s.terminalNotice?.tone, .bad)
        XCTAssertTrue(s.terminalNotice?.text.contains("System Settings") == true)
    }

    func testAGrantedAnswerIsGoodAndRefreshesTheRows() {
        let (s, r) = makeStore()
        s.allowAutomation(.terminal)
        r.automationDone[0](.granted)
        XCTAssertEqual(s.terminalNotice?.tone, .good)
        XCTAssertTrue(r.opened.isEmpty)
        XCTAssertEqual(r.probes.count, 1, "a forced refresh after the answer")
    }

    // MARK: the row's one button

    func testGetItOpensTheSite() {
        let (s, r) = makeStore()
        let url = C.entry(.herdr).downloadURL
        s.perform(.getIt(url), on: .herdr)
        XCTAssertEqual(r.opened, [url])
    }

    func testSetUpOnCmuxOpensItsPageAndOnOtherHostsDoesNothing() {
        let (s, r) = makeStore()
        s.selection = .agents
        s.perform(.setUp(label: "Set up…"), on: .cmux)
        XCTAssertTrue(s.cmuxSetupOpen)
        XCTAssertEqual(s.selection, .terminals, "the cmux page lives under Terminals")
        s.closeCmuxSetup()
        s.perform(.setUp(label: "Set up…"), on: .wezterm)
        XCTAssertFalse(s.cmuxSetupOpen)
        XCTAssertTrue(r.alerts.isEmpty)
    }

    func testUndoTakesThePageLinesOutAndSaysWhetherItDid() {
        let (s, r) = makeStore()
        r.undoResult = true
        s.perform(.undo, on: .kitty)
        XCTAssertEqual(r.undoCalls, 1)
        XCTAssertEqual(s.terminalNotice?.tone, .good)
        r.undoResult = false
        s.perform(.undo, on: .kitty)
        XCTAssertEqual(s.terminalNotice?.tone, .bad)
    }

    func testAllowFromARowAsksMacOS() {
        let (s, r) = makeStore()
        s.perform(.allow, on: .terminal)
        XCTAssertEqual(r.automationCalls, [.terminal])
    }
}

/// The control map's Terminals entries are actions, never form fields.
final class TowerTerminalsControlMapTests: XCTestCase {
    func testTheTerminalsPageHasControlHomesThatAreActions() {
        let entries = TowerControlMap.entries.filter { $0.section == .terminals }
        XCTAssertGreaterThanOrEqual(entries.count, 1)
        for entry in entries {
            XCTAssertTrue(entry.old.hasPrefix("action:"), entry.old)
        }
    }

    func testTheTerminalsPageAddsNoFormField() {
        XCTAssertEqual(TowerControlMap.fieldNames.count, 35)
        XCTAssertFalse(TowerControlMap.fieldNames.contains { $0.lowercased().contains("terminal") })
    }
}
