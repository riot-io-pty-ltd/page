package app.page.android.model

import java.time.Instant
import java.time.ZoneId
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// Port of iOS/Page/Models/Daypart.swift (the source of truth). THE TIME OF DAY: the Now and Lanes skies follow
// the local clock through four phases (early morning, morning, afternoon, nighttime), each blending into the next
// across a window. Plain numbers only, so the JVM tests and the golden (android/tools/daypart-golden.sh, read by
// DaypartGoldenTest) check it with nothing but MotionCurves.kt. AuroraPalette.of(mood, daypart) turns it into a
// palette; nighttime is today's aurora exactly.

/** One phase of the day. [raw] is the iOS case name (the harness's `page_daytime` takes it). */
enum class Daypart(val raw: String) {
    EARLY_MORNING("earlyMorning"), MORNING("morning"), AFTERNOON("afternoon"), NIGHTTIME("nighttime");

    /**
     * A minute in the middle of the phase's core, where it stands alone: what the render harness's
     * `page_daytime <name>` pins. Nighttime is 01:12, the harness's own clock.
     */
    val coreMinute: Double
        get() = when (this) {
            EARLY_MORNING -> 5 * 60 + 45.0
            MORNING -> 9 * 60 + 30.0
            AFTERNOON -> 15 * 60.0
            NIGHTTIME -> 72.0
        }

