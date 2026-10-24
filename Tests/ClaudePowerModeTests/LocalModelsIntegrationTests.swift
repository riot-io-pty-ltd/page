import XCTest
@testable import ClaudePowerMode

/// How local-model activity feeds keep-awake, the menu and config.
final class LocalModelsIntegrationTests: XCTestCase {
    private func activity(_ id: String, busy: Bool, signal: LocalActivity.Signal = .exact,
                          detail: String? = nil) -> LocalActivity {
        LocalActivity(id: id, displayName: id, kind: .server, busy: busy, signal: signal,
                      detail: detail ?? (busy ? "generating · exact" : "idle"))
    }

    private func snap(wantsPower: Bool, sessions: [AgentSession] = []) -> AgentBackendSnapshot {
        AgentBackendSnapshot(backendID: .claude, displayName: "Claude", sessions: sessions,
                             wantsPowerAssertion: wantsPower, pendingInterventions: [])
    }

    func testBusyLocalActivityWantsKeepAwake() {
        XCTAssertTrue(Coordinator.wantsKeepAwake([snap(wantsPower: false)], local: [activity("Ollama", busy: true)]))
        XCTAssertTrue(Coordinator.wantsKeepAwake([snap(wantsPower: true)], local: []))
    }

    /// The core rule: a loaded but idle model never keeps the Mac awake.
    func testIdleLocalActivityDoesNotWantKeepAwake() {
        XCTAssertFalse(Coordinator.wantsKeepAwake([snap(wantsPower: false)],
                                                  local: [activity("Ollama", busy: false), activity("LM Studio", busy: false)]))
        XCTAssertFalse(Coordinator.wantsKeepAwake([], local: []))
    }

    /// Local generation never enables lid-closed on battery: only agent
    /// sessions mid-turn do.
    func testLocalActivityIsNotAgentsWorking() {
        XCTAssertFalse(Coordinator.agentsWorking([snap(wantsPower: false)]))
    }

    func testStatusLineNamesBusyLocalModel() {
        var s = Coordinator.Snapshot(
            sessions: [], power: PowerSnapshot(percent: 80, onAC: true, hasBattery: true, isCharging: true),
            awake: AwakeAssertions(preventIdleSleep: true, preventSystemSleep: false),
            lidClosedOnBattery: false, lidClosedOnBatteryBlocker: nil, battery: .normal, activeRateLimit: nil,
            scheduledResumes: [], pendingInterventions: [], relayState: .off, backends: [], configProblem: nil)
        XCTAssertEqual(s.statusLine, "Keeping awake")
        s.localModels = [activity("LM Studio", busy: false), activity("Ollama", busy: true)]
        XCTAssertEqual(s.statusLine, "Keeping awake (Ollama working)")
    }

    func testMenuLinesPutBusyFirstAndKeepOrder() {
        let lines = LocalActivity.menuLines([
            activity("LM Studio", busy: false),
            activity("Ollama", busy: true),
            activity("opencode", busy: true, signal: .terminalOutput, detail: "working · terminal output"),
        ])
        XCTAssertEqual(lines, ["Ollama — generating · exact", "opencode — working · terminal output", "LM Studio — idle"])
        XCTAssertEqual(LocalActivity.menuLines([]), [])
    }

    func testConfigDefaultsOnAndDecodesOldFiles() throws {
        XCTAssertTrue(Config().localModelsEnabled)
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertTrue(old.localModelsEnabled)
        let off = try JSONDecoder().decode(Config.self, from: Data(#"{"localModelsEnabled": false}"#.utf8))
        XCTAssertFalse(off.localModelsEnabled)
        let wrongType = try JSONDecoder().decode(Config.self, from: Data(#"{"localModelsEnabled": "nope"}"#.utf8))
        XCTAssertTrue(wrongType.localModelsEnabled)
    }

    func testPreferencesFormMergesOnlyChangedLocalToggle() {
        let base = Config()
        var form = PreferencesForm(base)
        let baseline = form
        form.localModelsEnabled = false
        XCTAssertFalse(form.merged(onto: base, changedFrom: baseline).localModelsEnabled)
        // Untouched in the form: a hand edit to config.json survives Save.
        var edited = base
        edited.localModelsEnabled = false
        XCTAssertFalse(PreferencesForm(base).merged(onto: edited, changedFrom: PreferencesForm(base)).localModelsEnabled)
    }
}
