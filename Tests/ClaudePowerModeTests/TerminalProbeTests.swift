import XCTest
@testable import ClaudePowerMode

/// The probe's pure parts (macOS Automation answers, setup states, bundle
/// ids) and `gather` with fakes only: no Automation prompt, no process table,
/// no installed-app check, no cmux CLI, no Keychain. Terminal and iTerm2 count
/// as installed; everything else only when a session runs there.
final class TerminalProbeTests: XCTestCase {
    private typealias P = TerminalProbe
    private typealias C = TerminalCatalog

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var conf: URL { dir.appendingPathComponent("kitty.conf") }

    private func session(_ id: String, state: AgentSessionState = .active) -> AgentSession {
        AgentSession(backend: .claude, sessionId: id, cwd: "/tmp/\(id)", title: id, source: .terminal, state: state,
                     lastActivityAt: nil, activeFlags: [], supportsRemoteReply: true)
    }

    private func host(_ name: String, canType: Bool = true) -> SessionHostInfo {
        SessionHostInfo(host: name, canType: canType, typeBlocker: canType ? nil : "blocked", canInterrupt: canType)
    }

    /// `TerminalProbe.gather` with every machine-dependent seam faked.
    private func gather(sessions: [AgentSession],
                        probeHosts: ([AgentSession]) -> [String: SessionHostInfo],
                        automation: (String) -> P.Automation,
                        kittyURL: URL,
                        isInstalled: (C.ID) -> Bool = { $0 == .terminal || $0 == .iTerm },
                        cmuxSetup: (Bool) -> C.SetupState = { _ in .unchecked },
                        kittyPIDs: () -> [Int32] = { [] },
                        socketExists: (String) -> Bool = { _ in false }) -> P.Snapshot {
        P.gather(sessions: sessions, probeHosts: probeHosts, automation: automation, kittyURL: kittyURL,
                 isInstalled: isInstalled, cmuxSetup: cmuxSetup, kittyPIDs: kittyPIDs, socketExists: socketExists)
    }

    private func cmuxStatus(_ mode: CmuxBridge.SocketMode) -> CmuxBridge.SocketStatus {
        CmuxBridge.SocketStatus(effectiveMode: mode, configuredMode: mode, socketPath: nil, socketPathState: nil)
    }

    // MARK: pure

    func testOSStatusMapsToAutomationAnswers() {
        XCTAssertEqual(P.automation(osStatus: 0), .granted)
        XCTAssertEqual(P.automation(osStatus: -1743), .denied)
        XCTAssertEqual(P.automation(osStatus: -1744), .notAsked)
        XCTAssertEqual(P.automation(osStatus: -600), .appNotRunning)
        XCTAssertEqual(P.automation(osStatus: 1), .unknown)
        XCTAssertEqual(P.automation(osStatus: -1), .unknown)
    }

    func testGrantedIsDone() {
        XCTAssertEqual(P.setupState(.granted, appName: "Terminal"), .done)
    }

    func testDeniedAndNotAskedAreNeededAndNameTheApp() {
        for access in [P.Automation.denied, .notAsked] {
            guard case .needed(let why) = P.setupState(access, appName: "iTerm2") else {
                return XCTFail("expected needed for \(access)")
            }
            XCTAssertTrue(why.contains("iTerm2"), why)
        }
    }

    func testNotRunningOrUnknownIsUnchecked() {
        XCTAssertEqual(P.setupState(.appNotRunning, appName: "Terminal"), .unchecked)
        XCTAssertEqual(P.setupState(.unknown, appName: "Terminal"), .unchecked)
    }

    func testOnlyTerminalAndITermHaveBundleIdentifiers() {
        XCTAssertEqual(P.bundleIdentifier(.terminal), "com.apple.Terminal")
        XCTAssertEqual(P.bundleIdentifier(.iTerm), "com.googlecode.iterm2")
        for id in C.ID.allCases where id != .terminal && id != .iTerm {
            XCTAssertNil(P.bundleIdentifier(id), "\(id)")
        }
    }

    // MARK: gather (fakes only)

    func testOfflineSessionsAreNeverSentToTheProbe() {
        var asked: [String] = []
        _ = gather(sessions: [session("gone", state: .offline), session("live")],
                     probeHosts: { sessions in
                         asked = sessions.map(\.sessionId)
                         return [:]
                     },
                     automation: { _ in .unknown }, kittyURL: conf)
        XCTAssertEqual(asked, ["live"])
    }

