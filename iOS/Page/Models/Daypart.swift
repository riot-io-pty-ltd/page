import Foundation

// THE TIME OF DAY: the Now and Lanes skies follow the local clock through four
// phases (early morning, morning, afternoon, nighttime), each blending into
// the next across a window. Plain numbers only, so the logic tests and the
// Android golden (android/tools/daypart-golden.sh) build it with nothing but
// MotionCurves.swift. NightWatch.AuroraPalette(mood, daypart:) turns it into
// a palette; nighttime is today's aurora exactly.

/// One phase of the day.
enum Daypart: String, CaseIterable, Equatable {
    case earlyMorning, morning, afternoon, nighttime

    /// A minute in the middle of the phase's core, where it stands alone:
    /// what the render harness's `-NWDaypart <name>` pins. Nighttime is
    /// 01:12, the harness's own clock.
    var coreMinute: Double {
        switch self {
        case .earlyMorning: return 5 * 60 + 45
        case .morning: return 9 * 60 + 30
        case .afternoon: return 15 * 60
        case .nighttime: return 72
        }
    }
}

/// How much of each phase the sky is at one minute of the day: one phase at
/// weight 1 in its core, or two across a window, `k` of the way from `from`
/// to `to` (smoothstep). At most two weights are ever nonzero and they always
/// sum to 1. A core is always (p, p, 0), so two minutes in the same core
/// compare equal and nothing redraws between them.
struct DaypartWeights: Equatable {
    let from: Daypart
    let to: Daypart
    /// 0 ..< 1: how far into the window. 0 in a core.
    let k: Double

    private init(_ from: Daypart, _ to: Daypart, _ k: Double) {
        if k <= 0 || from == to { self.from = from; self.to = from; self.k = 0 }
        else if k >= 1 { self.from = to; self.to = to; self.k = 0 }
        else { self.from = from; self.to = to; self.k = k }
    }

    /// The four windows (minute of day), each from one phase into the next.
    /// The 18:00-20:00 one is the sunset, twice as long. Nighttime runs
    /// 20:00 to 04:00, across midnight.
    static let windows: [(start: Double, end: Double, from: Daypart, to: Daypart)] = [
        (4 * 60, 5 * 60, .nighttime, .earlyMorning),
        (6 * 60 + 30, 7 * 60 + 30, .earlyMorning, .morning),
        (11 * 60 + 30, 12 * 60 + 30, .morning, .afternoon),
        (18 * 60, 20 * 60, .afternoon, .nighttime),
    ]

    /// At `minute` of the local day (any number: it wraps to 0 ..< 1440). Pure.
    static func at(minuteOfDay minute: Double) -> DaypartWeights {
        let r = minute.truncatingRemainder(dividingBy: 1440)
        let m = r < 0 ? r + 1440 : r
        for w in windows where m >= w.start && m < w.end {
            return DaypartWeights(w.from, w.to, MotionCurve.smooth((m - w.start) / (w.end - w.start)))
        }
        // The cores fill the gaps between the windows.
        if m >= 5 * 60 && m < 6 * 60 + 30 { return DaypartWeights(.earlyMorning, .earlyMorning, 0) }
        if m >= 7 * 60 + 30 && m < 11 * 60 + 30 { return DaypartWeights(.morning, .morning, 0) }
        if m >= 12 * 60 + 30 && m < 18 * 60 { return DaypartWeights(.afternoon, .afternoon, 0) }
        return DaypartWeights(.nighttime, .nighttime, 0)
    }

    /// At `date` on the local wall clock: the minute is read off the calendar,
    /// so a DST change or a new time zone moves it with the clock on the wall.
    static func at(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> DaypartWeights {
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return at(minuteOfDay: Double(c.hour ?? 0) * 60 + Double(c.minute ?? 0) + Double(c.second ?? 0) / 60)
    }

    /// 01:12, the core of the night: today's aurora. What everything with no
    /// clock of its own draws (widgets, previews, the gallery, the macOS proxy).
    static let nighttime = at(minuteOfDay: 72)

    /// The phase's weight, 0 ... 1.
    func weight(_ p: Daypart) -> Double {
        if from == to { return p == from ? 1 : 0 }
        return p == to ? k : (p == from ? 1 - k : 0)
    }

    /// The one phase at full weight, or nil inside a window.
    var only: Daypart? { from == to ? from : nil }

    /// The background star field: the clock's, not the mood's (1 at night,
    /// 0.55 early, 0.2 in the morning, none in the afternoon).
    var stars: Double {
        let a = DaypartTone.row(from).stars, b = DaypartTone.row(to).stars
        return a + (b - a) * k
    }
}

/// One phase's sky: the curtains, the sky behind them for each mood, and how
/// strong and fast the curtains run (multipliers on each mood's own).
struct DaypartTone: Equatable {
    /// sRGB 0...1, as plain numbers.
    struct Colour: Equatable {
        let r: Double, g: Double, b: Double

