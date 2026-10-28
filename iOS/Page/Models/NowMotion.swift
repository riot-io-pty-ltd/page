import Foundation

/// Now's motion as plain maths: the In flight arcs and bars, and the few
/// numbers Now's other parts count and fade with, so a frame at any moment
/// can be computed and tested without running an animation (and the render
/// harness can pin one). Board 07: "Light says what changed. Springs say
/// it's real." Wherever Now shows what the Workflows lens shows, it borrows
/// the lens's numbers (`WorkflowMotion`), so Now and the room move as one
/// system. The Android port has the very same numbers and sample table
/// (model/NowMotion.kt).
///
/// The In flight scene runs on reference-date seconds (the display clock);
/// the harness replays a script on a base of its own. Where the spec gave
/// no number this picks one, named here: a line's breath and glint and a
/// tile's star lag `index · 0.37` rad, as the lens's nodes do; a finished
/// line's pulse follows its close by the lens's `closeDelay`; a closing line
/// folds once its pulse is over, so every ending lasts `grace` (1.95 s).
enum NowMotion {
    typealias WM = WorkflowMotion

    // MARK: In flight: the arc (strip) and the bar (card)

    /// The entrance sweep starts this long after a line first shows, and takes `sweepDuration`.
    static let sweepStart = WM.sweepStart
    static let sweepDuration = WM.sweepDuration
    /// Strip tiles sweep one after another, 0.06 s apart; a card's lines 0.08 s apart.
    static let stripStagger = WM.nodeStagger
    static let lineStagger = 0.08
    /// A change of value: the leading end's glow grows 1 → 1.8 × and fades 0.9 → 0.4 over 0.6 s.
    static let flareDuration = 0.6
    static let flareGrow = 1.8
    static let flareFrom = 0.9
    static let flareTo = 0.4
    /// The glint: a teal-white light 28 % of the track long, at most 0.45, along the filled part every 2.4 s.
    static let glintEvery = WM.rippleEvery
    static let glintSpan = 0.28
    static let glintOpacity = 0.45
    /// A row turning stuck (or back) cross-fades its tint over this long.
    static let tintFade = 0.5

    // MARK: Completion

    /// A closing line folds (height and opacity) once its pulse is over...
    static let collapseAt = WM.closeDelay + WM.pulseDuration
    static let collapse = WM.crossFade
    /// ...and has gone by this: the grace window a just-ended line is kept for.
    static let grace = collapseAt + collapse

    // MARK: Card and strip life

    /// The star breathes with the pulse: 4 s, scale 1 → 1.04, glow 0.3 → 0.55.
    static let starPeriod = PulseModel.baseBreath
    static let starScale = 0.04
    static let starGlowLow = 0.3
    static let starGlowHigh = 0.55
    /// The health dot: green breathes on 4 s, sky (a long-running command) on 6 s...
    static let dotBreath = PulseModel.baseBreath
    static let dotSlowBreath = 6.0
    /// ...and amber sends one slow ring every 3 s, like a waiting item's.
    static let dotRippleEvery = PulseModel.slowestRipple
    static let dotRippleFrom = 3.5
    static let dotRippleTo = 12.0
    static let dotRippleOpacity = 0.7
    /// A new step: the old one slides up 6 pt and fades (0.25 s), the new one rises in (0.35 s, spring).
    static let stepOut = 0.25
    static let stepIn = 0.35
    static let stepRise = 6.0
    /// The earlier steps move down a row with the stream's spring.
    static let streamResponse = ApproachModel.response
    static let streamDamping = ApproachModel.damping
    /// Cards and tiles rise 12 pt as they fade in, on a (0.5, 0.85) spring, 0.05 s apart.
    static let enterRise = 12.0
    static let enterResponse = 0.5
    static let enterDamping = 0.85
    static let enterStagger = 0.05
    static let enterFade = 0.3
    /// A card or tile leaving fades and closes over this long.
    static let leave = 0.3
    /// Springs here are drawn settled after this (exact, so a settled frame is the same every time).
    static let settle = WM.arcSettle

    // MARK: Counting and fading (the Brief's numbers, Settled, the tab badge)

    /// "Numbers count up in under 400 ms."
    static let chipDuration = 0.38
    /// Settled hairlines fade with age: full until 5 min, down to 0.55 at 2 h.
    static let settledFrom = 5.0
    static let settledTo = 120.0
    static let settledFloor = 0.55
    /// A tab badge whose count changes bumps 1 → 1.22 → 1 over 0.5 s (back to rest well inside 0.6 s).
    static let bumpPeak = 1.22
    static let bumpDuration = 0.5

    // MARK: curves

    /// Ease out (cubic), 1 − (1 − x)³. Pure.
    static func easeOutCubic(_ x: Double) -> Double { MotionCurve.easeOut(x) }

    /// The arc's spring from `from` to `to`, `e` seconds after the change. Pure.
    static func spring(_ e: Double, from: Double, to: Double) -> Double {
        guard e < settle else { return to }
        return from + (to - from) * MotionCurve.spring(e, response: WM.arcResponse, damping: WM.arcDamping)
    }

    // MARK: entrance

    /// Where a line's sweep is drawn: a strip tile's ring or a card's bar.
    enum Place: Equatable { case strip, card }

    /// When the sweep of line `i` (tile `i` on the strip) starts after it first showed. Pure.
    static func entranceStart(_ i: Int, place: Place) -> Double {
        sweepStart + Double(max(0, i)) * (place == .strip ? stripStagger : lineStagger)
    }

    /// How far the entrance has swept, 0 ... 1, `t` seconds after the line first showed. Pure.
    static func entrance(_ t: Double, staggerIndex i: Int = 0, place: Place = .strip) -> Double {
        WM.easeInOutCubic((t - entranceStart(i, place: place)) / sweepDuration)
    }

    /// The arc (or the bar) `t` seconds after it first showed: 0 → `fraction`. Pure.
    static func arcEntrance(_ t: Double, fraction: Double, staggerIndex i: Int = 0, place: Place = .strip) -> Double {
        fraction * entrance(t, staggerIndex: i, place: place)
    }

    /// A card or tile `e` seconds into its rise: offset (points down) and opacity. Reduce Motion: it fades in where it lands (0.2 s). Pure.
    static func rise(_ e: Double, reduceMotion: Bool = false) -> Slide {
        if reduceMotion { return Slide(offset: 0, opacity: MotionCurve.easeOut(e / WM.reducedFade)) }
        if e >= settle { return Slide(offset: 0, opacity: 1) }
        return Slide(offset: enterRise * (1 - MotionCurve.spring(e, response: enterResponse, damping: enterDamping)),
                     opacity: MotionCurve.easeOut(e / enterFade))
    }

    // MARK: live

