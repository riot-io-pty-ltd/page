import Foundation

// What Page tells its widgets, as one small JSON file.
//
// The app writes it into the app-group container whenever what the widgets
// would show changes; the widget extension (sandboxed, so it cannot reach
// Page's own files, the relay or the Keychain) only ever reads this file. It
// carries no secrets and no raw agent text: the app redacts step and summary
// lines before they get here, and `bounded()` clips everything again so a
// hostile or buggy writer cannot make the file big or the widget wrong.

public enum PageWidgetConstants {
    /// Added to the team id: `RQRMN9LT93.app.page.shared`. macOS accepts a
    /// team-prefixed group for a signed app without a provisioning profile.
    public static let groupSuffix = "app.page.shared"
    /// The Info.plist key build.sh sets (to the team-prefixed group) on both the
    /// app and the extension. Absent in an unsigned or ad-hoc build, where the
    /// widgets are off and nothing touches a group container.
    public static let groupInfoKey = "PageAppGroup"
    public static let snapshotFileName = "widget-snapshot.json"
    public static let extensionBundleID = "local.Page.widgets"
    public static let extensionName = "PageWidgets.appex"
    public static let urlScheme = "page-mac"
    public static let statusKind = "page.mac.status"
    public static let usageKind = "page.mac.usage"

    /// The group this bundle was signed with, or nil when it has none.
    public static func appGroup(bundle: Bundle = .main) -> String? {
        guard let g = bundle.object(forInfoDictionaryKey: groupInfoKey) as? String,
              g.hasSuffix("." + groupSuffix), g.count > groupSuffix.count + 1 else { return nil }
        return g
    }
}

public struct WidgetSnapshot: Codable, Equatable {
    public static let currentVersion = 1

    public enum Mood: String, Codable, Equatable, CaseIterable {
        case needsYou, working, quiet, dusk
    }

    public struct Battery: Codable, Equatable {
        public var percent: Int
        public var onAC: Bool
        public var charging: Bool
        public init(percent: Int, onAC: Bool, charging: Bool) {
            self.percent = percent; self.onAC = onAC; self.charging = charging
        }
    }

    /// A page waiting for the user. `chip` is `ChipKind.rawValue` (irreversible,
    /// considered, undoable, looksStuck, question, forecast, rateLimited, review).
    public struct Decision: Codable, Equatable, Identifiable {
        public var id: String
        public var project: String
        public var chip: String
        public var summary: String
        public init(id: String, project: String, chip: String, summary: String) {
            self.id = id; self.project = project; self.chip = chip; self.summary = summary
        }
    }

    /// A session working right now and the step it is on.
    public struct Flight: Codable, Equatable, Identifiable {
        public var id: String
        public var project: String
        public var doing: String
        public init(id: String, project: String, doing: String) {
            self.id = id; self.project = project; self.doing = doing
        }
    }

    public struct Gauge: Codable, Equatable {
        /// 0...100.
        public var pct: Double
        public var resetsAt: Date?
        public init(pct: Double, resetsAt: Date?) { self.pct = pct; self.resetsAt = resetsAt }
    }

    public struct Usage: Codable, Equatable {
        public var fiveHour: Gauge?
        public var sevenDay: Gauge?
        /// When Claude Code last wrote the numbers.
        public var updatedAt: Date
        public init(fiveHour: Gauge?, sevenDay: Gauge?, updatedAt: Date) {
            self.fiveHour = fiveHour; self.sevenDay = sevenDay; self.updatedAt = updatedAt
        }
    }

    public var version: Int
    public var writtenAt: Date
    /// False in the note Page leaves when it quits: the numbers are the last it knew.
    public var running: Bool
    public var macName: String
    public var mood: Mood
    public var needYou: Int
    public var look: Int
    public var working: Int
    /// "2 agents paused · plug in to resume": the popover's line while paused.
    public var subline: String
    /// The end of the runway, when something will stop the work.
    public var clearUntil: Date?
    public var battery: Battery?
    public var decisions: [Decision]
    public var inFlight: [Flight]
    public var usage: Usage?
    /// "off", "subtle" or "full": the Card glow setting.
    public var cardGlow: String

    public init(version: Int = WidgetSnapshot.currentVersion, writtenAt: Date, running: Bool = true, macName: String,
                mood: Mood, needYou: Int, look: Int = 0, working: Int, subline: String = "", clearUntil: Date? = nil,
                battery: Battery? = nil, decisions: [Decision] = [], inFlight: [Flight] = [], usage: Usage? = nil,
                cardGlow: String = "off") {
        self.version = version; self.writtenAt = writtenAt; self.running = running; self.macName = macName
        self.mood = mood; self.needYou = needYou; self.look = look; self.working = working; self.subline = subline
        self.clearUntil = clearUntil; self.battery = battery; self.decisions = decisions; self.inFlight = inFlight
        self.usage = usage; self.cardGlow = cardGlow
    }