        init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

        /// 0xRRGGBB.
        init(hex: UInt32) {
            self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
        }

        init(_ c: PerceptualMix.RGB) { self.init(c.r, c.g, c.b) }

        var rgb: PerceptualMix.RGB { (r, g, b) }

        /// "#RRGGBB", each channel rounded. Pure.
        var hexString: String {
            func ch(_ v: Double) -> Int { Int((MotionCurve.clamp01(v) * 255).rounded()) }
            return String(format: "#%02X%02X%02X", ch(r), ch(g), ch(b))
        }

        /// Straight through Oklab (no chroma kept): every path in the table
        /// stays inside sRGB this way. Exactly self at 0 and `other` at 1.
        func mixed(with other: Colour, _ t: Double) -> Colour {
            Colour(PerceptualMix.mix(rgb, other.rgb, t, keepChroma: false))
        }
    }

    let c1: Colour, c2: Colour, c3: Colour
    /// The working sky; quiet's top is `quietTop`.
    let skyTop: Colour, skyBottom: Colour
    /// The working top a third of the way down to the page, for quiet.
    let quietTop: Colour
    /// Needs-you's own near-black sky with a fifth of this phase's hue.
    let nyTop: Colour, nyBottom: Colour
    /// On each mood's own intensity and speed.
    let intensityX: Double, speedX: Double
    /// The background star field.
    let stars: Double

    private init(c1: UInt32, c2: UInt32, c3: UInt32, skyTop: UInt32, skyBottom: UInt32, quietTop: UInt32,
                 nyTop: UInt32, nyBottom: UInt32, intensityX: Double, speedX: Double, stars: Double) {
        self.init(c1: Colour(hex: c1), c2: Colour(hex: c2), c3: Colour(hex: c3), skyTop: Colour(hex: skyTop),
                  skyBottom: Colour(hex: skyBottom), quietTop: Colour(hex: quietTop), nyTop: Colour(hex: nyTop),
                  nyBottom: Colour(hex: nyBottom), intensityX: intensityX, speedX: speedX, stars: stars)
    }

    private init(c1: Colour, c2: Colour, c3: Colour, skyTop: Colour, skyBottom: Colour, quietTop: Colour,
                 nyTop: Colour, nyBottom: Colour, intensityX: Double, speedX: Double, stars: Double) {
        self.c1 = c1; self.c2 = c2; self.c3 = c3
        self.skyTop = skyTop; self.skyBottom = skyBottom; self.quietTop = quietTop
        self.nyTop = nyTop; self.nyBottom = nyBottom
        self.intensityX = intensityX; self.speedX = speedX; self.stars = stars
    }

    /// The blue hour: indigo over a rose horizon, azure and cornflower veils, a
    /// lavender band low down, the stars thinning. c1 and c2 stay cool so the
    /// exhale's amber never swings through red to reach them.
    static let earlyMorning = DaypartTone(c1: 0x60B0F4, c2: 0x689CFC, c3: 0xB79CFF, skyTop: 0x18123A, skyBottom: 0x33162E,
                                          quietTop: 0x110F2A, nyTop: 0x181311, nyBottom: 0x08060E,
                                          intensityX: 0.9, speedX: 0.8, stars: 0.55)
    /// Clear and awake: cerulean, cyan veils over a teal horizon (cyan, not the
    /// brand teal, so the working pulse never melts into the main band).
    static let morning = DaypartTone(c1: 0x3CC4E8, c2: 0x6FA8F5, c3: 0x5EEAD4, skyTop: 0x0B2A3A, skyBottom: 0x0F2F3A,
                                     quietTop: 0x0A1E2A, nyTop: 0x15140D, nyBottom: 0x03080E,
                                     intensityX: 0.9, speedX: 1.1, stars: 0.2)
    /// Warm and unhurried: petrol teal over a low gold haze. No curtain is warm
    /// (warm belongs to needs-you); dimmer veils pay for the brighter sky.
    static let afternoon = DaypartTone(c1: 0x5CE1BE, c2: 0x64B8D8, c3: 0x4FBFA0, skyTop: 0x113644, skyBottom: 0x3B2814,
                                       quietTop: 0x0E2530, nyTop: 0x15150D, nyBottom: 0x070709,
                                       intensityX: 0.8, speedX: 0.9, stars: 0)
    /// Today's deep aurora, byte for byte: every multiplier 1.
    static let nighttime = DaypartTone(c1: 0x5EEAD4, c2: 0x38BDF8, c3: 0x6D5BD0, skyTop: 0x0B1B24, skyBottom: 0x05070D,
                                       quietTop: 0x0A141C, nyTop: 0x1A1306, nyBottom: 0x05070D,
                                       intensityX: 1, speedX: 1, stars: 1)

