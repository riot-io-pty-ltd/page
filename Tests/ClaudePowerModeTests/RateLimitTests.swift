import XCTest
@testable import ClaudePowerMode

private func utc(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)!
}

private let joburg = TimeZone(identifier: "Africa/Johannesburg")!
private let london = TimeZone(identifier: "Europe/London")!

final class ResetTextParsingTests: XCTestCase {
    private func parse(_ text: String, _ ref: String, tz: TimeZone = joburg) -> Date? {
        TranscriptParser.parseResetTime(from: text, referenceTime: utc(ref), defaultTimeZone: tz)
    }

    func testRealClaudeCodeMessageMatchesStructuredResetsAt() {
        // Real line from Claude Code 2.1.2xx: quotaLimits.resetsAt = 1791390000.
        let d = parse("You've hit your session limit · resets 6:20pm (Africa/Johannesburg)", "2026-10-07T12:10:23Z")
        XCTAssertEqual(d, Date(timeIntervalSince1970: 1_791_390_000))
    }

    func testBareHourUsesDefaultTimeZone() {
        // 10:00Z is 11:00 BST; 7pm BST is 18:00Z.
        XCTAssertEqual(parse("resets 7pm", "2026-10-24T10:00:00Z", tz: london), utc("2026-10-24T18:00:00Z"))
    }

    func testAtWithMinutesAndAlias() {
        XCTAssertEqual(parse("resets at 7:30 PM (PT)", "2026-10-24T10:00:00Z"), utc("2026-10-25T02:30:00Z"))
    }

    func testNamedZoneRollsOverAcrossFallBack() {
        // 20:00Z Oct 24 is after 7pm BST, so the next 7pm is Oct 25 — the day
        // BST ends — at 19:00 GMT. A fixed +24h would give 18:00Z.
        XCTAssertEqual(parse("resets 7pm (Europe/London)", "2026-10-24T20:00:00Z"), utc("2026-10-25T19:00:00Z"))
    }

    func testDSTFallBackRolloverIsNotAnHourEarly() {
        // 23:00 PDT Oct 31; next 3am is Nov 1 03:00 PST = 11:00Z (not 10:00Z).
        XCTAssertEqual(parse("You've hit your limit · resets 3am (America/Los_Angeles)", "2026-11-01T06:00:00Z"),
                       utc("2026-11-01T11:00:00Z"))
    }

    func testDSTSpringForwardGapLandsAfterTheGap() {
        // 2:30am doesn't exist on 2027-03-14 in New York; must not land before 3:00 EDT (07:00Z).
        let d = parse("resets 2:30am (America/New_York)", "2027-03-14T05:00:00Z")
        XCTAssertNotNil(d)
        XCTAssertGreaterThanOrEqual(d!, utc("2027-03-14T07:00:00Z"))
        XCTAssertLessThanOrEqual(d!, utc("2027-03-14T07:30:00Z"))
    }

    func testMidnightAndNoonRollover() {
        XCTAssertEqual(parse("resets 12am (UTC)", "2026-10-24T23:30:00Z"), utc("2026-10-25T00:00:00Z"))
        XCTAssertEqual(parse("resets 12pm (UTC)", "2026-10-24T13:00:00Z"), utc("2026-10-25T12:00:00Z"))
        XCTAssertEqual(parse("resets 11:59pm (UTC)", "2026-10-24T23:58:00Z"), utc("2026-10-24T23:59:00Z"))
    }

    func testDatedWeeklyLimit() {
        XCTAssertEqual(parse("You've hit your weekly limit · resets Oct 27, 9am (Africa/Johannesburg)", "2026-10-24T10:00:00Z"),
                       utc("2026-10-27T07:00:00Z"))
        XCTAssertEqual(parse("resets Oct 25 at 7pm (Europe/London)", "2026-10-24T10:00:00Z"),
                       utc("2026-10-25T19:00:00Z"))
        XCTAssertEqual(parse("resets 27 October, 09:00 (UTC)", "2026-10-24T10:00:00Z"),
                       utc("2026-10-27T09:00:00Z"))
    }