    /// The leading end's flare `e` seconds after the value changed; nil before and after. Pure.
    static func flare(_ e: Double) -> Glow? {
        guard e >= 0, e < flareDuration else { return nil }
        let p = MotionCurve.easeOut(e / flareDuration)
        return Glow(scale: 1 + (flareGrow - 1) * p, opacity: flareFrom + (flareTo - flareFrom) * p)
    }

    /// The glint on line `i` at `t`: how far along the filled part (0 ... 1,
    /// eased in and out) and how bright (0 at either end). Pure.
    static func glint(_ t: Double, index i: Int) -> Glint {
        let c = WM.cycle(t / glintEvery - Double(i) * WM.nodePhase / (2 * Double.pi))
        return Glint(position: WM.easeInOutCubic(c), opacity: glintOpacity * sin(Double.pi * c))
    }

    /// The star's breath at `t` (tile or card `i`): scale and glow. Pure.
    static func star(_ t: Double, index i: Int) -> Breath {
        let b = 0.5 + 0.5 * sin(t * 2 * Double.pi / starPeriod - Double.pi / 2 - Double(i) * WM.nodePhase)
        return Breath(scale: 1 + starScale * b, glow: starGlowLow + (starGlowHigh - starGlowLow) * b)
    }

    /// The health dot at `t`: a breath (0 ... 1) while it works, one amber
    /// ring every 3 s while it is stuck or rate limited. Pure.
    static func dot(_ t: Double, health: FlightHealth) -> Dot {
        switch health {
        case .normal, .longRunning:
            let period = health == .normal ? dotBreath : dotSlowBreath
            return Dot(breath: 0.5 + 0.5 * sin(t * 2 * Double.pi / period - Double.pi / 2), ring: nil)
        case .stuck, .rateLimited:
            let p = WM.cycle(t / dotRippleEvery)
            return Dot(breath: nil, ring: Ring(radius: dotRippleFrom + (dotRippleTo - dotRippleFrom) * MotionCurve.easeOut(p),
                                               opacity: dotRippleOpacity * PulseModel.ringOpacity(p)))
        }
    }

    // MARK: changes

    /// A new step `e` seconds in. Nil once settled. Reduce Motion: a 0.2 s cross-fade, nothing moves. Pure.
    static func step(_ e: Double, reduceMotion: Bool = false) -> StepFrame? {
        guard e >= 0, e < settle else { return nil }
        if reduceMotion {
            let k = MotionCurve.easeOut(e / WM.reducedFade)
            return StepFrame(out: k < 1 ? Slide(offset: 0, opacity: 1 - k) : nil, into: Slide(offset: 0, opacity: k), travel: 0, newest: k, dropped: 1 - k)
        }
        let o = MotionCurve.easeOut(e / stepOut)
        return StepFrame(out: o < 1 ? Slide(offset: -stepRise * o, opacity: 1 - o) : nil,
                         into: Slide(offset: stepRise * (1 - MotionCurve.spring(e, response: stepIn, damping: WM.arcDamping)),
                                     opacity: MotionCurve.easeOut(e / stepIn)),
                         travel: 1 - MotionCurve.spring(e, response: streamResponse, damping: streamDamping),
                         newest: MotionCurve.easeOut(e / stepIn), dropped: 1 - o)
    }

    /// How far a tint change has crossed, `e` seconds in. Pure.
    static func tint(_ e: Double, reduceMotion: Bool = false) -> Double {
        MotionCurve.easeOut(e / (reduceMotion ? WM.reducedFade : tintFade))
    }

    /// A line that ended `e` seconds ago, drawn from `from` (its value when
    /// it ended). Done springs closed, sends one soft pulse and says "✓ done";
    /// failed and stopped turn amber; then it folds away. Reduce Motion: no
    /// ghost, it just fades. Pure.
    static func closing(_ e: Double, status: FlightLineStatus, from: Double, reduceMotion: Bool = false) -> Closing {
        if reduceMotion {
            return Closing(value: from, pulse: nil, amber: 0, check: 0, fold: 1 - MotionCurve.easeOut(e / WM.reducedFade))
        }
        let fold = e < collapseAt ? 1 : 1 - MotionCurve.easeOut((e - collapseAt) / collapse)
        switch status {
        case .done:
            return Closing(value: spring(e, from: from, to: 1), pulse: WM.pulse(e - WM.closeDelay).map { Glow(scale: $0.scale, opacity: $0.opacity) },
                           amber: 0, check: MotionCurve.easeOut(e / WM.crossFade), fold: fold)
        case .failed, .stopped:
            return Closing(value: from, pulse: nil, amber: MotionCurve.easeOut(e / WM.crossFade), check: 0, fold: fold)
        case .running:
            return Closing(value: from, pulse: nil, amber: 0, check: 0, fold: 1)
        }
    }

    // MARK: counting and fading

    /// A Brief count `t` seconds into its count-up: round(total · easeOutCubic(t / 0.38)). Pure.
    static func chipCount(_ t: Double, total: Int) -> Int {
        Int((Double(total) * easeOutCubic(t / chipDuration)).rounded())
    }

    /// A Settled hairline's opacity at its age: 1 until 5 min, falling in a straight line to 0.55 at 2 h, then holding. Pure.
    static func settledOpacity(ageMinutes: Double) -> Double {
        1 - (1 - settledFloor) * MotionCurve.progress(ageMinutes, from: settledFrom, to: settledTo)
    }

    /// A tab badge's scale `t` seconds after its count changed: 1 → 1.22 → 1 over 0.6 s. Pure.
    static func badgeBump(_ t: Double) -> Double {
        guard t > 0, t < bumpDuration else { return 1 }
        return 1 + (bumpPeak - 1) * sin(Double.pi * t / bumpDuration)
    }

    // MARK: values

    struct Slide: Equatable {
        let offset: Double
        let opacity: Double
    }

    struct Glow: Equatable {
        /// Of the radius it grows from.
        let scale: Double
        let opacity: Double
    }

    struct Glint: Equatable {
        let position: Double
        let opacity: Double
    }

    struct Breath: Equatable {
        let scale: Double
        let glow: Double
    }

    struct Ring: Equatable {
        let radius: Double
        let opacity: Double
    }

    struct Dot: Equatable {
        let breath: Double?
        let ring: Ring?
    }

    struct StepFrame: Equatable {
        /// The old step leaving (offset up is negative); nil once it has gone.
        let out: Slide?
        let into: Slide
        /// Rows still to travel (1 → 0): an earlier step that moved from row `j` to row `i` is drawn `(j − i) · travel` rows off its place.
        let travel: Double
        /// An earlier step new to the list fades in.
        let newest: Double
        /// An earlier step that fell off the end fades out.
        let dropped: Double
    }

    struct Closing: Equatable {
        let value: Double
        let pulse: Glow?
        let amber: Double
        /// "✓ done", 0 ... 1.
        let check: Double
        /// 1 → 0 as it folds away (height and opacity).
        let fold: Double
    }

