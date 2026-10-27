import XCTest
@testable import ClaudePowerMode

/// The popover's In-flight rows: building them, what each can do per host,
/// the live preview, the receipts, the keys, and the discoverability pieces
/// (action names, the shortcut sheet's source, the first-run tip).
final class InFlightTests: XCTestCase {
    private let now = NightWatchFixtures.boardNow()
    private let cmux = SessionHostInfo(host: "cmux", canType: true, typeBlocker: nil, canInterrupt: true)
    private let tmux = SessionHostInfo(host: "tmux", canType: true, typeBlocker: nil, canInterrupt: true)

    private func session(_ name: String, state: AgentSessionState = .active, ago: TimeInterval? = nil,
                         backend: AgentBackendID = .claude, title: String? = nil) -> AgentSession {
        AgentSession(backend: backend, sessionId: "sess-\(name)", cwd: "/Users/roy/projects/\(name)", title: title,
                     source: .terminal, state: state, lastActivityAt: ago.map { now.addingTimeInterval(-$0) },
                     activeFlags: [], supportsRemoteReply: true)
    }

    private func build(_ sessions: [AgentSession], hosts: [String: SessionHostInfo] = [:], activity: [String: String] = [:],
                       local: [LocalActivity] = []) -> [InFlightRow] {
        var snap = NightWatchFixtures.snapshot(sessions: sessions)
        snap.localModels = local
        // A test session's `ago` stands for the session file's busy-since.
        let since = Dictionary(uniqueKeysWithValues: sessions.compactMap { s in s.lastActivityAt.map { (s.sessionId, $0) } })
        return InFlightRows.build(snap, hosts: hosts, activity: activity, busySince: since, now: now)
    }

    private func row(host: SessionHostInfo?, working: Bool = true, name: String = "page") -> InFlightRow {
        var r = build([session(name, ago: 120)], hosts: host.map { ["sess-\(name)": $0] } ?? [:])[0]
        if !working { r = r.finished }
        return r
    }

    private func key(_ k: NowKeyPress.Key, phase: NowKeyPress.Phase = .down) -> NowKeyPress {
        NowKeyPress(key: k, phase: phase)
    }

    // MARK: rows

    func testOnlyWorkingSessionsBecomeRowsInAStableProjectOrder() {
        let rows = build([session("a", ago: 60), session("b", state: .waitingOnApproval, ago: 5),
                          session("c", ago: 3600), session("d", state: .idle, ago: 2), session("e", ago: 600)])
        XCTAssertEqual(rows.map(\.project), ["a", "c", "e"], "by project name, never by elapsed time or activity")
        XCTAssertEqual(rows.map(\.elapsed), ["1m", "1h", "10m"])
        XCTAssertTrue(rows.allSatisfy { $0.id.hasPrefix(InFlightRow.idPrefix) && $0.kind == .session })
    }

    func testRowShowsProjectRouteAndWhatItIsDoing() {
        let r = build([session("page", ago: 4 * 60)], hosts: ["sess-page": cmux],
                      activity: ["sess-page": "Bash: swift test"])[0]
        XCTAssertEqual(r.project, "page")
        XCTAssertEqual(r.route, "cmux › page")
        XCTAssertEqual(r.doing, "Bash: swift test")
        XCTAssertEqual(r.elapsed, "4m")
        XCTAssertEqual(r.sessionId, "sess-page")
        XCTAssertEqual(r.target?.expectCwd, SessionRemote.homeAbbreviated("/Users/roy/projects/page"))
    }

    func testWithoutAnyProbeTheRowSaysWorkingAndHasNoRoute() {
        let r = build([session("page")])[0]
        XCTAssertEqual(r.doing, "working")
        XCTAssertNil(r.route)
        XCTAssertNil(r.elapsed, "no activity time, no elapsed")
        XCTAssertTrue(r.actions.checking)
        // A blank step reads as working too.
        XCTAssertEqual(build([session("page")], activity: ["sess-page": "   "])[0].doing, "working")
    }

    func testElapsedComesOnlyFromABusySinceNeverFromALastWriteTime() {
        let s = session("page", ago: 120)   // lastActivityAt can be a transcript's mtime
        let snap = NightWatchFixtures.snapshot(sessions: [s])
        let none = InFlightRows.build(snap, hosts: [:], activity: [:], now: now)[0]
        XCTAssertNil(none.elapsed, "no busy-since, no elapsed: never 'working for 2m' from a last write")
        XCTAssertNil(none.since)
        let known = InFlightRows.build(snap, hosts: [:], activity: [:], busySince: ["sess-page": now.addingTimeInterval(-300)], now: now)[0]
        XCTAssertEqual(known.elapsed, "5m")
    }

    func testALongStepIsClipped() {
        let long = String(repeating: "x", count: 300)
        let r = build([session("page")], activity: ["sess-page": long])[0]
        XCTAssertLessThanOrEqual(r.doing.count, InFlightRows.maxDoing)
        XCTAssertTrue(r.doing.hasSuffix("…"))
    }

    func testBusyLocalModelsAreRowsToo_withNoActions() {
        let busy = LocalActivity(id: "ollama", displayName: "Ollama", kind: .server, busy: true, signal: .exact, detail: "generating · exact")
        let idle = LocalActivity(id: "lms", displayName: "LM Studio", kind: .app, busy: false, signal: .none, detail: "idle")
        let rows = build([session("page", ago: 60)], local: [busy, idle])
        XCTAssertEqual(rows.map(\.project), ["Ollama", "page"], "by project name, like the phone")
        let l = rows[0]
        XCTAssertEqual(l.kind, .localModel)
        XCTAssertEqual(l.doing, "generating · exact")
        XCTAssertFalse(l.actions.canOpen)
        XCTAssertFalse(l.actions.canType)
        XCTAssertNotNil(l.actions.openBlocker)
        XCTAssertNotNil(l.actions.typeBlocker)
        XCTAssertNil(l.target)
    }

