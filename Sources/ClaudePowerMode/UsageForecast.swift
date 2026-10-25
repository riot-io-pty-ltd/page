import Foundation

/// Claude subscription usage (the 5-hour and 7-day windows) and when, at
/// the current pace, the 5-hour limit will be hit.
///
/// Claude Code hands these numbers only to the status line command
/// (`rate_limits.five_hour.used_percentage` / `resets_at`), so Page can
/// wrap the user's status line (`UsageCapture`, opt-in from Preferences):
/// the wrapper saves its input for Page, then runs the original command
/// unchanged. Without it there is no quota signal, and Page shows only the
/// rate limits it sees in transcripts.
struct UsageSnapshot: Equatable {
    struct Window: Equatable {
        let pct: Double
        let resetsAt: Date?
    }

    var fiveHour: Window?
    var sevenDay: Window?
    /// When Claude Code last wrote the numbers.
    var updatedAt: Date

    /// Parses the status line input Claude Code sends (only `rate_limits`
    /// is read). nil without any window.
    static func parse(_ data: Data, updatedAt: Date) -> UsageSnapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = obj["rate_limits"] as? [String: Any] else { return nil }
        let s = UsageSnapshot(fiveHour: window(limits["five_hour"]), sevenDay: window(limits["seven_day"]),
                              updatedAt: updatedAt)
        return s.fiveHour == nil && s.sevenDay == nil ? nil : s
    }

    static func window(_ raw: Any?) -> Window? {
        guard let w = raw as? [String: Any],
              let pct = (w["used_percentage"] as? NSNumber)?.doubleValue ?? (w["utilization"] as? NSNumber)?.doubleValue,
              pct.isFinite else { return nil }
        return Window(pct: min(100, max(0, pct)), resetsAt: date(w["resets_at"]))
    }

    /// Epoch seconds, epoch ms, or ISO 8601.
    static func date(_ raw: Any?) -> Date? {
        if let n = (raw as? NSNumber)?.doubleValue, n.isFinite, n > 0 {
            return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        }
        if let s = raw as? String {
            if let n = Double(s) { return date(NSNumber(value: n)) }
            return TranscriptParser.parseISODate(s)
        }
        return nil
    }
}

struct UsageForecast: Equatable {
    struct Sample: Equatable {
        let at: Date
        let pct: Double
    }

    /// Pace is measured over at most the last hour of one 5-hour window.
    static let window: TimeInterval = 3600
    static let minSpan: TimeInterval = 10 * 60
    static let minRise = 2.0
    /// Numbers older than this aren't shown or forecast from.
    static let staleAfter: TimeInterval = 6 * 3600
    /// Page when the limit is this close (and before the reset).
    static let pageWithin: TimeInterval = 30 * 60

    private(set) var samples: [Sample] = []
    private(set) var resetsAt: Date?
    private(set) var latest: UsageSnapshot?

    mutating func observe(_ s: UsageSnapshot) {
        guard s != latest else { return }
        latest = s
        guard let five = s.fiveHour else { samples.removeAll(); return }
        // A new window (or the usage dropping) starts over.
        if five.resetsAt != resetsAt || (samples.last.map { five.pct < $0.pct } ?? false) { samples.removeAll() }
        resetsAt = five.resetsAt
        if samples.last?.at != s.updatedAt { samples.append(Sample(at: s.updatedAt, pct: five.pct)) }
        samples.removeAll { s.updatedAt.timeIntervalSince($0.at) > Self.window }
    }

    /// When the 5-hour window reaches 100% at the current pace, if that's
    /// before it resets. nil when not enough to go on, or it won't.
    func hitAt(now: Date) -> Date? {
        guard let latest, now.timeIntervalSince(latest.updatedAt) < Self.staleAfter,
              let first = samples.first, let last = samples.last,
              last.at.timeIntervalSince(first.at) >= Self.minSpan, last.pct - first.pct >= Self.minRise,
              let slope = Self.slope(samples), slope > 0 else { return nil }
        let hit = last.at.addingTimeInterval((100 - last.pct) / slope)
        if let reset = resetsAt, hit >= reset { return nil }
        return hit
    }

    static func slope(_ s: [Sample]) -> Double? {
        guard s.count >= 2, let t0 = s.first?.at else { return nil }
        let xs = s.map { $0.at.timeIntervalSince(t0) }, ys = s.map(\.pct)
        let n = Double(s.count), mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (x, y) in zip(xs, ys) { num += (x - mx) * (y - my); den += (x - mx) * (x - mx) }
        return den > 0 ? num / den : nil
    }