    // MARK: events

    /// Lines that changed from running to done, failed or stopped between two
    /// looks at a card, by key (the run's id, else the name). A line that is
    /// no longer listed has no status, so it is never an event; nor is
    /// anything on a first look (`old` empty). Pure.
    static func flightEvents(_ old: [FlightWorkflowLine], _ new: [FlightWorkflowLine]) -> [FlightWorkflowLine] {
        let was = Dictionary(old.map { ($0.key, $0.status) }, uniquingKeysWith: { a, _ in a })
        return new.filter { $0.status.isEnded && was[$0.key] == .running }
    }

    /// The one polite announcement an ending earns: "page: Review changes
    /// finished", "Docs sweep failed", "Docs sweep stopped". Pure.
    static func announcement(_ line: FlightWorkflowLine, project: String) -> String? {
        switch line.status {
        case .done: return "\(project): \(line.name) finished"
        case .failed: return "\(line.name) failed"
        case .stopped: return "\(line.name) stopped"
        case .running: return nil
        }
    }

    /// A line seen ending, on its row.
    struct FlightEnd: Equatable {
        let rowId: String
        let project: String
        /// As it was last drawn (its words, its value), with how it ended.
        let line: FlightWorkflowLine
        /// Where it stood among the card's running lines.
        let index: Int

        /// Once per run per app process (`OneShotBook`).
        var onceKey: String { "\(rowId)|\(line.key)|\(line.status.rawValue)" }
    }

    /// Now's grace for ended workflow lines: it remembers every working
    /// session's lines (running and ended) as last seen, and when one it saw
    /// running is now done, failed or stopped it keeps that line on its card
    /// for `grace` seconds from when the phone saw it end. Only the strip's
    /// rows (every working session) are compared, so Show fewer and the cap
    /// never end anything; a row that leaves takes its lines with it (its own
    /// exit plays); the first look after launch, a reconnect, a resume or
    /// another Mac plays nothing. Pure: the container holds it and the
    /// harness replays it.
    struct FlightGrace: Equatable {
        /// Each row's lines as last seen; nil until the first look.
        private(set) var last: [String: [FlightWorkflowLine]]?
        private(set) var closing: [String: [FlightClosingLine]] = [:]

        init() {}

        static func lines(_ row: InFlightRow) -> [FlightWorkflowLine] { row.card.workflows + row.card.ended }

        /// A new first look: the next snapshot plays nothing.
        mutating func reset() {
            last = nil
            closing = [:]
        }

        /// The lines that ended between the last look and `section`. Pure.
        func ends(in section: InFlightSection) -> [FlightEnd] {
            guard let last else { return [] }
            var out: [FlightEnd] = []
            for row in section.strip {
                guard let old = last[row.id] else { continue }
                let running = old.filter { $0.status == .running }
                for line in NowMotion.flightEvents(old, Self.lines(row)) {
                    guard let i = running.firstIndex(where: { $0.key == line.key }) else { continue }
                    var shown = running[i]
                    shown.status = line.status
                    out.append(FlightEnd(rowId: row.id, project: row.project, line: shown, index: i))
                }
            }
            return out
        }

        /// The section as it now stands, at `now`: remembers it, keeps each
        /// new ending for the grace window and drops the expired. `silent`
        /// (Now covered, the app not active) only remembers. `once` says
        /// whether an ending may still play (once per run). Returns the new
        /// endings, each once.
        @discardableResult
        mutating func observe(_ section: InFlightSection, at now: Date, silent: Bool = false, once: (FlightEnd) -> Bool = { _ in true }) -> [FlightEnd] {
            let found = silent ? [] : ends(in: section).filter(once)
            let live = Set(section.strip.map(\.id))
            var kept: [String: [FlightClosingLine]] = [:]
            for (id, lines) in closing where live.contains(id) {
                let still = lines.filter { now.timeIntervalSince($0.endedAt) < NowMotion.grace }
                if !still.isEmpty { kept[id] = still }
            }
            for e in found {
                kept[e.rowId, default: []].removeAll { $0.line.key == e.line.key }
                kept[e.rowId, default: []].append(FlightClosingLine(line: e.line, index: e.index, endedAt: now))
            }
            closing = kept
            last = Dictionary(section.strip.map { ($0.id, Self.lines($0)) }, uniquingKeysWith: { a, _ in a })
            return found
        }

        /// `section` with every line still in its grace window back on its
        /// card (and its strip tile). An ending not yet observed shows from
        /// `now`, so the frame that first lacks the line already draws it
        /// closing, if `provisional` says it may play (not while the next
        /// observe will be silent, nor once it has played). Pure.
        func merged(_ section: InFlightSection, now: Date, provisional: (FlightEnd) -> Bool = { _ in true }) -> InFlightSection {
            var shown = closing.mapValues { $0.filter { now.timeIntervalSince($0.endedAt) < NowMotion.grace } }
            for e in ends(in: section) where shown[e.rowId]?.contains(where: { $0.line.key == e.line.key }) != true && provisional(e) {
                shown[e.rowId, default: []].append(FlightClosingLine(line: e.line, index: e.index, endedAt: now))
            }
            guard shown.values.contains(where: { !$0.isEmpty }) else { return section }
            func put(_ row: InFlightRow) -> InFlightRow {
                var r = row
                r.card.closing = shown[row.id] ?? []
                return r
            }
            var s = section
            s.rows = s.rows.map(put)
            s.strip = s.strip.map(put)
            return s
        }

        /// When the next closing line's window is over (the container draws again then).
        var nextExpiry: Date? {
            closing.values.flatMap { $0 }.map { $0.endedAt.addingTimeInterval(NowMotion.grace) }.min()
        }
    }

    // MARK: the scene

    /// Everything the In flight section has seen since it appeared: when
    /// each row and each workflow line first showed, each line's spring to a
    /// new value, each row's new step and tint change, and Show all opening.
    /// Each frame is a pure function of it and the clock; the live section
    /// builds it as changes arrive, the harness by replaying a script. Times
    /// are absolute seconds on the caller's clock. A line is keyed
    /// "rowId|name" (names, never the list's position ids).
    struct FlightScene: Equatable {
        struct Spring: Equatable {
            let from: Double
            let to: Double
            let at: Double
        }

        struct StepChange: Equatable {
            let now: String
            let previous: [String]
            let at: Double
        }

        struct TintChange: Equatable {
            /// Whether it needed attention before.
            let from: Bool
            let at: Double
        }

        struct Seen: Equatable {
            let now: String
            let previous: [String]
            let attention: Bool
        }

        private(set) var rowsShown: [String: Double] = [:]
        private(set) var linesShown: [String: Double] = [:]
        private(set) var fractions: [String: Double] = [:]
        private(set) var springs: [String: Spring] = [:]
        private(set) var steps: [String: StepChange] = [:]
        private(set) var tints: [String: TintChange] = [:]
        private(set) var seen: [String: Seen] = [:]
        /// When Show all last opened: the cards it brings rise in.
        private(set) var expandedAt: Double?
        private(set) var expanded = false

