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
            out.append(Constellation(key: key, name: name, hue: ProjectHue(key: key), stars: stars, links: links))
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

// MARK: - Label layout

/// Plain geometry for the layout below (Foundation alone has no rectangle maths off the UI frameworks).
struct SkyPoint: Equatable { var x: Double; var y: Double }
struct SkySize: Equatable { var width: Double; var height: Double }
struct SkyRect: Equatable {
    var x: Double, y: Double, width: Double, height: Double
    var minX: Double { x }
    var minY: Double { y }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
    /// Rectangles that only share an edge do not intersect.
    func intersects(_ o: SkyRect) -> Bool { x < o.maxX && o.x < maxX && y < o.maxY && o.y < maxY }
    func contains(_ o: SkyRect) -> Bool {
        let e = 1e-9
        return o.x >= x - e && o.y >= y - e && o.maxX <= maxX + e && o.maxY <= maxY + e
    }
    func insetBy(dx: Double, dy: Double) -> SkyRect { SkyRect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy) }
}

enum SkyLabelKind: Equatable { case project, caption }

/// A star as an obstacle: where it is and how far its drawing reaches.
struct SkyLabelNode: Equatable {
    let id: String
    let center: SkyPoint
    let radius: Double
}

/// A label to place. `anchors` are the nodes it may sit beside, the preferred one first.
struct SkyLabelRequest: Equatable {
    let id: String
    let kind: SkyLabelKind
    /// As it should read; layout shortens it from the end, with "…", only when it has no room.
    let text: String
    let anchors: [String]
    /// Captions: try the left side of the node first.
    let preferLeft: Bool

    init(id: String, kind: SkyLabelKind, text: String, anchors: [String], preferLeft: Bool = false) {
        self.id = id; self.kind = kind; self.text = text; self.anchors = anchors; self.preferLeft = preferLeft
    }
}

struct SkyLabelPlacement: Equatable {
    let id: String
    let kind: SkyLabelKind
    /// What to draw: the request's text, or its shortened form.
    let text: String
    let rect: SkyRect
}

/// Estimated label boxes. Layout cannot measure text, so the views draw each
/// label in exactly the box it was given (at most `.large` Dynamic Type).
struct SkyLabelMetrics: Equatable {
    var projectCharWidth: Double = 7.8
    var projectPadding: Double = 10
    var projectHeight: Double = 24
    var captionCharWidth: Double = 6.6
    var captionHeight: Double = 14
    /// Between a label and its node.
    var gap: Double = 5
    /// Nothing else comes closer to a label than this.
    var clearance: Double = 3
    var maxProjectWidth: Double = 220
    /// The furthest a project name's nearest edge may sit from one of its own stars, on the grid fallback.
    var reach: Double = 80
    var captionChars = 12

    func size(kind: SkyLabelKind, chars: Int) -> SkySize {
        switch kind {
        case .project: return SkySize(width: Double(chars) * projectCharWidth + projectPadding * 2, height: projectHeight)
        case .caption: return SkySize(width: Double(chars) * captionCharWidth, height: captionHeight)
        }
    }
}

extension SkyModel {
    /// The sky is drawn below `labelTopPad` and over this share of the height; the Tonight card owns the rest.
    static let labelTopPad: Double = 54
    static let labelSkyShare: Double = 0.58
    /// The Tonight card and the capsule's clearance hang from the bottom: labels stay above them.
    static let labelBottomReserve: Double = 214

    /// The lowest a star may be drawn, and the height of the span a star's y runs over, in a sky of this size.
    private static func starSpan(_ size: SkySize) -> (lowest: Double, span: Double) {
        let lowest = max(labelTopPad + 60, size.height - labelBottomReserve - 20)
        return (lowest, min(size.height * labelSkyShare, (lowest - labelTopPad) / 0.94))
    }

