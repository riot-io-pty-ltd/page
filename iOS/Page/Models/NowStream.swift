import Foundation

// Two small pieces of the Now stream: the order that never re-sorts under a
// finger, and the In-flight ribbon (one strand per working session).

/// A card is never re-sorted under a finger. While the stream is being
/// touched, scrolled or has a sheet up, the order you can see stays put:
/// rows that have gone drop out, rows already shown keep their place and
/// their latest content, and new arrivals wait behind a "New ↑ 1" pill until
/// you let go. Pure.
enum StableOrder {
    struct Result: Equatable {
        /// What to draw, in order.
        var rows: [NowRow]
        /// Arrivals held back while frozen.
        var queuedNew: Int
    }

    /// `shown` is the ids on screen now (in order); `ranked` is the fresh
    /// ranking. Not frozen: the fresh ranking, nothing queued.
    static func merge(shown: [String], ranked: [NowRow], frozen: Bool) -> Result {
        guard frozen, !shown.isEmpty else { return Result(rows: ranked, queuedNew: 0) }
        let byId = Dictionary(ranked.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let kept = shown.compactMap { byId[$0] }
        let known = Set(shown)
        let fresh = ranked.filter { !known.contains($0.id) }
        return Result(rows: kept, queuedNew: fresh.count)
    }
}

/// One working session as a strand in the ribbon.
struct InFlightStrand: Equatable, Identifiable {
    let id: String
    let project: String
    /// What it is doing, clipped: "vitest · 212 passed".
    let lastAction: String
    /// "4m", how long since it last did something; nil when unknown.
    let age: String?
    let seed: UInt64
    let hue: ProjectHue
    /// A workflow's progress, when the phone has it: 4 of 7.
    let workflow: (done: Int, total: Int)?

    static func == (a: InFlightStrand, b: InFlightStrand) -> Bool {
        a.id == b.id && a.project == b.project && a.lastAction == b.lastAction && a.age == b.age && a.seed == b.seed
            && a.hue == b.hue && a.workflow?.done == b.workflow?.done && a.workflow?.total == b.workflow?.total
    }

    /// Working sessions, the most recently active first. Pure.
    static func build(sessions: [LiveSession], workflows: [String: [WorkflowRun]], now: Date, limit: Int = 12) -> [InFlightStrand] {
        sessions.filter { $0.state == .active }
            .sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
            .prefix(limit)
            .map { s in
                let run = workflows[s.id]?.first { $0.isRunning }
                return InFlightStrand(
                    id: s.id, project: SkyModel.projectName(cwd: s.cwd, fallback: s.title),
                    lastAction: s.preview.isEmpty ? "working" : SkyModel.clip(s.preview, 34),
                    age: s.lastActivityAt.map { RelativeTime.compact(seconds: Int(max(0, now.timeIntervalSince($0)))) },
                    seed: StableHash.fnv1a(s.cwd.isEmpty ? s.id : s.cwd + "|" + s.id),
                    hue: ProjectHue(key: s.cwd.isEmpty ? s.title : s.cwd),
                    workflow: run.map { ($0.done, $0.total) })
            }
    }
}

// MARK: - The day's rings, in words

enum RingSummary {
    /// "Two rings closed ✦", or "Tonight" while none is closed. Pure.
    static func title(_ rings: [RingStat]) -> String {
        switch rings.filter({ $0.progress >= 1 }).count {
        case 1: return "One ring closed ✦"
        case 2: return "Two rings closed ✦"
        case 3...: return "All three rings closed ✦"
        default: return "Tonight"
        }
    }

    /// "Unblocked 12/12 · Shipped 7/10 · Calm not tracked". Pure.
    static func detail(_ rings: [RingStat]) -> String {
        rings.map { "\($0.kind.rawValue) \($0.detail)" }.joined(separator: " · ")
    }
}