    func testDatedWithExplicitYearAndYearRollover() {
        XCTAssertEqual(parse("resets Jan 2, 2027, 9am (UTC)", "2026-10-24T10:00:00Z"), utc("2027-01-02T09:00:00Z"))
        XCTAssertEqual(parse("resets Jan 2, 9am (UTC)", "2026-12-30T12:00:00Z"), utc("2027-01-02T09:00:00Z"))
    }

    func testRelativeForms() {
        let ref = "2026-10-24T10:00:00Z"
        XCTAssertEqual(parse("resets in 2 hours", ref), utc("2026-10-24T12:00:00Z"))
        XCTAssertEqual(parse("Limit reached, resets in 45 minutes", ref), utc("2026-10-24T10:45:00Z"))
        XCTAssertEqual(parse("resets in 2h 30m", ref), utc("2026-10-24T12:30:00Z"))
        XCTAssertEqual(parse("resets in 1 hour and 5 minutes", ref), utc("2026-10-24T11:05:00Z"))
    }

    func test24HourAndAmbiguousTimes() {
        let ref = "2026-10-24T10:00:00Z"
        XCTAssertEqual(parse("resets 19:00 (UTC)", ref), utc("2026-10-24T19:00:00Z"))
        XCTAssertEqual(parse("resets at 07:30 (UTC)", ref), utc("2026-10-25T07:30:00Z"))
        // No am/pm, no leading zero: nearest future reading (19:30, not tomorrow 07:30).
        XCTAssertEqual(parse("resets 7:30 (UTC)", ref), utc("2026-10-24T19:30:00Z"))
        XCTAssertEqual(parse("resets 7pm UTC", ref), utc("2026-10-24T19:00:00Z"))
        XCTAssertEqual(parse("resets 9pm (UTC+2)", ref), utc("2026-10-24T19:00:00Z"))
    }

    func testISODateAndEpochSuffix() {
        XCTAssertEqual(parse("resets 2026-10-28 00:00 UTC", "2026-10-24T10:00:00Z"), utc("2026-10-28T00:00:00Z"))
        XCTAssertEqual(parse("Claude AI usage limit reached|1761350400", "2026-10-24T10:00:00Z"),
                       Date(timeIntervalSince1970: 1_761_350_400))
    }

    func testUnicodeSpacesFromICU() {
        XCTAssertEqual(parse("resets 7:00\u{202F}PM (UTC)", "2026-10-24T10:00:00Z"), utc("2026-10-24T19:00:00Z"))
    }

    func testInvalidInputReturnsNil() {
        let ref = "2026-10-24T10:00:00Z"
        XCTAssertNil(parse("resets 25:99", ref))
        XCTAssertNil(parse("resets 13pm", ref))
        XCTAssertNil(parse("resets Feb 30, 9am (UTC)", ref))
        XCTAssertNil(parse("API Error: Request rejected (429) · Please try again later.", ref))
        XCTAssertNil(parse("resets soon", ref))
    }
}

final class RateLimitRecordTests: XCTestCase {
    private func record(text: String, extra: [String: Any] = [:]) -> [String: Any] {
        var obj: [String: Any] = [
            "type": "assistant",
            "isSidechain": false,
            "timestamp": "2026-10-07T12:10:23.368Z",
            "error": "rate_limit",
            "isApiErrorMessage": true,
            "apiErrorStatus": 429,
            "sessionId": "c2615166-20b0-4940-adc9-662729f4c376",
            "cwd": "/nonexistent/project/sub",
            "message": ["model": "<synthetic>", "content": [["type": "text", "text": text]]]
        ]
        for (k, v) in extra { obj[k] = v }
        return obj
    }

    func testStructuredResetsAtWins() {
        let obj = record(text: "You've hit your session limit · resets 9pm (Africa/Johannesburg)", extra: [
            "quotaLimits": ["status": "rejected", "resetsAt": 1_791_390_000, "rateLimitType": "five_hour"]
        ])
        guard case .event(let e) = TranscriptParser.classifyRateLimitRecord(obj, transcriptPath: "/x/-p/s.jsonl") else {
            return XCTFail("expected event")
        }
        XCTAssertEqual(e.resetTime, Date(timeIntervalSince1970: 1_791_390_000))
        XCTAssertEqual(e.limitType, "five_hour")
        XCTAssertFalse(e.resetTimeIsEstimated)
        XCTAssertEqual(e.backend, .claude)
        XCTAssertEqual(e.sessionId, "c2615166-20b0-4940-adc9-662729f4c376")
    }

