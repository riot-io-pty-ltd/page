import AppKit

/// What the menu-bar glyph says (v4 spec, macMenuBar.GLYPH). One of the modes
/// plus three independent modifiers.
struct GlyphState: Equatable {
    enum Mode: Equatable {
        /// Page is not keeping the Mac awake and nothing is running: a hollow ring.
        case off
        /// Awake but nothing working (holding for a page, a local model): a still star-white dot.
        case quiet
        /// Agents working: teal, breathing.
        case working(agents: Int)
        /// Something is blocked: amber ripple with a count.
        case needsYou(count: Int)
        /// Paused for battery: a flat horizon under a dimmed dot.
        case paused
    }

    var mode: Mode
    /// Lid-closed awake is in force: a moon tick.
    var lidClosedAwake: Bool = false
    /// Battery headroom to the cutoff, 0...1; nil on AC or without a battery.
    var headroom: Double? = nil
    /// Phone paging is armed (relay up and you're away): a small phone badge.
    var phoneArmed: Bool = false
    /// Pages still waiting while paused for battery: the glyph keeps the amber
    /// count beside the dimmed dot. Ignored in every other mode (they carry
    /// their own count).
    var waiting: Int = 0

    /// Pure. Share of the charge above the cutoff that is left:
    /// (percent - cutoff) / (100 - cutoff), clamped to 0...1.
    static func headroom(power: PowerSnapshot, cutoff: Int) -> Double? {
        guard power.hasBattery, !power.onAC, power.percent >= 0 else { return nil }
        let span = Double(100 - cutoff)
        guard span > 0 else { return nil }
        return min(1, max(0, Double(power.percent - cutoff) / span))
    }

    /// Pure. The mode with the highest precedence: paused, then needs-you,
    /// then working, then quiet, then off.
    static func mode(paused: Bool, needYou: Int, working: Int, keepingAwake: Bool) -> Mode {
        if paused { return .paused }
        if needYou > 0 { return .needsYou(count: needYou) }
        if working > 0 { return .working(agents: working) }
        return keepingAwake ? .quiet : .off
    }
}

/// Everything the status-bar renderer needs to draw one frame, as numbers and
/// colours. Pure and comparable, so the animator can skip identical frames.
struct GlyphDrawing: Equatable {
    typealias RGBA = NightWatch.RGBA

    /// Menu-bar background the glyph sits on.
    enum Appearance: Equatable { case dark, light }

    var dotColor: RGBA
    var dotRadius: Double
    /// Hollow ring instead of a filled dot (keep-awake off).
    var hollow: Bool
    /// Soft glow behind the dot, 0...1.
    var glow: Double
    /// Expanding amber rings (0 = still), each 0...1 progress with its own alpha.
    var ripples: [Ripple]
    /// A still ring in place of the ripple (Reduce Motion with something waiting).
    var staticRing: Bool
    var countText: String?
    /// Headroom arc 0...1 and its colour; nil = no arc.
    var arc: Double?
    var arcColor: RGBA
    var arcTrack: RGBA
    var moonTick: Bool
    /// Flat horizon under the dot (paused).
    var horizon: Bool
    var neutral: RGBA
    var phoneBadge: Bool
    var phoneColor: RGBA

    struct Ripple: Equatable {
        var radius: Double
        var alpha: Double
    }

    /// Points. The glyph circle area is `side` square; a count adds `countWidth`.
    static let side: Double = 21
    static let countWidth: Double = 9
    /// The column to the right of the dot's glow and headroom arc that the
    /// phone badge and moon tick sit in, so they never touch either.
    static let modifierColumn: Double = 4.5

    /// Where the modifiers and the count begin.
    var dotArea: Double { Self.side + (moonTick || phoneBadge ? Self.modifierColumn : 0) }
    var width: Double { dotArea + (countText.map { Double($0.count) * Self.countWidth + 1 } ?? 0) }

