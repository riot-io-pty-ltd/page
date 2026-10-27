import XCTest
import SwiftUI
import AppKit
@testable import ClaudePowerMode

/// The Night Watch dialog, actually used: shown over a real (on-screen) window,
/// its buttons pressed with real mouse and key events through `NSWindow.sendEvent`
/// while the main run loop spins, the way a click reaches it in the app.
///
/// Why it exists: the dialog used to block in a nested modal loop started from a
/// SwiftUI button action, and its own buttons were then dead ("I can't click
/// Install or Cancel"). Rendering never clicks, so nothing caught it. These tests
/// click. (SwiftUI builds its accessibility tree only when a client asks, so the
/// buttons are found by the card's fixed layout, not through accessibility.)
final class NWDialogInteractionTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func setUp() {
        _ = NSApplication.shared
    }

    override func tearDown() {
        for p in NWDialog.live { p.finish(-1) }
        windows.forEach { $0.orderOut(nil) }
        windows = []
        spin(0.05)
    }

    // MARK: helpers

    private func spin(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func spin(until done: () -> Bool, timeout: TimeInterval = 3) {
        let end = Date().addingTimeInterval(timeout)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// A titled window like the Tower, on screen.
    private func makeTower() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 760, height: 520),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.orderFront(nil)
        windows.append(w)
        return w
    }

    private final class Answers {
        var values: [Int] = []
        /// What was true when the completion ran.
        var sheetsLeft: [Int] = []
        var panelVisible: [Bool] = []
    }

    @discardableResult
    private func present(_ spec: NWDialogSpec, over window: NSWindow?) -> (Answers, () -> NWDialogPanel?) {
        let a = Answers()
        let before = Set(NWDialog.live.map { ObjectIdentifier($0) })
        var shown: NWDialogPanel?
        NWDialog.present(spec, over: window) { index in
            a.values.append(index)
            a.sheetsLeft.append(window?.sheets.count ?? 0)
            a.panelVisible.append(shown?.isVisible ?? false)
        }
        let find: () -> NWDialogPanel? = {
            if shown == nil { shown = NWDialog.live.first { !before.contains(ObjectIdentifier($0)) }?.panel }
            return shown
        }
        return (a, find)
    }

    private func awaitPanel(_ find: () -> NWDialogPanel?) -> NWDialogPanel {
        spin(until: { find()?.isVisible == true })
        return find()!
    }

    private func mouse(_ type: NSEvent.EventType, _ panel: NSWindow, _ point: NSPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
    }

    private func click(_ window: NSWindow, at point: NSPoint) {
        window.sendEvent(mouse(.leftMouseDown, window, point))
        spin(0.03)
        window.sendEvent(mouse(.leftMouseUp, window, point))
        spin(0.03)
    }

    /// Two quick presses, the second counted as a double-click (clickCount 2).
    private func doubleClick(_ window: NSWindow, at point: NSPoint) {
        window.sendEvent(mouse(.leftMouseDown, window, point))
        window.sendEvent(mouse(.leftMouseUp, window, point))
        window.sendEvent(mouse(.leftMouseDown, window, point, clicks: 2))
        window.sendEvent(mouse(.leftMouseUp, window, point, clicks: 2))
        spin(0.1)
    }

    /// The row of buttons sits `inset + padding + half a button` above the card's bottom (the inset is 0 as a sheet).
    private func rowY(_ panel: NWDialogPanel) -> CGFloat { panel.inset + 22 + 15 }

    /// The first button is the right-most: click just inside the card's right edge.
    private func clickFirstButton(_ panel: NWDialogPanel) {
        click(panel, at: NSPoint(x: panel.contentView!.bounds.width - panel.inset - 22 - 10, y: rowY(panel)))
    }

    /// Cancel is the first button met sweeping the row rightwards from the middle (the buttons sit at the right).
    private func clickCancelButton(_ panel: NWDialogPanel, answered: () -> Bool) {
        var x = panel.contentView!.bounds.midX
        while x < panel.contentView!.bounds.width - panel.inset - 22, !answered() {
            click(panel, at: NSPoint(x: x, y: rowY(panel)))
            x += 6
        }
    }

    private func key(_ code: UInt16, _ chars: String, in panel: NSWindow, type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: panel.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    private let confirm = NWDialogSpec.confirm("Install Page's Codex hooks?", "diff", ok: "Install",
                                               detail: .diff("--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new"))

    // MARK: sheet over the window

    func testItIsASheetOnTheWindowAndNothingIsShownFromTheCallersStack() {
        let tower = makeTower()
        let (_, find) = present(confirm, over: tower)
        XCTAssertTrue(tower.sheets.isEmpty, "present hops off the caller's stack before showing anything")
        let panel = awaitPanel(find)
        XCTAssertEqual(tower.sheets, [panel], "the Tower is blocked by a sheet, not by a nested run loop")
        XCTAssertTrue(panel.isKeyWindow || panel.canBecomeKey)
    }

    func testClickingTheFirstButtonAnswersZeroAndTakesTheSheetDown() {
        let tower = makeTower()
        let (a, find) = present(confirm, over: tower)
        let panel = awaitPanel(find)
        clickFirstButton(panel)
        spin(until: { !a.values.isEmpty })
        XCTAssertEqual(a.values, [0])
        XCTAssertEqual(a.sheetsLeft, [0], "the sheet is gone by the time the completion runs")
        XCTAssertEqual(a.panelVisible, [false])
        XCTAssertTrue(tower.sheets.isEmpty)
        spin(0.1)
        XCTAssertTrue(NWDialog.live.isEmpty, "nothing is kept alive once it has answered")
    }

    func testClickingCancelAnswersOne() {
        let tower = makeTower()
        let (a, find) = present(confirm, over: tower)
        let panel = awaitPanel(find)
        clickCancelButton(panel, answered: { !a.values.isEmpty })
        spin(until: { !a.values.isEmpty })
        XCTAssertEqual(a.values, [1])
        XCTAssertTrue(tower.sheets.isEmpty)
    }

    func testEscCancelsAndReturnPressesTheDefault() {
        let tower = makeTower()
        let (esc, findEsc) = present(confirm, over: tower)
        let p1 = awaitPanel(findEsc)
        p1.cancelOperation(nil)
        spin(until: { !esc.values.isEmpty })
        XCTAssertEqual(esc.values, [1], "Esc is Cancel")
        XCTAssertTrue(tower.sheets.isEmpty)

        let (ret, findRet) = present(confirm, over: tower)
        let p2 = awaitPanel(findRet)
        p2.makeKey()
        spin(0.1)
        p2.sendEvent(key(36, "\r", in: p2))
        p2.sendEvent(key(36, "\r", in: p2, type: .keyUp))
        spin(until: { !ret.values.isEmpty })
        XCTAssertEqual(ret.values, [0], "Return presses the first button")
        XCTAssertTrue(tower.sheets.isEmpty)
    }

    func testEscKeyEventCancels() {
        let tower = makeTower()
        let (a, find) = present(confirm, over: tower)
        let panel = awaitPanel(find)
        panel.makeKey()
        spin(0.1)
        panel.sendEvent(key(53, "\u{1B}", in: panel))
        panel.sendEvent(key(53, "\u{1B}", in: panel, type: .keyUp))
        spin(until: { !a.values.isEmpty })
        XCTAssertEqual(a.values, [1])
    }

    func testALoneOkTakesEscAndReturnAndClick() {
        let tower = makeTower()
        let (esc, findEsc) = present(.notice("Couldn’t save", "why"), over: tower)
        awaitPanel(findEsc).cancelOperation(nil)
        spin(until: { !esc.values.isEmpty })
        XCTAssertEqual(esc.values, [0])

        let (clicked, findClick) = present(.notice("Couldn’t save", "why"), over: tower)
        clickFirstButton(awaitPanel(findClick))
        spin(until: { !clicked.values.isEmpty })
        XCTAssertEqual(clicked.values, [0])
        XCTAssertTrue(tower.sheets.isEmpty)
    }

    func testItAnswersOnlyOnce() {
        let tower = makeTower()
        let (a, find) = present(confirm, over: tower)
        let panel = awaitPanel(find)
        clickFirstButton(panel)
        panel.cancelOperation(nil)
        clickFirstButton(panel)
        spin(0.3)
        XCTAssertEqual(a.values, [0], "a second press after it answered does nothing")
    }

    func testClosingTheWindowUnderTheSheetAnswersCancelAndLeavesNothingBehind() {
        let tower = makeTower()
        let (a, find) = present(confirm, over: tower)
        let panel = awaitPanel(find)
        tower.close()
        spin(until: { !a.values.isEmpty })
        XCTAssertEqual(a.values, [1])
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(tower.sheets.isEmpty)
        spin(0.1)
        XCTAssertTrue(NWDialog.live.isEmpty)
    }

    func testClosingThePanelItselfAnswersCancel() {
        let tower = makeTower()
        let (a, find) = present(confirm, over: tower)
        awaitPanel(find).close()
        spin(until: { !a.values.isEmpty })
        XCTAssertEqual(a.values, [1])
        XCTAssertTrue(tower.sheets.isEmpty)
    }

    // MARK: the bug

    /// The reported freeze: the dialog is requested from inside a SwiftUI Button's action
    /// (as the Tower's Update… / Reinstall… buttons do), and then its Install must work.
    func testItsButtonsWorkWhenAskedFromInsideASwiftUIButtonAction() {
        let tower = makeTower()
        let host = NSWindow(contentRect: NSRect(x: 900, y: 200, width: 300, height: 200), styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.orderFront(nil)
        windows.append(host)
        let a = Answers()
        var actionRan = false
        var shownInsideAction = true
        host.contentView = NSHostingView(rootView: NWButton(title: "Reinstall…", kind: .primary) {
            NWDialog.present(self.confirm, over: tower) { a.values.append($0) }
            shownInsideAction = !tower.sheets.isEmpty
            actionRan = true
        }.frame(width: 300, height: 200))
        spin(0.2)
        click(host, at: NSPoint(x: host.contentView!.bounds.midX, y: host.contentView!.bounds.midY))
        XCTAssertTrue(actionRan, "the SwiftUI button's action ran")
        XCTAssertFalse(shownInsideAction, "nothing was shown from inside the action itself")
        spin(until: { tower.sheets.first?.isVisible == true })
        let shown = tower.sheets.first as? NWDialogPanel
        XCTAssertNotNil(shown, "clicking the SwiftUI button put the dialog up")
        if let shown { clickFirstButton(shown) }
        spin(until: { !a.values.isEmpty })
        XCTAssertEqual(a.values, [0], "Install answers: the dialog is not frozen")
        XCTAssertTrue(tower.sheets.isEmpty)
    }

    /// The reported flow end to end: the Phone approvals page's Install… for the Codex
    /// hooks, clicked in a real SwiftUI button, answered by clicking the dialog's
    /// Install, then the "Hooks installed" notice's OK. Runs on a temp home.
    func testInstallingTheCodexHooksFromTheRealButtonWorksEndToEnd() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nwint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let script = "/Applications/Page.app/Contents/Resources/hooks/page-notify.sh"
        let tower = makeTower()
        var env = TowerEnvironment()
        let installer = HookInstaller(homeDirectory: home, scriptPath: script)
        env.hookSource = { TowerHookSource(installer: installer, scriptPath: script) }
        env.runDialog = { spec, done in NWDialog.present(spec, over: tower, completion: done) }
        let store = TowerStore(env: env)
        let host = NSWindow(contentRect: NSRect(x: 900, y: 200, width: 300, height: 200), styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = NSHostingView(rootView: NWButton(title: "Install…", kind: .primary) {
            store.hooks.run(.install, .codex)
        }.frame(width: 300, height: 200))
        host.orderFront(nil)
        windows.append(host)
        spin(0.2)
        click(host, at: NSPoint(x: host.contentView!.bounds.midX, y: host.contentView!.bounds.midY))

        spin(until: { tower.sheets.first?.isVisible == true })
        let confirmPanel = try XCTUnwrap(tower.sheets.first as? NWDialogPanel, "the confirm dialog is up")
        XCTAssertEqual(confirmPanel.title, "Install Page's Codex hooks?")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/hooks.json").path),
                       "nothing is written before Install is pressed")
        clickFirstButton(confirmPanel)

        spin(until: { (tower.sheets.first as? NWDialogPanel)?.title == "Hooks installed" })
        let notice = try XCTUnwrap(tower.sheets.first as? NWDialogPanel, "the done notice follows")
        XCTAssertEqual(notice.title, "Hooks installed")
        let written = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".codex").path)
        XCTAssertTrue(written.contains("hooks.json"), "Install wrote the hooks: \(written)")
        clickFirstButton(notice)
        spin(until: { tower.sheets.isEmpty })
        XCTAssertTrue(tower.sheets.isEmpty, "OK took the notice down")
    }

    // MARK: exactly once, however the answer arrives

    func testADoubleClickOnTheFirstButtonAnswersOnce() {
        let tower = makeTower()
        let (a, find) = present(confirm, over: tower)
        let panel = awaitPanel(find)
        doubleClick(panel, at: NSPoint(x: panel.contentView!.bounds.width - panel.inset - 22 - 10, y: rowY(panel)))
        spin(0.3)
        XCTAssertEqual(a.values, [0], "the double-click answers once, with the first button")
        XCTAssertTrue(tower.sheets.isEmpty)
    }

    func testADoubleClickOnCancelAnswersOnceAndNotAgain() {
        let tower = makeTower()
        let (a, find) = present(confirm, over: tower)
        let panel = awaitPanel(find)
        var x = panel.contentView!.bounds.midX
        while x < panel.contentView!.bounds.width - panel.inset - 22, a.values.isEmpty {
            doubleClick(panel, at: NSPoint(x: x, y: rowY(panel)))
            x += 6
        }
        XCTAssertFalse(a.values.isEmpty, "the double-clicks found Cancel and answered with it")
        panel.cancelOperation(nil)
        clickFirstButton(panel)
        spin(0.3)
        XCTAssertEqual(a.values, [1], "a later Esc or click does not answer again")
    }

    func testEscPressedAgainAndAgainAnswersCancelOnce() {
        let tower = makeTower()
        let (a, find) = present(confirm, over: tower)
        let panel = awaitPanel(find)
        panel.makeKey()
        spin(0.1)
        panel.sendEvent(key(53, "\u{1B}", in: panel))
        panel.sendEvent(key(53, "\u{1B}", in: panel, type: .keyUp))
        panel.sendEvent(key(53, "\u{1B}", in: panel))
        panel.cancelOperation(nil)
        spin(0.3)
        XCTAssertEqual(a.values, [1])
    }

    func testReturnPressedAgainAndAgainAnswersZeroOnce() {
        let tower = makeTower()
        let (a, find) = present(confirm, over: tower)
        let panel = awaitPanel(find)
        panel.makeKey()
        spin(0.1)
        panel.sendEvent(key(36, "\r", in: panel))
        panel.sendEvent(key(36, "\r", in: panel, type: .keyUp))
        panel.sendEvent(key(36, "\r", in: panel))
        panel.sendEvent(key(36, "\r", in: panel, type: .keyUp))
        spin(0.3)
        XCTAssertEqual(a.values, [0])
    }

    func testALoneOkAnswersOnceWhenEscReturnAndAClickAllArrive() {
        let tower = makeTower()
        let (a, find) = present(.notice("Couldn’t save", "why"), over: tower)
        let panel = awaitPanel(find)
        panel.makeKey()
        spin(0.1)
        panel.sendEvent(key(53, "\u{1B}", in: panel))
        panel.cancelOperation(nil)
        panel.sendEvent(key(36, "\r", in: panel))
        clickFirstButton(panel)
        spin(0.3)
        XCTAssertEqual(a.values, [0])
    }

    func testFinishingTheSamePresentationTwiceCallsBackOnce() {
        let tower = makeTower()
        let (a, find) = present(confirm, over: tower)
        let panel = awaitPanel(find)
        let presentation = NWDialog.live.first { $0.panel === panel }
        XCTAssertNotNil(presentation, "the dialog is held while it is on screen")
        presentation?.finish(0)
        presentation?.finish(1)
        spin(0.2)
        XCTAssertEqual(a.values, [0])
        XCTAssertEqual(presentation?.finished, true)
    }

    func testTheTowerClosingAfterAnAnswerDoesNotAnswerAgain() {
        let tower = makeTower()
        let (a, find) = present(confirm, over: tower)
        clickFirstButton(awaitPanel(find))
        spin(until: { !a.values.isEmpty })
        tower.close()
        spin(0.3)
        XCTAssertEqual(a.values, [0], "the observers were removed when it answered")
    }

    // MARK: no window to sit on

    func testWithoutAVisibleWindowItIsAFloatingKeyPanelThatAnswers() {
        let hidden = makeTower()
        hidden.orderOut(nil)
        for over in [nil, hidden] as [NSWindow?] {
            let (a, find) = present(confirm, over: over)
            let panel = awaitPanel(find)
            XCTAssertTrue(panel.isFloatingPanel)
            XCTAssertTrue(panel.isVisible)
            XCTAssertTrue(hidden.sheets.isEmpty)
            clickFirstButton(panel)
            spin(until: { !a.values.isEmpty })
            XCTAssertEqual(a.values, [0])
            XCTAssertEqual(a.panelVisible, [false])
        }
    }

    func testEscAnswersCancelOnAFloatingPanel() {
        let (a, find) = present(confirm, over: nil)
        awaitPanel(find).cancelOperation(nil)
        spin(until: { !a.values.isEmpty })
        XCTAssertEqual(a.values, [1])
    }

    func testAskAwaitsTheAnswer() {
        let tower = makeTower()
        let done = expectation(description: "asked")
        var answer: Int?
        Task { @MainActor in
            answer = await NWDialog.ask(self.confirm, over: tower)
            done.fulfill()
        }
        spin(until: { tower.sheets.first?.isVisible == true })
        (tower.sheets.first as? NWDialogPanel)?.cancelOperation(nil)
        wait(for: [done], timeout: 3)
        XCTAssertEqual(answer, 1)
    }
}