    func testWithOnlyOfflineSessionsTheProbeIsNotRun() {
        var calls = 0
        _ = gather(sessions: [session("gone", state: .offline)],
                     probeHosts: { _ in
                         calls += 1
                         return [:]
                     },
                     automation: { _ in .unknown }, kittyURL: conf)
        XCTAssertEqual(calls, 0)
    }

    func testEveryHostGetsFacts() {
        let f = gather(sessions: [], probeHosts: { _ in [:] }, automation: { _ in .unknown }, kittyURL: conf)
        XCTAssertEqual(Set(f.facts.keys), Set(C.ID.allCases))
    }

    func testTmuxFactsComeFromTheSessionsHosts() {
        let tmux = host("tmux")
        let f = gather(sessions: [session("a"), session("b")],
                         probeHosts: { _ in ["a": tmux, "b": tmux] },
                         automation: { _ in .unknown }, kittyURL: conf)
        XCTAssertEqual(f.facts[.tmux]?.use.typable, 2)
        XCTAssertEqual(f.facts[.tmux]?.setup, .notNeeded)
    }

    func testTerminalWithAutomationDeniedNeedsSetup() {
        var asked: [String] = []
        let f = gather(sessions: [session("a")],
                         probeHosts: { _ in ["a": host("tmux")] },
                         automation: { bundle in
                             asked.append(bundle)
                             return bundle == "com.apple.Terminal" ? .denied : .granted
                         },
                         kittyURL: conf)
        guard case .needed? = f.facts[.terminal]?.setup else {
            return XCTFail("Terminal should need setup, got \(String(describing: f.facts[.terminal]?.setup))")
        }
        XCTAssertTrue(asked.contains("com.apple.Terminal"))
        XCTAssertTrue(Set(asked).isSubset(of: ["com.apple.Terminal", "com.googlecode.iterm2"]), "\(asked)")
    }

    func testTerminalWithAutomationGrantedIsDone() {
        let f = gather(sessions: [session("a")],
                         probeHosts: { _ in ["a": host("tmux")] },
                         automation: { _ in .granted }, kittyURL: conf)
        XCTAssertEqual(f.facts[.terminal]?.setup, .done)
    }

    func testKittyWithNoConfigNeedsSetupOnceItRuns() {
        let f = gather(sessions: [session("k")],
                         probeHosts: { _ in ["k": host("kitty")] },
                         automation: { _ in .unknown }, kittyURL: conf)
        XCTAssertEqual(f.facts[.kitty]?.installed, true)
        guard case .needed? = f.facts[.kitty]?.setup else {
            return XCTFail("kitty should need setup, got \(String(describing: f.facts[.kitty]?.setup))")
        }
        XCTAssertFalse(f.pageAddedKittyLines)
    }

    func testAPageWrittenKittyConfSetsTheUndoFlagAndDone() throws {
        _ = try KittyConfigFile.enable(url: conf).get()
        let f = gather(sessions: [session("k")],
                         probeHosts: { _ in ["k": host("kitty")] },
                         automation: { _ in .unknown }, kittyURL: conf)
        XCTAssertTrue(f.pageAddedKittyLines)
        XCTAssertEqual(f.facts[.kitty]?.setup, .done)
    }

    func testNothingInstalledAndNoSessionsMeansNothingIsInstalled() {
        let f = gather(sessions: [], probeHosts: { _ in [:] }, automation: { _ in .unknown }, kittyURL: conf,
                       isInstalled: { _ in false })
        for entry in C.entries { XCTAssertEqual(f.facts[entry.id]?.installed, false, entry.name) }
        XCTAssertEqual(f.facts[.terminal]?.setup, .unchecked)
    }

    func testCmuxFactsComeFromTheInjectedCheck() {
        var asked: [Bool] = []
        let f = gather(sessions: [], probeHosts: { _ in [:] }, automation: { _ in .unknown }, kittyURL: conf,
                       isInstalled: { $0 == .cmux },
                       cmuxSetup: { installed in asked.append(installed); return .done })
        XCTAssertEqual(f.facts[.cmux]?.setup, .done)
        XCTAssertEqual(asked, [true])
    }

    // MARK: kitty restart