    companion object {
        fun of(raw: String): Daypart? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * How much of each phase the sky is at one minute of the day: one phase at weight 1 in its core, or two across a
 * window, [k] of the way from [from] to [to] (smoothstep). At most two weights are ever nonzero and they always sum
 * to 1. A core is always (p, p, 0), so two minutes in the same core compare equal and nothing redraws between them.
 */
class DaypartWeights private constructor(from: Daypart, to: Daypart, k: Double) {
    val from: Daypart
    val to: Daypart

    /** 0 ..< 1: how far into the window. 0 in a core. */
    val k: Double

    init {
        if (k <= 0 || from == to) { this.from = from; this.to = from; this.k = 0.0 }
        else if (k >= 1) { this.from = to; this.to = to; this.k = 0.0 }
        else { this.from = from; this.to = to; this.k = k }
    }

    /** One window (minute of day), from one phase into the next. */
    data class Window(val start: Double, val end: Double, val from: Daypart, val to: Daypart)

    /** The phase's weight, 0 ... 1. */
    fun weight(p: Daypart): Double {
        if (from == to) return if (p == from) 1.0 else 0.0
        return if (p == to) k else if (p == from) 1 - k else 0.0
    }

    /** The one phase at full weight, or null inside a window. */
    val only: Daypart? get() = if (from == to) from else null

    /** The background star field: the clock's, not the mood's (1 at night, 0.55 early, 0.2 in the morning, none in the afternoon). */
    val stars: Double
        get() {
            val a = DaypartTone.row(from).stars
            val b = DaypartTone.row(to).stars
            return a + (b - a) * k
        }

    override fun equals(other: Any?): Boolean = other is DaypartWeights && other.from == from && other.to == to && other.k == k
    override fun hashCode(): Int = (from.hashCode() * 31 + to.hashCode()) * 31 + k.hashCode()
    override fun toString(): String = "DaypartWeights($from -> $to, k=$k)"

    companion object {
        /** The four windows, each from one phase into the next. The 18:00-20:00 one is the sunset, twice as long. Nighttime runs 20:00 to 04:00, across midnight. */
        val windows: List<Window> = listOf(
            Window(4 * 60.0, 5 * 60.0, Daypart.NIGHTTIME, Daypart.EARLY_MORNING),
            Window(6 * 60 + 30.0, 7 * 60 + 30.0, Daypart.EARLY_MORNING, Daypart.MORNING),
            Window(11 * 60 + 30.0, 12 * 60 + 30.0, Daypart.MORNING, Daypart.AFTERNOON),
            Window(18 * 60.0, 20 * 60.0, Daypart.AFTERNOON, Daypart.NIGHTTIME),
        )

        /** At [minute] of the local day (any number: it wraps to 0 ..< 1440). Pure. */
        fun at(minute: Double): DaypartWeights {
            val m = minute.mod(1440.0)
            for (w in windows) if (m >= w.start && m < w.end) return DaypartWeights(w.from, w.to, MotionCurve.smooth((m - w.start) / (w.end - w.start)))
            // The cores fill the gaps between the windows.
            if (m >= 5 * 60 && m < 6 * 60 + 30) return DaypartWeights(Daypart.EARLY_MORNING, Daypart.EARLY_MORNING, 0.0)
            if (m >= 7 * 60 + 30 && m < 11 * 60 + 30) return DaypartWeights(Daypart.MORNING, Daypart.MORNING, 0.0)
            if (m >= 12 * 60 + 30 && m < 18 * 60) return DaypartWeights(Daypart.AFTERNOON, Daypart.AFTERNOON, 0.0)
            return DaypartWeights(Daypart.NIGHTTIME, Daypart.NIGHTTIME, 0.0)
        }

        /**
         * At [instant] on the local wall clock of [zone]: the minute is read off the zone's rules, so a DST change
         * or a new time zone moves it with the clock on the wall. Pure.
         */
        fun at(instant: Instant, zone: ZoneId): DaypartWeights {
            val z = instant.atZone(zone)
            return at(z.hour * 60.0 + z.minute + z.second / 60.0)
        }

        /** 01:12, the core of the night: today's aurora. What everything with no clock of its own draws (widgets, the gallery). */
        val NIGHTTIME: DaypartWeights = at(72.0)
    }
}

/**
 * One phase's sky: the curtains, the sky behind them for each mood, and how strong and fast the curtains run
 * (multipliers on each mood's own).
 */
data class DaypartTone(
    val c1: Colour, val c2: Colour, val c3: Colour,
    /** The working sky; quiet's top is [quietTop]. */
    val skyTop: Colour, val skyBottom: Colour,
    /** The working top a third of the way down to the page, for quiet. */
    val quietTop: Colour,
    /** Needs-you's own near-black sky with a fifth of this phase's hue. */
    val nyTop: Colour, val nyBottom: Colour,
    /** On each mood's own intensity and speed. */
    val intensityX: Double, val speedX: Double,
    /** The background star field. */
    val stars: Double,
) {
    /** sRGB 0...1, as plain numbers. */
    data class Colour(val r: Double, val g: Double, val b: Double) {
        constructor(c: PerceptualMix.Rgb) : this(c.r, c.g, c.b)

        val rgb: PerceptualMix.Rgb get() = PerceptualMix.Rgb(r, g, b)

        /** "#RRGGBB", each channel rounded. Pure. */
        val hexString: String
            get() {
                fun ch(v: Double): Int = (MotionCurve.clamp01(v) * 255).roundToInt()
                return "#%02X%02X%02X".format(ch(r), ch(g), ch(b))
            }

        /** Straight through Oklab (no chroma kept): every path in the table stays inside sRGB this way. Exactly self at 0 and [other] at 1. */
        fun mixed(other: Colour, t: Double): Colour = Colour(PerceptualMix.mix(rgb, other.rgb, t, keepChroma = false))

        companion object {
            /** 0xRRGGBB. */
            fun hex(hex: Int): Colour = Colour(((hex shr 16) and 0xFF) / 255.0, ((hex shr 8) and 0xFF) / 255.0, (hex and 0xFF) / 255.0)
        }
    }

    /** One mood's aurora at this tone, as plain numbers (what AuroraPalette is built from, and what the golden prints). */
    data class Aurora(val c1: Colour, val c2: Colour, val c3: Colour, val skyTop: Colour, val skyBottom: Colour, val intensity: Double, val speed: Double)

    /** Agents working: the curtains at half strength, 0.4 speed, times the phase's. */
    val working: Aurora get() = Aurora(c1, c2, c3, skyTop, skyBottom, 0.5 * intensityX, 0.4 * speedX)

    /** Nothing running: the same curtains, barely there, over the deeper top. */
    val quiet: Aurora get() = Aurora(c1, c2, c3, quietTop, skyBottom, 0.3 * intensityX, 0.3 * speedX)

    /** Needs you: always the same amber curtains at full strength; only the sky behind them takes the hour's hue, never its light, so amber wins at noon. */
    val needsYou: Aurora get() = Aurora(Colour.hex(0xF5B14C), Colour.hex(0xF2C94C), Colour.hex(0xB45309), nyTop, nyBottom, 1.0, 1.0)

    companion object {
        private fun tone(
            c1: Int, c2: Int, c3: Int, skyTop: Int, skyBottom: Int, quietTop: Int, nyTop: Int, nyBottom: Int,
            intensityX: Double, speedX: Double, stars: Double,
        ) = DaypartTone(
            Colour.hex(c1), Colour.hex(c2), Colour.hex(c3), Colour.hex(skyTop), Colour.hex(skyBottom), Colour.hex(quietTop),
            Colour.hex(nyTop), Colour.hex(nyBottom), intensityX, speedX, stars,
        )

        /**
         * The blue hour: indigo over a rose horizon, azure and cornflower veils, a lavender band low down, the stars
         * thinning. c1 and c2 stay cool so the exhale's amber never swings through red to reach them.
         */
        val earlyMorning = tone(0x60B0F4, 0x689CFC, 0xB79CFF, 0x18123A, 0x33162E, 0x110F2A, 0x181311, 0x08060E, 0.9, 0.8, 0.55)

        /** Clear and awake: cerulean, cyan veils over a teal horizon (cyan, not the brand teal, so the working pulse never melts into the main band). */
        val morning = tone(0x3CC4E8, 0x6FA8F5, 0x5EEAD4, 0x0B2A3A, 0x0F2F3A, 0x0A1E2A, 0x15140D, 0x03080E, 0.9, 1.1, 0.2)

        /** Warm and unhurried: petrol teal over a low gold haze. No curtain is warm (warm belongs to needs-you); dimmer veils pay for the brighter sky. */
        val afternoon = tone(0x5CE1BE, 0x64B8D8, 0x4FBFA0, 0x113644, 0x3B2814, 0x0E2530, 0x15150D, 0x070709, 0.8, 0.9, 0.0)

        /** Today's deep aurora, byte for byte: every multiplier 1. */
        val nighttime = tone(0x5EEAD4, 0x38BDF8, 0x6D5BD0, 0x0B1B24, 0x05070D, 0x0A141C, 0x1A1306, 0x05070D, 1.0, 1.0, 1.0)

        fun row(p: Daypart): DaypartTone = when (p) {
            Daypart.EARLY_MORNING -> earlyMorning
            Daypart.MORNING -> morning
            Daypart.AFTERNOON -> afternoon
            Daypart.NIGHTTIME -> nighttime
        }

        /** The tone at [w]: the core's row untouched, or the window's two rows blended, colours straight through Oklab and the numbers linearly. Pure. */
        fun blended(w: DaypartWeights): DaypartTone {
            val a = row(w.from)
            if (w.from == w.to || w.k <= 0) return a
            val b = row(w.to)
            val k = w.k
            fun n(x: Double, y: Double): Double = x + (y - x) * k
            return DaypartTone(
                a.c1.mixed(b.c1, k), a.c2.mixed(b.c2, k), a.c3.mixed(b.c3, k),
                a.skyTop.mixed(b.skyTop, k), a.skyBottom.mixed(b.skyBottom, k), a.quietTop.mixed(b.quietTop, k),
                a.nyTop.mixed(b.nyTop, k), a.nyBottom.mixed(b.nyBottom, k),
                n(a.intensityX, b.intensityX), n(a.speedX, b.speedX), n(a.stars, b.stars),
            )
        }
    }
}

/**
 * When the time of day is read again: every two minutes on the wall clock (plus on a return to the foreground and on
 * a time or time-zone change). Inside a window the largest step per tick is a couple of levels on screen, so ticks
 * need no tween.
 */
object DaypartClock {
    /** Seconds. */
    const val tick: Long = 120

    /** The next whole multiple of [tick] after [instant]. Pure. */
    fun nextTick(after: Instant): Instant = Instant.ofEpochSecond((Math.floorDiv(after.epochSecond, tick) + 1) * tick)
}

/**
 * The aurora's curtain phase, accumulated rather than `seconds * rate`: with the absolute product, any change of
 * speed (a time-of-day tick, a mood change, the exhale) would jump the curtains by seconds times the change. The
 * first call seeds it from the clock; after that it moves by the time since the last call (at most a quarter second,
 * so a pause or a sheet resumes where it left off) at the current rate. Held by the view that draws the aurora.
 */
class AuroraPhaseClock {
    private var phase: Double? = null
    private var last = 0.0

    /** The phase at clock time [seconds], moving at [rate] per second. */
    fun advance(seconds: Double, rate: Double): Double {
        val p = phase
        if (p == null) {
            val seed = (seconds % 3600) * rate
            phase = seed
            last = seconds
            return seed
        }
        val next = p + min(maxStep, max(0.0, seconds - last)) * rate
        phase = next
        last = seconds
        return next
    }

    companion object {
        /** The longest step one call may take. */
        const val maxStep = 0.25

        /** The phase as the shader takes it: a 32-bit float stays fine-grained below this, so the phase wraps there (one jump about a day apart at working speed). Pure. */
        fun shaderPhase(phase: Double): Float = phase.mod(16_384.0).toFloat()
    }
}
