import XCTest
@testable import ClaudePowerMode

/// The steer target check on a whole command and session (the overload the
/// `input`, `interrupt` and `answer` handlers use): an old phone's command is
/// never checked, the folder decides when the phone sent one, and the title
/// falls back the way the Mac lists a session.
final class SessionTargetCheckTests: XCTestCase {
    private let home = "/Users/me"

    private func session(cwd: String?, title: String?, backend: AgentBackendID = .claude) -> AgentSession {
        AgentSession(backend: backend, sessionId: "s1", cwd: cwd, title: title, source: .terminal,
                     state: .active, lastActivityAt: nil, activeFlags: [], supportsRemoteReply: true)
    }

    private func command(expectCwd: String? = nil, expectTitle: String? = nil) -> SessionCommand {
        var c = SessionCommand(op: "input", clientId: "c1", ts: 1_000, viewer: nil, sessionId: "s1", text: "hi")
        c.expectCwd = expectCwd
        c.expectTitle = expectTitle
        return c
    }

    func testAnOldPhoneSendsNoExpectationAndIsNeverRefused() {
        // No keys at all: the command goes through, whatever the session is now.
        let moved = session(cwd: "/Users/me/projects/elsewhere", title: "something else")
        XCTAssertNil(SessionTargetCheck.verify(command(), against: moved, home: home))
    }

    func testAMatchingFolderGoesThroughEvenIfTheTitleChanged() {
        let s = session(cwd: "/Users/me/projects/page", title: "renamed in the meantime")
        XCTAssertNil(SessionTargetCheck.verify(command(expectCwd: "~/projects/page", expectTitle: "page"), against: s, home: home))
    }

    func testAMismatchedFolderIsRefusedAndNamesBothFoldersByLeafOnly() throws {
        let s = session(cwd: "/Users/me/projects/page", title: "page")
        let refused = try XCTUnwrap(SessionTargetCheck.verify(command(expectCwd: "~/projects/riot-io-teltonika"), against: s, home: home))
        XCTAssertEqual(refused.reason, .targetMismatch)
        XCTAssertEqual(refused.code, .refused)
        XCTAssertTrue(refused.detail.hasPrefix("Nothing was typed."), "it says nothing was typed")
        XCTAssertTrue(refused.detail.contains("riot-io-teltonika"), "it names the folder the room showed")
        XCTAssertTrue(refused.detail.contains("page"), "and the one the session is in now")
        XCTAssertFalse(refused.detail.contains("/Users/me"), "never a full path in what the phone shows")
    }

    func testTheTitleIsOnlyUsedWhenThePhoneSentNoFolder() {
        let s = session(cwd: "/Users/me/projects/page", title: "Page Thread")
        // The title is compared without case or padding.
        XCTAssertNil(SessionTargetCheck.verify(command(expectTitle: "  page thread "), against: s, home: home))
        XCTAssertEqual(SessionTargetCheck.verify(command(expectTitle: "other thread"), against: s, home: home)?.reason, .targetMismatch)
    }

    func testTheTitleFallsBackToTheFolderNameThenTheBackend() {
        // No title on the session: the folder's name is the title the Mac lists.
        let folderOnly = session(cwd: "/Users/me/projects/page", title: nil)
        XCTAssertNil(SessionTargetCheck.verify(command(expectTitle: "page"), against: folderOnly, home: home))
        XCTAssertEqual(SessionTargetCheck.verify(command(expectTitle: "claude"), against: folderOnly, home: home)?.reason, .targetMismatch,
                       "the backend's name is only the last resort, and the folder wins over it")

        // No title and no folder: the backend's name is what the Mac lists.
        let bare = session(cwd: nil, title: nil, backend: .codex)
        XCTAssertNil(SessionTargetCheck.verify(command(expectTitle: "codex"), against: bare, home: home))
        XCTAssertEqual(SessionTargetCheck.verify(command(expectTitle: "page"), against: bare, home: home)?.reason, .targetMismatch)
    }

    func testTheHomeFolderIsCalledTheWayTheMacListsIt() {
        let atHome = session(cwd: "/Users/me", title: nil)
        // The home folder lists as "~ (home folder)" (SessionRemote.folderTitle), so the phone's expectation is compared on that.
        XCTAssertNil(SessionTargetCheck.verify(command(expectTitle: "~ (home folder)"), against: atHome, home: home))
    }
}
