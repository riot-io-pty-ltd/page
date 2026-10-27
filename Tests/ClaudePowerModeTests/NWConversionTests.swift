import XCTest
import AppKit
@testable import ClaudePowerMode

/// The Night Watch conversion's wiring: which button each dialog answers with,
/// what every hook row shows for each installer state (from real files in a
/// temp home), the cmux password steps against a fake Keychain, the pairing
/// health copy, and that each old entry point lands on its page.
///
/// Nothing here runs cmux, reads the real Keychain, touches the network, or
/// shows a modal dialog. The cmux fake never reaches `open()`, `testConnection()`
/// or `enableForPage()`, which would run the real cmux CLI.
final class NWConversionTests: XCTestCase {
    private var home: URL!
    private let script = "/Applications/Page.app/Contents/Resources/hooks/page-notify.sh"
    private let otherScript = "/Users/me/Downloads/Page.app/Contents/Resources/hooks/page-notify.sh"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("nwconv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func writeClaude(_ text: String) throws {
        let dir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    }

    private func claudeFile() throws -> String {
        try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8)
    }

    /// A store over the temp home. `located` is the hook script Page "found" (nil: not found).
    /// Every dialog is recorded, and answered with `answer` when it has more than one button.
    /// Callers keep the returned store in a local: the hooks model holds it weakly.
    private func store(located: String? = "/Applications/Page.app/Contents/Resources/hooks/page-notify.sh",
                       answer: Int = 1, shown: @escaping (NWDialogSpec) -> Void = { _ in }) -> TowerStore {
        var env = TowerEnvironment()
        let installer = HookInstaller(homeDirectory: home, scriptPath: located ?? "")
        env.hookSource = { TowerHookSource(installer: installer, scriptPath: located) }
        env.runDialog = { spec in shown(spec); return spec.buttons.count > 1 ? answer : 0 }
        return TowerStore(env: env)
    }

    // MARK: the dialog's answers

    func testCancelIsTheLastButtonForEveryDialogSize() {
        XCTAssertEqual(NWDialogSpec.notice("t", "b").cancelIndex, 0, "a lone OK takes Esc too")
        XCTAssertEqual(NWDialogSpec.confirm("t", "b", ok: "Turn On").cancelIndex, 1)
        let three = NWDialogSpec(title: "t", body: "b", buttons: [.init(title: "Save", role: .primary),
                                                                  .init(title: "Don't save", role: .secondary),
                                                                  .init(title: "Cancel", role: .secondary)])
        XCTAssertEqual(three.cancelIndex, 2, "Esc presses the last button, which is Cancel")
        XCTAssertEqual(NWDialogSpec(title: "t", body: "b", buttons: []).cancelIndex, 0)
    }

    func testEscOnThePanelCancelsRatherThanActivatingTheDialog() {
        let panel = NWDialogPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        var answers: [Int] = []
        panel.onCancel = { answers.append(NWDialogSpec.confirm("t", "b", ok: "Turn On").cancelIndex) }
        panel.cancelOperation(nil)
        XCTAssertEqual(answers, [1], "Esc answers Cancel, as NSAlert did")
        XCTAssertTrue(panel.canBecomeKey, "the panel takes the keys")
        XCTAssertFalse(panel.canBecomeMain)
    }

    func testTheDialogCentresOnTheScreenWhenTheTowerIsNotOnScreen() {
        let size = CGSize(width: 460, height: 300)
        let hidden = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: true)
        XCTAssertEqual(NWDialog.origin(for: size, over: hidden), NWDialog.origin(for: size, over: nil),
                       "a window that is not on screen is ignored")
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(NWDialog.origin(for: size, over: nil).x + size.width / 2, area.midX, accuracy: 0.5)
    }

    func testHookConfirmationsAnswerInstallOrCancelWithTheActionFirst() throws {
        try writeClaude("{}\n")
        var shown: [NWDialogSpec] = []
        let s = store(answer: 0) { shown.append($0) }
        s.hooks.run(.install, .claude)
        // The question comes first; the "Hooks installed" notice follows it.
        XCTAssertEqual(shown.first?.buttons.map(\.title), ["Install", "Cancel"], "Return installs, Esc cancels")
        XCTAssertEqual(shown.first?.buttons.map(\.role), [.primary, .secondary])
        XCTAssertEqual(shown.first?.tone, .info)
        XCTAssertEqual(shown.map(\.title), ["Install Page's Claude Code hooks?", "Hooks installed"])
    }

    func testRemoveConfirmationIsTheDestructiveOneAndWarns() throws {
        try writeClaude("{}\n")
        var shown: [NWDialogSpec] = []
        let installed = store(answer: 0)
        installed.hooks.run(.install, .claude)
        let s = store(answer: 1) { shown.append($0) }
        s.hooks.run(.uninstall, .claude)
        XCTAssertEqual(shown.last?.title, "Remove Page's Claude Code hooks?")
        XCTAssertEqual(shown.last?.buttons.map(\.title), ["Remove", "Cancel"])
        XCTAssertEqual(shown.last?.buttons.first?.role, .destructive)
        XCTAssertEqual(shown.last?.tone, .warning)
        XCTAssertTrue(shown.last?.body.hasSuffix(" Other tools' hooks are left alone.") == true)
    }

    // MARK: hook rows, from real files

    func testNotInstalledRowOffersOnlyInstall() throws {
        try writeClaude("{\n  \"theme\": \"dark\"\n}\n")
        let s = store()
        s.hooks.refresh()
        let r = s.hooks.claude
        XCTAssertEqual(r.chip, .notInstalled)
        XCTAssertEqual(r.text, "Not installed.")
        XCTAssertEqual(r.installTitle, "Install…")
        XCTAssertTrue(r.canInstall)
        XCTAssertFalse(r.canUninstall)
    }

    func testInstalledRowOffersReinstallAndUninstall() throws {
        try writeClaude("{}\n")
        let first = store(answer: 0)
        first.hooks.run(.install, .claude)
        let s = store()
        s.hooks.refresh()
        let r = s.hooks.claude
        XCTAssertEqual(r.chip, .installed)
        XCTAssertEqual(r.text, "Installed.")
        XCTAssertEqual(r.installTitle, "Reinstall…")
        XCTAssertTrue(r.canInstall)
        XCTAssertTrue(r.canUninstall)
    }

    func testOutdatedRowOffersUpdateAndNamesWhatItReplaces() throws {
        try writeClaude("{}\n")
        let old = store(located: script, answer: 0)
        old.hooks.run(.install, .claude)
        let s = store(located: otherScript)
        s.hooks.refresh()
        let r = s.hooks.claude
        XCTAssertEqual(r.chip, .needsUpdate)
        XCTAssertEqual(r.installTitle, "Update…")
        XCTAssertTrue(r.canUninstall)
        XCTAssertTrue(r.text.hasPrefix("An older or partial Page hook is installed ("), r.text)
        XCTAssertTrue(r.text.hasSuffix("Update replaces it with the current one."), r.text)
    }

    func testUnreadableFileOffersNothingAndSaysWhy() throws {
        try writeClaude("{ not json")
        let s = store()
        s.hooks.refresh()
        XCTAssertEqual(s.hooks.claude.chip, .unavailable)
        XCTAssertFalse(s.hooks.claude.canInstall)
        XCTAssertFalse(s.hooks.claude.canUninstall)
        XCTAssertFalse(s.hooks.claude.text.isEmpty)
    }

    func testMissingAgentDisablesBothButtonsForBothAgents() {
        let s = store()
        s.hooks.refresh()
        XCTAssertEqual(s.hooks.claude.text, "Claude Code doesn't seem to be set up for this user (~/.claude is missing).")
        XCTAssertEqual(s.hooks.codex.text, "Codex doesn't seem to be set up for this user (~/.codex is missing).")
        for r in [s.hooks.claude, s.hooks.codex] {
            XCTAssertEqual(r.chip, .unavailable)
            XCTAssertFalse(r.canInstall)
            XCTAssertFalse(r.canUninstall)
        }
    }

    func testMissingScriptShowsWhyAndDisablesInstallButKeepsUninstallForAnInstalledHook() throws {
        try writeClaude("{}\n")
        let s = store(located: nil)
        s.hooks.refresh()
        XCTAssertEqual(s.hooks.claude.text, TowerHookText.scriptMissing)
        XCTAssertFalse(s.hooks.claude.canInstall)
        XCTAssertFalse(s.hooks.claude.canUninstall, "nothing is installed, so nothing to remove")
        XCTAssertEqual(s.hooks.preview.text, "Page's hook script wasn't found, so there's nothing to preview.")
        XCTAssertFalse(s.hooks.preview.isDiff)

        let installed = store(located: script, answer: 0)
        installed.hooks.run(.install, .claude)
        let broken = store(located: nil)
        broken.hooks.refresh()
        // Without the script the installed command can't be matched, so it reads as needing an update.
        XCTAssertEqual(broken.hooks.claude.chip, .needsUpdate)
        XCTAssertEqual(broken.hooks.claude.installTitle, "Update…")
        XCTAssertFalse(broken.hooks.claude.canInstall)
        XCTAssertTrue(broken.hooks.claude.canUninstall)
    }

    func testInstallWithoutTheScriptRefusesAndWritesNothing() throws {
        try writeClaude("{}\n")
        var titles: [String] = []
        let s = store(located: nil, answer: 0) { titles.append($0.title) }
        let before = try claudeFile()
        s.hooks.run(.install, .claude)
        XCTAssertEqual(try claudeFile(), before)
        XCTAssertEqual(titles, ["Can't install the Claude Code hooks"])
    }

    func testInstallForACodexThatIsNotSetUpSaysWhyAndWritesNothing() {
        var shown: [NWDialogSpec] = []
        let s = store(answer: 0) { shown.append($0) }
        s.hooks.run(.install, .codex)
        XCTAssertEqual(shown.map(\.title), ["Can't install the Codex hooks"])
        XCTAssertEqual(shown.first?.body, "~/.codex doesn't exist — run Codex once first.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path))
    }

    func testUninstallWithNoPageEntriesSaysSoAndAsksNothing() throws {
        try writeClaude("{}\n")
        var shown: [NWDialogSpec] = []
        let s = store(answer: 0) { shown.append($0) }
        s.hooks.run(.uninstall, .claude)
        XCTAssertEqual(shown.map(\.title), ["Nothing to remove"])
        XCTAssertEqual(shown.first?.tone, .info)
        XCTAssertEqual(shown.first?.buttons.count, 1, "a notice, not a question")
        XCTAssertTrue(shown.first?.body.hasSuffix("/.claude/settings.json has no Page hook entries.") == true)
    }

    func testCancellingUninstallLeavesTheHookInPlace() throws {
        try writeClaude("{}\n")
        let installed = store(answer: 0)
        installed.hooks.run(.install, .claude)
        let before = try claudeFile()
        let s = store(answer: 1)
        s.hooks.refresh()
        s.hooks.run(.uninstall, .claude)
        XCTAssertEqual(try claudeFile(), before)
        XCTAssertEqual(s.hooks.claude.chip, .installed)
    }

    func testCodexStopToggleIsReadBackFromTheFile() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let s = store(answer: 0)
        s.hooks.codexStop = true
        s.hooks.run(.install, .codex)
        XCTAssertEqual(s.hooks.codex.chip, .installed)
        s.hooks.codexStop = false
        s.hooks.refresh()
        XCTAssertTrue(s.hooks.codexStop, "the toggle follows the file, not the last click")
        XCTAssertEqual(s.hooks.codex.text, "Installed (approvals and reply-to-continue).")
    }

    func testComingBackRereadsPhoneApprovalsButNoOtherPage() throws {
        try writeClaude("{}\n")
        let s = store()
        s.selection = .phoneApprovals
        XCTAssertEqual(s.hooks.claude.chip, .notInstalled)
        let elsewhere = store(answer: 0)
        elsewhere.hooks.run(.install, .claude)
        s.windowBecameKey()
        XCTAssertEqual(s.hooks.claude.chip, .installed, "an edit made elsewhere shows up on return")

        s.selection = .power
        elsewhere.hooks.run(.uninstall, .claude)
        s.windowBecameKey()
        XCTAssertEqual(s.hooks.claude.chip, .installed, "other pages do not read the hook files on focus")
    }

    // MARK: the words

    func testConfirmationForANewFileSaysItWillBeCreated() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let plan = try HookInstaller(homeDirectory: home, scriptPath: script).planInstall(.claude)
        let spec = TowerHookText.confirmSpec(plan, action: .install, agent: .claude, path: "~/.claude/settings.json", diff: "d")
        XCTAssertEqual(spec.title, "Install Page's Claude Code hooks?")
        XCTAssertEqual(spec.body, "Page will change ~/.claude/settings.json as shown. The file doesn't exist yet and will be created.")
        XCTAssertEqual(spec.detail, .diff("d"))
        XCTAssertEqual(spec.tone, .info)
    }

    func testConfirmationForAnExistingFileNamesTheBackup() throws {
        try writeClaude("{}\n")
        let plan = try HookInstaller(homeDirectory: home, scriptPath: script).planInstall(.claude)
        let spec = TowerHookText.confirmSpec(plan, action: .install, agent: .claude, path: "~/.claude/settings.json", diff: "d")
        XCTAssertEqual(spec.body, "Page will change ~/.claude/settings.json as shown. The current file is saved first as settings.json.page-backup-<date> next to it.")
        XCTAssertFalse(spec.body.contains("Other tools"), "install does not say so")
    }

    func testDoneTextForEveryActionAndAgent() {
        XCTAssertEqual(TowerHookText.doneText(action: .install, agent: .codex, backupPath: "/p"),
                       "Now open Codex and run /hooks to trust Page's hook — Codex won't run it until you do.\n\nBackup: /p")
        XCTAssertEqual(TowerHookText.doneText(action: .install, agent: .codex, backupPath: nil),
                       "Now open Codex and run /hooks to trust Page's hook — Codex won't run it until you do.")
        XCTAssertEqual(TowerHookText.doneText(action: .install, agent: .claude, backupPath: nil),
                       "Claude Code picks this up automatically, including sessions that are already running.")
        XCTAssertEqual(TowerHookText.doneText(action: .uninstall, agent: .claude, backupPath: "/p"), "Backup: /p")
        XCTAssertEqual(TowerHookText.doneText(action: .uninstall, agent: .codex, backupPath: nil), "")
    }

    // MARK: pairing

    func testRelayHealthThatComesBackLateAfterTheRelayIsUnusableIsDropped() {
        var done: [(String, Bool) -> Void] = []
        var info: TowerPairingBackend.Info = .ready(base: URL(string: "https://r.example.workers.dev")!, payload: "p")
        var env = TowerEnvironment()
        env.pairing.info = { info }
        env.pairing.probeHealth = { _, d in done.append(d) }
        let s = TowerStore(env: env)
        s.pairing.refresh()
        info = .setupNeeded(reason: "Phone paging is turned off.")
        s.pairing.refresh()
        done[0]("✓ Relay is reachable", true)
        XCTAssertEqual(s.pairing.health, .idle, "a probe for a relay that is no longer set up changes nothing")
    }

    func testMacLineForEachRelayStateMatchesTheOldWindow() {
        XCTAssertEqual(TowerPairingModel.macLine(.connecting), "This Mac is connecting to the relay…")
        XCTAssertEqual(TowerPairingModel.macLine(.off), "This Mac isn’t using the relay.")
        XCTAssertEqual(TowerPairingModel.macLine(.misconfigured("bad URL")), "This Mac isn’t using the relay.")
    }

    func testSetupReasonPointsAtMacsAndPhonesAndNotAtOldPreferences() {
        XCTAssertEqual(TowerPairingModel.setupReason(relayEnabled: true, urlProblem: nil),
                       "The relay URL isn’t valid. Enter your Worker’s URL in Macs & phones.")
        let off = TowerPairingModel.setupReason(relayEnabled: false, urlProblem: "ignored")
        XCTAssertTrue(off.contains("Macs & phones"))
        XCTAssertFalse(off.contains("Preferences"))
        XCTAssertFalse(off.contains("ignored"), "a disabled relay names the switch, not the URL problem")
    }

    func testHealthCopyForANonRelayAnErrorAndAServerError() {
        let url = URL(string: "https://r.example.workers.dev")!
        func response(_ code: Int) -> HTTPURLResponse { HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)! }
        let notRelay = TowerPairingModel.healthText(base: url, data: Data("{\"ok\":\"yes\"}".utf8), response: response(200), error: nil)
        XCTAssertEqual(notRelay.text, "⚠ Reached r.example.workers.dev, but it doesn’t look like a Page relay")
        XCTAssertFalse(notRelay.ok, "a string ok is not the relay's ok: true")
        let offline = NSError(domain: NSURLErrorDomain, code: -1009,
                              userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        let failed = TowerPairingModel.healthText(base: url, data: nil, response: nil, error: offline)
        XCTAssertEqual(failed.text, "✗ Can’t reach the relay: The Internet connection appears to be offline.")
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(TowerPairingModel.healthText(base: url, data: nil, response: response(500), error: nil).text,
                       "✗ The relay answered HTTP 500")
    }

    // MARK: cmux

    func testSocketModeLineForEveryMode() {
        func status(_ m: CmuxBridge.SocketMode, configured: CmuxBridge.SocketMode? = nil) -> CmuxBridge.SocketStatus {
            CmuxBridge.SocketStatus(effectiveMode: m, configuredMode: configured, socketPath: nil, socketPathState: nil)
        }
        let goodModes: [CmuxBridge.SocketMode] = [.password, .automation, .allowAll]
        for m in goodModes {
            XCTAssertEqual(TowerCmuxModel.modeLine(status(m)).tone, .good, "\(m)")
        }
        let blockedModes: [CmuxBridge.SocketMode] = [.cmuxOnly, .off, .unknown("")]
        for m in blockedModes {
            let line = TowerCmuxModel.modeLine(status(m))
            XCTAssertEqual(line.tone, .warn, "\(m)")
            XCTAssertTrue(line.text.contains("cmux blocks Page. Follow the steps below."), line.text)
        }
        XCTAssertEqual(TowerCmuxModel.modeLine(status(.allowAll)).text,
                       "Socket mode: Full open access — Page can connect (no password needed).")
        XCTAssertEqual(TowerCmuxModel.modeLine(status(.password)).text,
                       "Socket mode: Password mode — Page can connect with the password below.")
        XCTAssertEqual(TowerCmuxModel.modeLine(status(.automation, configured: .password)).text,
                       "Socket mode: Automation mode — Page can connect (no password needed). (configured: Password mode)")
        XCTAssertEqual(TowerCmuxModel.modeLine(status(.password, configured: .password)).text,
                       "Socket mode: Password mode — Page can connect with the password below.", "no suffix when they agree")
    }

    private func cmuxStore(_ secrets: ConversionSecrets) -> TowerStore {
        var env = TowerEnvironment()
        env.cmuxSecrets = secrets
        return TowerStore(env: env)
    }

    func testPasswordLineForEachKeychainAnswer() {
        let secrets = ConversionSecrets()
        let s = cmuxStore(secrets)
        secrets.result = .found("x")
        s.cmux.refreshPasswordStatus()
        XCTAssertEqual(s.cmux.passwordStatus.text, "A password is saved in your Keychain.")
        XCTAssertTrue(s.cmux.canRemovePassword)
        secrets.result = .notFound
        s.cmux.refreshPasswordStatus()
        XCTAssertEqual(s.cmux.passwordStatus.text, "No password saved.")
        XCTAssertFalse(s.cmux.canRemovePassword)
        secrets.result = .interactionRequired
        s.cmux.refreshPasswordStatus()
        XCTAssertEqual(s.cmux.passwordStatus.text, "A password is saved, but macOS needs it saved again since Page was updated — enter it and click Save.")
        XCTAssertTrue(s.cmux.canRemovePassword)
        secrets.result = .failed(-25300)
        s.cmux.refreshPasswordStatus()
        XCTAssertEqual(s.cmux.passwordStatus.text, "Couldn't read the Keychain (error -25300).")
    }

    func testSavingAnEmptyPasswordAsksForOneAndWritesNothing() {
        let secrets = ConversionSecrets()
        let s = cmuxStore(secrets)
        s.cmux.savePassword()
        XCTAssertEqual(s.cmux.passwordStatus.text, "Enter the password you set in cmux first.")
        XCTAssertTrue(secrets.written.isEmpty)
    }

    func testSavingStoresWhatWasTypedAndClearsTheField() {
        let secrets = ConversionSecrets()
        let s = cmuxStore(secrets)
        s.cmux.passwordInput = "hunter2"
        s.cmux.savePassword()
        XCTAssertEqual(secrets.written, ["hunter2"])
        XCTAssertEqual(s.cmux.passwordInput, "")
        XCTAssertEqual(s.cmux.passwordStatus.text, "A password is saved in your Keychain.")
    }

    func testAFailedSaveKeepsWhatWasTypedAndShowsWhy() {
        let secrets = ConversionSecrets()
        secrets.writeError = "Keychain refused the password."
        let s = cmuxStore(secrets)
        s.cmux.passwordInput = "pw"
        s.cmux.savePassword()
        XCTAssertEqual(s.cmux.passwordStatus.text, "Keychain refused the password.")
        XCTAssertEqual(s.cmux.passwordInput, "pw", "the typed text is kept so it can be fixed and saved again")
    }

    func testRemovingThePasswordDeletesItAndSaysSo() {
        let secrets = ConversionSecrets()
        secrets.result = .found("x")
        let s = cmuxStore(secrets)
        s.cmux.refreshPasswordStatus()
        s.cmux.removePassword()
        XCTAssertEqual(secrets.deleted, 1)
        XCTAssertEqual(s.cmux.passwordStatus.text, "No password saved.")
        XCTAssertFalse(s.cmux.canRemovePassword)
    }

    // MARK: routing

    func testEveryEntryPointLandsOnItsPageFromAnyStartingPage() {
        for start in [TowerSection.power, .terminals, .pairing, .phoneApprovals] {
            let s = TowerStore()
            s.selection = start
            s.openPhoneApprovals()
            XCTAssertEqual(s.selection, .phoneApprovals, "from \(start)")
            s.selection = start
            s.openPairing()
            XCTAssertEqual(s.selection, .pairing, "from \(start)")
            s.selection = start
            s.openCmuxSetup()
            XCTAssertEqual(s.selection, .terminals, "from \(start)")
            XCTAssertTrue(s.cmuxSetupOpen, "from \(start)")
        }
    }

    func testTheCmuxRowOpensItsPageAndDoneReturnsToTheList() {
        let s = TowerStore()
        s.setUp(.cmux)
        XCTAssertEqual(s.selection, .terminals)
        XCTAssertTrue(s.cmuxSetupOpen)
        s.closeCmuxSetup()
        XCTAssertFalse(s.cmuxSetupOpen)
        XCTAssertEqual(s.selection, .terminals, "back on the Terminals list, not the Power page")
    }

    func testSelectingThePairingPageReadsTheRelayAndSelectingPowerDoesNot() {
        var reads = 0
        var env = TowerEnvironment()
        env.pairing.info = { reads += 1; return .setupNeeded(reason: "off") }
        let s = TowerStore(env: env)
        s.selection = .power
        XCTAssertEqual(reads, 0, "no page reads the relay until it is opened")
        s.selection = .pairing
        XCTAssertEqual(reads, 0, "opening the page reads nothing and shows no QR: that waits for a click")
        XCTAssertFalse(s.pairing.revealed)
        s.pairing.reveal()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(s.pairing.state, .setupNeeded(reason: "off"))
        s.selection = .power
        XCTAssertFalse(s.pairing.revealed, "leaving the page hides the QR again")
    }

    func testLeavingTerminalsClosesTheCmuxPage() {
        let s = TowerStore()
        s.openCmuxSetup()
        XCTAssertTrue(s.cmuxSetupOpen)
        s.selection = .power
        XCTAssertFalse(s.cmuxSetupOpen)
        s.selection = .terminals
        XCTAssertFalse(s.cmuxSetupOpen, "coming back shows the terminal list")
    }

    func testPairPhoneFromTheMenuOpensTheQrShowing() {
        var env = TowerEnvironment()
        env.pairing.info = { .ready(base: URL(string: "https://r.example.workers.dev")!, payload: "p") }
        let s = TowerStore(env: env)
        s.openPairingRevealed()
        XCTAssertEqual(s.selection, .pairing)
        XCTAssertTrue(s.pairing.revealed)
        XCTAssertNotNil(s.pairing.qr)
    }

    func testTheWindowEntryPointsHaveAPageInTheControlMap() {
        func entry(_ old: String) -> TowerControlHome? { TowerControlMap.entries.first { $0.old == old } }
        XCTAssertEqual(entry("action: Set up cmux…")?.section, .terminals)
        XCTAssertEqual(entry("action: Install agent hooks…")?.section, .phoneApprovals)
        XCTAssertEqual(entry("action: Pair phone…")?.section, .pairing)
    }

    func testThePhoneApprovalsSidebarItemHasItsOwnTitle() {
        XCTAssertEqual(TowerSection.phoneApprovals.title, "Phone approvals")
        XCTAssertEqual(TowerSection.pairing.title, "Pairing & encryption")
    }
}

/// An in-memory Keychain item for the cmux password steps. Never touches the real Keychain.
private final class ConversionSecrets: SecretStore {
    var result: SecretReadResult = .notFound
    var writeError: String?
    var written: [String] = []
    var deleted = 0

    func read(allowUI: Bool) -> SecretReadResult { result }

    func write(_ secret: String) -> String? {
        written.append(secret)
        if writeError == nil { result = .found(secret) }
        return writeError
    }

    @discardableResult
    func delete() -> Bool {
        deleted += 1
        result = .notFound
        return true
    }
}
