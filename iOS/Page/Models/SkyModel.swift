import Foundation

// Sky and Lanes: the fleet as constellations, and the same fleet as an
// accessible list. Every session is a star; every project folder is a
// constellation. Layout and hue come from a stable hash of the folder (never
// Swift's per-launch `hashValue`), so a project always looks and sits the
// same. Pure and Foundation-only.

// MARK: - Stable hashing

enum StableHash {
    /// FNV-1a over the UTF-8 bytes. The same on every launch and every device.
    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    /// A repeatable number in 0..<1 for a key and a salt.
    static func unit(_ s: String, salt: Int = 0) -> Double {
        let h = fnv1a("\(salt)|\(s)")
        return Double(h % 1_000_003) / 1_000_003.0
    }
}

/// A project's own colour. Amber is not one of them: amber means "needs you".
enum ProjectHue: Int, CaseIterable, Equatable {
    case teal, sky, lime, violet, rose, white

    init(key: String) { self = ProjectHue.allCases[Int(StableHash.fnv1a(key) % UInt64(ProjectHue.allCases.count))] }

    /// 0xRRGGBB for the views.
    var hex: UInt32 {
        switch self {
        case .teal: return 0x5EEAD4
        case .sky: return 0x38BDF8
        case .lime: return 0xBEF264
        case .violet: return 0xA78BFA
        case .rose: return 0xF9A8D4
        case .white: return 0xE5E7EB
        }
    }
}

// MARK: - Stars

/// Why a star looks the way it does. Every attribute is a real signal.
enum StarState: String, Equatable, CaseIterable {
    /// Teal, working.
    case working
    /// Amber, waiting for you.
    case needsYou
    /// A dashed amber orbit: stuck.
    case stuck
    /// A hollow star: rate-limited.
    case rateLimited
    /// Grey and dimmed: paused at the battery cutoff.
    case paused
    /// Dim white: idle.
    case idle
    /// Not answering.
    case offline

    /// Most urgent first, for ordering groups and rows.
    var urgency: Int {
        switch self {
        case .needsYou: return 0
        case .stuck: return 1
        case .rateLimited: return 2
        case .working: return 3
        case .paused: return 4
        case .idle: return 5
        case .offline: return 6
        }
    }

    /// "WORKING", "NEEDS YOU": as drawn on a lane.
    var label: String {
        switch self {
        case .working: return "WORKING"
        case .needsYou: return "NEEDS YOU"
        case .stuck: return "LOOKS STUCK"
        case .rateLimited: return "RATE LIMITED"
        case .paused: return "PAUSED"
        case .idle: return "IDLE"
        case .offline: return "OFFLINE"
        }
    }

    init(session: LiveSession, stuck: Bool, paused: Bool) {
        if stuck { self = .stuck; return }
        switch session.state {
        case .waitingOnUser, .waitingOnApproval: self = .needsYou
        case .active: self = paused ? .paused : .working
        case .rateLimited: self = .rateLimited
        case .idle: self = .idle
        case .interrupted, .failed, .offline, .unknown: self = session.state == .offline ? .offline : .idle
        }
    }
}

struct SkyStar: Equatable, Identifiable {
    let id: String
    let title: String
    let state: StarState
    /// Where it sits in the sky: 0...1 across, 0...1 down.
    let x: Double
    let y: Double
    /// 0.35...1: how recently it did something. Stillness is the signal.
    let brightness: Double
    /// What it is doing now, clipped: "swift test", "rm -rf …".
    let lastAction: String
    /// The open page behind a waiting star.
    let interventionId: String?
    let agent: String
    let canType: Bool
    /// Seed for the star's own shape.
    let seed: UInt64
}

struct Constellation: Equatable, Identifiable {
    /// The folder (cwd), which is also the stable-hash key.
    let key: String
    /// "page", "bottle-flip".
    let name: String
    let hue: ProjectHue
    let stars: [SkyStar]
    /// Index pairs: stars in the same repository are joined by faint lines.
    let links: [[Int]]
    var id: String { key }
    /// Where the name label sits.
    let labelX: Double
    let labelY: Double

    /// The most urgent state any star here is in.
    var urgentState: StarState { stars.map(\.state).min { $0.urgency < $1.urgency } ?? .idle }
}

// MARK: - The moon (the Mac)