    func testCodexMidTurnOutsideCmuxCannotBeTypedInto() {
        let codexTmux = tmux
        let r = build([session("cx", ago: 30, backend: .codex)], hosts: ["sess-cx": codexTmux])[0]
        XCTAssertTrue(r.actions.canOpen)
        XCTAssertFalse(r.actions.canType)
        XCTAssertEqual(r.actions.typeBlocker, SessionInputGate.codexMidTurnMessage)
        let inCmux = build([session("cx", ago: 30, backend: .codex)], hosts: ["sess-cx": cmux])[0]
        XCTAssertTrue(inCmux.actions.canType)
    }

    func testNowModelCarriesTheRowsAndKeepsTheOldStrip() {
        let i = NightWatchFixtures.oneWaitingTwoInFlight()
        let m = NowModel.build(i)
        XCTAssertEqual(m.rows.count, 1)
        XCTAssertEqual(m.inFlight.count, 2, "the legacy strip's data is unchanged")
        XCTAssertEqual(m.flight.map(\.project), ["llm-play", "page"])
        XCTAssertEqual(m.flight.map(\.id), m.flight.map { InFlightRow.idPrefix + $0.sessionId })
        XCTAssertFalse(m.rows.contains { $0.id.hasPrefix(InFlightRow.idPrefix) }, "in-flight rows are never page rows")
    }

    func testElapsedFormats() {
        func e(_ s: TimeInterval) -> String { InFlightRows.elapsed(since: now.addingTimeInterval(-s), now: now) }
        XCTAssertEqual(e(0), "0s")
        XCTAssertEqual(e(42), "42s")
        XCTAssertEqual(e(60), "1m")
        XCTAssertEqual(e(59 * 60 + 59), "59m")
        XCTAssertEqual(e(3600), "1h")
        XCTAssertEqual(e(3600 + 12 * 60), "1h 12m")
        XCTAssertEqual(e(-30), "0s", "a clock that ran backwards never shows a negative")
    }

    // MARK: what each row can do, per host

    func testOpenNeedsAFocusableHostAndTypeNeedsCanType() {
        let unknown = InFlightActions.resolve(host: nil)
        XCTAssertTrue(unknown.canOpen, "not probed: Open finds the pane itself")
        XCTAssertFalse(unknown.canType)
        XCTAssertTrue(unknown.checking)

        let ok = InFlightActions.resolve(host: cmux)
        XCTAssertTrue(ok.canOpen); XCTAssertTrue(ok.canType)
        XCTAssertNil(ok.openBlocker); XCTAssertNil(ok.typeBlocker); XCTAssertFalse(ok.checking)

        let ghostty = InFlightActions.resolve(host: .blocked("Ghostty", "Page can't type into Ghostty yet"))
        XCTAssertTrue(ghostty.canOpen, "a terminal app can still be brought forward")
        XCTAssertFalse(ghostty.canType)
        XCTAssertEqual(ghostty.typeBlocker, "Page can't type into Ghostty yet")

        let background = InFlightActions.resolve(host: .blocked("background", "no terminal"))
        XCTAssertFalse(background.canOpen)
        XCTAssertNotNil(background.openBlocker)
        XCTAssertFalse(background.canType)

        let desktop = InFlightActions.resolve(host: .blocked("desktop", "Codex app"))
        XCTAssertFalse(desktop.canOpen)
        XCTAssertTrue(desktop.openBlocker?.contains("Codex app") == true)

        XCTAssertFalse(InFlightActions.localModel.canOpen)
        XCTAssertFalse(InFlightActions.localModel.canType)
    }

    func testABlockedHostWithNoReasonStillGetsOne() {
        let h = SessionHostInfo(host: "unknown", canType: false, typeBlocker: nil, canInterrupt: false)
        XCTAssertNotNil(InFlightActions.resolve(host: h).typeBlocker)
    }

    // MARK: the live preview

    func testPreviewWhileBusyNamesTheRouteAndThatItQueues() {
        let r = row(host: cmux)
        let p = InFlightPreview.line(for: r, text: "also run the Terminals tests", macName: "Studio MBP")
        XCTAssertEqual(p.text, "Will type · Return · cmux › page · queues after this step")
        XCTAssertTrue(p.ok)
    }

    func testPreviewBeforeAnythingIsTyped() {
        let p = InFlightPreview.line(for: row(host: cmux), text: "  ", macName: "Studio MBP")
        XCTAssertEqual(p.text, "Type a message · Return sends · cmux › page · queues after this step")
        XCTAssertTrue(p.ok)
    }

    func testPreviewOnceTheTurnHasEndedNamesTheMacInsteadOfQueueing() {
        let r = row(host: cmux, working: false)
        let p = InFlightPreview.line(for: r, text: "hello", macName: "Studio MBP")
        XCTAssertEqual(p.text, "Will type · Return · cmux › page · Studio MBP")
        XCTAssertFalse(p.text.contains("queues"))
    }

    func testPreviewRefusesWhatTheGateWouldRefuse() {
        let busy = row(host: cmux)
        let digit = InFlightPreview.line(for: busy, text: "2 more cases", macName: "Mac")
        XCTAssertFalse(digit.ok)
        XCTAssertEqual(digit.text, SessionInputGate.digitWhileBusyMessage)
        // Not busy: a leading digit is fine.
        XCTAssertTrue(InFlightPreview.line(for: row(host: cmux, working: false), text: "2 more cases", macName: "Mac").ok)
        let tooLong = InFlightPreview.line(for: busy, text: String(repeating: "a", count: SessionInputGate.maxTextLength + 1), macName: "Mac")
        XCTAssertFalse(tooLong.ok)
    }