    func testSocketPathFillsInThePid() {
        XCTAssertEqual(KittyConfigFile.socketPath(listenOn: "unix:/tmp/kitty-{kitty_pid}", pid: 42), "/tmp/kitty-42")
        XCTAssertEqual(KittyConfigFile.socketPath(listenOn: "unix:/tmp/mine", pid: 42), "/tmp/mine")
        XCTAssertNil(KittyConfigFile.socketPath(listenOn: "unix:@abstract", pid: 42))
        XCTAssertNil(KittyConfigFile.socketPath(listenOn: "unix:/tmp/{kitty_window_id}", pid: 42))
        XCTAssertNil(KittyConfigFile.socketPath(listenOn: "tcp:localhost:1", pid: 42))
    }

    func testARunningKittyWithNoSocketNeedsARestart() {
        let state = P.kittySetup(.done, listenOn: KittyConfigFile.listenLine.replacingOccurrences(of: "listen_on ", with: ""),
                                 pids: [42], socketExists: { _ in false })
        XCTAssertEqual(state, .needsRestart)
    }

    func testARunningKittyWithItsSocketIsDone() {
        var checked: [String] = []
        let state = P.kittySetup(.done, listenOn: "unix:/tmp/kitty-{kitty_pid}", pids: [42],
                                 socketExists: { checked.append($0); return true })
        XCTAssertEqual(state, .done)
        XCTAssertEqual(checked, ["/tmp/kitty-42"])
    }

    func testKittyNotRunningOrSocketUnknownOrSetupNotDoneIsLeftAlone() {
        XCTAssertEqual(P.kittySetup(.done, listenOn: "unix:/tmp/kitty-{kitty_pid}", pids: [], socketExists: { _ in false }), .done)
        XCTAssertEqual(P.kittySetup(.done, listenOn: "unix:@x", pids: [1], socketExists: { _ in false }), .done)
        XCTAssertEqual(P.kittySetup(.done, listenOn: nil, pids: [1], socketExists: { _ in false }), .done)
        let needed = C.SetupState.needed("x")
        XCTAssertEqual(P.kittySetup(needed, listenOn: "unix:/tmp/kitty-{kitty_pid}", pids: [1], socketExists: { _ in false }), needed)
    }

    func testGatherMarksARunningKittyWithoutASocketAsNeedingARestart() throws {
        _ = try KittyConfigFile.enable(url: conf).get()
        let f = gather(sessions: [], probeHosts: { _ in [:] }, automation: { _ in .unknown }, kittyURL: conf,
                       isInstalled: { $0 == .kitty }, kittyPIDs: { [77] }, socketExists: { $0 == "/tmp/kitty-77" })
        XCTAssertEqual(f.facts[.kitty]?.setup, .done)
        let g = gather(sessions: [], probeHosts: { _ in [:] }, automation: { _ in .unknown }, kittyURL: conf,
                       isInstalled: { $0 == .kitty }, kittyPIDs: { [77] }, socketExists: { _ in false })
        XCTAssertEqual(g.facts[.kitty]?.setup, .needsRestart)
    }

    // MARK: cmux

    func testCmuxModesThatAdmitPageAreDone() {
        XCTAssertEqual(P.cmuxSetupState(cmuxStatus(.automation), passwordSaved: false), .done)
        XCTAssertEqual(P.cmuxSetupState(cmuxStatus(.allowAll), passwordSaved: false), .done)
    }

    func testCmuxPasswordModeIsDoneOnlyWithASavedPassword() {
        XCTAssertEqual(P.cmuxSetupState(cmuxStatus(.password), passwordSaved: true), .done)
        guard case .needed(let why) = P.cmuxSetupState(cmuxStatus(.password), passwordSaved: false) else {
            return XCTFail("expected needed")
        }
        XCTAssertTrue(why.contains("no password"), why)
        XCTAssertTrue(why.contains("Click Set up…"), why)
    }

    func testCmuxModesThatKeepPageOutNeedSetup() {
        for mode in [CmuxBridge.SocketMode.off, .cmuxOnly, .unknown("x")] {
            guard case .needed(let why) = P.cmuxSetupState(cmuxStatus(mode), passwordSaved: true) else {
                return XCTFail("expected needed for \(mode)")
            }
            XCTAssertTrue(why.contains("Click Set up…"), why)
        }
    }

    func testAFailedCmuxStatusIsNotDone() {
        guard case .needed(let why) = P.cmuxSetupState(nil, passwordSaved: false) else { return XCTFail("expected needed") }
        XCTAssertTrue(why.contains("couldn't read"), why)
    }
}
