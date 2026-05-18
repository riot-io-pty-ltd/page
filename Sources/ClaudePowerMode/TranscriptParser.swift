import Foundation

struct RateLimitEvent: Equatable, Hashable {
    let sessionId: String
    let cwd: String
    let projectName: String
    let eventTime: Date
    let resetTime: Date
    let resetTimeText: String
    let transcriptPath: String

    var uniqueId: String { "\(sessionId)-\(Int(eventTime.timeIntervalSince1970))" }
}

enum TranscriptParser {
    /// Walk every `*.jsonl` under `directory` and return each rate-limit event found,
    /// keyed by the event's transcript-line timestamp. Only events from the last
    /// `lookbackHours` are considered; older ones are skipped to keep this cheap.
    static func findRateLimitEvents(directory: String, lookbackHours: Double = 6) -> [RateLimitEvent] {
        let expanded = (directory as NSString).expandingTildeInPath
        let baseURL = URL(fileURLWithPath: expanded)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = Date().addingTimeInterval(-lookbackHours * 3600)
        var results: [RateLimitEvent] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            // Skip files that haven't been touched within the lookback window.
            if let mtime = values?.contentModificationDate, mtime < cutoff { continue }

            results.append(contentsOf: scanFile(fileURL, cutoff: cutoff))
        }
        return results
    }

    private static func scanFile(_ url: URL, cutoff: Date) -> [RateLimitEvent] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var events: [RateLimitEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"rate_limit\"") || line.contains("\"apiErrorStatus\":429") else { continue }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            guard isRateLimitEvent(obj) else { continue }
            // Skip subagent (Task-spawned) rate-limits — resuming the parent on a
            // subagent's failure usually does the wrong thing. We only handle
            // rate-limits that hit the user's main session.
            if obj["isSidechain"] as? Bool == true { continue }
            if obj["agentId"] != nil { continue }
            guard let eventTime = parseTimestamp(obj["timestamp"] as? String) else { continue }
            if eventTime < cutoff { continue }

            let sessionId = obj["sessionId"] as? String ?? url.deletingPathExtension().lastPathComponent
            let cwd = obj["cwd"] as? String ?? decodeProjectPath(from: url.deletingLastPathComponent().lastPathComponent)
            let resetText = extractResetText(from: obj) ?? ""
            guard let resetTime = parseResetTime(from: resetText, referenceTime: eventTime) else { continue }

            events.append(RateLimitEvent(
                sessionId: sessionId,
                cwd: cwd,
                projectName: URL(fileURLWithPath: cwd).lastPathComponent,
                eventTime: eventTime,
                resetTime: resetTime,
                resetTimeText: resetText,
                transcriptPath: url.path
            ))
        }
        return events
    }

    private static func isRateLimitEvent(_ obj: [String: Any]) -> Bool {
        if let err = obj["error"] as? String, err == "rate_limit" { return true }
        if let status = obj["apiErrorStatus"] as? Int, status == 429 { return true }
        return false
    }

    private static func extractResetText(from obj: [String: Any]) -> String? {
        guard let msg = obj["message"] as? [String: Any],
              let contentArr = msg["content"] as? [[String: Any]] else { return nil }
        for item in contentArr {
            if let text = item["text"] as? String { return text }
        }
        return nil
    }

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

    private static func parseTimestamp(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        return isoFormatter.date(from: s) ?? isoFormatterNoFractions.date(from: s)
    }

    /// Parses strings like "resets 7pm (Africa/Johannesburg)" or "resets at 7:30 PM (PT)".
    /// Returns the next Date matching that wall-clock time in that timezone, after `referenceTime`.
    static func parseResetTime(from text: String, referenceTime: Date) -> Date? {
        guard let regex = try? NSRegularExpression(
            pattern: #"reset[s]?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?(?:\s*\(([^)]+)\))?"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }

        func group(_ i: Int) -> String? {
            let r = match.range(at: i)
            guard r.location != NSNotFound else { return nil }
            return nsText.substring(with: r)
        }
        guard let hourStr = group(1), var hour = Int(hourStr) else { return nil }
        let minute = Int(group(2) ?? "0") ?? 0
        let ampm = group(3)?.lowercased()
        let tzName = group(4)

        if ampm == "pm" && hour < 12 { hour += 12 }
        if ampm == "am" && hour == 12 { hour = 0 }
        // If no am/pm and hour <= 12, assume it's the same half-day as referenceTime —
        // but the message comes from Claude Code's CLI which typically uses 12h with am/pm,
        // so we don't need to be clever there.

        let tz = resolveTimezone(tzName) ?? TimeZone.current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz

        var components = calendar.dateComponents([.year, .month, .day], from: referenceTime)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard var candidate = calendar.date(from: components) else { return nil }
        // If the parsed reset moment is already in the past relative to the event, push it +24h.
        if candidate <= referenceTime { candidate = candidate.addingTimeInterval(24 * 3600) }
        return candidate
    }

    private static func resolveTimezone(_ name: String?) -> TimeZone? {
        guard let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return nil }
        if let tz = TimeZone(identifier: n) { return tz }
        if let tz = TimeZone(abbreviation: n) { return tz }
        // Map common short forms
        let aliases: [String: String] = [
            "PT": "America/Los_Angeles", "PST": "America/Los_Angeles", "PDT": "America/Los_Angeles",
            "ET": "America/New_York", "EST": "America/New_York", "EDT": "America/New_York",
            "CT": "America/Chicago", "MT": "America/Denver",
            "BST": "Europe/London", "GMT": "Europe/London",
            "CET": "Europe/Berlin", "CEST": "Europe/Berlin",
            "SAST": "Africa/Johannesburg",
            "JST": "Asia/Tokyo", "IST": "Asia/Kolkata", "AEST": "Australia/Sydney"
        ]
        if let id = aliases[n.uppercased()], let tz = TimeZone(identifier: id) { return tz }
        return nil
    }

    /// `~/.claude/projects/-Users-foo-bar/` → `/Users/foo/bar`
    private static func decodeProjectPath(from encoded: String) -> String {
        // Claude Code prefixes with "-" and replaces "/" → "-".
        // We can't perfectly reverse if directory names contain dashes,
        // but the common case is that an absolute path like "/Users/x/y" becomes "-Users-x-y".
        var s = encoded
        if s.hasPrefix("-") { s.removeFirst() }
        return "/" + s.replacingOccurrences(of: "-", with: "/")
    }
}