    static func row(_ p: Daypart) -> DaypartTone {
        switch p {
        case .earlyMorning: return earlyMorning
        case .morning: return morning
        case .afternoon: return afternoon
        case .nighttime: return nighttime
        }
    }

    /// The tone at `w`: the core's row untouched, or the window's two rows
    /// blended, colours straight through Oklab and the numbers linearly. Pure.
    static func blended(_ w: DaypartWeights) -> DaypartTone {
        let a = row(w.from)
        guard w.from != w.to, w.k > 0 else { return a }
        let b = row(w.to), k = w.k
        func n(_ x: Double, _ y: Double) -> Double { x + (y - x) * k }
        return DaypartTone(c1: a.c1.mixed(with: b.c1, k), c2: a.c2.mixed(with: b.c2, k), c3: a.c3.mixed(with: b.c3, k),
                           skyTop: a.skyTop.mixed(with: b.skyTop, k), skyBottom: a.skyBottom.mixed(with: b.skyBottom, k),
                           quietTop: a.quietTop.mixed(with: b.quietTop, k),
                           nyTop: a.nyTop.mixed(with: b.nyTop, k), nyBottom: a.nyBottom.mixed(with: b.nyBottom, k),
                           intensityX: n(a.intensityX, b.intensityX), speedX: n(a.speedX, b.speedX), stars: n(a.stars, b.stars))
    }

    /// One mood's aurora at this tone, as plain numbers (what
    /// NightWatch.AuroraPalette is built from, and what the golden prints).
    struct Aurora: Equatable {
        let c1: Colour, c2: Colour, c3: Colour
        let skyTop: Colour, skyBottom: Colour
        let intensity: Double, speed: Double
    }

    /// Agents working: the curtains at half strength, 0.4 speed, times the phase's.
    var working: Aurora {
        Aurora(c1: c1, c2: c2, c3: c3, skyTop: skyTop, skyBottom: skyBottom, intensity: 0.5 * intensityX, speed: 0.4 * speedX)
    }

    /// Nothing running: the same curtains, barely there, over the deeper top.
    var quiet: Aurora {
        Aurora(c1: c1, c2: c2, c3: c3, skyTop: quietTop, skyBottom: skyBottom, intensity: 0.3 * intensityX, speed: 0.3 * speedX)
    }

    /// Needs you: always the same amber curtains at full strength; only the sky
    /// behind them takes the hour's hue, never its light, so amber wins at noon.
    var needsYou: Aurora {
        Aurora(c1: Colour(hex: 0xF5B14C), c2: Colour(hex: 0xF2C94C), c3: Colour(hex: 0xB45309), skyTop: nyTop, skyBottom: nyBottom,
               intensity: 1, speed: 1)
    }
}

/// When the time of day is read again: every two minutes on the wall clock
/// (plus on foreground and on a time or time-zone change). Inside a window the
/// largest step per tick is a couple of levels on screen, so ticks need no tween.
enum DaypartClock {
    static let tick: TimeInterval = 120

    /// The next whole multiple of `tick` after `date`. Pure.
    static func nextTick(after date: Date) -> Date {
        let t = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (floor(t / tick) + 1) * tick)
    }
}

/// The aurora's curtain phase, accumulated rather than `seconds * rate`: with
/// the absolute product, any change of speed (a time-of-day tick, a mood
/// change, the exhale) would jump the curtains by seconds times the change.
/// The first call seeds it from the clock; after that it moves by the time
/// since the last call (at most a quarter second, so a pause or a sheet
/// resumes where it left off) at the current rate. A reference, held by the
/// view that draws the aurora.
final class AuroraPhaseClock {
    private var phase: Double?
    private var last = 0.0

    /// The longest step one call may take.
    static let maxStep = 0.25

    /// The phase at clock time `seconds`, moving at `rate` per second.
    func advance(to seconds: Double, rate: Double) -> Double {
        guard let p = phase else {
            let seed = seconds.truncatingRemainder(dividingBy: 3600) * rate
            phase = seed
            last = seconds
            return seed
        }
        let next = p + min(Self.maxStep, max(0, seconds - last)) * rate
        phase = next
        last = seconds
        return next
    }

    /// The phase as the shader takes it: a 32-bit float stays fine-grained
    /// below this, so the phase wraps there (one jump about a day apart at
    /// working speed). Pure.
    static func shaderPhase(_ phase: Double) -> Float {
        let r = phase.truncatingRemainder(dividingBy: 16_384)
        return Float(r < 0 ? r + 16_384 : r)
    }
}