    // MARK: pure mapping

    /// Pure. Colours per menu-bar appearance: neutral parts are white on a
    /// dark bar and near-black on a light one; teal and amber are deepened on light.
    static func colors(_ a: Appearance) -> (neutral: RGBA, teal: RGBA, amber: RGBA) {
        switch a {
        case .dark: return (RGBA(1, 1, 1, 0.92), NightWatch.Palette.teal, NightWatch.Palette.amber)
        case .light: return (RGBA(0.11, 0.11, 0.12, 0.88), RGBA(hex: 0x0E9F8E), RGBA(hex: 0xC27803))
        }
    }

    /// Pure. Breath: 4 s per cycle, a little faster with more agents (PulseModel).
    static func breathPeriod(agents: Int) -> Double {
        PulseModel.breathPeriod(agents: agents)
    }

    /// Pure. 0...1 position in a cycle of `period` seconds at time `t`.
    static func cyclePhase(at t: Double, period: Double) -> Double {
        guard period > 0 else { return 0 }
        let p = (t / period).truncatingRemainder(dividingBy: 1)
        return p < 0 ? p + 1 : p
    }

    /// Pure. Seconds between ripples: the longer the wait, the faster, never
    /// faster than every 1.5 s (PulseModel).
    static func rippleInterval(longestWait: TimeInterval) -> Double {
        PulseModel.rippleInterval(longestWait: longestWait)
    }

    /// Rings in the 18 pt glyph: one per waiting item, up to three (more is a smudge at this size).
    static let maxRings = 3

    /// Pure. Seconds for one ripple ring to travel out in the glyph.
    static func ringLife(waiting: Int, longestWait: TimeInterval) -> Double {
        PulseModel.ringLife(waiting: waiting, longestWait: longestWait, cap: maxRings)
    }

    /// Pure. Maps a state to drawing parameters. `phase` is 0...1 through the
    /// current breath or ripple cycle; with `reduceMotion` the result is
    /// fixed (no breathing, no ripple, a still ring when something waits).
    /// `exhale` is the 800 ms after the last waiting item cleared: the dot
    /// turns from amber to teal and swells once while the rings fade.
    static func make(_ state: GlyphState, appearance: Appearance = .dark, phase: Double = 0.25,
                     reduceMotion: Bool = false, exhale: PulseModel.Exhale? = nil,
                     exhaleRings: Int = 0) -> GlyphDrawing {
        let c = colors(appearance)
        let wave = reduceMotion ? 0 : sin(phase * 2 * .pi) // -1...1
        var d = GlyphDrawing(
            dotColor: c.neutral, dotRadius: 3.2, hollow: false, glow: 0, ripples: [], staticRing: false,
            countText: nil, arc: state.headroom, arcColor: c.teal, arcTrack: c.neutral.opacity(0.22),
            moonTick: state.lidClosedAwake, horizon: false, neutral: c.neutral,
            phoneBadge: state.phoneArmed, phoneColor: c.teal)

        if let h = state.headroom, h < 0.25 { d.arcColor = c.amber }

        switch state.mode {
        case .off:
            d.hollow = true
            d.dotRadius = 3.4
            d.dotColor = c.neutral.opacity(0.8)
        case .quiet:
            d.dotColor = appearance == .dark ? NightWatch.Palette.star : c.neutral
        case .working:
            d.dotColor = c.teal
            d.dotRadius = 3.2 + 0.45 * wave
            d.glow = 0.55 + 0.25 * wave
        case .needsYou(let count):
            d.dotColor = c.amber
            d.dotRadius = 3.3
            d.glow = 0.7
            d.countText = count > 99 ? "99+" : "\(count)"
            if reduceMotion {
                d.staticRing = true
            } else {
                // One ring per waiting item (up to three), evenly spaced, growing and fading.
                d.ripples = PulseModel.rings(phase: phase, count: PulseModel.ringCount(waiting: count, cap: maxRings)).map {
                    Ripple(radius: 4.2 + 3.4 * $0.progress, alpha: 0.75 * $0.alpha)
                }
            }
        case .paused:
            // A low glow: dimmed dot over a flat horizon ("Paused for battery · resumes on power").
            d.dotColor = c.teal.opacity(0.4)
            d.glow = PulseModel.pausedGlow
            d.horizon = true
            // Something is still waiting on you: a dimmed amber count, no ripple.
            if state.waiting > 0 {
                d.dotColor = c.amber.opacity(0.75)
                d.countText = state.waiting > 99 ? "99+" : "\(state.waiting)"
            }
        }
        // The last waiting item cleared: amber exhales to the new colour, the
        // glow swells once, and the rings that were out fade.
        if let x = exhale, !x.finished, !reduceMotion {
            switch state.mode {
            case .working, .quiet:
                d.dotColor = c.amber.mixedPerceptual(with: d.dotColor, x.tealMix)
                d.glow = max(d.glow, 0.7 * (1 - x.tealMix)) + 0.8 * x.swell
                d.dotRadius += 1.6 * x.swell
                d.ripples = PulseModel.rings(phase: phase, count: PulseModel.ringCount(waiting: exhaleRings, cap: maxRings)).map {
                    Ripple(radius: 4.2 + 3.4 * $0.progress, alpha: 0.75 * $0.alpha * x.ringFade)
                }.filter { $0.alpha > 0.02 }
            default: break
            }
        }
        return d
    }
}