    /// Where a star is drawn in a sky of this size, before stars are kept apart. A short sky
    /// squeezes its stars together rather than let them run under the Tonight card. Pure.
    static func starPoint(_ s: SkyStar, in size: SkySize) -> SkyPoint {
        SkyPoint(x: s.x * size.width, y: labelTopPad + s.y * starSpan(size).span)
    }

    /// Where every star is drawn, by id: `starPoint`, then pushed apart until no two drawings
    /// overlap (a short sky squeezes stars together) and kept on the sky. Deterministic. Pure.
    static func starPoints(_ constellations: [Constellation], in size: SkySize) -> [String: SkyPoint] {
        let stars = constellations.flatMap(\.stars)
        var pts = stars.map { starPoint($0, in: size) }
        let radii = stars.map { nodeRadius($0.state) }
        let lowest = starSpan(size).lowest
        func clamp(_ i: Int) {
            pts[i].x = min(max(pts[i].x, 8 + radii[i]), max(8 + radii[i], size.width - 8 - radii[i]))
            pts[i].y = min(max(pts[i].y, labelTopPad), max(labelTopPad, lowest))
        }
        for pass in 0..<24 {
            var moved = false
            for i in stars.indices {
                for j in stars.indices where j > i {
                    var dx = pts[j].x - pts[i].x, dy = pts[j].y - pts[i].y
                    var d = hypot(dx, dy)
                    let need = radii[i] + radii[j]
                    if d >= need - 0.01 { continue }
                    if d < 0.001 {
                        // On top of each other: split along a repeatable direction.
                        let a = Double((i * 7 + j * 3 + pass) % 12) * Double.pi / 6
                        dx = cos(a); dy = sin(a); d = 1
                    }
                    let push = (need - hypot(dx, dy) + 0.5) / 2
                    pts[i].x -= dx / d * push; pts[i].y -= dy / d * push
                    pts[j].x += dx / d * push; pts[j].y += dy / d * push
                    clamp(i); clamp(j)
                    moved = true
                }
            }
            if !moved { break }
        }
        var out: [String: SkyPoint] = [:]
        for (i, s) in stars.enumerated() where out[s.id] == nil { out[s.id] = pts[i] }
        return out
    }

    /// How far a star's drawing reaches: the orbit of a stuck star, the larger glyph of one that needs you.
    static func nodeRadius(_ state: StarState) -> Double {
        switch state {
        case .needsYou: return 22
        case .stuck: return 24
        case .rateLimited: return 14
        default: return 17
        }
    }

    /// Shortens from the end with "…": at a word edge ("-", "_", "/", ".", space) when that keeps
    /// at least half the room, never leaving a space or separator in front of the dots. Pure.
    static func ellipsize(_ s: String, maxChars: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard maxChars > 0 else { return "" }
        if t.count <= maxChars { return t }
        if maxChars == 1 { return "…" }
        let budget = maxChars - 1
        let probe = Array(t.prefix(budget + 1))
        if let edge = probe.lastIndex(where: { " -_/.".contains($0) }), edge > 0, edge >= (budget + 1) / 2 {
            return String(probe[..<edge]).trimmingCharacters(in: .whitespaces) + "…"
        }
        let head = String(probe.prefix(budget)).trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? "…" : head + "…"
    }