    func testPreviewWhenPageCannotTypeHereSaysWhy() {
        let r = row(host: .blocked("Ghostty", "Page can't type into Ghostty yet"))
        let p = InFlightPreview.line(for: r, text: "hello", macName: "Mac")
        XCTAssertFalse(p.ok)
        XCTAssertEqual(p.text, "Can't steer here · Page can't type into Ghostty yet")
    }

    // MARK: receipts

    func testReceiptFromTheInputPathsResults() {
        let route = "cmux › page"
        let typed = InFlightReceipt.from(SessionCommandResult(code: .delivered, reason: nil, detail: "Sent"), route: route, at: now)
        XCTAssertEqual(typed.outcome, .typed)
        XCTAssertTrue(typed.line(timeZone: TimeZone(identifier: "UTC")!).hasPrefix("Typed · cmux › page · "))
        XCTAssertFalse(typed.failed)

        let queued = InFlightReceipt.from(SessionCommandResult(code: .queued, reason: nil, detail: SessionInputGate.queuedMessage), route: route, at: now)
        XCTAssertEqual(queued.outcome, .queued)
        XCTAssertTrue(queued.line().hasPrefix("Queued · cmux › page"))
        XCTAssertFalse(queued.failed)

        let refused = InFlightReceipt.from(.refused(.waiting, SessionInputGate.waitingMessage), route: route, at: now)
        XCTAssertEqual(refused.outcome, .refused(SessionInputGate.waitingMessage))
        XCTAssertEqual(refused.line(), "Refused · A prompt is waiting — answer it first")
        XCTAssertTrue(refused.failed)

        let failed = InFlightReceipt.from(.failed("Couldn't type into the session"), route: nil, at: now)
        XCTAssertTrue(failed.failed)
        XCTAssertEqual(InFlightReceipt(outcome: .sending, route: nil, at: now).line(), "Typing…")
        XCTAssertEqual(InFlightReceipt(outcome: .refused(""), route: nil, at: now).line(), "Refused · Couldn't type into the session")
    }

    // MARK: where a message goes

    func testTheCommandIsTheInputOpAndNeverACustomReply() {
        let s = session("page", ago: 60, title: "My title")
        let t = InFlightTarget(session: s)
        let cmd = t.command(text: "hello", clientId: "mac-1", ts: 1_761_300_000_000)
        XCTAssertEqual(cmd.op, "input")
        XCTAssertNotEqual(cmd.op, "custom")
        XCTAssertEqual(cmd.sessionId, "sess-page")
        XCTAssertEqual(cmd.text, "hello")
        XCTAssertEqual(cmd.expectCwd, SessionRemote.homeAbbreviated("/Users/roy/projects/page"))
        XCTAssertEqual(cmd.expectTitle, "My title")
        XCTAssertFalse(cmd.local, "only SessionRemote.performLocal marks a command local")
        XCTAssertNil(cmd.viewer)
    }

    func testTheCommandPassesTheTargetCheckForItsOwnSessionAndNotForAnother() {
        let s = session("page", ago: 60)
        let cmd = InFlightTarget(session: s).command(text: "hi", ts: 0)
        XCTAssertNil(SessionTargetCheck.verify(cmd, against: s))
        let moved = AgentSession(backend: .claude, sessionId: s.sessionId, cwd: "/Users/roy/projects/other", title: nil,
                                 source: .terminal, state: .active, lastActivityAt: nil, activeFlags: [], supportsRemoteReply: true)
        XCTAssertEqual(SessionTargetCheck.verify(cmd, against: moved)?.reason, .targetMismatch)
    }

    // MARK: layout

    func testGroupShowsThreeThenMoreAndCollapses() {
        let rows = (0..<5).map { n in build([session("p\(n)", ago: Double(n + 1) * 60)])[0] }
        let compact = InFlightLayout.visible(rows, collapsed: false, expanded: false)
        XCTAssertEqual(compact.shown.count, 3)
        XCTAssertEqual(compact.more, 2)
        let open = InFlightLayout.visible(rows, collapsed: false, expanded: true)
        XCTAssertEqual(open.shown.count, 5)
        XCTAssertEqual(open.more, 0)
        let folded = InFlightLayout.visible(rows, collapsed: true, expanded: true)
        XCTAssertTrue(folded.shown.isEmpty)
        XCTAssertEqual(folded.more, 5)
        XCTAssertEqual(InFlightLayout.visible(Array(rows.prefix(3)), collapsed: false, expanded: false).more, 0)
        XCTAssertEqual(InFlightLayout.title(count: 2), "In flight · 2")
        XCTAssertEqual(InFlightLayout.names(rows), "p0 · p1 · p2")
    }

    // MARK: the classic menu

    func testMenuLeavesOutStepAndElapsedWhenTheyAreStale() {
        let rows = build([session("page", ago: 4 * 60)], hosts: ["sess-page": cmux], activity: ["sess-page": "Bash: swift test"])
        let stale = InFlightMenu.entries(rows, fresh: false)[0]
        XCTAssertEqual(stale.title, "page — cmux › page", "no elapsed time from an earlier turn")
        XCTAssertEqual(stale.doing, "working")
        XCTAssertTrue(stale.openEnabled)
        XCTAssertTrue(stale.typeEnabled)
    }

