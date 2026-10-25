import XCTest
@testable import ClaudePowerMode

final class UsageForecastTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func input(_ five: Double, resets: Any = 1_800_018_000, seven: Double? = 30) -> Data {
        var limits: [String: Any] = ["five_hour": ["used_percentage": five, "resets_at": resets]]
        if let seven { limits["seven_day"] = ["used_percentage": seven, "resets_at": "2026-11-01T00:00:00Z"] }
        return try! JSONSerialization.data(withJSONObject: ["model": ["id": "x"], "rate_limits": limits])
    }

    func testParse() {
        let s = UsageSnapshot.parse(input(62.5), updatedAt: t0)
        XCTAssertEqual(s?.fiveHour, .init(pct: 62.5, resetsAt: Date(timeIntervalSince1970: 1_800_018_000)))
        XCTAssertEqual(s?.sevenDay?.pct, 30)
        XCTAssertNotNil(s?.sevenDay?.resetsAt)
        XCTAssertNil(UsageSnapshot.parse(Data(#"{"model":{}}"#.utf8), updatedAt: t0), "no rate_limits (API key users)")
        XCTAssertEqual(UsageSnapshot.date(1_800_000_000_000), t0, "ms")
        XCTAssertEqual(UsageSnapshot.date("1800000000"), t0)
        XCTAssertEqual(UsageSnapshot.parse(input(140), updatedAt: t0)?.fiveHour?.pct, 100)
    }

    private func forecast(_ points: [(minutes: Double, pct: Double)]) -> UsageForecast {
        var f = UsageForecast()
        for p in points {
            f.observe(UsageSnapshot.parse(input(p.pct), updatedAt: t0.addingTimeInterval(p.minutes * 60))!)
        }
        return f
    }

    func testHitAtAtTheCurrentPace() {
        // 1 point a minute from 50% → 100% 50 min after the 0-minute mark.
        let f = forecast([(0, 50), (10, 60), (20, 70)])
        let hit = f.hitAt(now: t0.addingTimeInterval(20 * 60))
        XCTAssertEqual(hit!.timeIntervalSince(t0), 50 * 60, accuracy: 30)
        let hb = f.heartbeatPayload(now: t0.addingTimeInterval(20 * 60))
        XCTAssertNotNil(hb?["hitAt"])
        XCTAssertEqual((hb?["fiveHour"] as? [String: Any])?["pct"] as? Double, 70)
    }

    func testNoForecastWhenTheResetComesFirstOrTooLittleData() {
        // Slow: 100% would be ~hours after the reset (5 h after t0).
        XCTAssertNil(forecast([(0, 10), (60, 12.5)]).hitAt(now: t0.addingTimeInterval(3600)))
        XCTAssertNil(forecast([(0, 50), (5, 60)]).hitAt(now: t0.addingTimeInterval(300)), "span too short")
        XCTAssertNil(forecast([(0, 50), (20, 51)]).hitAt(now: t0.addingTimeInterval(1200)), "barely moving")
        let f = forecast([(0, 50), (10, 60), (20, 70)])
        XCTAssertNil(f.hitAt(now: t0.addingTimeInterval(7 * 3600)), "stale numbers")
        XCTAssertTrue(f.menuLines(now: t0.addingTimeInterval(7 * 3600)).isEmpty)
    }

    func testANewWindowStartsOver() {
        var f = forecast([(0, 50), (10, 60)])
        f.observe(UsageSnapshot.parse(input(5, resets: 1_800_036_000), updatedAt: t0.addingTimeInterval(1200))!)
        XCTAssertEqual(f.samples.count, 1)
    }

    func testMenuLinesAndPageCopy() {
        let f = forecast([(0, 50), (10, 60), (20, 70)])
        let lines = f.menuLines(now: t0.addingTimeInterval(20 * 60))
        XCTAssertTrue(lines[0].hasPrefix("Claude usage: 5-hour 70% (resets "), lines[0])
        XCTAssertTrue(lines[0].hasSuffix(" · 7-day 30%"), lines[0])
        XCTAssertTrue(lines[1].contains("At this pace you'll hit the limit around"))
        let c = UsageForecast.pageContext(hitAt: t0, pct: 82, resetsAt: t0.addingTimeInterval(3600), busy: 2)
        XCTAssertTrue(c.hasPrefix("Claude usage is at 82% of the 5-hour limit — at this pace you'll hit it around "), c)
        XCTAssertTrue(c.hasSuffix(". 2 sessions are working."), c)
        XCTAssertTrue(UsageForecast.isPageId(UsageForecast.pageId(hitAt: t0)))
        XCTAssertEqual(UsageForecast.pageId(hitAt: t0), UsageForecast.pageId(hitAt: t0.addingTimeInterval(60)),
                       "a small drift in the forecast keeps the same page")
    }

    // MARK: capture (settings.json wrapping)

    private func tempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("usage-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        return home
    }

    func testWrapAndUnwrapKeepTheUsersStatusLine() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".claude/settings.json")
        let original = """
        {
          "model": "opus",
          "statusLine": {
            "type": "command",
            "command": "~/.claude/statusline.sh",
            "padding": 0
          }
        }

        """
        try original.write(to: settings, atomically: true, encoding: .utf8)
        let cap = UsageCapture(home: home, supportDirectory: home.appendingPathComponent("support"))
        XCTAssertEqual(cap.state(), .off)
        let backup = try cap.set(true)
        XCTAssertNotNil(backup, "settings.json is backed up first")
        XCTAssertEqual(cap.state(), .on)
        let on = try String(contentsOf: settings, encoding: .utf8)
        XCTAssertTrue(on.contains(cap.wrapperURL.path))
        XCTAssertTrue(on.contains("\"padding\": 0"))
        XCTAssertTrue(on.contains("\"model\": \"opus\""))
        XCTAssertEqual(try String(contentsOf: cap.originalURL, encoding: .utf8), "~/.claude/statusline.sh")
        let perms = try FileManager.default.attributesOfItem(atPath: cap.wrapperURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o700)
        XCTAssertNil(try cap.set(true), "already on: no change")

        try cap.set(false)
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), original, "byte-identical after off")
        XCTAssertEqual(cap.state(), .off)
    }

    func testNoStatusLineBeforeMeansNoneAfter() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".claude/settings.json")
        try "{\n  \"model\": \"opus\"\n}\n".write(to: settings, atomically: true, encoding: .utf8)
        let cap = UsageCapture(home: home, supportDirectory: home.appendingPathComponent("support"))
        try cap.set(true)
        XCTAssertTrue(try String(contentsOf: settings, encoding: .utf8).contains("\"statusLine\""))
        try cap.set(false)
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{\n  \"model\": \"opus\"\n}\n")
    }

    func testTheWrapperSavesInputAndRunsTheOriginal() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".claude/settings.json")
        let support = home.appendingPathComponent("sup port")   // a space, like "Application Support"
        let marker = home.appendingPathComponent("ran.txt")
        try """
        {"statusLine": {"type": "command", "command": "cat > \(marker.path); echo STATUS"}}
        """.write(to: settings, atomically: true, encoding: .utf8)
        let cap = UsageCapture(home: home, supportDirectory: support)
        try cap.set(true)
        let sent = input(42)
        let r = ProcessRunner.run("/bin/sh", ["-c", cap.wrapperCommand], timeout: 10, stdin: sent)
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "STATUS")
        XCTAssertEqual(try Data(contentsOf: marker), sent, "the original got the same input")
        XCTAssertEqual(cap.read()?.fiveHour?.pct, 42)
    }

    func testRefusesInvalidSettings() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try "{ nope".write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        let cap = UsageCapture(home: home, supportDirectory: home.appendingPathComponent("support"))
        XCTAssertThrowsError(try cap.set(true))
        if case .unreadable = cap.state() {} else { XCTFail("expected unreadable") }
    }
}