/// Draws a `GlyphDrawing` into a coloured (never template) `NSImage` for the
/// status item.
enum StatusGlyphRenderer {
    static let height: CGFloat = 18

    /// `scale` enlarges the same vector drawing (for the harness's close-ups);
    /// the status item uses 1.
    static func image(_ d: GlyphDrawing, scale: CGFloat = 1) -> NSImage {
        let size = NSSize(width: CGFloat(d.width), height: height)
        let image = NSImage(size: NSSize(width: size.width * scale, height: size.height * scale), flipped: false) { _ in
            let t = NSAffineTransform()
            t.scale(by: scale)
            t.concat()
            draw(d, in: size)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Page"
        return image
    }

    private static func draw(_ d: GlyphDrawing, in size: NSSize) {
        let center = NSPoint(x: 9.5, y: size.height / 2 + (d.horizon ? 1.5 : 0))
        func circle(_ r: Double, at p: NSPoint = center) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }

        // Battery headroom: a hairline arc around the dot, 12 o'clock clockwise.
        if let arc = d.arc {
            let r: CGFloat = 7.6
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: r, startAngle: 0, endAngle: 360)
            track.lineWidth = 1
            d.arcTrack.nsColor.setStroke()
            track.stroke()
            if arc > 0.005 {
                let value = NSBezierPath()
                value.appendArc(withCenter: center, radius: r, startAngle: 90, endAngle: 90 - CGFloat(arc) * 360, clockwise: true)
                value.lineWidth = 1.2
                value.lineCapStyle = .round
                d.arcColor.nsColor.setStroke()
                value.stroke()
            }
        }

        // Glow.
        if d.glow > 0 {
            let r = CGFloat(d.dotRadius) + 3.5
            let g = NSGradient(colors: [d.dotColor.opacity(0.45 * d.glow).nsColor, d.dotColor.opacity(0).nsColor])
            g?.draw(in: circle(Double(r)), relativeCenterPosition: .zero)
        }

        // Ripples / static ring.
        for r in d.ripples {
            let p = circle(r.radius)
            p.lineWidth = 1
            d.dotColor.opacity(r.alpha).nsColor.setStroke()
            p.stroke()
        }
        if d.staticRing {
            let p = circle(6.2)
            p.lineWidth = 1.2
            d.dotColor.opacity(0.7).nsColor.setStroke()
            p.stroke()
        }