        init() {}

        /// The section appearing at `t`. `shown` maps a key and the moment
        /// it is first seen to when it first showed this app process (the
        /// live section's `OneShotBook`), so a line seen before shows its
        /// value at once.
        init(opening section: InFlightSection, at t: Double, shown: (String, Double) -> Double = { $1 }) {
            observe(section, at: t, shown: shown)
        }

        static func lineKey(_ rowId: String, _ name: String) -> String { "\(rowId)|\(name)" }
        static func rowKey(_ rowId: String) -> String { "row|\(rowId)" }

        /// A card's line names, a repeated name numbered ("Lint", "Lint #2"), in order.
        static func names(_ lines: [FlightWorkflowLine]) -> [String] {
            var count: [String: Int] = [:]
            return lines.map { l in
                count[l.name, default: 0] += 1
                let n = count[l.name] ?? 1
                return n == 1 ? l.name : "\(l.name) #\(n)"
            }
        }

        /// The section as it now stands, `t`.
        mutating func observe(_ section: InFlightSection, at t: Double, shown: (String, Double) -> Double = { $1 }) {
            if section.isExpanded, !expanded, !rowsShown.isEmpty { expandedAt = t }
            expanded = section.isExpanded
            for row in section.strip {
                if rowsShown[row.id] == nil { rowsShown[row.id] = shown(Self.rowKey(row.id), t) }
                let card = row.card
                let now = Seen(now: card.now, previous: card.previous, attention: card.health.needsAttention)
                if let was = seen[row.id] {
                    if was.now != now.now { steps[row.id] = StepChange(now: was.now, previous: was.previous, at: t) }
                    if was.attention != now.attention { tints[row.id] = TintChange(from: was.attention, at: t) }
                }
                seen[row.id] = now
                for (name, line) in zip(Self.names(card.workflows), card.workflows) {
                    let k = Self.lineKey(row.id, name)
                    let f = line.fraction ?? 0
                    guard linesShown[k] != nil, let old = fractions[k] else {
                        if linesShown[k] == nil { linesShown[k] = shown(k, t) }
                        fractions[k] = f
                        continue
                    }
                    if abs(f - old) > 1e-9 {
                        springs[k] = Spring(from: springValue(k, at: t) ?? old, to: f, at: t)
                        fractions[k] = f
                    }
                }
            }
        }

        private func springValue(_ k: String, at t: Double) -> Double? {
            springs[k].map { NowMotion.spring(t - $0.at, from: $0.from, to: $0.to) }
        }

        /// Line `k`'s value at `t`, drawn at `place` as its `index`th: the entrance sweep, then a spring to each new value. Pure.
        func value(_ k: String, fraction: Double, place: Place, index: Int, at t: Double, reduceMotion: Bool) -> Double {
            if reduceMotion { return fraction }
            if let s = springs[k] { return NowMotion.spring(t - s.at, from: s.from, to: s.to) }
            guard let shownAt = linesShown[k] else { return fraction }
            return arcEntrance(t - shownAt, fraction: fraction, staggerIndex: index, place: place)
        }

        /// Line `k`'s flare at `t`. Pure.
        func flare(_ k: String, at t: Double, reduceMotion: Bool) -> Glow? {
            reduceMotion ? nil : springs[k].flatMap { NowMotion.flare(t - $0.at) }
        }

        /// A row's rise as the `index`th card (or tile). `extra`: a card Show all brought in. Pure.
        func rise(_ rowId: String, index: Int, extra: Bool = false, at t: Double, reduceMotion: Bool) -> Slide {
            // Reduce Motion: no stagger; each fades in as it first shows.
            let stagger = reduceMotion ? 0 : enterStagger
            var start = (rowsShown[rowId] ?? -.infinity) + Double(index) * stagger
            if extra, let x = expandedAt { start = max(start, x + Double(max(0, index - InFlightSection.collapsedLimit)) * stagger) }
            return NowMotion.rise(t - start, reduceMotion: reduceMotion)
        }

        /// A row's new step at `t`, while it plays. Pure.
        func step(_ rowId: String, at t: Double, reduceMotion: Bool) -> (change: StepChange, frame: StepFrame)? {
            guard let c = steps[rowId], let f = NowMotion.step(t - c.at, reduceMotion: reduceMotion) else { return nil }
            return (c, f)
        }

        /// How amber a row is at `t`, 0 ... 1 (`attention`: it needs it now). Pure.
        func amber(_ rowId: String, attention: Bool, at t: Double, reduceMotion: Bool) -> Double {
            let to: Double = attention ? 1 : 0
            guard let c = tints[rowId] else { return to }
            let from: Double = c.from ? 1 : 0
            return from + (to - from) * NowMotion.tint(t - c.at, reduceMotion: reduceMotion)
        }

        /// When the last entrance, spring, step or tint change of these rows is over. Pure.
        func settlesAt(rows ids: [String], reduceMotion: Bool) -> Double {
            let set = Set(ids)
            func row(_ key: String) -> String { String(key.split(separator: "|", maxSplits: 1).first ?? "") }
            if reduceMotion {
                var changes: [Double] = steps.filter { set.contains($0.key) }.map(\.value.at)
                changes += tints.filter { set.contains($0.key) }.map(\.value.at)
                // A card or tile fading in as it first shows, or as Show all brings it.
                changes += rowsShown.filter { set.contains($0.key) }.map(\.value) + [expandedAt ?? -.infinity]
                return (changes.max() ?? -.infinity) + WM.reducedFade
            }
            var end = -Double.infinity
            for (id, at) in rowsShown where set.contains(id) { end = max(end, at + Double(ids.count) * enterStagger + settle) }
            for (k, at) in linesShown where set.contains(row(k)) { end = max(end, at + entranceStart(8, place: .card) + sweepDuration) }
            for (k, s) in springs where set.contains(row(k)) { end = max(end, s.at + max(settle, flareDuration)) }
            for (id, c) in steps where set.contains(id) { end = max(end, c.at + settle) }
            for (id, c) in tints where set.contains(id) { end = max(end, c.at + tintFade) }
            if let x = expandedAt { end = max(end, x + Double(ids.count) * enterStagger + settle) }
            return end
        }
    }

    // MARK: a frame

    /// One workflow line at one moment, on a strip tile's ring or a card's bar.
    struct LineFrame: Equatable {
        let value: Double
        /// The head's breath while it works (0 ... 1); nil: a still head.
        let head: Double?
        /// The glint along a card's bar.
        let glint: Glint?
        /// The comet round a tile's ring: its head, radians clockwise from 12.
        let comet: Double?
        let flare: Glow?
        /// A finished line's one soft pulse.
        let pulse: Glow?
        /// How amber, 0 ... 1: a stuck row's tint, or a failed or stopped line's.
        let amber: Double
        /// "✓ done", 0 ... 1.
        let check: Double
        /// 1, folding to 0 as a closing line leaves.
        let fold: Double
    }