    func testNoActionButtonIsAKeyAloneEveryOneSaysItsName() {
        XCTAssertEqual(KeyHint.Action.openTerminal.title, "Open")
        XCTAssertEqual(KeyHint.Action.tellInstead.title, "Steer")
        XCTAssertEqual(KeyHint.Action.approve.title, "Approve")
        XCTAssertEqual(KeyHint.Action.deny.title, "Deny")
        XCTAssertEqual(KeyHint.Action.approveHold.title, "Hold to approve")
    }

    func testAnUnansweredTypeIsNeverCalledRefused() {
        let r = InFlightReceipt(outcome: .unconfirmed, route: "cmux › page", at: now)
        XCTAssertEqual(r.line(), "No answer yet · check the terminal before retyping")
        XCTAssertFalse(r.line().contains("Refused"))
        XCTAssertTrue(r.failed, "drawn in amber")
    }

    func testMenuEntriesOnePerWorkingSessionWithTitleAndAvailability() {
        let busy = LocalActivity(id: "ollama", displayName: "Ollama", kind: .server, busy: true, signal: .exact, detail: "generating")
        let rows = build([session("page", ago: 4 * 60), session("pay", ago: 60), session("bg", ago: 30)],
                         hosts: ["sess-page": cmux, "sess-pay": .blocked("Ghostty", "Page can't type into Ghostty yet"),
                                 "sess-bg": .blocked("background", "no terminal")],
                         activity: ["sess-page": "Bash: swift test"], local: [busy])
        let entries = InFlightMenu.entries(rows)
        XCTAssertEqual(entries.map(\.sessionId), ["sess-bg", "sess-page", "sess-pay"], "local models are not listed")
        let page = entries[1]
        XCTAssertEqual(page.title, "page — cmux › page · 4m")
        XCTAssertEqual(page.doing, "Bash: swift test")
        XCTAssertTrue(page.openEnabled); XCTAssertTrue(page.typeEnabled)
        let pay = entries[2]
        XCTAssertTrue(pay.openEnabled); XCTAssertFalse(pay.typeEnabled)
        XCTAssertEqual(pay.typeNote, "Page can't type into Ghostty yet")
        let bg = entries[0]
        XCTAssertFalse(bg.openEnabled); XCTAssertFalse(bg.typeEnabled)
        XCTAssertNotNil(bg.openNote)
        // Unprobed: Type… stays enabled (it opens the panel, which finishes the check).
        let unprobed = InFlightMenu.entries(build([session("x", ago: 10)]))[0]
        XCTAssertTrue(unprobed.openEnabled); XCTAssertTrue(unprobed.typeEnabled)
        XCTAssertEqual(unprobed.title, "x · 10s")
    }

    // MARK: keys

    private func rowsAndFlights() -> (rows: [DecideRow], flights: [InFlightRow]) {
        let m = NowModel.build(NightWatchFixtures.oneWaitingTwoInFlight())
        return (m.rows, m.flight)
    }

    private func handle(_ k: NowKeyPress, _ s: NowPanelState, rows: [DecideRow]? = nil, flights: [InFlightRow]? = nil)
        -> (state: NowPanelState, effect: NowEffect) {
        let base = rowsAndFlights()
        return NowKeys.handle(k, state: s, rows: rows ?? base.rows, flights: flights ?? base.flights, now: now)
    }

    func testArrowsReachInFlightRowsAfterThePages() {
        let (rows, flights) = rowsAndFlights()
        var s = NowPanelState()
        var order: [String] = []
        for _ in 0..<3 {
            s = handle(key(.down), s).state
            order.append(s.selectedId ?? "-")
        }
        XCTAssertEqual(order, [rows[0].id] + flights.map(\.id))
        // The end stays on the last row; up walks back.
        XCTAssertEqual(handle(key(.down), s).state.selectedId, flights.last?.id)
        XCTAssertEqual(handle(key(.up), s).state.selectedId, flights.first?.id)
        // Up from nothing lands on the last row, which is in flight.
        XCTAssertEqual(handle(key(.up), NowPanelState()).state.selectedId, flights.last?.id)
    }

    func testCollapsedGroupIsSkippedByTheArrows() {
        let (rows, _) = rowsAndFlights()
        var s = NowPanelState()
        s.inFlightCollapsed = true
        s = handle(key(.down), s).state
        s = handle(key(.down), s).state
        XCTAssertEqual(s.selectedId, rows[0].id)
    }

    func testReachingAFourthInFlightRowOpensTheRest() {
        let many = (0..<5).map { n in build([session("p\(n)", ago: Double(n + 1) * 60)], hosts: ["sess-p\(n)": cmux])[0] }
        var s = NowPanelState()
        for _ in 0..<InFlightLayout.cap { s = handle(key(.down), s, rows: [], flights: many).state }
        XCTAssertFalse(s.inFlightExpanded)
        s = handle(key(.down), s, rows: [], flights: many).state
        XCTAssertTrue(s.inFlightExpanded)
        XCTAssertEqual(s.selectedId, many[3].id)
    }

    func testOOpensTheSessionsTerminal() {
        let (_, flights) = rowsAndFlights()
        var s = NowPanelState(); s.selectedId = flights[0].id
        let r = handle(key(.char("o")), s)
        XCTAssertEqual(r.effect, .openSession(sessionId: flights[0].sessionId, backend: .claude))
        XCTAssertEqual(handle(NowKeyPress(key: .char("o"), isRepeat: true), s).effect, .none, "a held key opens once")
    }