    /// The heartbeat `usage` object, nil when there's nothing fresh.
    func heartbeatPayload(now: Date) -> [String: Any]? {
        guard let latest, now.timeIntervalSince(latest.updatedAt) < Self.staleAfter else { return nil }
        func w(_ w: UsageSnapshot.Window?) -> [String: Any]? {
            guard let w else { return nil }
            var o: [String: Any] = ["pct": (w.pct * 10).rounded() / 10]
            if let r = w.resetsAt { o["resetsAt"] = Self.iso(r) }
            return o
        }
        var o: [String: Any] = ["updatedAt": Self.iso(latest.updatedAt)]
        if let f = w(latest.fiveHour) { o["fiveHour"] = f }
        if let s = w(latest.sevenDay) { o["sevenDay"] = s }
        if let hit = hitAt(now: now) { o["hitAt"] = Self.iso(hit) }
        return o
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func iso(_ d: Date) -> String { isoFormatter.string(from: d) }

    // MARK: copy

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = Calendar.current.isDateInToday(d) ? .none : .short
        f.timeStyle = .short
        return f.string(from: d)
    }

    /// Menu lines: "Claude usage: 5-hour 62% (resets 5:00 pm) · 7-day 30%"
    /// and, when it applies, "At this pace you'll hit the limit around 4:10 pm".
    func menuLines(now: Date) -> [String] {
        guard let latest, now.timeIntervalSince(latest.updatedAt) < Self.staleAfter else { return [] }
        var parts: [String] = []
        if let f = latest.fiveHour {
            parts.append("5-hour \(Int(f.pct.rounded()))%" + (f.resetsAt.map { " (resets \(Self.time($0)))" } ?? ""))
        }
        if let s = latest.sevenDay { parts.append("7-day \(Int(s.pct.rounded()))%") }
        var lines = ["Claude usage: " + parts.joined(separator: " · ")]
        if let hit = hitAt(now: now) { lines.append("   At this pace you'll hit the limit around \(Self.time(hit))") }
        return lines
    }

    static let pageSessionId = "page-mac-usage"
    static func pageId(hitAt: Date) -> String { "page-mac-usage_forecast-\(Int(hitAt.timeIntervalSince1970) / 600 * 600)" }
    static func isPageId(_ id: String) -> Bool { id.hasPrefix("page-mac-usage_forecast-") }

    static func pageContext(hitAt: Date, pct: Double, resetsAt: Date?, busy: Int) -> String {
        var s = "Claude usage is at \(Int(pct.rounded()))% of the 5-hour limit — at this pace you'll hit it around \(time(hitAt))"
        if let r = resetsAt { s += " (it resets at \(time(r)))" }
        s += "."
        if busy > 0 { s += " \(busy) session\(busy == 1 ? " is" : "s are") working." }
        return s
    }
}