    private enum CodingKeys: String, CodingKey {
        case version, writtenAt, running, macName, mood, needYou, look, working, subline, clearUntil, battery
        case decisions, inFlight, usage, cardGlow
    }

    /// A snapshot missing the later keys (an older Page's file) still decodes, with the same defaults the
    /// initializer gives; only what every version wrote is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        writtenAt = try c.decode(Date.self, forKey: .writtenAt)
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? true
        macName = try c.decode(String.self, forKey: .macName)
        mood = try c.decode(Mood.self, forKey: .mood)
        needYou = try c.decode(Int.self, forKey: .needYou)
        look = try c.decodeIfPresent(Int.self, forKey: .look) ?? 0
        working = try c.decode(Int.self, forKey: .working)
        subline = try c.decodeIfPresent(String.self, forKey: .subline) ?? ""
        clearUntil = try c.decodeIfPresent(Date.self, forKey: .clearUntil)
        battery = try c.decodeIfPresent(Battery.self, forKey: .battery)
        decisions = try c.decodeIfPresent([Decision].self, forKey: .decisions) ?? []
        inFlight = try c.decodeIfPresent([Flight].self, forKey: .inFlight) ?? []
        usage = try c.decodeIfPresent(Usage.self, forKey: .usage)
        cardGlow = try c.decodeIfPresent(String.self, forKey: .cardGlow) ?? "off"
    }

    /// Decisions and looks: what "need you" counts.
    public var attention: Int { needYou + look }

    // MARK: - Bounds

    public enum Limits {
        public static let maxDecisions = 5
        public static let maxInFlight = 5
        public static let maxProject = 40
        public static let maxSummary = 90
        public static let maxDoing = 70
        public static let maxMacName = 40
        public static let maxSubline = 90
        public static let maxId = 120
        public static let maxCount = 999
        /// The encoded file never exceeds this; `WidgetSnapshotCodec.encode` drops rows to fit.
        public static let maxBytes = 16 * 1024
    }

    /// Pure. A line with control characters and runs of whitespace flattened to
    /// single spaces, clipped to `limit` characters with an ellipsis.
    public static func clean(_ text: String, limit: Int) -> String {
        var out = ""
        var lastSpace = true
        for scalar in text.unicodeScalars {
            let isSpace = CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
                || scalar.value == 0x2028 || scalar.value == 0x2029
            if isSpace {
                if !lastSpace { out.unicodeScalars.append(" "); lastSpace = true }
            } else {
                out.unicodeScalars.append(scalar)
                lastSpace = false
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        guard out.count > limit else { return out }
        return String(out.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Pure. This snapshot with every field inside its bounds: clipped text, capped lists, counts and
    /// percentages in range, a known glow level.
    public func bounded() -> WidgetSnapshot {
        var s = self
        func count(_ n: Int) -> Int { min(Limits.maxCount, max(0, n)) }
        func pct(_ v: Double) -> Double { v.isFinite ? min(100, max(0, v)) : 0 }
        s.macName = Self.clean(macName, limit: Limits.maxMacName)
        s.subline = Self.clean(subline, limit: Limits.maxSubline)
        s.needYou = count(needYou); s.look = count(look); s.working = count(working)
        s.decisions = decisions.prefix(Limits.maxDecisions).map {
            Decision(id: Self.clean($0.id, limit: Limits.maxId), project: Self.clean($0.project, limit: Limits.maxProject),
                     chip: Self.clean($0.chip, limit: 20), summary: Self.clean($0.summary, limit: Limits.maxSummary))
        }
        s.inFlight = inFlight.prefix(Limits.maxInFlight).map {
            Flight(id: Self.clean($0.id, limit: Limits.maxId), project: Self.clean($0.project, limit: Limits.maxProject),
                   doing: Self.clean($0.doing, limit: Limits.maxDoing))
        }
        if let b = battery { s.battery = Battery(percent: min(100, max(0, b.percent)), onAC: b.onAC, charging: b.charging) }
        if let u = usage {
            s.usage = Usage(fiveHour: u.fiveHour.map { Gauge(pct: pct($0.pct), resetsAt: $0.resetsAt) },
                            sevenDay: u.sevenDay.map { Gauge(pct: pct($0.pct), resetsAt: $0.resetsAt) },
                            updatedAt: u.updatedAt)
        }
        if !["off", "subtle", "full"].contains(cardGlow) { s.cardGlow = "off" }
        return s
    }

    /// 0, 0.5 or 1: how much Card glow the widget draws.
    public var glowIntensity: Double {
        switch cardGlow {
        case "full": return 1
        case "subtle": return 0.5
        default: return 0
        }
    }

    // MARK: - Freshness

    /// How the widget treats the snapshot's age. The app rewrites the file at
    /// least every `heartbeat`, so older than `staleAfter` means Page is asleep
    /// or gone without saying so.
    public enum Freshness: Equatable {
        case fresh
        case stale(since: Date)
        case notRunning
    }

    public static let heartbeat: TimeInterval = 10 * 60
    /// Longer than a heartbeat plus the widget's own 15-minute timeline refresh plus slack: heartbeat writes
    /// do not reload the widgets, so a widget can be showing a file that is up to that old and still be right.
    public static let staleAfter: TimeInterval = 40 * 60

    /// Pure.
    public func freshness(now: Date) -> Freshness {
        if !running { return .notRunning }
        // A clock set back must not leave a snapshot "fresh" for hours.
        let age = now.timeIntervalSince(writtenAt)
        if age > Self.staleAfter || age < -300 { return .stale(since: writtenAt) }
        return .fresh
    }

    /// When the widget should show the stale note: the moment this snapshot ages out.
    public var staleAt: Date { writtenAt.addingTimeInterval(Self.staleAfter) }

    /// Pure. The bytes that decide whether anything visible changed (so the file is rewritten): the
    /// encoding without the things that drift on their own. The write time is zeroed; "Claude Code last
    /// wrote the numbers" is left out (it moves with the numbers, and the heartbeat carries it); the end of
    /// the runway is rounded to five minutes, because on battery it is re-estimated at every tick and the
    /// widgets show it as HH:mm.
    public func fingerprint() -> Data {
        var s = self
        s.writtenAt = Date(timeIntervalSince1970: 0)
        if var u = s.usage { u.updatedAt = Date(timeIntervalSince1970: 0); s.usage = u }
        if let end = s.clearUntil {
            s.clearUntil = Date(timeIntervalSince1970: (end.timeIntervalSince1970 / 300).rounded() * 300)
        }
        return (try? WidgetSnapshotCodec.encoder().encode(s)) ?? Data()
    }

    /// Pure. The bytes that decide whether WidgetKit is asked to reload at once: what needs the person (the
    /// counts, the mood, which decisions are waiting and how loud), whether Page is running, whether the
    /// Mac is on battery and the glow setting. Everything else (a step's text, the working count, the
    /// battery percentage, usage) is written to the file but waits for the slower reload.
    public func urgentFingerprint() -> Data {
        var s = WidgetSnapshot(version: version, writtenAt: Date(timeIntervalSince1970: 0), running: running,
                               macName: "", mood: mood, needYou: needYou, look: look, working: 0,
                               cardGlow: cardGlow)
        s.decisions = decisions.map { Decision(id: $0.id, project: "", chip: $0.chip, summary: "") }
        s.battery = battery.map { Battery(percent: 0, onAC: $0.onAC, charging: false) }
        return (try? WidgetSnapshotCodec.encoder().encode(s)) ?? Data()
    }
}

// MARK: - Encoding

public enum WidgetSnapshotCodec {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    /// Pure. The bounded snapshot as JSON, at most `maxBytes`: rows are dropped
    /// (in-flight first, then decisions) until it fits.
    public static func encode(_ snapshot: WidgetSnapshot, maxBytes: Int = WidgetSnapshot.Limits.maxBytes) -> Data? {
        var s = snapshot.bounded()
        while true {
            guard let data = try? encoder().encode(s) else { return nil }
            if data.count <= maxBytes { return data }
            if !s.inFlight.isEmpty { s.inFlight.removeLast() }
            else if !s.decisions.isEmpty { s.decisions.removeLast() }
            else { return nil }
        }
    }

    /// Pure. nil for a file that is too big, damaged or from a newer Page than this widget.
    public static func decode(_ data: Data, maxBytes: Int = WidgetSnapshot.Limits.maxBytes * 4) -> WidgetSnapshot? {
        guard !data.isEmpty, data.count <= maxBytes,
              let s = try? decoder().decode(WidgetSnapshot.self, from: data),
              s.version >= 1, s.version <= WidgetSnapshot.currentVersion else { return nil }
        return s.bounded()
    }
}

// MARK: - The file

public enum WidgetSnapshotStore {
    /// The group container, or nil when the bundle has no group (or macOS refuses it).
    public static func containerURL(bundle: Bundle = .main) -> URL? {
        guard let group = PageWidgetConstants.appGroup(bundle: bundle) else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    public static func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(PageWidgetConstants.snapshotFileName)
    }

    /// Reads the snapshot in `directory`; nil when missing or unreadable.
    public static func load(from directory: URL) -> WidgetSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL(in: directory)) else { return nil }
        defer { try? handle.close() }
        let limit = WidgetSnapshot.Limits.maxBytes * 4
        guard let data = try? handle.read(upToCount: limit + 1) else { return nil }
        return WidgetSnapshotCodec.decode(data, maxBytes: limit)
    }

    /// Writes the snapshot atomically (readers see the old file or the new one).
    @discardableResult
    public static func write(_ snapshot: WidgetSnapshot, to directory: URL) -> Bool {
        guard let data = WidgetSnapshotCodec.encode(snapshot) else { return false }
        do {
            try data.write(to: fileURL(in: directory), options: [.atomic])
            return true
        } catch { return false }
    }
}
