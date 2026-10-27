import XCTest
@testable import ClaudePowerMode
import PageWidgetSupport

/// What Page tells its widgets: the counts and words come from the popover's
/// model, every agent-written line is redacted and clipped, and nothing else
/// leaves the app.
final class WidgetSnapshotBuilderTests: XCTestCase {
    private func built(_ inputs: NowInputs, running: Bool = true, glow: CardGlow = .subtle) -> (snap: WidgetSnapshot, model: NowModel) {
        let model = NowModel.build(inputs)
        let snap = WidgetSnapshotBuilder.build(model: model, snapshot: inputs.snapshot, cardGlow: glow,
                                               now: inputs.now, running: running)
        return (snap, model)
    }

    private func json(_ s: WidgetSnapshot) -> String {
        // JSONEncoder writes "/" as "\\/"; unescape so a path search means what it says.
        String(decoding: WidgetSnapshotCodec.encode(s) ?? Data(), as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }

    private var now: Date { NightWatchFixtures.boardNow() }

    // MARK: counts and words

    func testCountsAndWordsComeFromTheModel() {
        let (s, m) = built(NightWatchFixtures.needsYou())
        XCTAssertEqual(s.needYou, m.needYouCount)
        XCTAssertEqual(s.needYou, 2)
        XCTAssertEqual(s.look, 1)
        XCTAssertEqual(s.working, 5)
        XCTAssertEqual(s.mood, .needsYou)
        XCTAssertEqual(s.macName, "Studio MBP")
        XCTAssertEqual(s.subline, m.subline)
        XCTAssertEqual(s.clearUntil, m.runway.clearUntil.map(WidgetSnapshotBuilder.roundedToMinute))
        XCTAssertEqual(s.cardGlow, "subtle")
        XCTAssertTrue(s.running)
        XCTAssertEqual(s.freshness(now: now), .fresh)
    }

    func testAttentionIsTheRowsTheWidgetListsAndNotCountedTwice() {
        let (s, m) = built(NightWatchFixtures.needsYou())
        let listed = m.rows.filter { $0.section == .decide || $0.section == .look }
        XCTAssertEqual(s.attention, listed.count)
        XCTAssertEqual(s.attention, m.attentionCount)
    }

    func testDecisionsKeepTheModelsOrderIdsAndChips() {
        let (s, m) = built(NightWatchFixtures.needsYou())
        let listed = Array(m.rows.filter { $0.section == .decide || $0.section == .look }.prefix(5))
        XCTAssertEqual(s.decisions.map(\.id), listed.map(\.id))
        XCTAssertEqual(s.decisions.map(\.chip), listed.map { $0.chip.rawValue })
        XCTAssertEqual(s.decisions.map(\.project), listed.map(\.projectName))
    }

    func testDecisionsAreCappedAtFive() {
        let (s, m) = built(NightWatchFixtures.manyPages())
        XCTAssertGreaterThan(m.rows.filter { $0.section == .decide || $0.section == .look }.count, 5,
                             "the fixture should have more pages than the widget shows")
        XCTAssertEqual(s.decisions.count, WidgetSnapshot.Limits.maxDecisions)
    }

    func testInFlightRowsKeepTheirIdsAndCapAtFive() {
        let (s, m) = built(NightWatchFixtures.oneWaitingTwoInFlight(blocked: true))
        XCTAssertEqual(s.inFlight.map(\.id), Array(m.flight.prefix(5)).map(\.id))
        XCTAssertLessThanOrEqual(s.inFlight.count, WidgetSnapshot.Limits.maxInFlight)
        XCTAssertTrue(s.inFlight.contains { $0.doing == "Edit: Sources/Agent/Planner.swift" })
    }

    func testASessionWithNoStepShowsNoPlaceholderText() {
        var i = NightWatchFixtures.oneWaitingTwoInFlight()
        i.activity = [:]
        let (s, _) = built(i)
        XCTAssertFalse(s.inFlight.isEmpty)
        XCTAssertTrue(s.inFlight.allSatisfy { $0.doing.isEmpty }, "the word 'working' is not a step")
    }

    func testUsageIsCarriedOnlyWhenThereIsAGauge() {
        // The app sets both the inputs' usage and the snapshot's (AppDelegate); the builder reads the snapshot's.
        var withUsage = NightWatchFixtures.needsYou()
        withUsage.snapshot.usage = withUsage.usage
        let (s, _) = built(withUsage)
        XCTAssertEqual(s.usage?.fiveHour?.pct, 62)
        XCTAssertEqual(s.usage?.sevenDay?.pct, 30)
        let quiet = NowInputs(snapshot: NightWatchFixtures.snapshot(), now: now, macName: "Studio MBP", idleSeconds: 0)
        XCTAssertNil(built(quiet).snap.usage)
    }

    func testBatteryIsOmittedOnADesktopMac() {
        let desk = NowInputs(
            snapshot: NightWatchFixtures.snapshot(power: PowerSnapshot(percent: -1, onAC: true, hasBattery: false, isCharging: false)),
            now: now, macName: "Studio Mac", idleSeconds: 0)
        XCTAssertNil(built(desk).snap.battery)
        XCTAssertNotNil(built(NightWatchFixtures.needsYou()).snap.battery)
    }

    func testTheQuitNoteIsNotRunning() {
        let (s, _) = built(NightWatchFixtures.needsYou(), running: false)
        XCTAssertFalse(s.running)
        XCTAssertEqual(s.freshness(now: now), .notRunning)
    }

    // MARK: redaction and clipping

    func testSecretsInAnApprovalNeverReachTheFile() {
        let pending = [NightWatchFixtures.event("orchard", kind: .permission,
                                                context: "[Bash] export OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwx1234\nDeploy it",
                                                openedAt: now.addingTimeInterval(-60))]
        let i = NowInputs(snapshot: NightWatchFixtures.snapshot(pending: pending), now: now, macName: "Studio MBP", idleSeconds: 5)
        let (s, _) = built(i)
        XCTAssertFalse(json(s).contains("sk-abcdefghijklmnopqrstuvwx1234"))
    }

    func testStepLinesAreRedactedClippedAndFlattened() {
        var i = NightWatchFixtures.oneWaitingTwoInFlight()
        i.activity["sess-page"] = "Bash: curl -H 'Authorization: Bearer abcdefghijklmnop1234' https://example.test "
            + String(repeating: "x", count: 300)
        i.activity["sess-llm-play"] = "Edit: first line\nsecond line"
        let (s, _) = built(i)
        let page = s.inFlight.first { $0.project == "page" }?.doing ?? ""
        XCTAssertFalse(page.contains("abcdefghijklmnop1234"))
        XCTAssertTrue(page.contains("[redacted]"))
        XCTAssertLessThanOrEqual(page.count, WidgetSnapshot.Limits.maxDoing)
        XCTAssertTrue(page.hasSuffix("…"))
        XCTAssertEqual(s.inFlight.first { $0.project == "llm-play" }?.doing, "Edit: first line second line")
        XCTAssertFalse(json(s).contains("abcdefghijklmnop1234"))
    }

    func testRedactionRunsBeforeTheClipSoAFragmentCannotLeak() {
        // The secret starts after the first 15 characters: a clip first would show "sk-a…" to the widget.
        let text = String(repeating: "x", count: 15) + " sk-abcdefghijklmnopqrstu"
        XCTAssertFalse(WidgetSnapshotBuilder.redacted(text, limit: 20).contains("sk-a"))
    }

    /// The widgets sit on the desktop where a screen share shows them: no full path leaves the Mac.
    func testAHomeFolderPathInAStepDoesNotLeaveTheMac() {
        var i = NightWatchFixtures.oneWaitingTwoInFlight()
        i.activity["sess-page"] = "Edit: /Users/alice/clients/secret-plan/notes.md"
        let (s, _) = built(i)
        XCTAssertFalse(json(s).contains("/Users/alice"))
        XCTAssertFalse(json(s).contains("secret-plan"))
        XCTAssertEqual(s.inFlight.first { $0.project == "page" }?.doing, "Edit: notes.md")
    }

    func testPathsCollapseToTheirLastPart() {
        let c = WidgetSnapshotBuilder.collapsingPaths
        XCTAssertEqual(c("Edit: /Users/alice/clients/plan/notes.md"), "Edit: notes.md")
        XCTAssertEqual(c("Read ~/clients/plan/notes.md and ~/.zshrc"), "Read notes.md and .zshrc")
        XCTAssertEqual(c("Bash: cd /Users/alice/proj && npm test"), "Bash: cd proj && npm test")
        XCTAssertEqual(c("Write \"/Users/alice/a b/c.txt\""), "Write \"a b/c.txt\"", "a space ends the path")
        XCTAssertEqual(c("ls ~"), "ls ~")
        XCTAssertEqual(c("cd ~/"), "cd ~")
        XCTAssertEqual(c("open /tmp"), "open /tmp", "a one-part absolute path carries nothing private")
        XCTAssertEqual(c("curl https://example.test/a/b/c"), "curl https://example.test/a/b/c", "URLs are left alone")
        XCTAssertEqual(c("1/2 and and/or"), "1/2 and and/or")
        XCTAssertEqual(c("--out=/Users/alice/build/out.log"), "--out=out.log")
    }

    func testTheRunwayEndIsRoundedToTheMinute() {
        let odd = Date(timeIntervalSince1970: 1_790_000_000 + 29)
        XCTAssertEqual(WidgetSnapshotBuilder.roundedToMinute(odd).timeIntervalSince1970.truncatingRemainder(dividingBy: 60), 0)
        XCTAssertLessThanOrEqual(abs(WidgetSnapshotBuilder.roundedToMinute(odd).timeIntervalSince(odd)), 30)
    }

    /// On battery the runway is re-estimated every tick; a few seconds later must not look like news.
    func testTwoTicksOnBatteryLookTheSameToTheGate() {
        let i = NightWatchFixtures.onBattery()
        var later = i
        later.now = i.now.addingTimeInterval(4)
        let (a, _) = built(i)
        let (b, _) = built(later)
        XCTAssertEqual(a.fingerprint(), b.fingerprint())
    }

    func testTheFileStaysSmallWithManyLongRows() {
        let long = String(repeating: "word ", count: 400)
        let names = (0..<12).map { "project-\($0)" }
        let pending = names.enumerated().map { n, name in
            NightWatchFixtures.event(name, kind: .permission, context: "[Bash] " + long,
                                     openedAt: now.addingTimeInterval(-Double(n + 1) * 60))
        }
        let i = NowInputs(snapshot: NightWatchFixtures.snapshot(sessions: NightWatchFixtures.working5, pending: pending),
                          now: now, macName: String(repeating: "M", count: 300), idleSeconds: 5)
        let (s, _) = built(i)
        XCTAssertLessThanOrEqual(s.decisions.count, WidgetSnapshot.Limits.maxDecisions)
        XCTAssertLessThanOrEqual(s.macName.count, WidgetSnapshot.Limits.maxMacName)
        let data = WidgetSnapshotCodec.encode(s)
        XCTAssertNotNil(data)
        XCTAssertLessThanOrEqual(data?.count ?? .max, WidgetSnapshot.Limits.maxBytes)
    }
}