    func testOIsRefusedWhereThereIsNothingToOpen() {
        let bg = row(host: .blocked("background", "no terminal"), name: "bg")
        var s = NowPanelState(); s.selectedId = bg.id
        XCTAssertEqual(handle(key(.char("o")), s, flights: [bg]).effect, .none)
        let local = build([], local: [LocalActivity(id: "ollama", displayName: "Ollama", kind: .server, busy: true, signal: .exact, detail: "x")])[0]
        s.selectedId = local.id
        XCTAssertEqual(handle(key(.char("o")), s, flights: [local]).effect, .none)
        XCTAssertEqual(handle(key(.char("t")), s, flights: [local]).effect, .none)
        XCTAssertNil(handle(key(.char("t")), s, flights: [local]).state.composer)
    }

    func testTOpensATypeComposerWithTheCapturedTarget() {
        let (_, flights) = rowsAndFlights()
        var s = NowPanelState(); s.selectedId = flights[1].id
        let r = handle(key(.char("t")), s)
        XCTAssertEqual(r.effect, .none, "opening the box sends nothing")
        XCTAssertEqual(r.state.composer?.rowId, flights[1].id)
        XCTAssertEqual(r.state.composer?.kind, .type)
        XCTAssertEqual(r.state.composer?.target, flights[1].target)
    }

    func testTIsRefusedWhenPageCannotTypeThere() {
        let ghostty = row(host: .blocked("Ghostty", "no"), name: "pay")
        var s = NowPanelState(); s.selectedId = ghostty.id
        XCTAssertNil(handle(key(.char("t")), s, flights: [ghostty]).state.composer)
        let unprobed = build([session("x", ago: 5)])[0]
        s.selectedId = unprobed.id
        XCTAssertNil(handle(key(.char("t")), s, flights: [unprobed]).state.composer, "not until the host is known")
    }

    func testReturnInATypeComposerTypesAndNeverSendsAPageReply() {
        let (_, flights) = rowsAndFlights()
        var s = NowPanelState()
        s.selectedId = flights[0].id
        s.composer = NowPanelState.Composer(rowId: flights[0].id, text: "  also run the Terminals tests ", kind: .type, target: flights[0].target)
        let r = handle(key(.ret), s)
        XCTAssertEqual(r.effect, .typeInto(flights[0].target!, text: "also run the Terminals tests"))
        XCTAssertNil(r.state.composer)
        XCTAssertEqual(r.state.selectedId, flights[0].id, "the row stays selected so its receipt shows")
        if case .send = r.effect { XCTFail("a working session is never sent Esc + text") }
        // Empty text and a held Return send nothing.
        s.composer?.text = "  "
        XCTAssertEqual(handle(key(.ret), s).effect, .none)
        s.composer?.text = "hi"
        XCTAssertEqual(handle(NowKeyPress(key: .ret, isRepeat: true), s).effect, .none)
        // A composer with no captured target cannot send.
        s.composer = NowPanelState.Composer(rowId: flights[0].id, text: "hi", kind: .type, target: nil)
        XCTAssertEqual(handle(key(.ret), s).effect, .none)
    }

    func testEscInTheComposerClosesItAndNothingElse() {
        let (_, flights) = rowsAndFlights()
        var s = NowPanelState()
        s.selectedId = flights[0].id
        s.composer = NowPanelState.Composer(rowId: flights[0].id, text: "draft", kind: .type, target: flights[0].target)
        let r = handle(key(.esc), s)
        XCTAssertNil(r.state.composer)
        XCTAssertEqual(r.effect, .none)
        XCTAssertEqual(r.state.selectedId, flights[0].id)
    }

    func testThePageReplyComposerStillSendsEscTextReturn() {
        let (rows, _) = rowsAndFlights()
        var s = NowPanelState()
        s.selectedId = rows[0].id
        s.composer = NowPanelState.Composer(rowId: rows[0].id, text: "use a branch")
        XCTAssertEqual(handle(key(.ret), s).effect, .send(rowId: rows[0].id, text: "use a branch"))
    }

    func testEscOneAndReturnOnAnInFlightRowNeverDenyApproveOrSend() {
        let (_, flights) = rowsAndFlights()
        var s = NowPanelState(); s.selectedId = flights[0].id
        let esc = handle(key(.esc), s)
        XCTAssertEqual(esc.effect, .none, "Esc lets go of the row; it must not close the panel or interrupt the session")
        XCTAssertNil(esc.state.selectedId)
        XCTAssertEqual(handle(key(.char("1")), s).effect, .none)
        XCTAssertEqual(handle(key(.ret), s).effect, .none)
        XCTAssertNil(handle(key(.char("1")), s).state.hold, "1 never starts an approve hold on a working session")
        for c in ["2", "y", "n", "a", "d"] {
            XCTAssertEqual(handle(key(.char(Character(c))), s).effect, .none, c)
        }
    }

    func testTypingKeysWithTheComposerOpenAreTextNotShortcuts() {
        let (_, flights) = rowsAndFlights()
        var s = NowPanelState()
        s.selectedId = flights[0].id
        s.composer = NowPanelState.Composer(rowId: flights[0].id, kind: .type, target: flights[0].target)
        for c in ["?", "o", "t", "1", "m"] {
            let r = handle(key(.char(Character(c))), s)
            XCTAssertEqual(r.effect, .none, c)
            XCTAssertFalse(r.state.showShortcuts, c)
            XCTAssertNotNil(r.state.composer, c)
        }
    }

