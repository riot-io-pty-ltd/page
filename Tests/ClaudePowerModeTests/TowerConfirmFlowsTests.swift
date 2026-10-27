import XCTest
@testable import ClaudePowerMode

/// Every Tower flow that asks before it acts: the hook installs and removals,
/// kitty setup, the broken-config Apply and the pairing regenerate. Each
/// question goes through a deferred fake, so it is held until the test answers
/// it. Nothing may happen before the answer; OK does the thing (and the
/// follow-up notice appears); Cancel, or a dismissed dialog (-1), does nothing.
/// Files live in a temp home. Nothing reads the real ~/.claude or ~/.codex.
final class TowerConfirmFlowsTests: XCTestCase {
    /// Every question the store asked, and the ones still waiting for an answer.
    private struct Question {
        let spec: NWDialogSpec
        let answer: (Int) -> Void
    }

    private final class Dialogs {
        var history: [NWDialogSpec] = []
        var open: [Question] = []

        func ask(_ spec: NWDialogSpec, _ done: @escaping (Int) -> Void) {
            history.append(spec)
            open.append(Question(spec: spec, answer: done))
        }
    }

    private let ok: (NWDialogSpec) -> Int = { _ in 0 }
    private let cancel: (NWDialogSpec) -> Int = { $0.cancelIndex }
    private let dismissed: (NWDialogSpec) -> Int = { _ in -1 }

    /// Answers the oldest open question with `pick`'s choice.
    private func answerNext(_ d: Dialogs, _ pick: (NWDialogSpec) -> Int, file: StaticString = #filePath, line: UInt = #line) {
        guard !d.open.isEmpty else {
            XCTFail("no question is waiting for an answer", file: file, line: line)
            return
        }
        let next = d.open.removeFirst()
        next.answer(pick(next.spec))
    }

