import XCTest
@testable import ClaudePowerMode

/// The Night Watch dialog's pure parts, and the pages that used to be windows
/// (Phone approvals, cmux setup, pairing): what they say, and that they do
/// nothing until asked.
final class NWDialogAndPagesTests: XCTestCase {
    // MARK: dialog

    func testNoticeHasOneButtonThatEscAlsoPresses() {
        let n = NWDialogSpec.notice("Couldn’t save", "why")
        XCTAssertEqual(n.buttons.map(\.title), ["OK"])
        XCTAssertEqual(n.cancelIndex, 0)
        XCTAssertEqual(n.tone, .warning)
    }

    func testConfirmPutsTheActionFirstAndCancelLast() {
        let c = NWDialogSpec.confirm("Install?", "x", ok: "Install")
        XCTAssertEqual(c.buttons.map(\.title), ["Install", "Cancel"])
        XCTAssertEqual(c.buttons.map(\.role), [.primary, .secondary])
        XCTAssertEqual(c.cancelIndex, 1, "Esc is Cancel, as in NSAlert")
        XCTAssertEqual(NWDialogSpec.confirm("R", "x", ok: "Regenerate", destructive: true).buttons[0].role, .destructive)
    }

    func testIndentedParagraphsBecomeMonoBlocks() {
        let text = TerminalCatalog.kittyConfirmText(path: "/k/kitty.conf", added: ["allow_remote_control socket-only", "listen_on unix:/tmp/kitty"],
                                                    creating: false)
        let blocks = NWDialogBody.blocks(text)
        XCTAssertTrue(blocks.contains(.mono("allow_remote_control socket-only\nlisten_on unix:/tmp/kitty")))
        XCTAssertEqual(blocks.filter { if case .text = $0 { return true } else { return false } }.count, 3)
        XCTAssertEqual(NWDialogBody.blocks("one\n\ntwo"), [.text("one"), .text("two")])
    }

    func testDiffLinesAreClassified() {
        XCTAssertEqual(NWDialogBody.diffKind("--- a"), .header)
        XCTAssertEqual(NWDialogBody.diffKind("+++ b"), .header)
        XCTAssertEqual(NWDialogBody.diffKind("@@ -1 +1 @@"), .hunk)
        XCTAssertEqual(NWDialogBody.diffKind("+x"), .added)
        XCTAssertEqual(NWDialogBody.diffKind("-x"), .removed)
        XCTAssertEqual(NWDialogBody.diffKind(" x"), .context)
    }

    func testTheDefaultDialogPressesCancelSoNothingIsConfirmedByAHarness() {
        let env = TowerEnvironment()
        XCTAssertEqual(env.runDialog(.confirm("x", "y", ok: "Do it")), 1)
        XCTAssertEqual(env.runDialog(.notice("x", "y")), 0)
    }