    /// Line `line` of row `row` (its `index`th, keyed `key`) at `t`: closing
    /// when `closing` says it ended, else live while the row works normally
    /// (breath, glint, comet) and still while it is stuck. Pure.
    static func line(_ scene: FlightScene, row: InFlightRow, line: FlightWorkflowLine, key: String, closing: FlightClosingLine? = nil,
                     place: Place, index: Int, at t: Double, reduceMotion: Bool) -> LineFrame {
        let amber = scene.amber(row.id, attention: row.card.health.needsAttention, at: t, reduceMotion: reduceMotion)
        if let c = closing {
            let f = NowMotion.closing(t - c.endedAt.timeIntervalSinceReferenceDate, status: c.line.status, from: c.line.fraction ?? 0,
                                      reduceMotion: reduceMotion)
            return LineFrame(value: f.value, head: nil, glint: nil, comet: nil, flare: nil, pulse: f.pulse, amber: max(amber, f.amber),
                             check: f.check, fold: f.fold)
        }
        let k = FlightScene.lineKey(row.id, key)
        let live = !reduceMotion && !row.card.health.needsAttention
        return LineFrame(value: scene.value(k, fraction: line.fraction ?? 0, place: place, index: index, at: t, reduceMotion: reduceMotion),
                         head: live ? WM.breath(t, index: index) : nil,
                         glint: live && place == .card ? glint(t, index: index) : nil,
                         comet: live && place == .strip ? WM.comet(t) : nil,
                         flare: scene.flare(k, at: t, reduceMotion: reduceMotion), pulse: nil, amber: amber, check: 0, fold: 1)
    }

    /// A row (a card, or a strip tile) at one moment.
    struct RowFrame: Equatable {
        let rise: Slide
        /// The star's breath while it works normally; nil: still.
        let star: Breath?
        let dot: Dot
        let amber: Double
    }

    /// Row `row`, the `index`th card or tile, at `t`. Reduce Motion: the final state, still. Pure.
    static func row(_ scene: FlightScene, row: InFlightRow, index: Int, extra: Bool = false, at t: Double, reduceMotion: Bool) -> RowFrame {
        let health = row.card.health
        return RowFrame(rise: scene.rise(row.id, index: index, extra: extra, at: t, reduceMotion: reduceMotion),
                        star: reduceMotion || health.needsAttention ? nil : star(t, index: index),
                        dot: reduceMotion ? Dot(breath: nil, ring: nil) : dot(t, health: health),
                        amber: scene.amber(row.id, attention: health.needsAttention, at: t, reduceMotion: reduceMotion))
    }

    /// Until when these rows need a clock (absolute), drawn at `place`: for
    /// ever while something in them loops, unless Reduce Motion; else until
    /// the last entrance, cross-fade or closing line is over. A card always
    /// loops (its star breathes, or its stuck dot ripples); a strip tile only
    /// while its session works normally (a stuck tile has no dot, and its
    /// star and ring are still). Pure.
    static func animatesUntil(_ scene: FlightScene, rows: [InFlightRow], place: Place = .card, reduceMotion: Bool) -> Double {
        let closing = rows.flatMap(\.card.closing).map { $0.endedAt.timeIntervalSinceReferenceDate + (reduceMotion ? WM.reducedFade : grace) }
        let settles = max(scene.settlesAt(rows: rows.map(\.id), reduceMotion: reduceMotion), closing.max() ?? -.infinity)
        let loops = place == .card ? !rows.isEmpty : rows.contains { !$0.card.health.needsAttention }
        return !reduceMotion && loops ? .infinity : settles
    }

    /// The frame rate these rows need now: 30 while a bar glints, a ring's
    /// comet turns or a one-shot plays; a slow breath reads smoothly at 20.
    static func framesPerSecond(_ scene: FlightScene, rows: [InFlightRow], at t: Double, reduceMotion: Bool) -> Double {
        let lines = rows.contains { !$0.card.health.needsAttention && $0.card.workflows.contains { $0.fraction != nil } }
        let closing = rows.contains { r in r.card.closing.contains { t - $0.endedAt.timeIntervalSinceReferenceDate < grace } }
        return lines || closing || scene.settlesAt(rows: rows.map(\.id), reduceMotion: reduceMotion) > t ? 30 : 20
    }

    // MARK: a script (the render harness, the tests)

    /// The section as it stands from `at` seconds after the script began.
    struct FlightStep {
        let at: Double
        let section: InFlightSection
    }

    struct FlightScript {
        /// The script's 0, as absolute seconds.
        let base: Double
        let steps: [FlightStep]
        /// The first look's lines and cards showed long before (no entrance plays).
        var entered = false
    }

    /// The section, the scene and the grace `t` seconds into `script`, every
    /// step observed at its moment, as the live section and container would. Pure.
    static func replay(_ script: FlightScript, until t: Double) -> (section: InFlightSection, scene: FlightScene, grace: FlightGrace)? {
        guard let first = script.steps.first else { return nil }
        let base = script.base
        let date = { (s: Double) in Date(timeIntervalSinceReferenceDate: base + s) }
        var scene = FlightScene(opening: first.section, at: base + first.at, shown: script.entered ? { _, _ in base - 100 } : { $1 })
        var grace = FlightGrace()
        grace.observe(first.section, at: date(first.at), silent: true)
        var section = first.section
        for s in script.steps.dropFirst() where s.at <= t {
            scene.observe(s.section, at: base + s.at)
            grace.observe(s.section, at: date(s.at))
            section = s.section
        }
        return (grace.merged(section, now: date(t)), scene, grace)
    }

    // MARK: - The rest of Now: the Runway, the Horizon's words, the badges, the chips, Settled

    // Where the spec gave no number this picks one with the Android port,
    // named here: a Runway marker pops as the line reaches it (0.35 s, its
    // fade over the first 0.12 s); a marker reaching now flashes up and
    // down (a sine) with the In flight flare's size; a receipt is news only
    // if it settled in the last two minutes; its ✓ draws once it has landed.

    /// On the Runway's first appearance this app process its line draws left to right (0.6 s, ease out)...
    static let runwayDraw = 0.6
    /// ...and each marker pops in as the line reaches it, at least 0.07 s after the one to its left:
    /// 0.6 → 1 on the lens's ease-out-back (1.2) over 0.35 s, fading in over its first 0.12 s.
    static let markerStagger = 0.07
    static let markerPop = 0.35
    static let markerFade = 0.12
    static let markerFrom = 0.6
    /// A marker that moves glides there (0.8 s, ease in and out). Time's own drift (about 0.08 pt per
    /// 5 s tick) is left where it is until it adds up to this share of the line, about a point.
    static let markerSlide = 0.8
    static let markerSlideMin = 0.003
    /// A marker that reaches now flashes once (0.6 s) and fades out; one that goes for any other reason
    /// (on power, the forecast gone) just fades (`leave`).
    static let markerFlash = flareDuration