    private let script = "/Applications/Page.app/Contents/Resources/hooks/page-notify.sh"
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("towerflows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try "{\n  \"theme\": \"dark\"\n}\n".write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func read(_ relative: String) -> String? {
        try? String(contentsOf: home.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: hooks: install and remove

    private func makeHooks(_ d: Dialogs) -> TowerStore {
        let installer = HookInstaller(homeDirectory: home, scriptPath: script)
        var env = TowerEnvironment()
        env.hookSource = { TowerHookSource(installer: installer, scriptPath: installer.scriptPath) }
        env.runDialog = { spec, done in d.ask(spec, done) }
        let store = TowerStore(config: Config(), macName: "Mac", env: env)
        store.hooks.refresh()
        return store
    }

    func testInstallingClaudeHooksWritesOnlyAfterOK() {
        let d = Dialogs()
        let s = makeHooks(d)
        let before = read(".claude/settings.json")

        s.hooks.run(.install, .claude)
        XCTAssertEqual(d.open.map(\.spec.title), ["Install Page's Claude Code hooks?"])
        XCTAssertEqual(read(".claude/settings.json"), before, "nothing is written before Install is pressed")

        answerNext(d, ok)
        XCTAssertNotEqual(read(".claude/settings.json"), before, "Install wrote the hooks")
        XCTAssertTrue(read(".claude/settings.json")?.contains("page-notify") == true)
        XCTAssertEqual(d.open.map(\.spec.title), ["Hooks installed"], "then the done notice is asked")
        XCTAssertEqual(s.hooks.claude.chip, .installed)
    }

    func testInstallingCodexHooksDoesNothingOnCancel() {
        let d = Dialogs()
        let s = makeHooks(d)

        s.hooks.run(.install, .codex)
        XCTAssertEqual(d.open.map(\.spec.title), ["Install Page's Codex hooks?"])
        answerNext(d, cancel)

        XCTAssertNil(read(".codex/hooks.json"), "Cancel writes no Codex hooks")
        XCTAssertTrue(d.open.isEmpty, "and asks no follow-up")
        XCTAssertEqual(d.history.count, 1, "no 'Hooks installed' notice after Cancel")
        XCTAssertEqual(s.hooks.codex.chip, .notInstalled)
    }

    func testASecondClickBeforeTheDialogIsUpAsksNothingMore() {
        let d = Dialogs()
        let s = makeHooks(d)

        s.hooks.run(.install, .codex)
        s.hooks.run(.install, .codex)
        XCTAssertEqual(d.open.map(\.spec.title), ["Install Page's Codex hooks?"], "one dialog, not two")
        XCTAssertEqual(d.history.count, 1)

        answerNext(d, ok)
        XCTAssertNotNil(read(".codex/hooks.json"), "the one Install wrote the hooks")
        XCTAssertEqual(d.open.map(\.spec.title), ["Hooks installed"], "the notice still shows, from inside the answer")
        answerNext(d, ok)

        s.hooks.run(.uninstall, .codex)
        XCTAssertEqual(d.open.count, 1, "and once answered, the next question is asked as usual")
    }

    func testADismissedInstallDialogIsACancel() {
        let d = Dialogs()
        let s = makeHooks(d)
        let before = read(".claude/settings.json")

        s.hooks.run(.install, .claude)
        answerNext(d, dismissed)

        XCTAssertEqual(read(".claude/settings.json"), before)
        XCTAssertEqual(d.history.count, 1)
        XCTAssertEqual(s.hooks.claude.chip, .notInstalled)
    }

    func testInstallingCodexHooksWritesAfterOK() {
        let d = Dialogs()
        let s = makeHooks(d)

        s.hooks.run(.install, .codex)
        answerNext(d, ok)

        XCTAssertTrue(read(".codex/hooks.json")?.contains("page-notify") == true, "Install wrote the Codex hooks")
        XCTAssertEqual(d.open.map(\.spec.title), ["Hooks installed"])
    }

    func testRemovingClaudeHooksDoesNothingOnCancelAndWritesOnOK() {
        let d = Dialogs()
        let s = makeHooks(d)
        s.hooks.run(.install, .claude)
        answerNext(d, ok)
        answerNext(d, ok)
        XCTAssertEqual(s.hooks.claude.chip, .installed)
        let installed = read(".claude/settings.json")

        s.hooks.run(.uninstall, .claude)
        XCTAssertEqual(d.open.map(\.spec.title), ["Remove Page's Claude Code hooks?"])
        answerNext(d, cancel)
        XCTAssertEqual(read(".claude/settings.json"), installed, "Cancel keeps the hooks as they were")
        XCTAssertTrue(d.open.isEmpty, "no 'Hooks removed' notice after Cancel")
        XCTAssertEqual(s.hooks.claude.chip, .installed)

        s.hooks.run(.uninstall, .claude)
        answerNext(d, ok)
        XCTAssertFalse(read(".claude/settings.json")?.contains("page-notify") == true, "OK removed Page's entries")
        XCTAssertEqual(d.open.map(\.spec.title), ["Hooks removed"])
        answerNext(d, ok)
        XCTAssertEqual(s.hooks.claude.chip, .notInstalled)
    }

    // MARK: kitty setup

    private struct Confirm {
        let title: String
        let ok: String
        let done: (Bool) -> Void
    }

    private final class Kitty {
        var enables = 0
        var probes = 0
        var confirms: [Confirm] = []
    }

    private let kittyURL = URL(fileURLWithPath: "/k/kitty.conf")

    private func makeKitty(_ k: Kitty) -> TowerStore {
        var env = TowerEnvironment()
        let added = [KittyConfigFile.allowLine, KittyConfigFile.listenLine]
        env.previewKitty = {
            .success(KittyConfigFile.Preview(url: self.kittyURL, plan: .write(text: "x", added: added), creating: false))
        }
        env.enableKitty = {
            k.enables += 1
            return .success(KittyConfigFile.Outcome(url: self.kittyURL, backup: nil, added: added))
        }
        env.probeTerminals = { _, done in
            k.probes += 1
            done(nil)
        }
        env.confirm = { title, _, okTitle, done in k.confirms.append(Confirm(title: title, ok: okTitle, done: done)) }
        env.windowVisible = { true }
        return TowerStore(config: Config(), macName: "Studio", env: env)
    }

    func testKittySetupWritesAndRefreshesOnlyAfterOK() {
        let k = Kitty()
        let s = makeKitty(k)

        s.setUpKitty()
        XCTAssertEqual(k.confirms.map { $0.title }, ["Turn on kitty remote control?"])
        XCTAssertEqual(k.enables, 0, "nothing is written before the answer")
        XCTAssertEqual(k.probes, 0, "nothing is refreshed before the answer")
        XCTAssertNil(s.terminalNotice)

        k.confirms[0].done(true)
        XCTAssertEqual(k.enables, 1)
        XCTAssertEqual(k.probes, 1, "the Terminals page refreshes after the write")
        XCTAssertNotNil(s.terminalNotice, "and says what changed")
    }

    func testKittySetupDoesNothingOnCancel() {
        let k = Kitty()
        let s = makeKitty(k)

        s.setUpKitty()
        k.confirms[0].done(false)

        XCTAssertEqual(k.enables, 0, "Cancel writes nothing")
        XCTAssertEqual(k.probes, 0, "and skips the refresh, as before")
        XCTAssertNil(s.terminalNotice)
    }

    // MARK: broken config.json on Apply

    private final class Saves {
        var writes: [Config] = []
        var closes = 0
        var reloads = 0
        var replaceAsks: [(Bool) -> Void] = []
    }

    private func makeBrokenConfigStore(_ saves: Saves) -> TowerStore {
        var env = TowerEnvironment()
        env.loadConfig = {
            Config.LoadResult(config: nil, problem: "malformed", backupURL: URL(fileURLWithPath: "/x/config.broken.json"))
        }
        env.writeConfig = { saves.writes.append($0) }
        env.reloadConfig = { saves.reloads += 1 }
        env.close = { saves.closes += 1 }
        env.confirmReplaceBrokenConfig = { _, done in saves.replaceAsks.append(done) }
        return TowerStore(config: Config(), macName: "Mac", env: env)
    }

    func testApplyWithABrokenConfigSavesOnlyAfterReplaceIsConfirmed() {
        let saves = Saves()
        let s = makeBrokenConfigStore(saves)
        var results: [Bool] = []

        s.apply { results.append($0) }
        XCTAssertEqual(saves.replaceAsks.count, 1, "Replace config.json? is asked")
        XCTAssertEqual(results, [], "Apply waits for the answer")
        XCTAssertTrue(saves.writes.isEmpty)

        saves.replaceAsks[0](true)
        XCTAssertEqual(results, [true], "Replace saves, once")
        XCTAssertEqual(saves.writes.count, 1)
        XCTAssertEqual(saves.reloads, 1)
        XCTAssertEqual(saves.closes, 1)
    }

    func testApplyWithABrokenConfigDoesNothingOnCancel() {
        let saves = Saves()
        let s = makeBrokenConfigStore(saves)
        var results: [Bool] = []

        s.apply { results.append($0) }
        saves.replaceAsks[0](false)

        XCTAssertEqual(results, [false], "Cancel answers Apply once, with no save")
        XCTAssertTrue(saves.writes.isEmpty, "the broken file is left alone")
        XCTAssertEqual(saves.reloads, 0)
        XCTAssertEqual(saves.closes, 0, "the window stays open")
    }

    // MARK: pairing: regenerate the token

    private final class Pairing {
        var regenerated = 0
    }

    func testRegenerateWaitsForOKAndDoesNothingOnCancelOrDismiss() {
        let d = Dialogs()
        let p = Pairing()
        var env = TowerEnvironment()
        env.pairing.info = { .ready(base: URL(string: "https://r.example.workers.dev")!, payload: "payload-\(p.regenerated)") }
        env.pairing.regenerate = { p.regenerated += 1 }
        env.runDialog = { spec, done in d.ask(spec, done) }
        let s = TowerStore(config: Config(), macName: "Mac", env: env)
        s.pairing.refresh()

        s.pairing.regenerate()
        XCTAssertEqual(d.open.map(\.spec.title), ["Regenerate the pairing token?"])
        XCTAssertEqual(p.regenerated, 0, "the token is not touched before the answer")
        let shown = s.pairing.payload
        answerNext(d, cancel)
        XCTAssertEqual(p.regenerated, 0, "Cancel leaves the token alone")
        XCTAssertEqual(s.pairing.payload, shown)

        s.pairing.regenerate()
        answerNext(d, dismissed)
        XCTAssertEqual(p.regenerated, 0, "a dismissed dialog leaves the token alone")

        s.pairing.regenerate()
        XCTAssertEqual(p.regenerated, 0, "still waiting")
        answerNext(d, ok)
        XCTAssertEqual(p.regenerated, 1, "OK regenerates, once")
        XCTAssertEqual(s.pairing.payload, "payload-1", "and the QR is rebuilt from the new token")
        XCTAssertTrue(d.open.isEmpty)
    }
}