    /// Places labels so that none overlaps another, a node, an `avoid` rect, or leaves `canvas`.
    /// Captions (what a star is doing) go first and sit beside their star; project names then
    /// take the nearest free spot around any of their stars: above, below, beside, then a little
    /// further out. A label with no room at full length is shortened from the end; one with no
    /// room at all is left out (the star still says what it is when tapped). Deterministic:
    /// the same input gives the same rects. Pure.
    static func layoutLabels(nodes: [SkyLabelNode], requests: [SkyLabelRequest], canvas: SkyRect, avoid: [SkyRect] = [],
                             metrics m: SkyLabelMetrics = SkyLabelMetrics()) -> [SkyLabelPlacement] {
        guard canvas.width > 0, canvas.height > 0 else { return [] }
        var byId: [String: SkyLabelNode] = [:]
        for n in nodes where byId[n.id] == nil { byId[n.id] = n }
        var blocked = avoid
        for n in nodes { blocked.append(SkyRect(x: n.center.x - n.radius, y: n.center.y - n.radius, width: n.radius * 2, height: n.radius * 2)) }
        var placed: [String: SkyLabelPlacement] = [:]
        let order = requests.filter { $0.kind == .caption } + requests.filter { $0.kind == .project }
        for req in order {
            let anchors = req.anchors.compactMap { byId[$0] }
            if anchors.isEmpty || placed[key(req)] != nil { continue }
            let foreign = nodes.filter { !req.anchors.contains($0.id) }
            let texts = candidateTexts(for: req, among: requests, canvas: canvas, metrics: m)
            for (i, text) in texts.enumerated() {
                let size = m.size(kind: req.kind, chars: text.count)
                // The grid search is the slow one: only the shortest form gets it.
                if let rect = firstFit(req, anchors: anchors, foreign: foreign, size: size, canvas: canvas, blocked: blocked,
                                       metrics: m, grid: i == texts.count - 1) {
                    placed[key(req)] = SkyLabelPlacement(id: req.id, kind: req.kind, text: text, rect: rect)
                    blocked.append(rect)
                    break
                }
            }
        }
        return requests.compactMap { placed[key($0)] }
    }

    private static func key(_ r: SkyLabelRequest) -> String { (r.kind == .project ? "p|" : "c|") + r.id }

    /// The forms of a label to try, full length first, then ever shorter. Each form appears once.
    /// A project name is never cut below 11 characters, and never to a stub that is also the start
    /// of another project's name (`PAYM…`): it keeps its full form or goes without a name.
    private static func candidateTexts(for r: SkyLabelRequest, among requests: [SkyLabelRequest], canvas: SkyRect,
                                       metrics m: SkyLabelMetrics) -> [String] {
        let widest: Int
        let floor: Int
        switch r.kind {
        case .project: widest = Int((min(m.maxProjectWidth, canvas.width) - m.projectPadding * 2) / m.projectCharWidth); floor = 11
        case .caption: widest = m.captionChars; floor = 1
        }
        let whole = ellipsize(r.text, maxChars: max(1, r.text.count))
        var out: [String] = []
        for c in [widest, 18, 14, 11, 8, 5] where c <= widest && c >= floor {
            let text = ellipsize(r.text, maxChars: c)
            if text.isEmpty || out.contains(text) { continue }
            let size = m.size(kind: r.kind, chars: text.count)
            if size.width > canvas.width || size.height > canvas.height { continue }
            if r.kind == .project, text != whole {
                let stem = String(text.dropLast())
                if requests.contains(where: { $0.kind == .project && $0.id != r.id && $0.text.hasPrefix(stem) }) { continue }
            }
            out.append(text)
        }
        return out
    }

    /// How far a point is from a rectangle (0 inside it).
    private static func distance(from p: SkyPoint, to rect: SkyRect) -> Double {
        hypot(max(rect.minX - p.x, 0, p.x - rect.maxX), max(rect.minY - p.y, 0, p.y - rect.maxY))
    }

