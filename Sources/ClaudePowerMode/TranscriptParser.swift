import Foundation

struct RateLimitEvent: Equatable, Hashable {
    let sessionId: String
    /// The directory the session was *started* in (where `claude --resume`
    /// can find it), not wherever the agent had `cd`-ed to when it hit the
    /// limit. See `TranscriptParser.launchDirectory`.
    let cwd: String
    let projectName: String
    let eventTime: Date
    let resetTime: Date
    let resetTimeText: String
    let transcriptPath: String
    /// Which agent hit the limit. Only Claude limits can be auto-resumed.
    var backend: AgentBackendID = .claude
    /// True when Claude Code said the session is blocked but neither the
    /// structured `resetsAt` nor the message text gave a usable reset time.
    /// `resetTime` is then a conservative guess (event + 5h): fine for
    /// "rate-limited" UI and keeping the Mac awake, never good enough to
    /// auto-schedule a resume (ResumeScheduler refuses these by default).
    var resetTimeIsEstimated: Bool = false
    /// "five_hour" / "seven_day" when Claude Code recorded it, else nil.
    var limitType: String? = nil

    var uniqueId: String { "\(sessionId)-\(Int(eventTime.timeIntervalSince1970))" }

    /// Identity of the limit "wall" itself. Every retry against the same wall
    /// writes another transcript line (10+ identical lines per wall are
    /// common), each with its own `uniqueId` but the same reset; notifying
    /// and scheduling once per wall is what the user expects.
    var wallKey: String {
        if resetTimeIsEstimated {
            // The estimate moves with each retry; bucket retries into the
            // 5-hour window they fall in instead.
            return "\(backend.rawValue)-\(sessionId)-est-\(Int(eventTime.timeIntervalSince1970) / 18_000)"
        }
        return "\(backend.rawValue)-\(sessionId)-\(Int(resetTime.timeIntervalSince1970) / 60)"
    }
}

enum TranscriptParser {
    /// Fallback block length when Claude Code says the session hit its limit
    /// but we can't tell when it resets. Claude's shortest window is 5h.
    static let estimatedResetInterval: TimeInterval = 5 * 3600

    /// Every rate-limit event in `*.jsonl` transcripts under `directory` from
    /// the last `lookbackHours`, plus older ones whose reset is still ahead.
    ///
    /// Backed by the process-wide incremental index: the first call reads
    /// each recent transcript once, later calls only read bytes appended
    /// since. Calling this every tick is cheap.
    static func findRateLimitEvents(directory: String, lookbackHours: Double = 6) -> [RateLimitEvent] {
        RateLimitTranscriptIndex.shared.scan(directory: directory, lookbackHours: lookbackHours).events
    }

    // MARK: - Line classification

    enum RateLimitRecord: Equatable {
        case event(RateLimitEvent)
        /// A 429 that isn't a usage-limit wall ("Request rejected (429) ·
        /// … Please try again later"): a short API throttle Claude Code
        /// recovers from. Paging the user "rate-limited for 5 hours" for one
        /// of these would be wrong, so they're logged and dropped.
        case transient(String)
        case ignored
    }

    static func isRateLimitRecord(_ obj: [String: Any]) -> Bool {
        if let err = obj["error"] as? String, err == "rate_limit" { return true }
        if let status = obj["apiErrorStatus"] as? Int, status == 429 { return true }
        return false
    }