    func testTextFallbackAndLaunchDirectory() {
        let obj = record(text: "You've hit your session limit · resets 6:20pm (Africa/Johannesburg)")
        let result = TranscriptParser.classifyRateLimitRecord(obj, transcriptPath: "/x/-p/s.jsonl",
                                                              launchDirectory: { _ in "/nonexistent/project" })
        guard case .event(let e) = result else { return XCTFail("expected event") }
        XCTAssertEqual(e.resetTime, Date(timeIntervalSince1970: 1_791_390_000))
        XCTAssertEqual(e.cwd, "/nonexistent/project")
        XCTAssertEqual(e.projectName, "project")
    }

    func testTransient429IsNotAWall() {
        let obj = record(text: "API Error: Request rejected (429) · This request would exceed your account's rate limit. Please try again later.")
        guard case .transient = TranscriptParser.classifyRateLimitRecord(obj, transcriptPath: "/x/-p/s.jsonl") else {
            return XCTFail("expected transient")
        }
    }

    func testUnparseableWallIsEmittedWithEstimatedReset() {
        let obj = record(text: "You've hit your usage limit. Upgrade for more.")
        guard case .event(let e) = TranscriptParser.classifyRateLimitRecord(obj, transcriptPath: "/x/-p/s.jsonl") else {
            return XCTFail("expected event")
        }
        XCTAssertTrue(e.resetTimeIsEstimated)
        XCTAssertEqual(e.resetTime, e.eventTime.addingTimeInterval(5 * 3600))
    }

    func testSubagentLimitsAreIgnored() {
        let obj = record(text: "resets 7pm", extra: ["isSidechain": true])
        XCTAssertEqual(TranscriptParser.classifyRateLimitRecord(obj, transcriptPath: "/x/-p/s.jsonl"), .ignored)
        let obj2 = record(text: "resets 7pm", extra: ["agentId": "a1"])
        XCTAssertEqual(TranscriptParser.classifyRateLimitRecord(obj2, transcriptPath: "/x/-p/s.jsonl"), .ignored)
    }
}

final class LaunchDirectoryTests: XCTestCase {
    func testEncodingMatchesClaudeCode() {
        XCTAssertEqual(TranscriptParser.encodeProjectFolder("/Users/me/projects/mac-on-claude-code"),
                       "-Users-me-projects-mac-on-claude-code")
        XCTAssertEqual(TranscriptParser.encodeProjectFolder("/Users/me/.ssh"), "-Users-me--ssh")
        XCTAssertEqual(TranscriptParser.encodeProjectFolder("/private/tmp/claude-501/-Users-x"),
                       "-private-tmp-claude-501--Users-x")
        XCTAssertEqual(TranscriptParser.encodeProjectFolder("/a/é"), "-a--")
    }

    func testWalksUpFromSubdirectory() {
        let dirs: Set<String> = ["/Users/me/projects/mac-on-claude-code", "/Users/me/projects/mac-on-claude-code/Designs"]
        let dir = TranscriptParser.launchDirectory(
            projectFolder: "-Users-me-projects-mac-on-claude-code",
            hintCwd: "/Users/me/projects/mac-on-claude-code/Designs",
            firstRecordCwd: nil,
            isDirectory: { dirs.contains($0) })
        XCTAssertEqual(dir, "/Users/me/projects/mac-on-claude-code")
    }

    func testDotsAndDashesInPath() {
        let dir = TranscriptParser.launchDirectory(
            projectFolder: "-Users-me-Documents--work-1-5-1-Sate-t-production",
            hintCwd: "/Users/me/Documents/.work-1.5.1/Sate-t-production/tools/fota_test_lte",
            firstRecordCwd: nil,
            isDirectory: { _ in true })
        XCTAssertEqual(dir, "/Users/me/Documents/.work-1.5.1/Sate-t-production")
    }