    func testQuestionMarkOpensTheShortcutsSheetAndEscClosesIt() {
        var s = handle(key(.char("?")), NowPanelState()).state
        XCTAssertTrue(s.showShortcuts)
        // Nothing else acts under the sheet.
        XCTAssertEqual(handle(key(.char("1")), s).effect, .none)
        XCTAssertEqual(handle(key(.down), s).state.selectedId, nil)
        XCTAssertTrue(handle(key(.char("o")), s).state.showShortcuts)
        // Esc closes the sheet, not the panel.
        let esc = handle(key(.esc), s)
        XCTAssertFalse(esc.state.showShortcuts)
        XCTAssertEqual(esc.effect, .none)
        s = handle(key(.char("/")), NowPanelState()).state
        XCTAssertTrue(s.showShortcuts, "the unshifted key works too")
        XCTAssertFalse(handle(key(.char("?")), s).state.showShortcuts, "the key toggles it")
    }

    func testReconcileKeepsAnInFlightSelectionAndComposerWhileTheRowLives() {
        let (rows, flights) = rowsAndFlights()
        var s = NowPanelState()
        s.selectedId = flights[0].id
        s.composer = NowPanelState.Composer(rowId: flights[0].id, text: "draft", kind: .type, target: flights[0].target)
        let kept = NowKeys.reconcile(s, rows: rows, flights: flights)
        XCTAssertEqual(kept.selectedId, flights[0].id)
        XCTAssertEqual(kept.composer?.text, "draft")
        // Without the rows in the list (the old call shape) they would be dropped.
        let dropped = NowKeys.reconcile(s, rows: rows, flights: [])
        XCTAssertNil(dropped.selectedId)
        XCTAssertNil(dropped.composer)
    }

    func testFlightClickEffects() {
        let ok = row(host: cmux)
        XCTAssertEqual(NowKeys.effect(forFlightClick: .open, row: ok), .openSession(sessionId: ok.sessionId, backend: .claude))
        XCTAssertEqual(NowKeys.effect(forFlightClick: .steer, row: ok), .none, "Type… opens the box; it sends nothing itself")
        let bg = row(host: .blocked("background", "x"))
        XCTAssertEqual(NowKeys.effect(forFlightClick: .open, row: bg), .none)
    }

    // MARK: the store

    private func store(_ i: NowInputs? = nil, prefs: NowPrefs = .ephemeral()) -> (NowStore, () -> [NowEffect]) {
        let inputs = i ?? NightWatchFixtures.oneWaitingTwoInFlight()
        let st = NowStore(model: NowModel.build(inputs), prefs: prefs)
        st.now = { inputs.now }
        var effects: [NowEffect] = []
        st.perform = { effects.append($0) }
        return (st, { effects })
    }

    private var pageRow: String { InFlightRow.idPrefix + "sess-page" }

    func testPointingAtARowSelectsItButNeverMovesADraft() {
        let (st, _) = store()
        st.hoverFlight(pageRow)
        XCTAssertEqual(st.selectedId, pageRow)
        st.handle(NowKeyPress(key: .char("t")))
        XCTAssertNotNil(st.composer)
        st.hoverFlight(InFlightRow.idPrefix + "sess-llm-play")
        XCTAssertEqual(st.selectedId, pageRow, "a draft stays on its row")
    }

    func testRowsShiftingUnderAStillPointerNeverTakeTheSelection() {
        let (st, _) = store()
        guard let decision = st.model.rows.first?.id else { return XCTFail("the scene has a decision row") }
        st.select(decision)
        // The first hover with a decision row selected, and any hover from a pointer that has not moved, do nothing.
        st.hoverFlight(pageRow, pointer: CGPoint(x: 10, y: 10))
        XCTAssertEqual(st.selectedId, decision)
        st.hoverFlight(pageRow, pointer: CGPoint(x: 10, y: 10))
        XCTAssertEqual(st.selectedId, decision, "still pointer: the content moved, not the mouse")
        // A real move onto a card selects it.
        st.hoverFlight(pageRow, pointer: CGPoint(x: 14, y: 30))
        XCTAssertEqual(st.selectedId, pageRow)
    }

    func testTypeFromTheKeyboardSendsOneTypeIntoEffectAndShowsTheReceipt() {
        let (st, effects) = store()
        st.hoverFlight(pageRow)
        st.handle(NowKeyPress(key: .char("t")))
        st.composerText = "run the Stuck tests too"
        st.handle(NowKeyPress(key: .ret))
        let target = st.model.flight.first { $0.id == pageRow }!.target!
        XCTAssertEqual(effects(), [.typeInto(target, text: "run the Stuck tests too")])
        XCTAssertEqual(st.flightReceipts[pageRow]?.outcome, .sending)
        XCTAssertNil(st.composer)
        XCTAssertTrue(st.sending.isEmpty, "not a page reply: no receipt thread and no sending row")
        XCTAssertTrue(st.motion.threads.isEmpty)
        st.finishTyping(sessionId: "sess-page", result: SessionCommandResult(code: .queued, reason: nil, detail: SessionInputGate.queuedMessage))
        XCTAssertEqual(st.flightReceipts[pageRow]?.outcome, .queued)
        XCTAssertEqual(st.flightReceipts[pageRow]?.route, "cmux › page")
        st.finishTyping(sessionId: "sess-page", result: .refused(.waiting, "A prompt is waiting — answer it first"))
        XCTAssertTrue(st.flightReceipts[pageRow]?.failed == true)
    }

    func testAReceiptSurvivesTheCloseOfThePanelSoALateAnswerStillShows() {
        let (st, effects) = store()
        st.hoverFlight(pageRow)
        st.handle(NowKeyPress(key: .char("t")))
        st.composerText = "hello"
        st.handle(NowKeyPress(key: .ret))
        XCTAssertEqual(effects().count, 1)
        XCTAssertEqual(st.flightReceipts[pageRow]?.outcome, .sending)
        st.reset()   // the panel closes (a click elsewhere) before the Mac answers
        XCTAssertEqual(st.flightReceipts[pageRow]?.outcome, .sending, "still waiting for the answer")
        st.finishTyping(sessionId: "sess-page", result: .refused(.waiting, "A prompt is waiting — answer it first"))
        st.reset()   // and it opens again
        XCTAssertEqual(st.flightReceipts[pageRow]?.failed, true, "the refusal is there to read")
    }