struct MoonModel: Equatable {
    /// "41%", or "—" when the Mac doesn't report one.
    let percent: String
    /// "on battery · cutoff in about 1 h 50 min", "on power".
    let detail: String
    /// 0...1, nil when unknown.
    let fraction: Double?
    let onAC: Bool

    static func build(status: MacStatusSnapshot?) -> MoonModel {
        let pct = status?.batteryPercent
        let onAC = status?.onAC == true
        var detail: String
        if status == nil { detail = "no reading from your Mac" }
        else if onAC { detail = "on power" }
        else if let f = status?.forecast, f.minutes > 0 { detail = "on battery · cutoff in about \(MacBatteryForecast.duration(f.minutes))" }
        else if status?.onAC == false { detail = "on battery" }
        else { detail = "power unknown" }
        if let f = status?.forecast, !onAC, f.minutes == 0 { detail = "on battery · at the \(f.cutoff)% cutoff" }
        return MoonModel(percent: pct.map { "\($0)%" } ?? "—", detail: detail, fraction: pct.map { Double($0) / 100 }, onAC: onAC)
    }
}

// MARK: - Sky

struct SkyModel: Equatable {
    var constellations: [Constellation]
    /// "7 sessions · 3 projects".
    var headline: String
    var moon: MoonModel
    var rings: [RingStat]
    var macName: String
    var paused: Bool

    var starCount: Int { constellations.reduce(0) { $0 + $1.stars.count } }
    var isEmpty: Bool { constellations.isEmpty }

    /// Past this many minutes of silence a star is as dim as it gets.
    static let dimAfter: TimeInterval = 10 * 60
    static let brightFor: TimeInterval = 30

    /// How bright a star is: full for 30 s after it last did something, then
    /// easing to 0.35 over ten minutes. Idle and unknown activity sit at the floor. Pure.
    static func brightness(lastActivityAt: Date?, state: StarState, now: Date) -> Double {
        guard let at = lastActivityAt else { return state == .needsYou ? 1 : 0.35 }
        let age = max(0, now.timeIntervalSince(at))
        if age <= brightFor { return 1 }
        let t = min(1, (age - brightFor) / (dimAfter - brightFor))
        let floor = state == .needsYou || state == .stuck ? 0.8 : 0.35
        return max(floor, 1 - t * 0.65)
    }

    /// The project's name: the folder's last component.
    static func projectName(cwd: String, fallback: String) -> String {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        if let last = trimmed.split(separator: "/").last, last != "~" { return String(last) }
        return fallback
    }

    /// The fleet as constellations. `interventions` are the open pages
    /// (a stuck page makes its session's star stuck); `paused` is the battery
    /// pause. Pure.
    static func build(sessions: [LiveSession], interventions: [Intervention], status: MacStatusSnapshot?,
                      rings: [RingStat], macName: String, paused: Bool, now: Date) -> SkyModel {
        let stuckSessions = Set(interventions.filter { $0.kind == .idle && PageSubtype.isStuck($0.subtype) }.map(\.sessionId))
        var groups: [String: [LiveSession]] = [:]
        for s in sessions { groups[s.cwd.isEmpty ? s.title : s.cwd, default: []].append(s) }
        let keys = groups.keys.sorted { a, b in
            let na = projectName(cwd: a, fallback: a).lowercased(), nb = projectName(cwd: b, fallback: b).lowercased()
            return na == nb ? a < b : na < nb
        }
        let rows = max(1, (keys.count + 1) / 2)
        var out: [Constellation] = []
        for (i, key) in keys.enumerated() {
            let list = (groups[key] ?? []).sorted { $0.id < $1.id }
            let col = i % 2, row = i / 2
            // A cell of the sky, with a repeatable nudge, so two projects never stack.
            let cellW = 0.5, cellH = 0.9 / Double(rows)
            let ax = (Double(col) + 0.5) * cellW + (StableHash.unit(key, salt: 1) - 0.5) * 0.14
            let ay = 0.06 + (Double(row) + 0.5) * cellH + (StableHash.unit(key, salt: 2) - 0.5) * cellH * 0.28
            var stars: [SkyStar] = []
            var angle = StableHash.unit(key, salt: 3) * 2 * Double.pi
            for (k, s) in list.enumerated() {
                let state = StarState(session: s, stuck: stuckSessions.contains(s.id), paused: paused)
                let radius = k == 0 ? 0 : 0.09 + 0.07 * StableHash.unit(s.id, salt: 4)
                angle += 1.9 + StableHash.unit(s.id, salt: 5)
                let x = min(0.9, max(0.1, ax + cos(angle) * radius * (k == 0 ? 0 : 1.0)))
                let y = min(0.94, max(0.05, ay + sin(angle) * radius * 1.3))
                stars.append(SkyStar(
                    id: s.id, title: s.title, state: state, x: x, y: y,
                    brightness: brightness(lastActivityAt: s.lastActivityAt, state: state, now: now),
                    lastAction: clip(s.preview, 28), interventionId: s.openPageId, agent: s.backend.displayName,
                    canType: s.canType, seed: StableHash.fnv1a(s.cwd.isEmpty ? s.id : s.cwd + "|" + s.id)))
            }
            let links = stars.count > 1 ? (1..<stars.count).map { [$0 - 1, $0] } : []
            let name = projectName(cwd: key, fallback: key)
            let first = stars.first
            out.append(Constellation(key: key, name: name, hue: ProjectHue(key: key), stars: stars, links: links,
                                     labelX: max(0.12, min(0.88, (first?.x ?? ax) - 0.04)), labelY: max(0.03, (stars.map(\.y).min() ?? ay) - 0.07)))
        }
        let n = sessions.count
        let headline = n == 0 ? "No live sessions"
            : "\(n) session\(n == 1 ? "" : "s") · \(out.count) project\(out.count == 1 ? "" : "s")"
        return SkyModel(constellations: out, headline: headline, moon: MoonModel.build(status: status), rings: rings,
                        macName: macName, paused: paused)
    }