/// Installs / removes the status line wrapper (`UsageCapture`): Claude
/// Code's `statusLine.command` in ~/.claude/settings.json is pointed at
/// Page's script, which saves the input and runs the original command,
/// kept in `originalURL`. Uses HookInstaller's backup + atomic write.
struct UsageCapture {
    let home: URL
    let supportDirectory: URL
    var fileManager: FileManager = .default

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         supportDirectory: URL = Config.configURL.deletingLastPathComponent()) {
        self.home = home
        self.supportDirectory = supportDirectory
    }

    var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    var wrapperURL: URL { supportDirectory.appendingPathComponent("page-statusline.sh") }
    var inputURL: URL { supportDirectory.appendingPathComponent("statusline-input.json") }
    var originalURL: URL { supportDirectory.appendingPathComponent("statusline-original.txt") }
    /// Whether settings.json had a statusLine before Page's (so turning
    /// the option off removes the key instead of leaving an empty command).
    var hadStatusLineURL: URL { supportDirectory.appendingPathComponent("statusline-had-original") }

    var wrapperCommand: String { HookInstaller.shellQuote(wrapperURL.path) }

    static let script = """
    #!/bin/sh
    # Page: saves the usage numbers Claude Code gives the status line
    # (rate_limits), then runs your own status line command unchanged.
    # Installed from Page → Preferences → Rate limits; turning that option
    # off puts your original command back.
    dir="$(cd "$(dirname "$0")" && pwd)"
    input=$(cat)
    (
      umask 077
      tmp="$dir/.statusline-input.$$"
      if printf '%s' "$input" > "$tmp" 2>/dev/null; then mv -f "$tmp" "$dir/statusline-input.json"; else rm -f "$tmp"; fi
    )
    orig="$dir/statusline-original.txt"
    if [ -s "$orig" ]; then
      printf '%s' "$input" | /bin/sh -c "$(cat "$orig")"
    fi

    """

    enum State: Equatable { case off, on, unreadable(String) }

    func state() -> State {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return .off }
        guard let data = try? Data(contentsOf: settingsURL.resolvingSymlinksInPath()),
              let text = String(data: data, encoding: .utf8) else { return .unreadable("Can't read ~/.claude/settings.json") }
        guard let root = try? OrderedJSON.parse(text.isEmpty ? "{}" : text) else { return .unreadable("~/.claude/settings.json isn't valid JSON") }
        return Self.isWrapped(root, wrapper: wrapperURL.path) ? .on : .off
    }

    static func isWrapped(_ root: OrderedJSON, wrapper: String) -> Bool {
        root["statusLine"]?["command"]?.stringValue?.contains(wrapper) == true
    }

    /// Pure: the settings with `statusLine.command` pointed at `command`
    /// (other statusLine keys kept), and the original command, if any.
    static func wrapping(_ root: OrderedJSON, command: String) -> (OrderedJSON, original: String?, hadStatusLine: Bool) {
        guard var members = root.objectMembers else { return (root, nil, false) }
        if let i = members.lastIndex(where: { $0.key == "statusLine" }), var line = members[i].value.objectMembers {
            let original = line.last { $0.key == "command" }?.value.stringValue
            if let j = line.lastIndex(where: { $0.key == "command" }) { line[j].value = .str(command) } else {
                line.append(.init("command", .str(command)))
            }
            if !line.contains(where: { $0.key == "type" }) { line.insert(.init("type", .str("command")), at: 0) }
            members[i].value = .object(line)
            return (.object(members), original, true)
        }
        members.removeAll { $0.key == "statusLine" }
        members.append(.init("statusLine", .object([.init("type", .str("command")), .init("command", .str(command))])))
        return (.object(members), nil, false)
    }

    /// Pure: the settings with Page's wrapper replaced by `original`, or the
    /// statusLine removed when there was none before.
    static func unwrapping(_ root: OrderedJSON, wrapper: String, original: String?, hadStatusLine: Bool) -> OrderedJSON {
        guard isWrapped(root, wrapper: wrapper), var members = root.objectMembers,
              let i = members.lastIndex(where: { $0.key == "statusLine" }), var line = members[i].value.objectMembers else { return root }
        if !hadStatusLine || (original ?? "").isEmpty {
            members.remove(at: i)
            return .object(members)
        }
        if let j = line.lastIndex(where: { $0.key == "command" }) { line[j].value = .str(original!) }
        members[i].value = .object(line)
        return .object(members)
    }

    /// Turns capture on or off. Returns the settings backup, if one was made.
    @discardableResult
    func set(_ on: Bool) throws -> URL? {
        let claudeDir = home.appendingPathComponent(".claude")
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: claudeDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw HookInstallerError.agentNotInstalled(.claude)
        }
        let writeURL = settingsURL.resolvingSymlinksInPath()
        let data = fileManager.fileExists(atPath: writeURL.path) ? try Data(contentsOf: writeURL) : nil
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let root: OrderedJSON
        do { root = try OrderedJSON.parse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : text) } catch {
            throw HookInstallerError.invalidJSON(String(describing: error))
        }
        guard root.objectMembers != nil else { throw HookInstallerError.notAnObject }

        let newRoot: OrderedJSON
        if on {
            guard !Self.isWrapped(root, wrapper: wrapperURL.path) else { return nil }
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let (wrapped, original, had) = Self.wrapping(root, command: wrapperCommand)
            try writeOwnerOnly(Data((original ?? "").utf8), to: originalURL)
            try writeOwnerOnly(Data((had ? "1" : "0").utf8), to: hadStatusLineURL)
            try writeOwnerOnly(Data(Self.script.utf8), to: wrapperURL, permissions: 0o700)
            newRoot = wrapped
        } else {
            let original = (try? String(contentsOf: originalURL, encoding: .utf8))
            let had = (try? String(contentsOf: hadStatusLineURL, encoding: .utf8)) == "1"
            newRoot = Self.unwrapping(root, wrapper: wrapperURL.path, original: original, hadStatusLine: had)
            try? fileManager.removeItem(at: inputURL)
        }
        let indent = HookInstaller.detectIndent(text)
        let body = newRoot.rendered(indent: indent)
        let newText = text.isEmpty || text.hasSuffix("\n") ? body + "\n" : body
        let plan = HookChangePlan(agent: .claude, action: on ? .install : .uninstall, fileURL: settingsURL,
                                  writeURL: writeURL, originalData: data, originalText: text, newText: newText)
        let installer = HookInstaller(homeDirectory: home, scriptPath: wrapperURL.path, fileManager: fileManager)
        return try installer.apply(plan)
    }

    private func writeOwnerOnly(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    /// The latest numbers, or nil (capture off, or nothing written yet).
    func read() -> UsageSnapshot? {
        guard let mtime = (try? fileManager.attributesOfItem(atPath: inputURL.path))?[.modificationDate] as? Date,
              let data = BoundedFileRead.read(inputURL.path, maxBytes: 256 * 1024) else { return nil }
        return UsageSnapshot.parse(data, updatedAt: mtime)
    }
}