    // MARK: phone approvals

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("nwpages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try "{\n  \"theme\": \"dark\"\n}\n".write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func hookStore(answer: Int, dialogs: @escaping (NWDialogSpec) -> Void = { _ in }) -> TowerStore {
        var env = TowerEnvironment()
        let installer = HookInstaller(homeDirectory: home, scriptPath: "/Applications/Page.app/Contents/Resources/hooks/page-notify.sh")
        env.hookSource = { TowerHookSource(installer: installer, scriptPath: installer.scriptPath) }
        env.runDialog = { spec in dialogs(spec); return spec.buttons.count > 1 ? answer : 0 }
        return TowerStore(config: Config(), macName: "Mac", env: env)
    }

    func testThePageReadsNothingUntilItIsOpened() {
        let s = TowerStore()
        s.hooks.refresh()
        XCTAssertEqual(s.hooks.claude, TowerHooksModel.AgentRow(), "no hook source: nothing is read")
        XCTAssertEqual(s.hooks.preview, TowerHooksModel.Preview())
    }

    func testRefreshReadsTheHookFilesAndPreviewsTheDiff() {
        let s = hookStore(answer: 1)
        s.hooks.refresh()
        XCTAssertEqual(s.hooks.claude.chip, .notInstalled)
        XCTAssertTrue(s.hooks.claude.canInstall)
        XCTAssertFalse(s.hooks.claude.canUninstall)
        XCTAssertEqual(s.hooks.codex.chip, .unavailable, "no ~/.codex in the temp home")
        XCTAssertTrue(s.hooks.preview.isDiff)
        XCTAssertTrue(s.hooks.preview.text.contains("+"))
    }

    func testCancellingTheConfirmationWritesNothing() throws {
        var shown: [NWDialogSpec] = []
        let s = hookStore(answer: 1) { shown.append($0) }
        let before = try String(contentsOf: home.appendingPathComponent(".claude/settings.json"))
        s.hooks.run(.install, .claude)
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown[0].title, "Install Page's Claude Code hooks?")
        XCTAssertEqual(shown[0].buttons.map(\.title), ["Install", "Cancel"])
        if case .diff(let d)? = shown[0].detail { XCTAssertTrue(d.contains("PermissionRequest")) } else { XCTFail("no diff shown") }
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".claude/settings.json")), before)
    }

    func testConfirmingInstallsWithABackupThenUninstallRemoves() throws {
        var titles: [String] = []
        let s = hookStore(answer: 0) { titles.append($0.title) }
        s.hooks.run(.install, .claude)
        XCTAssertEqual(titles, ["Install Page's Claude Code hooks?", "Hooks installed"])
        XCTAssertEqual(s.hooks.claude.chip, .installed)
        XCTAssertEqual(s.hooks.claude.installTitle, "Reinstall…")
        let files = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".claude").path)
        XCTAssertTrue(files.contains { $0.contains("page-backup") }, "the old file was saved first")
        titles = []
        s.hooks.run(.install, .claude)
        XCTAssertEqual(titles, ["Already up to date"])
        titles = []
        s.hooks.run(.uninstall, .claude)
        XCTAssertEqual(titles, ["Remove Page's Claude Code hooks?", "Hooks removed"])
        XCTAssertEqual(s.hooks.claude.chip, .notInstalled)
    }

    func testHookCopy() {
        XCTAssertEqual(TowerHookText.describe(HookStatus(state: .installed, codexStopEnabled: true), agent: .codex),
                       "Installed (approvals and reply-to-continue).")
        XCTAssertNil(TowerHookText.cmuxNote(CmuxHookInfo()))
        XCTAssertTrue(TowerHookText.cmuxNote(CmuxHookInfo(settingsFiles: 1, withPermissionRequestHook: 1))!.contains("(1 found)"))
        XCTAssertNil(TowerHookText.codexWarning(CodexConfigInfo()))
        XCTAssertEqual(TowerHookText.displayPath(URL(fileURLWithPath: "/Users/a/.claude/settings.json"), home: "/Users/a"), "~/.claude/settings.json")
    }

    // MARK: entry points

    func testEntryPointsRouteToThePages() {
        let s = TowerStore()
        s.openPhoneApprovals()
        XCTAssertEqual(s.selection, .phoneApprovals)
        s.openPairing()
        XCTAssertEqual(s.selection, .pairing)
        s.openCmuxSetup()
        XCTAssertEqual(s.selection, .terminals)
        XCTAssertTrue(s.cmuxSetupOpen)
        s.load(section: .power)
        XCTAssertFalse(s.cmuxSetupOpen, "opening the Tower at another page leaves the cmux page")
    }

    // MARK: pairing

    func testPairingShowsTheQrOnlyForAUsableRelayAndClearsItOtherwise() {
        var info: TowerPairingBackend.Info = .ready(base: URL(string: "https://r.example.workers.dev")!, payload: "{\"x\":1}")
        var probes = 0
        var env = TowerEnvironment()
        env.pairing.info = { info }
        env.pairing.probeHealth = { _, _ in probes += 1 }
        let s = TowerStore(env: env)
        s.pairing.refresh()
        XCTAssertEqual(s.pairing.state, .ready(host: "r.example.workers.dev"))
        XCTAssertEqual(s.pairing.payload, "{\"x\":1}")
        XCTAssertNotNil(s.pairing.qr)
        XCTAssertEqual(probes, 1)
        info = .setupNeeded(reason: "off")
        s.pairing.refresh()
        XCTAssertEqual(s.pairing.payload, "", "an unusable relay leaves no payload to copy")
        XCTAssertNil(s.pairing.qr)
        XCTAssertEqual(probes, 1, "the relay is not probed when it is unusable")
    }

    func testAStaleHealthAnswerIsDropped() {
        var done: [(String, Bool) -> Void] = []
        var env = TowerEnvironment()
        env.pairing.info = { .ready(base: URL(string: "https://r.example.workers.dev")!, payload: "p") }
        env.pairing.probeHealth = { _, d in done.append(d) }
        let s = TowerStore(env: env)
        s.pairing.refresh()
        s.pairing.refresh()
        done[0]("✗ old", false)
        XCTAssertEqual(s.pairing.health, .checking)
        done[1]("✓ Relay is reachable", true)
        XCTAssertEqual(s.pairing.health, .result(text: "✓ Relay is reachable", ok: true))
    }

    func testRegenerateAsksFirstAndThenShowsTheNewQr() {
        var regenerated = 0
        var answer = 1
        var asked: [NWDialogSpec] = []
        var env = TowerEnvironment()
        env.pairing.info = { .ready(base: URL(string: "https://r.example.workers.dev")!, payload: "p\(regenerated)") }
        env.pairing.regenerate = { regenerated += 1 }
        env.runDialog = { asked.append($0); return answer }
        let s = TowerStore(env: env)
        s.pairing.refresh()
        s.pairing.regenerate()
        XCTAssertEqual(regenerated, 0, "Cancel leaves the token alone")
        answer = 0
        s.pairing.regenerate()
        XCTAssertEqual(regenerated, 1)
        XCTAssertEqual(s.pairing.payload, "p1", "the QR is rebuilt from the new token")
        XCTAssertEqual(asked.first?.title, "Regenerate the pairing token?")
        XCTAssertEqual(asked.first?.buttons.map(\.title), ["Regenerate", "Cancel"])
    }

    func testCopyDoesNothingWithoutAPayload() {
        var copied: [String] = []
        var env = TowerEnvironment()
        env.pairing.copy = { copied.append($0) }
        let s = TowerStore(env: env)
        s.pairing.copyPayload()
        XCTAssertTrue(copied.isEmpty)
        s.pairing.setFixture(state: .ready(host: "h"), payload: "abc")
        s.pairing.copyPayload()
        XCTAssertEqual(copied, ["abc"])
    }

    func testPairingCopy() {
        XCTAssertEqual(TowerPairingModel.macLine(.connected), "This Mac is connected to the relay.")
        XCTAssertEqual(TowerPairingModel.macLine(nil), "")
        XCTAssertTrue(TowerPairingModel.setupReason(relayEnabled: false, urlProblem: nil).hasPrefix("Phone paging is turned off."))
        XCTAssertTrue(TowerPairingModel.setupReason(relayEnabled: true, urlProblem: "Use https://").hasPrefix("Use https://"))
        let url = URL(string: "https://r.example.workers.dev")!
        XCTAssertEqual(TowerPairingModel.healthText(base: url, data: Data("{\"ok\":true}".utf8),
                                                    response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil),
                                                    error: nil).text, "✓ Relay is reachable")
        XCTAssertEqual(TowerPairingModel.healthText(base: url, data: Data("{}".utf8),
                                                    response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil),
                                                    error: nil).ok, false)
        XCTAssertEqual(TowerPairingModel.healthText(base: url, data: nil,
                                                    response: HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil),
                                                    error: nil).text, "✗ The relay answered HTTP 503")
    }

    // MARK: cmux

    func testTheCmuxPageDoesNotProbeWithoutASecretStore() {
        let s = TowerStore()
        s.openCmuxSetup()
        XCTAssertEqual(s.cmux.version.text, "cmux: checking…", "no cmux command ran")
        XCTAssertTrue(s.cmux.testStatus.text.isEmpty)
    }
}
