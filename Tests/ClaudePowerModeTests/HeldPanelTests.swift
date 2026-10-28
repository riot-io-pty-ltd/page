import XCTest
@testable import ClaudePowerMode

/// The Mac panel's side of held messages: a working session's card lists
/// what a phone asked to type once the turn ends, each with a Delete, and a
/// reply held until a rate limit resets reads as not typed yet.
final class HeldPanelTests: XCTestCase {
    private let now = NightWatchFixtures.boardNow()

    private func session(_ name: String) -> AgentSession {
        AgentSession(backend: .claude, sessionId: "sess-\(name)", cwd: "/Users/roy/projects/\(name)", title: nil,
                     source: .terminal, state: .active, lastActivityAt: nil, activeFlags: [], supportsRemoteReply: true)
    }

    private func rows(held: [HeldMessageInfo]) -> [InFlightRow] {
        var snap = NightWatchFixtures.snapshot(sessions: [session("page"), session("docs")])
        snap.held = held
        return InFlightRows.build(snap, hosts: [:], activity: [:], now: now)
    }

    private func info(_ id: String, _ session: String, text: String = "then run the linter", ago: TimeInterval = 240,
                      typing: Bool = false) -> HeldMessageInfo {
        HeldMessageInfo(clientId: id, sessionId: "sess-\(session)", text: text, heldAt: now.addingTimeInterval(-ago), typing: typing)
    }

    func testEachCardListsOnlyItsOwnHeldMessages() throws {
        let built = rows(held: [info("c1", "page"), info("c2", "docs"), info("c3", "page", ago: 30)])
        let page = try XCTUnwrap(built.first { $0.sessionId == "sess-page" })
        let docs = try XCTUnwrap(built.first { $0.sessionId == "sess-docs" })
        XCTAssertEqual(page.held.map(\.clientId), ["c1", "c3"])
        XCTAssertEqual(docs.held.map(\.clientId), ["c2"])
        XCTAssertEqual(page.finished.held, page.held, "kept once the turn ends, until the snapshot drops them")
    }

    func testTheLineSaysWhatAndHowLong() {
        let h = InFlightHeld(clientId: "c1", text: "then run the linter", heldAt: now.addingTimeInterval(-240))
        XCTAssertEqual(h.line(now: now), "Held from your phone · “then run the linter” · 4m")
        let long = InFlightHeld(clientId: "c2", text: String(repeating: "a", count: 100) + "\nmore", heldAt: now)
        XCTAssertLessThanOrEqual(long.line(now: now).count, "Held from your phone · “”· 0s".count + InFlightHeld.maxText + 2)
        XCTAssertFalse(long.line(now: now).contains("\n"))
        var typing = h
        typing.typing = true
        XCTAssertTrue(typing.line(now: now).hasPrefix("Typing it now"))
        XCTAssertTrue(typing.deleteHelp.contains("too late"))
    }

    func testDeleteActsOnlyOnAMessageTheCardShows() throws {
        let page = try XCTUnwrap(rows(held: [info("c1", "page")]).first { $0.sessionId == "sess-page" })
        XCTAssertEqual(NowKeys.effect(forHeldDelete: "c1", row: page), .deleteHeld(clientId: "c1"))
        XCTAssertEqual(NowKeys.effect(forHeldDelete: "other", row: page), .none)
    }

    func testTheStoreSendsDeleteOnceAndReportsTheAnswer() throws {
        let store = NowStore(model: NowModel.build(NightWatchFixtures.snapshotOnly()), prefs: .ephemeral())
        var effects: [NowEffect] = []
        store.perform = { effects.append($0) }
        let page = try XCTUnwrap(rows(held: [info("c1", "page")]).first { $0.sessionId == "sess-page" })
        store.deleteHeld("c1", on: page)
        store.deleteHeld("c1", on: page)
        XCTAssertEqual(effects, [.deleteHeld(clientId: "c1")], "a second click while it's on its way does nothing")
        XCTAssertTrue(store.deletingHeld.contains("c1"))
        store.finishDeletingHeld("c1", result: HeldOutbox.retractResult(.deleted))
        XCTAssertEqual(store.notice, NowStore.Notice(text: "Deleted — not sent", failed: false))
        XCTAssertFalse(store.deletingHeld.contains("c1"))
        store.finishDeletingHeld("c1", result: HeldOutbox.retractResult(.tooLate))
        XCTAssertEqual(store.notice, NowStore.Notice(text: "Too late — it was already typed", failed: true))
    }

    func testAReplyHeldUntilTheResetIsNotShownAsDelivered() {
        let held = ReplyFinished(interventionId: "ratelimit-1", success: true, method: "held_until_reset",
                                 detail: "Will send it when the limit resets at 3:00 PM")
        XCTAssertEqual(ReplyOutcomeMapper.outcome(for: held), .queued)
        let typed = ReplyFinished(interventionId: "p", success: true, method: "tmux", detail: "Typed into tmux pane %3")
        XCTAssertEqual(ReplyOutcomeMapper.outcome(for: typed), .delivered)
    }

    func testACancelledResultReadsAsNotTyped() {
        let r = SessionCommandResult(code: .cancelled, reason: .cancelled, detail: HeldOutbox.deletedDetail)
        XCTAssertEqual(InFlightReceipt.from(r, route: nil, at: now).outcome, .refused("Deleted — not sent"))
    }
}