    private static func firstFit(_ r: SkyLabelRequest, anchors: [SkyLabelNode], foreign: [SkyLabelNode], size: SkySize, canvas: SkyRect,
                                 blocked: [SkyRect], metrics m: SkyLabelMetrics, grid: Bool) -> SkyRect? {
        let pad = m.clearance
        func free(_ rect: SkyRect) -> Bool {
            guard canvas.contains(rect) else { return false }
            guard !blocked.contains(where: { $0.insetBy(dx: -pad, dy: -pad).intersects(rect) }) else { return false }
            // A project's name reads as belonging to the nearest star: never to another project's.
            guard r.kind == .project, !foreign.isEmpty else { return true }
            let own = anchors.map { distance(from: $0.center, to: rect) }.min() ?? .infinity
            return !foreign.contains { distance(from: $0.center, to: rect) < own - 0.5 }
        }
        func inside(_ x: Double, _ y: Double) -> SkyRect {
            SkyRect(x: min(max(x, canvas.minX), canvas.maxX - size.width), y: min(max(y, canvas.minY), canvas.maxY - size.height),
                   width: size.width, height: size.height)
        }
        let w = size.width, h = size.height
        // Closest first; each step out is another try at every position.
        for ring in [Double(0), 10, 24, 42] {
            for a in anchors {
                let c = a.center, d = a.radius + m.gap + ring
                let spots: [SkyRect]
                switch r.kind {
                case .caption:
                    let right = inside(c.x + d, c.y - h / 2), left = inside(c.x - d - w, c.y - h / 2)
                    spots = (r.preferLeft ? [left, right] : [right, left]) + [inside(c.x - w / 2, c.y - d - h), inside(c.x - w / 2, c.y + d)]
                case .project:
                    spots = [inside(c.x - w / 2, c.y - d - h), inside(c.x - w / 2, c.y + d),
                             inside(c.x + d, c.y - h / 2), inside(c.x - d - w, c.y - h / 2),
                             inside(c.x - 8, c.y - d - h), inside(c.x + 8 - w, c.y - d - h),
                             inside(c.x - 8, c.y + d), inside(c.x + 8 - w, c.y + d)]
                }
                if let hit = spots.first(where: free) { return hit }
            }
        }
        // Still nothing: the nearest free spot anywhere within reach of a star, on a coarse grid.
        guard grid else { return nil }
        var best: (distance: Double, rect: SkyRect)?
        var y = canvas.minY
        while y + size.height <= canvas.maxY {
            var x = canvas.minX
            while x + size.width <= canvas.maxX {
                let rect = SkyRect(x: x, y: y, width: size.width, height: size.height)
                let near = anchors.map { distance(from: $0.center, to: rect) }.min() ?? .infinity
                if near <= m.reach, near < (best?.distance ?? .infinity), free(rect) { best = (near, rect) }
                x += 4
            }
            y += 4
        }
        return best?.rect
    }

    /// Every label of a sky of this size: each project's name, and what the stars that need you
    /// (or look stuck) are doing. `labelLayout` is what the views draw. Pure.
    static func labelLayout(_ constellations: [Constellation], in size: SkySize, metrics: SkyLabelMetrics = SkyLabelMetrics()) -> [SkyLabelPlacement] {
        var nodes: [SkyLabelNode] = []
        var requests: [SkyLabelRequest] = []
        let points = starPoints(constellations, in: size)
        // Most urgent first, so the labels that matter keep their place when the sky is full.
        for c in constellations.sorted(by: { $0.urgentState.urgency < $1.urgentState.urgency }) {
            let ordered = c.stars.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
            for s in c.stars {
                nodes.append(SkyLabelNode(id: s.id, center: points[s.id] ?? starPoint(s, in: size), radius: nodeRadius(s.state)))
                if (s.state == .needsYou || s.state == .stuck) && !s.lastAction.isEmpty {
                    requests.append(SkyLabelRequest(id: s.id, kind: .caption, text: s.lastAction, anchors: [s.id], preferLeft: s.x > 0.55))
                }
            }
            requests.append(SkyLabelRequest(id: c.key, kind: .project, text: c.name.uppercased(), anchors: ordered.map(\.id)))
        }
        let bottom = min(labelTopPad + size.height * labelSkyShare + 6, size.height - labelBottomReserve)
        let canvas = SkyRect(x: 8, y: 8, width: max(0, size.width - 16), height: max(0, bottom - 8))
        // The moon (the Mac's battery) sits top right.
        let moon = SkyRect(x: size.width - 64 - 70, y: 34 - 26, width: 140, height: 52)
        return layoutLabels(nodes: nodes, requests: requests, canvas: canvas, avoid: [moon], metrics: metrics)
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
