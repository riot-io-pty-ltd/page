import XCTest
@testable import ClaudePowerMode

/// The Dispatch panel (⌘N): when it can send, folder choice, the hints and
/// what a result looks like on screen.
final class DispatchModelTests: XCTestCase {
    private let folders: [SessionStarter.Folder] = ["page", "bottle-flip", "llm-play"].map {
        SessionStarter.Folder(path: "/Users/roy/projects/\($0)", name: $0, lastUsedAt: nil)
    }

    private func model(prompt: String = "fix the flaky test", phase: DispatchModel.Phase = .editing,
                       folders list: [SessionStarter.Folder]? = nil) -> DispatchModel {
        var m = DispatchModel()
        m.prompt = prompt
        m.phase = phase
        m.setFolders(list ?? folders)
        return m
    }

    // MARK: sending

    func testCanSendNeedsAFolderAndSomePrompt() {
        XCTAssertTrue(model().canSend)
        XCTAssertFalse(model(prompt: "   \n ").canSend, "a blank prompt")
        XCTAssertFalse(model(folders: []).canSend, "no folder to start in")
    }

    func testCanSendIsFalseWhileSendingOrDoneAndTrueAfterAFailure() {
        XCTAssertFalse(model(phase: .sending).canSend)
        XCTAssertFalse(model(phase: .done("Started Claude")).canSend)
        XCTAssertTrue(model(phase: .failed("Couldn't start the session")).canSend, "a failed attempt can be sent again")
    }

    // MARK: folders

    func testCycleWrapsInBothDirections() {
        var m = model()
        m.cycleFolder(by: -1)
        XCTAssertEqual(m.folderIndex, 2)
        m.cycleFolder(by: 1)
        XCTAssertEqual(m.folderIndex, 0)
        m.cycleFolder(by: 4)
        XCTAssertEqual(m.folderIndex, 1)
        m.cycleFolder(by: -7)
        XCTAssertEqual(m.folderIndex, 0)
    }

    func testCycleWithNoFoldersDoesNothing() {
        var m = model(folders: [])
        m.cycleFolder(by: 1)
        XCTAssertEqual(m.folderIndex, 0)
        XCTAssertNil(m.folder)
    }

    func testSetFoldersKeepsTheChosenFolderByPath() {
        var m = model()
        m.folderIndex = 2
        XCTAssertEqual(m.folder?.name, "llm-play")
        m.setFolders(Array(folders.reversed()))
        XCTAssertEqual(m.folder?.name, "llm-play")
        XCTAssertEqual(m.folderIndex, 0, "llm-play is first in the reversed list")
    }

    func testSetFoldersResetsWhenTheChosenFolderIsGone() {
        var m = model()
        m.folderIndex = 2
        m.setFolders(Array(folders.prefix(2)))
        XCTAssertEqual(m.folderIndex, 0)
        XCTAssertFalse(m.loadingFolders)
    }

    func testFolderLabel() {
        XCTAssertEqual(model().folderLabel, "page")
        var loading = DispatchModel()
        loading.loadingFolders = true
        XCTAssertEqual(loading.folderLabel, "Loading…")
        XCTAssertEqual(DispatchModel().folderLabel, "No folder")
    }

    // MARK: hints

    func testHintsByPhase() {
        XCTAssertEqual(model().hint, "↵ dispatch · ⌘↑↓ change folder · esc")
        XCTAssertEqual(model(phase: .failed("x")).hint, "↵ try again · esc")
        XCTAssertEqual(model(phase: .done("x")).hint, "esc to close")
        XCTAssertEqual(model(phase: .sending).hint, "starting…")
    }

    func testAgentAndWhenChipsAreFixed() {
        XCTAssertEqual(DispatchModel().agentLabel, "Claude")
        XCTAssertEqual(DispatchModel().whenLabel, "Now")
    }

    func testDisplayPathShortensTheHomeFolder() {
        XCTAssertEqual(DispatchModel.displayPath("/Users/x/p", home: "/Users/x"), "~/p")
        XCTAssertEqual(DispatchModel.displayPath("/Users/x", home: "/Users/x"), "~")
        XCTAssertEqual(DispatchModel.displayPath("/opt/tool", home: "/Users/x"), "/opt/tool")
    }

    func testDisplayPathOnlyShortensWholePathComponents() {
        XCTAssertEqual(DispatchModel.displayPath("/Users/xy/p", home: "/Users/x"), "/Users/xy/p",
                       "a sibling folder whose name starts with the home name is not the home folder")
    }

    // MARK: the store

    func testSubmitSendsTheTrimmedPromptToTheChosenFolder() {
        let store = DispatchStore(model: model(prompt: "  fix the flaky test  "))
        var sent: [(String, String)] = []
        store.send = { sent.append(($0, $1)) }
        store.model.folderIndex = 1
        store.submit()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.0, "/Users/roy/projects/bottle-flip")
        XCTAssertEqual(sent.first?.1, "fix the flaky test")
        XCTAssertEqual(store.model.phase, .sending)
    }

    func testSubmitDoesNothingWhenItCannotSend() {
        let store = DispatchStore(model: model(prompt: "  "))
        var calls = 0
        store.send = { _, _ in calls += 1 }
        store.submit()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(store.model.phase, .editing)

        store.model.prompt = "go"
        store.model.phase = .sending
        store.submit()
        XCTAssertEqual(calls, 0, "a second submit while sending is ignored")
    }

    func testFinishMapsDeliveredAndQueuedToDone() {
        let store = DispatchStore(model: model(phase: .sending))
        store.finish(SessionCommandResult(code: .delivered, reason: nil, detail: "Started Claude in page"))
        XCTAssertEqual(store.model.phase, .done("Started Claude in page"))
        store.model.phase = .sending
        store.finish(SessionCommandResult(code: .queued, reason: nil, detail: ""))
        XCTAssertEqual(store.model.phase, .done("Started Claude"))
    }

    func testFinishMapsOtherResultsToFailed() {
        let store = DispatchStore(model: model(phase: .sending))
        store.finish(.refused(.disabled, SessionStarter.disabledMessage))
        XCTAssertEqual(store.model.phase, .failed(SessionStarter.disabledMessage))
        store.finish(.failed(""))
        XCTAssertEqual(store.model.phase, .failed("Couldn't start the session"))
    }
}
