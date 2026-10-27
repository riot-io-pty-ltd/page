import XCTest
import PageWidgetSupport

/// The snapshot Page writes for its widgets: its bounds, its JSON (round trip,
/// old and missing fields), its freshness thresholds and its fingerprint.
final class WidgetSnapshotTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func full() -> WidgetSnapshot {
        WidgetSnapshot(
            writtenAt: t0, macName: "Studio MBP", mood: .needsYou, needYou: 2, look: 1, working: 5,
            subline: "runway clear till 02:40", clearUntil: t0.addingTimeInterval(3600),
            battery: .init(percent: 64, onAC: false, charging: false),
            decisions: [.init(id: "sess-a-permission-1", project: "bottle-flip", chip: "irreversible",
                              summary: "Run: terraform apply")],
            inFlight: [.init(id: "inflight-s1", project: "harbor", doing: "Bash: swift test")],
            usage: .init(fiveHour: .init(pct: 62, resetsAt: t0.addingTimeInterval(7200)), sevenDay: nil, updatedAt: t0),
            cardGlow: "subtle")
    }

    private func minimal() -> WidgetSnapshot {
        WidgetSnapshot(writtenAt: t0, macName: "Studio MBP", mood: .quiet, needYou: 0, working: 0)
    }

    private func json(_ s: WidgetSnapshot) throws -> [String: Any] {
        let data = try XCTUnwrap(WidgetSnapshotCodec.encode(s))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: round trip

    func testRoundTripKeepsEveryField() throws {
        let s = full()
        let data = try XCTUnwrap(WidgetSnapshotCodec.encode(s))
        XCTAssertEqual(WidgetSnapshotCodec.decode(data), s)
    }

    func testRoundTripOfAMinimalSnapshotKeepsTheNilOptionals() throws {
        let s = minimal()
        let data = try XCTUnwrap(WidgetSnapshotCodec.encode(s))
        let back = try XCTUnwrap(WidgetSnapshotCodec.decode(data))
        XCTAssertEqual(back, s)
        XCTAssertNil(back.battery)
        XCTAssertNil(back.usage)
        XCTAssertNil(back.clearUntil)
    }

    func testDatesAreWholeSecondsSinceTheEpoch() throws {
        let object = try json(full())
        XCTAssertEqual(object["writtenAt"] as? Double, 1_790_000_000)
        let usage = try XCTUnwrap(object["usage"] as? [String: Any])
        XCTAssertEqual(usage["updatedAt"] as? Double, 1_790_000_000)
    }

    func testMissingOptionalFieldsDecodeAsNil() throws {
        var object = try json(full())
        for key in ["battery", "usage", "clearUntil"] { object.removeValue(forKey: key) }
        let back = try XCTUnwrap(WidgetSnapshotCodec.decode(try data(object)))
        XCTAssertNil(back.battery)
        XCTAssertNil(back.usage)
        XCTAssertNil(back.clearUntil)
        XCTAssertEqual(back.needYou, 2)
    }

    func testUnknownKeysFromANewerWriterAreIgnored() throws {
        var object = try json(full())
        object["someFutureField"] = ["anything": 1]
        XCTAssertNotNil(WidgetSnapshotCodec.decode(try data(object)))
    }

    /// A snapshot written before `look`, `subline`, `cardGlow` and the lists
    /// existed: the init gives them defaults, so the decoder should too.
    /// (Synthesized Codable ignores init defaults, so this is a probe.)
    func testSnapshotWithoutTheLaterKeysStillDecodesWithDefaults() throws {
        var object = try json(full())
        for key in ["look", "subline", "cardGlow", "decisions", "inFlight", "running"] {
            object.removeValue(forKey: key)
        }
        let back = try XCTUnwrap(WidgetSnapshotCodec.decode(try data(object)),
                                 "an older snapshot without look/subline/cardGlow/decisions/inFlight/running must still decode")
        XCTAssertEqual(back.look, 0)
        XCTAssertEqual(back.subline, "")
        XCTAssertEqual(back.cardGlow, "off")
        XCTAssertEqual(back.decisions, [])
        XCTAssertEqual(back.inFlight, [])
        XCTAssertTrue(back.running)
    }

    func testVersionOutsideWhatThisWidgetReadsIsRefused() throws {
        var newer = try json(full())
        newer["version"] = WidgetSnapshot.currentVersion + 1
        XCTAssertNil(WidgetSnapshotCodec.decode(try data(newer)), "a newer Page's file must not be guessed at")
        var zero = try json(full())
        zero["version"] = 0
        XCTAssertNil(WidgetSnapshotCodec.decode(try data(zero)))
    }

    func testDamagedOrEmptyOrOversizedDataIsRefused() throws {
        XCTAssertNil(WidgetSnapshotCodec.decode(Data()))
        XCTAssertNil(WidgetSnapshotCodec.decode(Data("not json".utf8)))
        XCTAssertNil(WidgetSnapshotCodec.decode(Data("{\"version\":1}".utf8)))
        let big = try XCTUnwrap(WidgetSnapshotCodec.encode(full()))
        XCTAssertNil(WidgetSnapshotCodec.decode(big, maxBytes: 10))
    }

    // MARK: bounds

    func testBoundedClipsCountsAndLists() {
        var s = full()
        s.decisions = (0..<9).map { .init(id: "d\($0)", project: "p", chip: "considered", summary: "s") }
        s.inFlight = (0..<9).map { .init(id: "f\($0)", project: "p", doing: "d") }
        s.needYou = -3; s.look = 5000; s.working = 999_999
        let b = s.bounded()
        XCTAssertEqual(b.decisions.count, WidgetSnapshot.Limits.maxDecisions)
        XCTAssertEqual(b.inFlight.count, WidgetSnapshot.Limits.maxInFlight)
        XCTAssertEqual(b.needYou, 0)
        XCTAssertEqual(b.look, WidgetSnapshot.Limits.maxCount)
        XCTAssertEqual(b.working, WidgetSnapshot.Limits.maxCount)
    }

    func testBoundedClipsLongTextWithAnEllipsis() {
        var s = full()
        s.macName = String(repeating: "m", count: 200)
        s.decisions = [.init(id: "x", project: String(repeating: "p", count: 200), chip: "considered",
                             summary: String(repeating: "s", count: 500))]
        let b = s.bounded()
        XCTAssertLessThanOrEqual(b.macName.count, WidgetSnapshot.Limits.maxMacName)
        XCTAssertTrue(b.macName.hasSuffix("…"))
        XCTAssertLessThanOrEqual(b.decisions[0].project.count, WidgetSnapshot.Limits.maxProject)
        XCTAssertLessThanOrEqual(b.decisions[0].summary.count, WidgetSnapshot.Limits.maxSummary)
        XCTAssertTrue(b.decisions[0].summary.hasSuffix("…"))
    }

    func testBoundedClampsPercentagesAndBattery() {
        var s = full()
        s.usage = .init(fiveHour: .init(pct: 150, resetsAt: nil), sevenDay: .init(pct: -4, resetsAt: nil), updatedAt: t0)
        s.battery = .init(percent: 140, onAC: true, charging: true)
        let b = s.bounded()
        XCTAssertEqual(b.usage?.fiveHour?.pct, 100)
        XCTAssertEqual(b.usage?.sevenDay?.pct, 0)
        XCTAssertEqual(b.battery?.percent, 100)
        var nan = full()
        nan.usage = .init(fiveHour: .init(pct: .nan, resetsAt: nil), sevenDay: nil, updatedAt: t0)
        XCTAssertEqual(nan.bounded().usage?.fiveHour?.pct, 0)
    }

    func testBoundedRefusesAnUnknownGlowLevel() {
        var s = full()
        s.cardGlow = "neon"
        XCTAssertEqual(s.bounded().cardGlow, "off")
        XCTAssertEqual(s.bounded().glowIntensity, 0)
    }

    func testGlowIntensityFollowsTheLevel() {
        var s = full()
        s.cardGlow = "full"; XCTAssertEqual(s.glowIntensity, 1)
        s.cardGlow = "subtle"; XCTAssertEqual(s.glowIntensity, 0.5)
        s.cardGlow = "off"; XCTAssertEqual(s.glowIntensity, 0)
    }

    func testCleanFlattensWhitespaceAndControlCharacters() {
        XCTAssertEqual(WidgetSnapshot.clean("  a\n\tb\u{0007}c   d  ", limit: 50), "a b c d")
        XCTAssertEqual(WidgetSnapshot.clean("a\u{2028}b\u{2029}c", limit: 50), "a b c")
        XCTAssertEqual(WidgetSnapshot.clean("", limit: 5), "")
    }

    func testCleanClipsToTheLimitIncludingTheEllipsis() {
        let out = WidgetSnapshot.clean("abcdefghij", limit: 5)
        XCTAssertEqual(out, "abcd…")
        XCTAssertEqual(out.count, 5)
        XCTAssertEqual(WidgetSnapshot.clean("abcde", limit: 5), "abcde")
    }

    func testEncodeStaysUnderTheByteCapWithEveryRowAtItsMaximum() throws {
        var s = full()
        let id = String(repeating: "i", count: WidgetSnapshot.Limits.maxId)
        s.decisions = (0..<5).map { _ in .init(id: id, project: String(repeating: "p", count: 40), chip: "irreversible",
                                               summary: String(repeating: "s", count: 90)) }
        s.inFlight = (0..<5).map { _ in .init(id: id, project: String(repeating: "p", count: 40),
                                              doing: String(repeating: "d", count: 70)) }
        let data = try XCTUnwrap(WidgetSnapshotCodec.encode(s))
        XCTAssertLessThanOrEqual(data.count, WidgetSnapshot.Limits.maxBytes)
        XCTAssertNotNil(WidgetSnapshotCodec.decode(data))
    }

    func testEncodeDropsRowsToFitWhenTheTextIsWide() throws {
        // Combining marks: each grapheme is 1 character to `clean` but ~80 bytes of JSON.
        let wide = String(repeating: "e" + String(repeating: "\u{0301}", count: 40), count: 90)
        var s = full()
        s.decisions = (0..<5).map { .init(id: "d\($0)", project: "p", chip: "considered", summary: wide) }
        s.inFlight = [.init(id: "f", project: "p", doing: "x")]
        let data = try XCTUnwrap(WidgetSnapshotCodec.encode(s), "rows should be dropped, not the file refused")
        XCTAssertLessThanOrEqual(data.count, WidgetSnapshot.Limits.maxBytes)
        XCTAssertLessThan(try XCTUnwrap(WidgetSnapshotCodec.decode(data)).decisions.count, 5)
    }

    /// Probe: `clean` counts characters, not bytes, so one row of pathological
    /// text can be bigger than the cap by itself. Then `encode` returns nil and
    /// the write is silently skipped, leaving the widgets on the old file.
    func testOneHugeRowStillEncodesWithinTheCap() throws {
        let wide = String(repeating: "e" + String(repeating: "\u{0301}", count: 40), count: 90)
        var s = full()
        s.decisions = [.init(id: String(repeating: "e" + String(repeating: "\u{0301}", count: 40), count: 120),
                             project: "p", chip: "considered", summary: wide)]
        XCTAssertNotNil(WidgetSnapshotCodec.encode(s), "a single row must not make the whole snapshot unwritable")
    }

    // MARK: freshness

    func testFreshUntilTwentyFiveMinutesThenStale() {
        let s = minimal()
        XCTAssertEqual(s.freshness(now: t0), .fresh)
        XCTAssertEqual(s.freshness(now: t0.addingTimeInterval(39 * 60)), .fresh)
        XCTAssertEqual(s.freshness(now: t0.addingTimeInterval(40 * 60)), .fresh, "exactly at the limit is still fresh")
        XCTAssertEqual(s.freshness(now: t0.addingTimeInterval(40 * 60 + 1)), .stale(since: t0))
    }

    func testStaleAtIsTheMomentItAgesOut() {
        XCTAssertEqual(minimal().staleAt, t0.addingTimeInterval(40 * 60))
        XCTAssertEqual(WidgetSnapshot.staleAfter, 40 * 60)
        XCTAssertEqual(WidgetSnapshot.heartbeat, 10 * 60)
    }

    func testHeartbeatLeavesRoomToSpare() {
        // The app rewrites at least every heartbeat; the timer re-offers every minute.
        // Two missed heartbeats (plus a minute of timer slack) must still be fresh.
        XCTAssertLessThan(2 * WidgetSnapshot.heartbeat + 60, WidgetSnapshot.staleAfter)
    }

    /// Heartbeat writes do not reload the widgets, so a widget may show a file as old as one heartbeat plus
    /// the 15-minute timeline refresh (plus a minute of timer slack) and must not call it stale.
    func testStaleAfterOutlastsAHeartbeatPlusTheWidgetsOwnRefresh() {
        XCTAssertGreaterThan(WidgetSnapshot.staleAfter, WidgetSnapshot.heartbeat + 15 * 60 + 60)
    }

    func testSmallClockSkewIsFreshButALargeOneIsStale() {
        let s = minimal()
        XCTAssertEqual(s.freshness(now: t0.addingTimeInterval(-200)), .fresh)
        XCTAssertEqual(s.freshness(now: t0.addingTimeInterval(-400)), .stale(since: t0))
    }

    func testAQuitNoteIsNotRunningWhateverItsAge() {
        var s = minimal()
        s.running = false
        XCTAssertEqual(s.freshness(now: t0), .notRunning)
        XCTAssertEqual(s.freshness(now: t0.addingTimeInterval(3600)), .notRunning)
    }

    // MARK: fingerprint

    func testFingerprintIgnoresOnlyTheWriteTime() {
        var later = full()
        later.writtenAt = t0.addingTimeInterval(90)
        XCTAssertEqual(full().fingerprint(), later.fingerprint())
        var moved = full()
        moved.mood = .working
        XCTAssertNotEqual(full().fingerprint(), moved.fingerprint())
        var quit = full()
        quit.running = false
        XCTAssertNotEqual(full().fingerprint(), quit.fingerprint())
    }

    func testFingerprintIgnoresRunwayDriftWithinFiveMinutesAndUsageUpdateTime() {
        var base = full()
        base.clearUntil = t0.addingTimeInterval(3600)
        var drift = base
        drift.clearUntil = t0.addingTimeInterval(3600 + 60)
        XCTAssertEqual(base.fingerprint(), drift.fingerprint(), "a minute of runway drift is not news")
        var far = base
        far.clearUntil = t0.addingTimeInterval(3600 + 20 * 60)
        XCTAssertNotEqual(base.fingerprint(), far.fingerprint())
        if let u = base.usage {
            var touched = base
            touched.usage = .init(fiveHour: u.fiveHour, sevenDay: u.sevenDay, updatedAt: u.updatedAt.addingTimeInterval(120))
            XCTAssertEqual(base.fingerprint(), touched.fingerprint(), "when Claude Code last wrote the numbers is not news")
            var moved = base
            moved.usage = .init(fiveHour: .init(pct: 99, resetsAt: u.fiveHour?.resetsAt), sevenDay: u.sevenDay, updatedAt: u.updatedAt)
            XCTAssertNotEqual(base.fingerprint(), moved.fingerprint())
        }
    }

    func testUrgentFingerprintTracksOnlyWhatNeedsThePerson() {
        let base = full()
        var a = base
        a.working += 1; a.battery = .init(percent: 3, onAC: base.battery?.onAC ?? false, charging: false)
        a.inFlight = []; a.subline = "other"
        if !a.decisions.isEmpty { a.decisions[0].summary = "different words" }
        XCTAssertEqual(base.urgentFingerprint(), a.urgentFingerprint(), "step text, working count and battery percentage are not urgent")
        var b = base; b.needYou += 1
        XCTAssertNotEqual(base.urgentFingerprint(), b.urgentFingerprint())
        var c = base; c.mood = (base.mood == .dusk ? .quiet : .dusk)
        XCTAssertNotEqual(base.urgentFingerprint(), c.urgentFingerprint())
        var d = base; d.running = false
        XCTAssertNotEqual(base.urgentFingerprint(), d.urgentFingerprint())
        var e = base
        if e.decisions.isEmpty { e.decisions = [.init(id: "x", project: "p", chip: "question", summary: "")] } else { e.decisions[0].id = "other-id" }
        XCTAssertNotEqual(base.urgentFingerprint(), e.urgentFingerprint())
    }

    // MARK: the bundled fixtures

    func testEveryFixtureIsBoundedAndRoundTrips() throws {
        let now = t0
        for s in [WidgetFixtures.needsYou(now: now), WidgetFixtures.working(now: now), WidgetFixtures.quiet(now: now),
                  WidgetFixtures.dusk(now: now), WidgetFixtures.sample(now: now)] {
            let data = try XCTUnwrap(WidgetSnapshotCodec.encode(s))
            XCTAssertLessThanOrEqual(data.count, WidgetSnapshot.Limits.maxBytes)
            XCTAssertEqual(WidgetSnapshotCodec.decode(data), s.bounded())
        }
    }
}