    func testClickingTypeOpensTheComposerAndClickingOpenAsksToOpen() {
        let (st, effects) = store()
        let row = st.model.flight.first { $0.id == pageRow }!
        st.clickFlight(.steer, on: row)
        XCTAssertEqual(st.composer?.rowId, pageRow)
        XCTAssertEqual(st.composer?.kind, .type)
        XCTAssertTrue(effects().isEmpty)
        st.clickFlight(.open, on: row)
        XCTAssertNil(st.composer, "choosing Open closes a draft")
        XCTAssertEqual(effects(), [.openSession(sessionId: "sess-page", backend: .claude)])
    }

    func testClickingAnotherRowsButtonKeepsAHalfTypedMessage() {
        let (st, effects) = store()
        let page = st.model.flight.first { $0.id == pageRow }!
        let other = st.model.flight.first { $0.id != pageRow }!
        st.clickFlight(.steer, on: page)
        st.composerText = "half a thought"
        st.clickFlight(.open, on: other)
        XCTAssertEqual(st.composer?.text, "half a thought", "the draft survives a click elsewhere")
        XCTAssertEqual(st.composer?.rowId, pageRow)
        XCTAssertNotNil(st.notice)
        XCTAssertTrue(effects().isEmpty)
        // An empty box still gives way.
        st.composerText = ""
        st.clickFlight(.open, on: other)
        XCTAssertNil(st.composer)
        XCTAssertEqual(effects(), [.openSession(sessionId: other.sessionId, backend: .claude)])
    }

    func testTOnABlockedSelectedRowExplainsInsteadOfStayingSilent() {
        let (st, effects) = store(NightWatchFixtures.oneWaitingTwoInFlight(blocked: true))
        st.hoverFlight(InFlightRow.idPrefix + "sess-payments-api")
        XCTAssertNil(st.notice)
        st.handle(NowKeyPress(key: .char("t")))
        XCTAssertNil(st.composer)
        XCTAssertEqual(st.notice?.failed, true)
        XCTAssertTrue(st.notice?.text.contains("Ghostty") == true)
        XCTAssertTrue(effects().isEmpty)
    }

    func testClickingTypeWhereItCannotWorkExplainsInsteadOfOpeningABox() {
        let (st, effects) = store(NightWatchFixtures.oneWaitingTwoInFlight(blocked: true))
        let row = st.model.flight.first { $0.sessionId == "sess-payments-api" }!
        st.clickFlight(.steer, on: row)
        XCTAssertNil(st.composer)
        XCTAssertEqual(st.notice?.failed, true)
        XCTAssertTrue(st.notice?.text.contains("Ghostty") == true)
        XCTAssertTrue(effects().isEmpty)
    }

    func testARowKeepsItsPlaceWhileADraftIsOpenAfterItsTurnEnds() {
        let inputs = NightWatchFixtures.oneWaitingTwoInFlight()
        let (st, _) = store(inputs)
        st.hoverFlight(pageRow)
        st.handle(NowKeyPress(key: .char("t")))
        st.composerText = "keep this draft"
        // The next snapshot: page finished its turn.
        var done = inputs
        done.snapshot = NightWatchFixtures.snapshot(
            sessions: inputs.snapshot.sessions.map { s in
                s.sessionId == "sess-page"
                    ? AgentSession(backend: s.backend, sessionId: s.sessionId, cwd: s.cwd, title: nil, source: .terminal,
                                   state: .idle, lastActivityAt: nil, activeFlags: [], supportsRemoteReply: true)
                    : s },
            pending: inputs.snapshot.pendingInterventions)
        st.update(NowModel.build(done))
        XCTAssertEqual(st.model.flight.map(\.sessionId), ["sess-llm-play"])
        let kept = st.flightRows.first { $0.id == pageRow }
        XCTAssertNotNil(kept, "the draft's row stays")
        XCTAssertEqual(kept?.working, false)
        XCTAssertEqual(st.composer?.text, "keep this draft")
        XCTAssertEqual(st.selectedId, pageRow)
        // Its preview stops promising to queue.
        let p = InFlightPreview.line(for: kept!, text: "keep this draft", macName: "Studio MBP")
        XCTAssertFalse(p.text.contains("queues"))
        // Closing the draft lets the row go.
        st.cancelComposer()
        XCTAssertNil(st.flightRows.first { $0.id == pageRow })
    }

    func testCollapsingIsRememberedAndDropsAnInFlightSelection() {
        let prefs = NowPrefs.ephemeral()
        let (st, _) = store(prefs: prefs)
        st.hoverFlight(pageRow)
        st.setInFlightCollapsed(true)
        XCTAssertNil(st.selectedId)
        XCTAssertTrue(prefs.inFlightCollapsed)
        let (next, _) = store(prefs: prefs)
        XCTAssertTrue(next.state.inFlightCollapsed, "a new store starts as it was left")
        next.reset()
        XCTAssertTrue(next.state.inFlightCollapsed, "and so does the panel after it closes and opens")
        next.setInFlightCollapsed(false)
        XCTAssertFalse(prefs.inFlightCollapsed)
    }