    func testFallsBackToFirstRecordAndRequiresExistence() {
        let folder = "-Users-me-proj"
        XCTAssertEqual(TranscriptParser.launchDirectory(projectFolder: folder, hintCwd: "/tmp/elsewhere",
                                                        firstRecordCwd: "/Users/me/proj", isDirectory: { _ in true }),
                       "/Users/me/proj")
        XCTAssertNil(TranscriptParser.launchDirectory(projectFolder: folder, hintCwd: "/Users/me/proj/sub",
                                                      firstRecordCwd: "/Users/me/proj", isDirectory: { _ in false }))
    }
}

final class RateLimitIndexTests: XCTestCase {
    private var root: URL!
    private var projectDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ratelimit-\(UUID().uuidString)")
        projectDir = root.appendingPathComponent("-tmp-project")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func limitLine(_ ts: String, resetsAt: Int, sid: String = "sess-1") -> String {
        let obj: [String: Any] = [
            "type": "assistant", "isSidechain": false, "timestamp": ts, "error": "rate_limit",
            "isApiErrorMessage": true, "apiErrorStatus": 429, "sessionId": sid, "cwd": "/tmp",
            "quotaLimits": ["resetsAt": resetsAt, "rateLimitType": "five_hour"],
            "message": ["model": "<synthetic>", "content": [["type": "text", "text": "You've hit your session limit · resets 9pm (UTC)"]]]
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private func replyLine(_ ts: String) -> String {
        #"{"type":"assistant","isSidechain":false,"timestamp":"\#(ts)","sessionId":"sess-1","message":{"model":"claude-opus","role":"assistant","content":[{"type":"text","text":"ok"}]}}"#
    }

    private func append(_ s: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(s.utf8))
        try h.close()
    }

    func testIncrementalReadsPartialLinesAndTruncation() throws {
        let now = utc("2026-10-24T12:00:00Z")
        let reset = Int(utc("2026-10-24T15:00:00Z").timeIntervalSince1970)
        let file = projectDir.appendingPathComponent("sess-1.jsonl")
        let index = RateLimitTranscriptIndex(defaultTimeZone: TimeZone(identifier: "UTC")!)
        index.chunkSize = 64   // force multi-chunk reads

        try append(#"{"type":"user","cwd":"/tmp"}"# + "\n" + limitLine("2026-10-24T11:00:00Z", resetsAt: reset) + "\n", to: file)
        XCTAssertEqual(index.scan(directory: root.path, lookbackHours: 6, now: now).events.count, 1)

        // Half-written line: not parsed yet, and not double-counted later.
        let second = limitLine("2026-10-24T11:05:00Z", resetsAt: reset)
        let cut = second.index(second.startIndex, offsetBy: 40)
        try append(String(second[..<cut]), to: file)
        XCTAssertEqual(index.scan(directory: root.path, lookbackHours: 6, now: now).events.count, 1)
        try append(String(second[cut...]) + "\n", to: file)
        XCTAssertEqual(index.scan(directory: root.path, lookbackHours: 6, now: now).events.count, 2)
        XCTAssertEqual(index.scan(directory: root.path, lookbackHours: 6, now: now).events.count, 2)

        // Rewritten smaller (rotation / truncation) → rescanned from scratch.
        try (limitLine("2026-10-24T11:30:00Z", resetsAt: reset) + "\n").write(to: file, atomically: true, encoding: .utf8)
        let events = index.scan(directory: root.path, lookbackHours: 6, now: now).events
        XCTAssertEqual(events.map(\.eventTime), [utc("2026-10-24T11:30:00Z")])
    }

    func testSubagentTranscriptsAreSkippedAndSuccessfulRepliesTracked() throws {
        let now = utc("2026-10-24T12:00:00Z")
        let reset = Int(utc("2026-10-24T15:00:00Z").timeIntervalSince1970)
        let sub = projectDir.appendingPathComponent("sess-1/subagents")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try append(limitLine("2026-10-24T11:00:00Z", resetsAt: reset, sid: "sub") + "\n", to: sub.appendingPathComponent("agent-a.jsonl"))
        let file = projectDir.appendingPathComponent("sess-1.jsonl")
        try append(limitLine("2026-10-24T11:00:00Z", resetsAt: reset) + "\n" + replyLine("2026-10-24T11:10:00Z") + "\n", to: file)

        let index = RateLimitTranscriptIndex()
        let result = index.scan(directory: root.path, lookbackHours: 6, now: now)
        XCTAssertEqual(result.events.map(\.sessionId), ["sess-1"])
        XCTAssertEqual(result.lastSuccessfulReply[file.standardizedFileURL.path], utc("2026-10-24T11:10:00Z"))
        XCTAssertTrue(RateLimitWatcher.activeLimits(result.events, lastSuccessfulReply: result.lastSuccessfulReply, now: now).isEmpty)
    }

    func testExpiredEventsOutsideLookbackAreDropped() throws {
        let now = utc("2026-10-24T12:00:00Z")
        let file = projectDir.appendingPathComponent("sess-1.jsonl")
        try append(limitLine("2026-10-24T01:00:00Z", resetsAt: Int(utc("2026-10-24T05:00:00Z").timeIntervalSince1970)) + "\n", to: file)
        XCTAssertTrue(RateLimitTranscriptIndex().scan(directory: root.path, lookbackHours: 6, now: now).events.isEmpty)
    }

    func testWatcherPrimesOnlyExpiredAndNotifiesOncePerWall() throws {
        let now = utc("2026-10-24T12:00:00Z")
        let reset = Int(utc("2026-10-24T15:00:00Z").timeIntervalSince1970)
        let file = projectDir.appendingPathComponent("sess-1.jsonl")
        try append([
            limitLine("2026-10-24T08:00:00Z", resetsAt: Int(utc("2026-10-24T09:00:00Z").timeIntervalSince1970)),
            limitLine("2026-10-24T11:00:00Z", resetsAt: reset),
            limitLine("2026-10-24T11:01:00Z", resetsAt: reset),
            limitLine("2026-10-24T11:02:00Z", resetsAt: reset)
        ].joined(separator: "\n") + "\n", to: file)

        let watcher = RateLimitWatcher(index: RateLimitTranscriptIndex())
        var notified: [RateLimitEvent] = []
        watcher.onNewEvent = { notified.append($0) }
        watcher.primeWithExistingEvents(transcriptDirectory: root.path, now: now)
        XCTAssertTrue(notified.isEmpty)

        watcher.scan(transcriptDirectory: root.path, now: now)
        XCTAssertEqual(notified.map(\.eventTime), [utc("2026-10-24T11:00:00Z")], "active limit survives priming; retries collapse")
        XCTAssertEqual(watcher.activeLimit(now: now)?.eventTime, utc("2026-10-24T11:02:00Z"))

        try append(limitLine("2026-10-24T11:30:00Z", resetsAt: reset) + "\n", to: file)
        watcher.scan(transcriptDirectory: root.path, now: now)
        XCTAssertEqual(notified.count, 1, "another retry against the same wall doesn't re-notify")

        XCTAssertNil(watcher.activeLimit(now: utc("2026-10-24T15:00:01Z")))
    }

    func testNotifyStateIsPrunedToPresentEvents() {
        let e = RateLimitEvent(sessionId: "s", cwd: "/", projectName: "", eventTime: utc("2026-10-24T11:00:00Z"),
                               resetTime: utc("2026-10-24T15:00:00Z"), resetTimeText: "", transcriptPath: "/t")
        let (n1, s1) = RateLimitWatcher.eventsToNotify([e], state: .init(), lastSuccessfulReply: [:], now: utc("2026-10-24T12:00:00Z"))
        XCTAssertEqual(n1, [e])
        let (n2, s2) = RateLimitWatcher.eventsToNotify([], state: s1, lastSuccessfulReply: [:], now: utc("2026-10-24T12:00:00Z"))
        XCTAssertTrue(n2.isEmpty)
        XCTAssertEqual(s2, .init())
    }
}
