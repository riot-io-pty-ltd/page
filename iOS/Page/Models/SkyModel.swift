import Foundation

// Lanes: the fleet as a list. Every live session is a row with its own star
// glyph; every project folder is a group. Hue and glyph shape come from a
// stable hash of the folder (never Swift's per-launch `hashValue`), so a
// project always looks the same. The model is still built through `SkyModel`
// (the fleet, the Mac's battery and the pause), which `LanesModel` turns into
// groups. Pure and Foundation-only.

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

/// Why a session's star looks the way it does. Every attribute is a real signal.
enum StarState: String, Equatable, CaseIterable {
    /// Teal, working.
    case working
    /// Amber, waiting for you.
    case needsYou
    /// A dashed amber ring: stuck.
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
    var id: String { key }

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

// MARK: - The fleet

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

    /// The project's name: the folder's last component.
    /// A cwd of "/" or the home folder is never shown as a bare slash: it is
    /// the session's name, or "~" (`ProjectLabel`).
    static func projectName(cwd: String, fallback: String) -> String {
        ProjectLabel.name(cwd: cwd, fallback: fallback)
    }

    /// The fleet, grouped by project. `interventions` are the open pages
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
        var out: [Constellation] = []
        for key in keys {
            let list = (groups[key] ?? []).sorted { $0.id < $1.id }
            var stars: [SkyStar] = []
            for s in list {
                let state = StarState(session: s, stuck: stuckSessions.contains(s.id), paused: paused)
                stars.append(SkyStar(
                    id: s.id, title: s.title, state: state,
                    lastAction: clip(s.preview, 28), interventionId: s.openPageId, agent: s.backend.displayName,
                    canType: s.canType, seed: StableHash.fnv1a(s.cwd.isEmpty ? s.id : s.cwd + "|" + s.id)))
            }
            let name = projectName(cwd: key, fallback: key)
            out.append(Constellation(key: key, name: name, hue: ProjectHue(key: key), stars: stars))
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