    func testMenuTypeWaitsForTheHostProbeThenOpensTheComposer() {
        var inputs = NightWatchFixtures.oneWaitingTwoInFlight()
        inputs.hosts = [:]
        let (st, _) = store(inputs)
        st.requestComposer(forSessionId: "sess-page")
        XCTAssertNil(st.composer, "host not probed yet")
        inputs.hosts = ["sess-page": cmux]
        st.update(NowModel.build(inputs))
        XCTAssertEqual(st.composer?.rowId, pageRow)
        XCTAssertEqual(st.composer?.kind, .type)
    }

    func testMenuTypeOnABlockedHostSaysWhyAndStops() {
        let (st, _) = store(NightWatchFixtures.oneWaitingTwoInFlight(blocked: true))
        st.requestComposer(forSessionId: "sess-payments-api")
        XCTAssertNil(st.composer)
        XCTAssertEqual(st.notice?.failed, true)
    }

    // MARK: first-run tip

    func testTipShowsOnlyWithARowAndOnlyUntilDismissedAndIsRemembered() {
        XCTAssertFalse(PanelTip.shouldShow(dismissed: false, hasDecisionRows: false, hasInFlightRows: false))
        XCTAssertTrue(PanelTip.shouldShow(dismissed: false, hasDecisionRows: true, hasInFlightRows: false))
        XCTAssertTrue(PanelTip.shouldShow(dismissed: false, hasDecisionRows: false, hasInFlightRows: true))
        XCTAssertFalse(PanelTip.shouldShow(dismissed: true, hasDecisionRows: true, hasInFlightRows: true))
        XCTAssertEqual(PanelTip.text, "Click a row for actions · ? shows every shortcut")

        let prefs = NowPrefs.ephemeral()
        XCTAssertFalse(prefs.tipDismissed)
        let (first, _) = store(prefs: prefs)
        XCTAssertTrue(first.tipVisible)
        first.dismissTip()
        XCTAssertFalse(first.tipVisible)
        XCTAssertTrue(prefs.tipDismissed)
        let (second, _) = store(prefs: prefs)
        XCTAssertFalse(second.tipVisible, "remembered across launches")
        // Another store with fresh preferences still shows it.
        XCTAssertTrue(store(prefs: .ephemeral()).0.tipVisible)
    }

    func testEphemeralPrefsAreSeparateStoresAndCopiesShareState() {
        let e = NowPrefs.ephemeral()
        XCTAssertFalse(e.tipDismissed)
        let copy = e
        copy.tipDismissed = true
        XCTAssertTrue(e.tipDismissed)
        XCTAssertFalse(NowPrefs.ephemeral().tipDismissed)
        XCTAssertTrue(NowPrefs.ephemeral().dismissingTip().tipDismissed)
        XCTAssertNotEqual(NowPrefs.tipKey, NowPrefs.collapsedKey)
    }

    func testTipDoesNotShowOnAnEmptyPanel() {
        let (st, _) = store(NightWatchFixtures.snapshotOnly())
        XCTAssertFalse(st.tipVisible)
    }

    // MARK: discoverability

    func testEveryActionHasANameAndItsKeyLivesInTheTooltip() {
        let all: [KeyHint.Action] = [.approve, .approveHold, .deny, .tellInstead, .openTerminal]
        XCTAssertEqual(all.map(\.title), ["Approve", "Hold to approve", "Deny", "Steer", "Open"])
        for a in all {
            XCTAssertFalse(a.title.isEmpty)
            XCTAssertTrue(a.tooltip(key: "K").hasPrefix("\(a.title) · K"), a.title)
        }
        XCTAssertEqual(InFlightAction.open.title, "Open")
        XCTAssertEqual(InFlightAction.steer.title, "Steer")
        XCTAssertEqual(InFlightAction.open.key, "O")
        XCTAssertEqual(InFlightAction.steer.key, "T")
        XCTAssertTrue(InFlightAction.open.tooltip.hasPrefix("Open · O"))
        XCTAssertTrue(InFlightAction.steer.tooltip.hasPrefix("Steer · T"))
        XCTAssertEqual(InFlightMenu.openTitle, "Open")
        XCTAssertEqual(InFlightMenu.typeTitle, "Steer…")
    }

    func testButtonKeysAreTheOnesTheShortcutCatalogListsAndTheSheetShows() {
        let keys = ShortcutCatalog.groups.flatMap(\.items).map(\.keys)
        XCTAssertTrue(keys.contains([InFlightAction.open.key]))
        XCTAssertTrue(keys.contains([InFlightAction.steer.key]))
        XCTAssertTrue(keys.contains([PanelKeys.help]))
        // Every key a decision row draws is in the catalog too.
        let m = NowModel.build(NightWatchFixtures.needsYou())
        for label in Set(m.rows.flatMap { ($0.keys + $0.moreKeys).map(\.label) }) where label != "hold 1" {
            XCTAssertTrue(keys.contains { $0.map { $0.lowercased() } == [label.lowercased()] }, "catalog lacks \(label)")
        }
        XCTAssertTrue(keys.contains(["hold", "⌘", "."]))
    }

    func testTheCatalogStaysHonestAboutWhatTypingDoes() {
        let t = ShortcutCatalog.groups.flatMap(\.items).first { $0.keys == [PanelKeys.type] }
        XCTAssertNotNil(t)
        XCTAssertTrue(t?.detail.contains("Esc first") == true, "a waiting page still gets Esc, text, Return")
        XCTAssertTrue(t?.detail.contains("just your text and Return") == true, "a working session never gets Esc")
    }
}

extension NightWatchFixtures {
    /// A snapshot with nothing in it (no pages, nothing working).
    static func snapshotOnly(now: Date = boardNow()) -> NowInputs {
        NowInputs(snapshot: snapshot(), now: now, macName: "Studio MBP", idleSeconds: 5)
    }
}