        // The dot.
        if d.hollow {
            let p = circle(d.dotRadius - 0.6)
            p.lineWidth = 1.2
            d.dotColor.nsColor.setStroke()
            p.stroke()
        } else {
            d.dotColor.nsColor.setFill()
            circle(d.dotRadius).fill()
        }

        // Flat horizon under a paused dot.
        if d.horizon {
            let y = center.y - 5.6
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 4, y: y))
            line.line(to: NSPoint(x: 15, y: y))
            line.lineWidth = 1.2
            line.lineCapStyle = .round
            d.neutral.opacity(0.6).nsColor.setStroke()
            line.stroke()
        }

        // Moon tick: a small crescent at the top right.
        if d.moonTick {
            let m = NSPoint(x: d.dotArea - 3.2, y: size.height - 3.4)
            let outer = circle(2.6, at: m)
            let bite = circle(2.3, at: NSPoint(x: m.x + 1.2, y: m.y + 0.7))
            let crescent = NSBezierPath()
            crescent.append(outer)
            crescent.append(bite)
            crescent.windingRule = .evenOdd
            d.neutral.nsColor.setFill()
            crescent.fill()
        }

        // Phone badge: a tiny phone outline at the bottom right.
        if d.phoneBadge {
            let r = NSRect(x: d.dotArea - 4.8, y: 1.0, width: 3.8, height: 6.4)
            let p = NSBezierPath(roundedRect: r, xRadius: 1.1, yRadius: 1.1)
            p.lineWidth = 0.9
            d.phoneColor.nsColor.setStroke()
            p.stroke()
            d.phoneColor.nsColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.midX - 0.45, y: r.minY + 0.9, width: 0.9, height: 0.9)).fill()
        }

        // Count.
        if let text = d.countText {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .heavy),
                .foregroundColor: d.dotColor.nsColor
            ]
            let s = NSAttributedString(string: text, attributes: attrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: CGFloat(d.dotArea) + 0.5, y: (size.height - sz.height) / 2))
        }
    }
}

/// Breathes the status glyph. The owner sets `state`, hands over `onImage`,
/// and calls `start()`. Falls back to one still frame when Reduce Motion is
/// on (and follows the setting live), does not tick while the state has
/// nothing to animate, and goes still while the screen is asleep or the user
/// session is in the background: a battery-first app has no business redrawing
/// a menu-bar icon nobody can see.
final class GlyphAnimator {
    /// Frames per second while animating.
    static let framesPerSecond: Double = 8
    /// Phase steps per cycle: identical frames are skipped.
    static let phaseSteps = 24

    /// Frames per second during the 800 ms exhale (a short one-shot).
    static let exhaleFramesPerSecond: Double = 15

    var onImage: ((NSImage) -> Void)?
    var appearance: GlyphDrawing.Appearance = .dark { didSet { redraw() } }
    var state = GlyphState(mode: .off) {
        didSet {
            guard oldValue != state else { return }
            if case .needsYou(let n) = oldValue.mode, Self.exhalesInto(state.mode) {
                exhaleStart = Date()
                exhaleRings = n
            } else if case .needsYou = state.mode {
                exhaleStart = nil
            }
            redraw()
            updateTimer()
        }
    }
    /// Seconds the longest waiting page has waited (ripple speed).
    var longestWait: TimeInterval = 0
    /// When the last waiting item cleared (the exhale plays from it).
    private var exhaleStart: Date?
    private var exhaleRings = 0

    private var timer: Timer?
    private var lastDrawing: GlyphDrawing?
    private let reduceMotion: () -> Bool
    private var started = false
    /// The screen is asleep or the session is not the active one.
    private var suspended = false
    private var observers: [NSObjectProtocol] = []