    /// A change of a Horizon line's words cross-fades over 0.35 s, the new words rising 4 pt into place.
    static let rewordDuration = WM.crossFade
    static let rewordRise = 4.0

    /// A tab badge appearing scales in from 0.5 on a (0.35, 0.6) spring as it fades in; going, it scales
    /// back to 0.5 and fades. Its number rolls on the same spring.
    static let badgeFrom = 0.5
    static let badgeResponse = 0.35
    static let badgeDamping = 0.6

    /// A Review card's tests ✓ draws over 0.3 s once its numbers have counted up.
    static let checkDraw = 0.3
    static let chipsSettle = chipDuration + checkDraw

    /// A new Settled receipt comes down 6 pt from the top as it fades in and opens its row (0.35 s); then its ✓ draws.
    static let receiptIn = WM.crossFade
    static let receiptDrop = 6.0
    static let receiptSettle = receiptIn + checkDraw
    /// A receipt is news only if it settled this recently (seconds): older lines a reload brings in simply appear.
    static let receiptFresh = 120.0

    /// Queued (the reply waiting at the relay or held on the Mac, and the New pill): arriving it rises
    /// 6 pt as it fades in; going it fades as what is below closes up; a new word cross-fades. 0.3 s each.
    static let queuedFade = 0.3
    static let queuedRise = 6.0

    // MARK: the Runway

    /// How much of the Runway's line has drawn, `e` seconds after it first showed. Pure.
    static func runwayLine(_ e: Double) -> Double { easeOutCubic(e / runwayDraw) }

    /// When the drawing line reaches `fraction` (0: the NOW dot, 1: its end): its ease out, inverted. Pure.
    static func runwayReach(_ fraction: Double) -> Double { runwayDraw * (1 - cbrt(1 - MotionCurve.clamp01(fraction))) }

    /// When each marker starts to pop, by `fractions` in their own order, after the Runway first showed:
    /// as the line reaches it, and at least 0.07 s after the one to its left. Pure.
    static func markerStarts(_ fractions: [Double]) -> [Double] {
        var out = Array(repeating: 0.0, count: fractions.count)
        var last = -Double.infinity
        for i in fractions.indices.sorted(by: { fractions[$0] < fractions[$1] }) {
            out[i] = max(runwayReach(fractions[i]), last + markerStagger)
            last = out[i]
        }
        return out
    }

    /// A marker `e` seconds into its pop: 0.6 → 1 (a little over first), fading in over 0.12 s. Pure.
    static func markerPop(_ e: Double) -> Pop {
        Pop(scale: markerFrom + (1 - markerFrom) * WM.easeOutBack(e / markerPop), opacity: MotionCurve.easeOut(e / markerFade))
    }

    /// A marker gliding from `from` to `to` (shares of the line), `e` seconds in. Pure.
    static func markerGlide(_ e: Double, from: Double, to: Double) -> Double {
        from + (to - from) * WM.easeInOutCubic(e / markerSlide)
    }

    /// A marker that reached now, `e` seconds on: its one flash (0 → 1 → 0, a sine) and what is left of
    /// the tick (1 → 0, smoothly); nil once gone. Pure.
    static func markerPassing(_ e: Double) -> (flash: Double, opacity: Double)? {
        guard e >= 0, e < markerFlash else { return nil }
        let p = e / markerFlash
        return (sin(Double.pi * p), 1 - MotionCurve.smooth(p))
    }

    /// The glow a flash of `k` (0 ... 1) draws round its tick: as big and bright as the In flight flare at its height. Pure.
    static func flashGlow(_ k: Double) -> Glow { Glow(scale: 1 + (flareGrow - 1) * k, opacity: flareFrom * k) }

    /// The NOW dot's breath at `t`, on the pulse's `period`: 0 ... 1, the pulse's own sine. Pure.
    static func nowDot(_ t: Double, period: Double) -> Double {
        0.5 + 0.5 * sin(t * 2 * Double.pi / max(0.1, period) - Double.pi / 2)
    }

    // MARK: the Horizon's words