    /// Turns one decoded transcript record into a rate-limit event.
    ///
    /// Reset time, best source first:
    /// 1. `quotaLimits.resetsAt` / `apiErrorParams.rate_limit_info.resetsAt`
    ///    (epoch seconds, Claude Code 2.1.2xx+): exact, no TZ/DST guessing.
    /// 2. The human text ("resets 7pm (Europe/London)", "resets Oct 27, 9am",
    ///    "resets in 2 hours", ...), via `parseResetTime`.
    /// 3. If the record is clearly a usage-limit wall but neither parses,
    ///    emit anyway with eventTime + 5h, flagged `resetTimeIsEstimated`,
    ///    so the user still hears about it. Generic 429s are `.transient`.
    ///
    /// `launchDirectory` maps the record's own `cwd` (may be a subdirectory)
    /// to the session's launch directory; nil means unknown.
    static func classifyRateLimitRecord(
        _ obj: [String: Any],
        transcriptPath: String,
        defaultTimeZone: TimeZone = .current,
        launchDirectory: (String?) -> String? = { _ in nil }
    ) -> RateLimitRecord {
        guard isRateLimitRecord(obj) else { return .ignored }
        // Skip subagent (Task-spawned) rate-limits — resuming the parent on a
        // subagent's failure usually does the wrong thing. We only handle
        // rate-limits that hit the user's main session.
        if obj["isSidechain"] as? Bool == true { return .ignored }
        if obj["agentId"] != nil { return .ignored }
        guard let eventTime = parseTimestamp(obj["timestamp"] as? String) else { return .ignored }

        let url = URL(fileURLWithPath: transcriptPath)
        let sessionId = (obj["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent
        let lineCwd = obj["cwd"] as? String
        let cwd = launchDirectory(lineCwd)
            ?? lineCwd
            ?? decodeProjectPath(from: url.deletingLastPathComponent().lastPathComponent)
        let text = extractResetText(from: obj) ?? ""

        var resetTime = structuredResetTime(from: obj, referenceTime: eventTime)
            ?? parseResetTime(from: text, referenceTime: eventTime, defaultTimeZone: defaultTimeZone)
        var estimated = false
        if resetTime == nil {
            guard isUsageLimitWall(obj, text: text) else { return .transient(text) }
            resetTime = eventTime.addingTimeInterval(estimatedResetInterval)
            estimated = true
        }

        return .event(RateLimitEvent(
            sessionId: sessionId,
            cwd: cwd,
            projectName: URL(fileURLWithPath: cwd).lastPathComponent,
            eventTime: eventTime,
            resetTime: resetTime!,
            resetTimeText: text,
            transcriptPath: transcriptPath,
            backend: .claude,
            resetTimeIsEstimated: estimated,
            limitType: limitType(from: obj)
        ))
    }

    /// Epoch reset from Claude Code's structured quota fields, if present
    /// and plausible (within a day before / 35 days after the event).
    static func structuredResetTime(from obj: [String: Any], referenceTime: Date) -> Date? {
        let quota = obj["quotaLimits"] as? [String: Any]
        let info = (obj["apiErrorParams"] as? [String: Any])?["rate_limit_info"] as? [String: Any]
        for raw in [quota?["resetsAt"], info?["resetsAt"]] {
            guard let n = (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap(Double.init) else { continue }
            let seconds = n > 1e12 ? n / 1000 : n   // tolerate milliseconds
            let date = Date(timeIntervalSince1970: seconds)
            let delta = date.timeIntervalSince(referenceTime)
            if delta > -86_400 && delta < 35 * 86_400 { return date }
        }
        return nil
    }

    private static func limitType(from obj: [String: Any]) -> String? {
        if let t = (obj["quotaLimits"] as? [String: Any])?["rateLimitType"] as? String { return t }
        let info = (obj["apiErrorParams"] as? [String: Any])?["rate_limit_info"] as? [String: Any]
        return info?["rateLimitType"] as? String
    }

    /// True for "you're blocked until a reset" records, as opposed to
    /// transient API throttles.
    static func isUsageLimitWall(_ obj: [String: Any], text: String) -> Bool {
        if obj["quotaLimits"] != nil { return true }
        if let apiError = obj["apiError"] as? String, apiError.contains("limit_reached") { return true }
        let t = text.lowercased()
        guard t.contains("limit") else { return false }
        return t.contains("hit your") || t.contains("usage limit") || t.contains("limit reached")
            || t.contains("reached your") || t.contains("reset")
    }

    private static func extractResetText(from obj: [String: Any]) -> String? {
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        if let s = msg["content"] as? String { return s }
        guard let contentArr = msg["content"] as? [[String: Any]] else { return nil }
        for item in contentArr {
            if let text = item["text"] as? String { return text }
        }
        return nil
    }

    // MARK: - Timestamps

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoFormatterNoFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    /// ISO8601DateFormatter isn't documented as thread-safe; the index and
    /// InterventionDetector can parse concurrently.
    private static let isoLock = NSLock()

    /// Transcript `timestamp` values ("2026-10-07T12:10:23.368Z", with or
    /// without fractional seconds).
    static func parseTimestamp(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        isoLock.lock()
        defer { isoLock.unlock() }
        return isoFormatter.date(from: s) ?? isoFormatterNoFractions.date(from: s)
    }

    // MARK: - Reset text

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure is a programming error.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let resetAnchor = regex(#"\breset(?:s|ting)?\b"#)
    private static let epochSuffix = regex(#"\|\s*(\d{10,13})\s*$"#)
    private static let relativeForm = regex(#"^\s*in\s+((?:\d+\s*[a-z]+[\s,]*(?:and\s+)?)+)"#)
    private static let relativeUnit = regex(#"(\d+)\s*([a-z]+)"#)

    // TIME: "7pm", "7:30 PM", "19:00", "7 p.m." — never followed by more digits.
    private static let timePattern = #"(\d{1,2})(?::(\d{2}))?(?::\d{2})?\s*(a\.?\s?m\.?|p\.?\s?m\.?)?(?![\d:])"#
    // TZ: "(Europe/London)", "(PT)", or a bare trailing "UTC" / "PST" / "UTC+2".
    private static let tzPattern = #"(?:\s*\(([^)]+)\)|\s+([a-z]{2,5}(?:[+-]\d{1,2}(?::?\d{2})?)?)(?![a-z]))?"#
    private static let monthPattern = #"(jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)[a-z]*\.?"#
    private static let weekdayPattern = #"(?:(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*\.?,?\s+)?"#

    private static let monthFirstForm = regex(
        #"^\s*(?:at\s+|on\s+)?"# + weekdayPattern + monthPattern
        + #"\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?,?\s+(?:at\s+)?"# + timePattern + tzPattern)
    private static let dayFirstForm = regex(
        #"^\s*(?:at\s+|on\s+)?"# + weekdayPattern + #"(\d{1,2})(?:st|nd|rd|th)?\s+"# + monthPattern
        + #"(?:,?\s+(\d{4}))?,?\s+(?:at\s+)?"# + timePattern + tzPattern)
    private static let isoForm = regex(
        #"^\s*(?:at\s+|on\s+)?(\d{4})-(\d{2})-(\d{2})[ t](\d{1,2}):(\d{2})(?::\d{2})?(?![\d])\s*(z\b|[a-z]{2,5}(?:[+-]\d{1,2}(?::?\d{2})?)?)?"#)
    private static let timeOnlyForm = regex(#"^\s*(?:at\s+)?"# + timePattern + tzPattern)

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// Parses the reset moment out of Claude Code's limit message.
    ///
    /// Handles "resets 7pm", "resets at 7:30 PM", "resets 7pm (Europe/London)",
    /// "resets Oct 25, 7pm (TZ)", "resets Jan 2, 2027, 9am (UTC)",
    /// "resets 25 Oct at 19:00", "resets 2026-08-08 00:00 UTC",
    /// "resets in 2 hours" / "in 45 minutes" / "in 2h 30m", 24h "19:00",
    /// and the legacy "...|1761350400" epoch suffix.
    ///
    /// Wall-clock times resolve in the named timezone (else
    /// `defaultTimeZone`, which is what Claude Code prints in) to the first
    /// matching moment strictly after `referenceTime`, using Calendar date
    /// math so DST transitions land on the right hour. Out-of-range values
    /// ("25:99") return nil rather than being normalised into something else.
    static func parseResetTime(
        from text: String,
        referenceTime: Date,
        defaultTimeZone: TimeZone = .current
    ) -> Date? {
        // ICU emits U+202F / U+00A0 before "PM" in newer Node builds.
        let text = text
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        if let m = epochSuffix.firstMatch(in: text, range: full),
           let n = Double(ns.substring(with: m.range(at: 1))) {
            return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        }

        guard let anchor = resetAnchor.firstMatch(in: text, range: full) else { return nil }
        let tail = ns.substring(from: anchor.range.location + anchor.range.length)
        let tailNS = tail as NSString
        let tailRange = NSRange(location: 0, length: tailNS.length)
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : tailNS.substring(with: r)
        }

        if let m = relativeForm.firstMatch(in: tail, range: tailRange), let body = group(m, 1) {
            return parseRelative(body).map { referenceTime.addingTimeInterval($0) }
        }

        if let m = isoForm.firstMatch(in: tail, range: tailRange) {
            guard let y = Int(group(m, 1) ?? ""), let mo = Int(group(m, 2) ?? ""), let d = Int(group(m, 3) ?? ""),
                  let h = Int(group(m, 4) ?? ""), let mi = Int(group(m, 5) ?? ""),
                  (0...23).contains(h), (0...59).contains(mi) else { return nil }
            let tzToken = group(m, 6).map { $0.lowercased() == "z" ? "UTC" : $0 }
            let tz = resolveTimezone(tzToken) ?? defaultTimeZone
            return makeDate(year: y, month: mo, day: d, hour: h, minute: mi, in: tz)
        }

        for (form, monthGroup, dayGroup) in [(monthFirstForm, 1, 2), (dayFirstForm, 2, 1)] {
            guard let m = form.firstMatch(in: tail, range: tailRange) else { continue }
            guard let monthName = group(m, monthGroup)?.lowercased(),
                  let monthIndex = months.firstIndex(where: { monthName.hasPrefix($0) }),
                  let day = Int(group(m, dayGroup) ?? ""),
                  let clock = clockTime(hour: group(m, 4), minute: group(m, 5), meridiem: group(m, 6)) else { return nil }
            let tz = resolveTimezone(group(m, 7) ?? group(m, 8)) ?? defaultTimeZone
            let explicitYear = group(m, 3).flatMap { Int($0) }
            let year = explicitYear ?? gregorian(tz).component(.year, from: referenceTime)
            // Ambiguous no-am/pm hours take the earlier reading for dated
            // resets; Claude Code always prints am/pm here anyway.
            guard var date = makeDate(year: year, month: monthIndex + 1, day: day,
                                      hour: clock.hours[0], minute: clock.minute, in: tz) else { return nil }
            // "Jan 2" seen on Dec 30 means next January.
            if explicitYear == nil, date < referenceTime.addingTimeInterval(-7 * 86_400),
               let next = makeDate(year: year + 1, month: monthIndex + 1, day: day,
                                   hour: clock.hours[0], minute: clock.minute, in: tz) {
                date = next
            }
            return date
        }

        if let m = timeOnlyForm.firstMatch(in: tail, range: tailRange) {
            guard let clock = clockTime(hour: group(m, 1), minute: group(m, 2), meridiem: group(m, 3)) else { return nil }
            let tz = resolveTimezone(group(m, 4) ?? group(m, 5)) ?? defaultTimeZone
            let calendar = gregorian(tz)
            let candidates = clock.hours.compactMap { hour in
                calendar.nextDate(
                    after: referenceTime,
                    matching: DateComponents(hour: hour, minute: clock.minute, second: 0),
                    matchingPolicy: .nextTime,
                    repeatedTimePolicy: .first,
                    direction: .forward
                )
            }
            return candidates.min()
        }
        return nil
    }

    /// Validated 24h hour candidates + minute. An unambiguous time yields one
    /// hour; a bare 1–12 with no am/pm and no leading zero ("resets 7:30")
    /// yields both readings so the caller can take the nearest future one.
    private static func clockTime(hour: String?, minute: String?, meridiem: String?) -> (hours: [Int], minute: Int)? {
        guard let hourStr = hour, let h = Int(hourStr) else { return nil }
        let mi = minute.flatMap { Int($0) } ?? 0
        guard (0...59).contains(mi) else { return nil }
        let ampm = meridiem?.lowercased().filter { $0 == "a" || $0 == "p" }
        switch ampm {
        case "a"?:
            guard (1...12).contains(h) else { return nil }
            return ([h == 12 ? 0 : h], mi)
        case "p"?:
            guard (1...12).contains(h) else { return nil }
            return ([h == 12 ? 12 : h + 12], mi)
        default:
            guard (0...23).contains(h) else { return nil }
            if (1...12).contains(h) && !hourStr.hasPrefix("0") {
                return ([h, (h + 12) % 24], mi)
            }
            return ([h], mi)
        }
    }

    /// "2 hours", "45 minutes", "2h 30m", "1 hour and 5 minutes" → seconds.
    private static func parseRelative(_ body: String) -> TimeInterval? {
        let ns = body as NSString
        var total: TimeInterval = 0
        for m in relativeUnit.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            guard let n = Double(ns.substring(with: m.range(at: 1))) else { return nil }
            let unit = ns.substring(with: m.range(at: 2)).lowercased()
            switch unit {
            case "d", "day", "days": total += n * 86_400
            case "h", "hr", "hrs", "hour", "hours": total += n * 3600
            case "m", "min", "mins", "minute", "minutes": total += n * 60
            case "s", "sec", "secs", "second", "seconds": total += n
            default: return nil
            }
        }
        return total > 0 ? total : nil
    }

    private static func gregorian(_ tz: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "en_US_POSIX")
        c.timeZone = tz
        return c
    }

    /// A strict (non-normalising) wall-clock date: "Feb 30" is nil, not Mar 2.
    private static func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, in tz: TimeZone) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let calendar = gregorian(tz)
        let comps = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0)
        guard let date = calendar.date(from: comps) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return date
    }

    private static let offsetZone = regex(#"^(?:utc|gmt)\s*([+-])(\d{1,2})(?::?(\d{2}))?$"#)

    static func resolveTimezone(_ name: String?) -> TimeZone? {
        guard let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return nil }
        // Common short forms first: Foundation resolves several of these
        // ("EST", "MST") to a fixed offset, not the DST-observing zone
        // Claude Code meant.
        if let id = aliases[n.uppercased()], let tz = TimeZone(identifier: id) { return tz }
        if let tz = TimeZone(identifier: n) { return tz }
        // "UTC+2", "GMT-05:30"
        if let m = offsetZone.firstMatch(in: n, range: NSRange(location: 0, length: (n as NSString).length)) {
            let ns = n as NSString
            let sign = ns.substring(with: m.range(at: 1)) == "-" ? -1 : 1
            let h = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let mins = m.range(at: 3).location == NSNotFound ? 0 : Int(ns.substring(with: m.range(at: 3))) ?? 0
            guard h <= 14, mins < 60 else { return nil }
            return TimeZone(secondsFromGMT: sign * (h * 3600 + mins * 60))
        }
        return TimeZone(abbreviation: n.uppercased())
    }

    private static let aliases: [String: String] = [
        "PT": "America/Los_Angeles", "PST": "America/Los_Angeles", "PDT": "America/Los_Angeles",
        "ET": "America/New_York", "EST": "America/New_York", "EDT": "America/New_York",
        "CT": "America/Chicago", "CST": "America/Chicago", "CDT": "America/Chicago",
        "MT": "America/Denver", "MST": "America/Denver", "MDT": "America/Denver",
        "BST": "Europe/London", "UTC": "UTC", "GMT": "GMT", "Z": "UTC",
        "CET": "Europe/Berlin", "CEST": "Europe/Berlin",
        "SAST": "Africa/Johannesburg",
        "JST": "Asia/Tokyo", "IST": "Asia/Kolkata",
        "AEST": "Australia/Sydney", "AEDT": "Australia/Sydney"
    ]

    // MARK: - Project / launch directory

    /// Claude Code's project-folder name for a path: every UTF-16 code unit
    /// that isn't [A-Za-z0-9] becomes "-" ("/Users/x/.ssh" → "-Users-x--ssh").
    static func encodeProjectFolder(_ path: String) -> String {
        String(String.UnicodeScalarView(path.utf16.map { unit -> Unicode.Scalar in
            let isAlnum = (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
            return isAlnum ? Unicode.Scalar(UInt8(unit)) : "-"
        }))
    }

    /// Recent Claude Code versions cap folder names at 200 characters and
    /// append a hash; compare the prefix in that case.
    static func projectFolder(_ folder: String, matches path: String) -> Bool {
        let encoded = encodeProjectFolder(path)
        if encoded == folder { return true }
        let cap = 200
        return encoded.count > cap && folder.count > cap && folder.hasPrefix(String(encoded.prefix(cap)))
    }

    /// The directory a session was started in — the only place
    /// `claude --resume <id>` finds it. A record's own `cwd` is wherever the
    /// agent had `cd`-ed to, which made resumes fail with "No conversation
    /// found" whenever the agent was in a subdirectory.
    ///
    /// 1. `hintCwd` or the nearest ancestor whose encoding equals the
    ///    transcript's project folder.
    /// 2. The first record's `cwd`, when its encoding matches.
    /// Each candidate must exist. Returns nil when nothing verifies; never
    /// reverses the lossy folder encoding (dashes are ambiguous).
    static func launchDirectory(
        projectFolder folder: String,
        hintCwd: String?,
        firstRecordCwd: String?,
        isDirectory: (String) -> Bool = TranscriptParser.directoryExists
    ) -> String? {
        if let hint = hintCwd, hint.hasPrefix("/") {
            var path = (hint as NSString).standardizingPath
            while true {
                if projectFolder(folder, matches: path) && isDirectory(path) { return path }
                if path == "/" || path.isEmpty { break }
                path = (path as NSString).deletingLastPathComponent
            }
        }
        if let first = firstRecordCwd, projectFolder(folder, matches: first), isDirectory(first) {
            return first
        }
        return nil
    }

    /// Convenience over the pure overload: reads the first record's cwd.
    static func launchDirectory(transcriptPath: String, hintCwd: String?) -> String? {
        let folder = URL(fileURLWithPath: transcriptPath).deletingLastPathComponent().lastPathComponent
        if let hit = launchDirectory(projectFolder: folder, hintCwd: hintCwd, firstRecordCwd: nil) {
            return hit
        }
        return launchDirectory(projectFolder: folder, hintCwd: nil,
                               firstRecordCwd: firstRecordCwd(transcriptPath: transcriptPath))
    }

    static func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// `cwd` of the first transcript record that has one. The first lines are
    /// often summaries / file-history snapshots without a cwd, so this scans
    /// forward (bounded to the first 4 MB).
    static func firstRecordCwd(transcriptPath: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }
        let marker = Data(#""cwd":""#.utf8)
        var buffer = Data()
        var consumed = 0
        let limit = 4 << 20
        while consumed < limit {
            guard let chunk = try? handle.read(upToCount: 256 << 10), !chunk.isEmpty else { break }
            consumed += chunk.count
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard line.range(of: marker) != nil,
                      let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
                return cwd
            }
        }
        return nil
    }

    /// `~/.claude/projects/-Users-foo-bar/` → `/Users/foo/bar`. Lossy (any
    /// "-" might have been "/", "." or "-"); display fallback only.
    static func decodeProjectPath(from encoded: String) -> String {
        var s = encoded
        if s.hasPrefix("-") { s.removeFirst() }
        return "/" + s.replacingOccurrences(of: "-", with: "/")
    }
}

/// Incremental rate-limit index over the transcript tree.
///
/// The old scan did `Data(contentsOf:)` + `String` + `split` on every
/// transcript touched in the last 6h, twice per 15s tick — ~450 MB of UTF-8
/// decoding per tick on a busy Mac, in an app whose job is saving power.
/// This keeps, per file, the inode and the byte offset just past the last
/// complete line, and on each scan reads only the appended bytes:
/// - inode changed or file shrank → rescan from 0 (rotation / truncation);
/// - a half-written trailing line stays unread until its "\n" arrives;
/// - lines are filtered on raw bytes (memmem) before any JSON decoding.
/// One directory walk per scan; `subagents/` trees are never descended.
final class RateLimitTranscriptIndex {
    static let shared = RateLimitTranscriptIndex()

    struct ScanResult {
        /// Events from the lookback window plus older ones still in effect.
        let events: [RateLimitEvent]
        /// transcript path → timestamp of its newest successful (real,
        /// non-error, main-thread) assistant reply. A reply newer than a
        /// limit event means that limit is over, whatever its reset said.
        let lastSuccessfulReply: [String: Date]
    }

    private struct Entry {
        var device: UInt64
        var inode: UInt64
        var offset: UInt64
        var events: [RateLimitEvent] = []
        var lastSuccess: Date?
        /// Read lazily, once per file, the first time a limit is found.
        var firstRecordCwd: String??
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let defaultTimeZone: TimeZone
    /// Read granularity; bounds memory on the first pass over a large file.
    var chunkSize = 8 << 20

    init(defaultTimeZone: TimeZone = .current) {
        self.defaultTimeZone = defaultTimeZone
    }

    private static let rateMarkers = [Data(#""rate_limit""#.utf8), Data(#""apiErrorStatus":429"#.utf8)]
    private static let assistantMarker = Data(#""type":"assistant""#.utf8)
    private static let apiErrorMarker = Data(#""isApiErrorMessage":true"#.utf8)

    func scan(directory: String, lookbackHours: Double, now: Date = Date()) -> ScanResult {
        lock.lock()
        defer { lock.unlock() }

        let base = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath).standardizedFileURL
        let basePrefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        let cutoff = now.addingTimeInterval(-lookbackHours * 3600)
        var visited = Set<String>()

        for path in transcriptPaths(under: base) {
            var st = stat()
            guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            if mtime < cutoff {
                // Untouched for the whole window: nothing new to read. Keep
                // what we know only while one of its limits is still running
                // (a weekly wall can outlive the 6h window).
                if let e = entries[path], e.events.contains(where: { $0.resetTime > now }) {
                    visited.insert(path)
                }
                continue
            }
            visited.insert(path)
            update(path: path, stat: st, cutoff: cutoff, now: now)
        }

        // Forget files that vanished or aged out (only under this directory,
        // so callers scanning different roots don't evict each other).
        for key in entries.keys where key.hasPrefix(basePrefix) && !visited.contains(key) {
            entries.removeValue(forKey: key)
        }

        var events: [RateLimitEvent] = []
        var lastSuccess: [String: Date] = [:]
        for path in visited {
            guard var e = entries[path] else { continue }
            e.events.removeAll { $0.eventTime < cutoff && $0.resetTime <= now }
            entries[path] = e
            events.append(contentsOf: e.events)
            if let s = e.lastSuccess { lastSuccess[path] = s }
        }
        events.sort { $0.eventTime < $1.eventTime }
        return ScanResult(events: events, lastSuccessfulReply: lastSuccess)
    }

    /// Main-session transcripts: `*.jsonl` directly under `base` or one
    /// folder down (`<project>/<session>.jsonl`). Session sub-folders
    /// (`subagents/`, `tool-results/`) are never descended.
    private func transcriptPaths(under base: URL) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var out: [String] = []
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if enumerator.level >= 2 || url.lastPathComponent == "subagents" { enumerator.skipDescendants() }
                continue
            }
            if url.pathExtension == "jsonl" { out.append(url.standardizedFileURL.path) }
        }
        return out
    }

    private func update(path: String, stat st: stat, cutoff: Date, now: Date) {
        let device = UInt64(bitPattern: Int64(st.st_dev))
        let inode = UInt64(st.st_ino)
        let size = UInt64(max(0, st.st_size))
        var entry = entries[path] ?? Entry(device: device, inode: inode, offset: 0)
        if entry.device != device || entry.inode != inode || size < entry.offset {
            entry = Entry(device: device, inode: inode, offset: 0)
        }
        guard size > entry.offset, let handle = FileHandle(forReadingAtPath: path) else {
            entries[path] = entry
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: entry.offset)
        } catch {
            entries[path] = entry
            return
        }

        var remaining = size - entry.offset
        var pending = Data()
        while remaining > 0 {
            let want = Int(min(UInt64(chunkSize), remaining))
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { break }
            remaining -= UInt64(chunk.count)
            pending.append(chunk)
            // Only complete lines; the tail waits for the next chunk / scan.
            guard let lastNewline = pending.lastIndex(of: 0x0A) else { continue }
            let complete = pending[pending.startIndex...lastNewline]
            process(lines: complete, path: path, cutoff: cutoff, now: now, entry: &entry)
            entry.offset += UInt64(complete.count)
            pending = Data(pending[pending.index(after: lastNewline)...])
        }
        entries[path] = entry
    }

    private func process(lines: Data, path: String, cutoff: Date, now: Date, entry: inout Entry) {
        var limitLines: [Data] = []
        var successCandidates: [Data] = []
        lines.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var start = 0
            while start < count {
                let nlPtr = memchr(base + start, 0x0A, count - start)
                let end = nlPtr.map { base.distance(to: UnsafeRawPointer($0)) } ?? count
                let len = end - start
                if len > 0 {
                    let linePtr = base + start
                    if Self.rateMarkers.contains(where: { Self.contains($0, in: linePtr, length: len) }) {
                        limitLines.append(Data(bytes: linePtr, count: len))
                    } else if Self.contains(Self.assistantMarker, in: linePtr, length: len),
                              !Self.contains(Self.apiErrorMarker, in: linePtr, length: len) {
                        // Only the newest few can matter; keep it bounded.
                        successCandidates.append(Data(bytes: linePtr, count: len))
                        if successCandidates.count > 8 { successCandidates.removeFirst() }
                    }
                }
                start = end + 1
            }
        }

        for line in limitLines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let record = TranscriptParser.classifyRateLimitRecord(
                obj,
                transcriptPath: path,
                defaultTimeZone: defaultTimeZone,
                launchDirectory: { hint in self.launchDirectory(path: path, hintCwd: hint, entry: &entry) }
            )
            switch record {
            case .event(let event):
                if event.eventTime >= cutoff || event.resetTime > now { entry.events.append(event) }
            case .transient(let text):
                Logger.shared.log("Ignoring transient 429 in \(URL(fileURLWithPath: path).lastPathComponent) (no usage-limit reset): \(text.prefix(120))")
            case .ignored:
                break
            }
        }

        // Newest verified successful reply in this batch.
        for line in successCandidates.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  Self.isSuccessfulReply(obj),
                  let ts = TranscriptParser.parseTimestamp(obj["timestamp"] as? String) else { continue }
            if entry.lastSuccess.map({ ts > $0 }) ?? true { entry.lastSuccess = ts }
            break
        }
    }

    private func launchDirectory(path: String, hintCwd: String?, entry: inout Entry) -> String? {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        if let hit = TranscriptParser.launchDirectory(projectFolder: folder, hintCwd: hintCwd, firstRecordCwd: nil) {
            return hit
        }
        if entry.firstRecordCwd == nil {
            entry.firstRecordCwd = .some(TranscriptParser.firstRecordCwd(transcriptPath: path))
        }
        return TranscriptParser.launchDirectory(projectFolder: folder, hintCwd: nil,
                                                firstRecordCwd: entry.firstRecordCwd ?? nil)
    }

    /// A real model reply on the main thread: proves the API is answering
    /// again. Synthetic (locally generated) and error messages don't count.
    static func isSuccessfulReply(_ obj: [String: Any]) -> Bool {
        guard obj["type"] as? String == "assistant" else { return false }
        if obj["isSidechain"] as? Bool == true || obj["agentId"] != nil { return false }
        if obj["error"] != nil || obj["isApiErrorMessage"] as? Bool == true || obj["apiErrorStatus"] != nil { return false }
        if let model = (obj["message"] as? [String: Any])?["model"] as? String, model == "<synthetic>" { return false }
        return true
    }

    private static func contains(_ needle: Data, in haystack: UnsafeRawPointer, length: Int) -> Bool {
        needle.withUnsafeBytes { n in
            guard let np = n.baseAddress else { return false }
            return memmem(haystack, length, np, n.count) != nil
        }
    }
}