    init(reduceMotion: @escaping () -> Bool = { NightWatch.systemReduceMotion }) {
        self.reduceMotion = reduceMotion
        let nc = NSWorkspace.shared.notificationCenter
        func watch(_ name: Notification.Name, _ body: @escaping (GlyphAnimator) -> Void) {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if let self { body(self) }
            })
        }
        watch(NSWorkspace.screensDidSleepNotification) { $0.setSuspended(true) }
        watch(NSWorkspace.sessionDidResignActiveNotification) { $0.setSuspended(true) }
        watch(NSWorkspace.screensDidWakeNotification) { $0.setSuspended(false) }
        watch(NSWorkspace.sessionDidBecomeActiveNotification) { $0.setSuspended(false) }
        // Reduce Motion flipped mid-session: pick the new behaviour up now.
        watch(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { me in
            me.lastDrawing = nil
            me.redraw()
            me.updateTimer()
        }
    }

    deinit {
        timer?.invalidate()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    func start() {
        started = true
        redraw()
        updateTimer()
    }

    func stop() {
        started = false
        timer?.invalidate()
        timer = nil
    }

    private func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        if !value { redraw() }
        updateTimer()
    }

    /// Pure. The modes the needs-you amber exhales into (not dusk, not off).
    static func exhalesInto(_ mode: GlyphState.Mode) -> Bool {
        switch mode {
        case .working, .quiet: return true
        case .off, .needsYou, .paused: return false
        }
    }

    /// Pure. Whether a state moves at all.
    static func animates(_ mode: GlyphState.Mode) -> Bool {
        switch mode {
        case .working, .needsYou: return true
        case .off, .quiet, .paused: return false
        }
    }

    /// Pure. Snaps a 0...1 phase to one of `steps` positions, so two frames
    /// within a step are the same drawing and the second is skipped.
    static func quantised(_ phase: Double, steps: Int = GlyphAnimator.phaseSteps) -> Double {
        guard steps > 0 else { return phase }
        return (phase * Double(steps)).rounded(.down) / Double(steps)
    }

    /// The exhale still playing, if any.
    private var exhale: PulseModel.Exhale? {
        guard let start = exhaleStart else { return nil }
        let x = PulseModel.exhale(elapsed: Date().timeIntervalSince(start))
        return x.tealMix < 1 || x.swell > 0.001 ? x : nil
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        let exhaling = exhaleStart.map { Date().timeIntervalSince($0) < PulseModel.clearDuration } ?? false
        guard started, !suspended, !reduceMotion(), Self.animates(state.mode) || exhaling else { return }
        // The status item is always visible: 8 fps normally, 15 only for the 800 ms exhale.
        let fps = exhaling ? Self.exhaleFramesPerSecond : Self.framesPerSecond
        let t = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in self?.redraw() }
        t.tolerance = exhaling ? 0.01 : 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func redraw() {
        guard started else { return }
        let now = Date().timeIntervalSinceReferenceDate
        let phase: Double
        switch state.mode {
        case .working(let n): phase = GlyphDrawing.cyclePhase(at: now, period: GlyphDrawing.breathPeriod(agents: n))
        case .needsYou(let n): phase = GlyphDrawing.cyclePhase(at: now, period: GlyphDrawing.ringLife(waiting: n, longestWait: longestWait))
        default: phase = 0.25
        }
        let x = exhale
        if x == nil, exhaleStart != nil {
            // The exhale is over: back to the plain timer (or none at all).
            exhaleStart = nil
            updateTimer()
        }
        let ripplePhase = x == nil ? phase : GlyphDrawing.cyclePhase(at: now, period: GlyphDrawing.ringLife(waiting: exhaleRings, longestWait: 0))
        let drawing = GlyphDrawing.make(state, appearance: appearance,
                                        phase: x == nil ? Self.quantised(phase) : ripplePhase,
                                        reduceMotion: reduceMotion(), exhale: x, exhaleRings: exhaleRings)
        guard drawing != lastDrawing else { return }
        lastDrawing = drawing
        onImage?(StatusGlyphRenderer.image(drawing))
    }
}