    /// A line's words with each run of digits as one "#". Pure.
    static func wording(_ s: String) -> String { s.replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression) }

    /// Whether a change to a line is new words (it cross-fades) rather than new numbers (they roll):
    /// "2 need you" → "3 need you" rolls; "1 needs you" → "2 need you" is new words. Pure.
    static func rewords(_ a: String, _ b: String) -> Bool { wording(a) != wording(b) }

    /// New words `e` seconds in: the old line rising 4 pt out as it fades, the new one rising 4 pt in;
    /// nil once settled. Reduce Motion: a 0.2 s cross-fade in place. Pure.
    static func reword(_ e: Double, reduceMotion: Bool = false) -> Reword? {
        let d = reduceMotion ? WM.reducedFade : rewordDuration
        guard e >= 0, e < d else { return nil }
        let k = MotionCurve.easeOut(e / d)
        let rise = reduceMotion ? 0 : rewordRise
        return Reword(out: Slide(offset: -rise * k, opacity: 1 - k), into: Slide(offset: rise * (1 - k), opacity: k))
    }

    // MARK: chips and receipts

    /// A Review chip's words `e` seconds after its card first showed: its number counting up from 0
    /// ("+0" … "+120"); words with no number as they are. Pure.
    static func chipText(_ text: String, at e: Double) -> String {
        guard let r = text.range(of: #"\d+"#, options: .regularExpression), let total = Int(text[r]) else { return text }
        return text.replacingCharacters(in: r, with: String(chipCount(e, total: total)))
    }

    /// How much of the tests ✓ has drawn, `e` seconds after its card first showed (after the count). Pure.
    static func chipCheck(_ e: Double) -> Double { MotionCurve.easeOut((e - chipDuration) / checkDraw) }

    /// A Settled receipt `e` seconds after it arrived. Reduce Motion: it fades in where it lands (0.2 s), its ✓ drawn. Pure.
    static func receipt(_ e: Double, reduceMotion: Bool = false) -> Receipt {
        if reduceMotion { return Receipt(offset: 0, opacity: MotionCurve.easeOut(e / WM.reducedFade), height: 1, check: 1) }
        let k = MotionCurve.easeOut(e / receiptIn)
        return Receipt(offset: -receiptDrop * (1 - k), opacity: k, height: k, check: MotionCurve.easeOut((e - receiptIn) / checkDraw))
    }

    struct Pop: Equatable {
        let scale: Double
        let opacity: Double
    }

    struct Reword: Equatable {
        let out: Slide
        let into: Slide
    }

    struct Receipt: Equatable {
        /// Points down (negative: still above its place).
        let offset: Double
        let opacity: Double
        /// How much of its row has opened, 0 ... 1: the receipts below move down with it.
        let height: Double
        /// Its ✓, 0 ... 1.
        let check: Double
    }

    // MARK: the scenes

    /// What the rest of Now's motion looks at, as values.
    struct NowLook: Equatable {
        var headline: String
        var subline: String
        var runway: RunwayModel
        /// Today's Settled receipts, newest first.
        var settled: [SettledLine] = []
        /// The Review rows whose chips count up the first time each shows.
        var reviews: [String] = []
        /// The capsule's badges: Now's (the Decide count), then Lanes' (the working count).
        var badges: [Int] = []
    }

    /// A line's words changing to new words at `at`, from `from`.
    struct Change: Equatable {
        let from: String
        let at: Double
    }

    /// The Runway since it first showed: when that was (its line draws and
    /// its markers pop from then), each marker's glide to a new place, a
    /// marker new since then popping on its own, and the markers that went
    /// (reached now, or simply gone). Times are absolute on the caller's clock.
    struct RunwayScene: Equatable {
        struct Track: Equatable {
            var marker: RunwayMarker
            let from: Double
            let to: Double
            let at: Double
            /// A marker new since the first look pops from here; nil pops with the Runway.
            let popAt: Double?
        }

        struct Gone: Equatable {
            let marker: RunwayMarker
            /// Where it was drawn when it went.
            let x: Double
            let at: Double
            let reachedNow: Bool
        }

        private(set) var shownAt: Double?
        private(set) var tracks: [String: Track] = [:]
        private(set) var gone: [String: Gone] = [:]

        init() {}

        /// Track `k`'s place at `t` (shares of the line). Pure.
        func x(_ k: Track, at t: Double) -> Double { NowMotion.markerGlide(t - k.at, from: k.from, to: k.to) }

        /// Whether track `k`'s moment has come, at `t` (to the second the clock ticked). Pure.
        static func reached(_ k: Track, at t: Double) -> Bool { k.marker.at.timeIntervalSinceReferenceDate <= t + 1 }

        /// The Runway as it now stands, at `t`; `first` is when it first showed this app process.
        mutating func observe(_ model: RunwayModel, at t: Double, first: Double) {
            let opening = shownAt == nil
            if opening { shownAt = first }
            var next: [String: Track] = [:]
            for m in model.markers {
                if var k = tracks[m.id] {
                    if Self.reached(k, at: t), m.at > k.marker.at {
                        // A marker is one per kind: the reset that came round reached now, and the next one is new.
                        gone[m.id] = Gone(marker: k.marker, x: x(k, at: t), at: t, reachedNow: true)
                        k = Track(marker: m, from: m.fraction, to: m.fraction, at: -.infinity, popAt: t)
                    } else if abs(m.fraction - k.to) >= NowMotion.markerSlideMin {
                        k = Track(marker: m, from: x(k, at: t), to: m.fraction, at: t, popAt: k.popAt)
                    } else {
                        k.marker = m
                    }
                    next[m.id] = k
                } else {
                    next[m.id] = Track(marker: m, from: m.fraction, to: m.fraction, at: -.infinity, popAt: opening ? nil : t)
                }
            }
            for (id, k) in tracks where next[id] == nil {
                gone[id] = Gone(marker: k.marker, x: x(k, at: t), at: t, reachedNow: Self.reached(k, at: t))
            }
            gone = gone.filter { t - $0.value.at < NowMotion.markerFlash }
            tracks = next
        }

        /// When the last draw, pop, glide, flash or fade is over. Pure.
        func settlesAt(reduceMotion: Bool) -> Double {
            var end = -Double.infinity
            if let s = shownAt, !reduceMotion {
                let starts = NowMotion.markerStarts(tracks.values.filter { $0.popAt == nil }.map(\.marker.fraction))
                end = s + max(NowMotion.runwayDraw, (starts.max() ?? 0) + NowMotion.markerPop)
            }
            for k in tracks.values {
                end = reduceMotion ? max(end, max(k.at, k.popAt ?? -.infinity) + WM.reducedFade)
                    : max(end, k.at + NowMotion.markerSlide, (k.popAt ?? -.infinity) + NowMotion.markerPop)
            }
            for g in gone.values {
                end = max(end, g.at + (reduceMotion ? WM.reducedFade : (g.reachedNow ? NowMotion.markerFlash : NowMotion.leave)))
            }
            return end
        }
    }

    /// The capsule's badges: each count as last seen, and when one changed
    /// (from a number to another; appearing and going are transitions).
    struct BadgeScene: Equatable {
        private(set) var counts: [Int]?
        private(set) var bumps: [Int: Double] = [:]

        init() {}

        mutating func observe(_ new: [Int], at t: Double) {
            if let old = counts {
                for (i, n) in new.enumerated() where i < old.count && old[i] > 0 && n > 0 && old[i] != n { bumps[i] = t }
            }
            counts = new
        }

        /// Badge `i`'s scale at `t`. Pure.
        func scale(_ i: Int, at t: Double, reduceMotion: Bool) -> Double {
            reduceMotion ? 1 : bumps[i].map { NowMotion.badgeBump(t - $0) } ?? 1
        }

        /// When badge `i`'s bump is over. Pure.
        func settlesAt(_ i: Int, reduceMotion: Bool) -> Double {
            reduceMotion ? -.infinity : (bumps[i] ?? -.infinity) + NowMotion.bumpDuration
        }
    }

    /// Everything the rest of Now has seen since it appeared: the Runway's
    /// scene, the badges', each change of a Horizon line's words, each
    /// Settled receipt that arrived, and when each Review row's chips first
    /// showed this app process. The first look plays nothing but the
    /// first-appearance one-shots (`shown` says when those began: the live
    /// screen's `OneShotBook`, so they play once per process). A frame is a
    /// pure function of it and the clock; the live screen builds it as
    /// changes arrive, the harness by replaying a script.
    struct NowScene: Equatable {
        private(set) var runway = RunwayScene()
        private(set) var badges = BadgeScene()
        private(set) var headline: Change?
        private(set) var subline: Change?
        private(set) var arrivals: [String: Double] = [:]
        private(set) var chipsShown: [String: Double] = [:]
        private(set) var last: NowLook?

        init() {}

        init(opening look: NowLook, at t: Double, shown: (String, Double) -> Double = { $1 }) {
            observe(look, at: t, shown: shown)
        }

        static let runwayKey = "runway"
        static func chipsKey(_ id: String) -> String { "chips|\(id)" }

        /// Now as it stands, at `t`.
        mutating func observe(_ look: NowLook, at t: Double, shown: (String, Double) -> Double = { $1 }) {
            runway.observe(look.runway, at: t, first: runway.shownAt ?? shown(Self.runwayKey, t))
            badges.observe(look.badges, at: t)
            for id in look.reviews where chipsShown[id] == nil { chipsShown[id] = shown(Self.chipsKey(id), t) }
            if let was = last {
                if NowMotion.rewords(was.headline, look.headline) { headline = Change(from: was.headline, at: t) }
                if NowMotion.rewords(was.subline, look.subline) { subline = Change(from: was.subline, at: t) }
                let before = Set(was.settled.map(\.id))
                for line in look.settled where !before.contains(line.id) && t - line.at.timeIntervalSinceReferenceDate < NowMotion.receiptFresh {
                    arrivals[line.id] = t
                }
            }
            arrivals = arrivals.filter { t - $0.value < NowMotion.receiptSettle }
            last = look
        }

        /// A Horizon line's change of words at `t`, while it plays. Pure.
        func reword(_ change: Change?, at t: Double, reduceMotion: Bool) -> (change: Change, frame: Reword)? {
            guard let c = change, let f = NowMotion.reword(t - c.at, reduceMotion: reduceMotion) else { return nil }
            return (c, f)
        }

        /// When the last change of words is over. Pure.
        func rewordsSettle(reduceMotion: Bool) -> Double {
            max(headline?.at ?? -.infinity, subline?.at ?? -.infinity) + (reduceMotion ? WM.reducedFade : NowMotion.rewordDuration)
        }

        /// Receipt `id` arriving, at `t`, while it plays; nil for one that was already there. Pure.
        func receipt(_ id: String, at t: Double, reduceMotion: Bool) -> Receipt? {
            guard let a = arrivals[id], t >= a, t - a < (reduceMotion ? WM.reducedFade : NowMotion.receiptSettle) else { return nil }
            return NowMotion.receipt(t - a, reduceMotion: reduceMotion)
        }

        /// When the last receipt has landed and drawn its ✓. Pure.
        func receiptsSettle(reduceMotion: Bool) -> Double {
            (arrivals.values.max() ?? -.infinity) + (reduceMotion ? WM.reducedFade : NowMotion.receiptSettle)
        }

        /// Seconds since Review row `id`'s chips first showed (`.infinity`, all counted, when unknown or with Reduce Motion). Pure.
        func chips(_ id: String, at t: Double, reduceMotion: Bool) -> Double {
            reduceMotion ? .infinity : chipsShown[id].map { t - $0 } ?? .infinity
        }
    }

    /// A marker at one moment.
    struct MarkerFrame: Equatable {
        let marker: RunwayMarker
        /// One that went is drawn apart from its kind's next marker.
        var leaving = false
        var key: String { leaving ? "gone|" + marker.id : marker.id }
        /// Its place, a share of the line.
        let x: Double
        let scale: Double
        let opacity: Double
        /// Reaching now.
        let flash: Glow?
    }

    /// The Runway at one moment.
    struct RunwayFrame: Equatable {
        /// How much of the line has drawn.
        let line: Double
        let markers: [MarkerFrame]
        /// The NOW dot's breath (0 ... 1); nil: still.
        let breath: Double?

        /// `model` at rest: drawn, every marker at its place, the dot still. Pure.
        static func settled(_ model: RunwayModel) -> RunwayFrame {
            RunwayFrame(line: 1, markers: model.markers.map { MarkerFrame(marker: $0, x: $0.fraction, scale: 1, opacity: 1, flash: nil) }, breath: nil)
        }
    }

    /// The Runway `model` at `t`: its line and markers drawing in, each
    /// marker at its place on its glide, the markers that went flashing or
    /// fading, and the NOW dot breathing on `breathPeriod` (nil: still, as
    /// at dusk and with nothing running). Reduce Motion: drawn, still; a
    /// marker that moves or arrives fades in at its place and one that goes
    /// fades (0.2 s). Pure.
    static func runway(_ s: RunwayScene, _ model: RunwayModel, at t: Double, breathPeriod: Double?, reduceMotion rm: Bool) -> RunwayFrame {
        let shown = s.shownAt ?? -.infinity
        let starts = markerStarts(model.markers.map(\.fraction))
        var out: [MarkerFrame] = []
        for (i, m) in model.markers.enumerated() {
            let k = s.tracks[m.id]
            if rm {
                let since = k.map { max($0.at, $0.popAt ?? -.infinity) } ?? -.infinity
                out.append(MarkerFrame(marker: m, x: k?.to ?? m.fraction, scale: 1, opacity: MotionCurve.easeOut((t - since) / WM.reducedFade), flash: nil))
                continue
            }
            let pop = markerPop(k?.popAt.map { t - $0 } ?? (t - shown - starts[i]))
            out.append(MarkerFrame(marker: m, x: k.map { s.x($0, at: t) } ?? m.fraction, scale: pop.scale, opacity: pop.opacity, flash: nil))
        }
        for g in s.gone.values.sorted(by: { $0.marker.id < $1.marker.id }) {
            let e = t - g.at
            guard e >= 0 else { continue }
            if rm {
                if e < WM.reducedFade {
                    out.append(MarkerFrame(marker: g.marker, leaving: true, x: g.x, scale: 1, opacity: 1 - MotionCurve.easeOut(e / WM.reducedFade), flash: nil))
                }
            } else if g.reachedNow {
                if let p = markerPassing(e) { out.append(MarkerFrame(marker: g.marker, leaving: true, x: 0, scale: 1, opacity: p.opacity, flash: flashGlow(p.flash))) }
            } else if e < leave {
                out.append(MarkerFrame(marker: g.marker, leaving: true, x: g.x, scale: 1, opacity: 1 - MotionCurve.easeOut(e / leave), flash: nil))
            }
        }
        return RunwayFrame(line: rm ? 1 : runwayLine(t - shown), markers: out, breath: rm ? nil : breathPeriod.map { nowDot(t, period: $0) })
    }

    // MARK: a script (the render harness, the tests)

    /// Now as it looks from `at` seconds after the script began.
    struct NowStep {
        let at: Double
        let look: NowLook
    }

    struct NowScript {
        /// The script's 0, as absolute seconds.
        let base: Double
        let steps: [NowStep]
        /// The first look's one-shots played long before (the Runway drawn, the chips counted).
        var entered = true
    }

    /// Now's look and scene `t` seconds into `script`, every step observed at its moment, as the live screen would. Pure.
    static func replay(_ script: NowScript, until t: Double) -> (look: NowLook, scene: NowScene)? {
        guard let first = script.steps.first else { return nil }
        let base = script.base
        var scene = NowScene(opening: first.look, at: base + first.at, shown: script.entered ? { _, _ in base - 100 } : { $1 })
        var look = first.look
        for s in script.steps.dropFirst() where s.at <= t {
            scene.observe(s.look, at: base + s.at)
            look = s.look
        }
        return (look, scene)
    }
}