    static func clip(_ s: String, _ limit: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return t.count <= limit ? t : String(t.prefix(limit - 1)) + "…"
    }
}

// MARK: - Lanes

struct LaneRow: Equatable, Identifiable {
    let id: String
    let title: String
    let state: StarState
    let strip: [StripCell]
    let interventionId: String?
    let agent: String
    let seed: UInt64
    let lastAction: String
}

struct LaneGroup: Equatable, Identifiable {
    let key: String
    let name: String
    let hue: ProjectHue
    let rows: [LaneRow]
    var id: String { key }
    var urgentState: StarState { rows.map(\.state).min { $0.urgency < $1.urgency } ?? .idle }
}

struct LanesModel: Equatable {
    var groups: [LaneGroup]
    /// "-4h", "-3h", "-2h", "-1h", "now".
    var axis: [String]
    /// The strip is drawn from what this phone saw: say so, once.
    var coverageNote: String?

    /// Groups ordered needs-you first, then working, then idle; rows the same
    /// way inside a group, then by title. Pure.
    static func build(sky: SkyModel, log: ActivityLog, now: Date, hours: Int = 4) -> LanesModel {
        var groups: [LaneGroup] = []
        for c in sky.constellations {
            var rows: [LaneRow] = []
            for s in c.stars {
                let strip = log.strip(for: s.id, now: now, hours: hours, current: s.state)
                rows.append(LaneRow(id: s.id, title: s.title, state: s.state, strip: strip, interventionId: s.interventionId,
                                    agent: s.agent, seed: s.seed, lastAction: s.lastAction))
            }
            rows.sort(by: laneOrder)
            groups.append(LaneGroup(key: c.key, name: c.name, hue: c.hue, rows: rows))
        }
        groups.sort(by: groupOrder)
        let axis = (0..<hours).map { "-\(hours - $0)h" } + ["now"]
        let observed = log.observedSpan(now: now, hours: hours)
        let note: String? = observed >= Double(hours) * 3600 * 0.95 ? nil
            : "Drawn from what this iPhone has seen while Page was open. Earlier time is left blank."
        return LanesModel(groups: groups, axis: axis, coverageNote: note)
    }

    private static func laneOrder(_ a: LaneRow, _ b: LaneRow) -> Bool {
        if a.state.urgency != b.state.urgency { return a.state.urgency < b.state.urgency }
        return a.title.lowercased() < b.title.lowercased()
    }

    private static func groupOrder(_ a: LaneGroup, _ b: LaneGroup) -> Bool {
        if a.urgentState.urgency != b.urgentState.urgency { return a.urgentState.urgency < b.urgentState.urgency }
        return a.name.lowercased() < b.name.lowercased()
    }
}
