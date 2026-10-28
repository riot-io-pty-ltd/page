package app.page.android.ui.nw.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.page.android.model.Daypart
import app.page.android.model.DaypartTone
import app.page.android.model.DaypartWeights
import app.page.android.model.PerceptualMix
import app.page.android.model.NowModel

/**
 * Night Watch design tokens for the phone: colour, type, spacing, radius and the aurora palettes. A 1:1 port of
 * `NightWatch` in iOS/Page/Design/NightWatch/NWTheme.swift, whose values are read off the approved v4 boards
 * (Designs/v4) and match the Mac app's tokens. Fonts are the system ones (Roboto, Droid Sans Mono); all text is
 * in `sp`, so it follows the user's font size. Night Watch is a dark design: these do not follow the light
 * appearance.
 */

/** A colour as plain numbers, so it can be compared, mixed and tested. sRGB, 0..1. */
@Immutable
data class Rgba(val r: Double, val g: Double, val b: Double, val a: Double = 1.0) {
    fun opacity(alpha: Double): Rgba = Rgba(r, g, b, alpha)

    /** Mix towards [other] by [t] (0 = self, 1 = other); alpha follows. */
    fun mixed(other: Rgba, t: Double): Rgba = Rgba(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t, a + (other.a - a) * t)

    /** Part-way to [other] through OKLCH (`PerceptualMix`), for the exhale: amber reaches teal by way of a bright green, never khaki. */
    fun mixedPerceptual(other: Rgba, t: Double, keepChroma: Boolean = true): Rgba {
        val k = t.coerceIn(0.0, 1.0)
        if (k == 0.0) return this
        if (k == 1.0) return other
        val c = PerceptualMix.mix(PerceptualMix.Rgb(r, g, b), PerceptualMix.Rgb(other.r, other.g, other.b), k, keepChroma)
        return Rgba(c.r, c.g, c.b, a + (other.a - a) * k)
    }

    val color: Color get() = Color(r.toFloat(), g.toFloat(), b.toFloat(), a.toFloat())

    companion object {
        /** 0xRRGGBB. */
        fun hex(hex: Int, alpha: Double = 1.0): Rgba =
            Rgba(((hex shr 16) and 0xFF) / 255.0, ((hex shr 8) and 0xFF) / 255.0, (hex and 0xFF) / 255.0, alpha)
    }
}

object NW {
    object Palette {
        /** Near-black navy the surfaces sit on. */
        val background = Rgba.hex(0x05070D)
        val backgroundDeep = Rgba.hex(0x04060A)

        /** Card / row fills. */
        val surface = Rgba.hex(0x14161C)
        val surfaceRaised = Rgba.hex(0x1B1E25)
        val inset = Rgba.hex(0x0A0C11)
        val hairline = Rgba(1.0, 1.0, 1.0, 0.08)

        val textPrimary = Rgba(1.0, 1.0, 1.0, 0.96)
        val textSecondary = Rgba(1.0, 1.0, 1.0, 0.70)
        val textTertiary = Rgba(1.0, 1.0, 1.0, 0.50)
        val textQuiet = Rgba(1.0, 1.0, 1.0, 0.38)

        /** Text drawn on the bright teal-to-sky and amber fills. */
        val onBright = Rgba.hex(0x06141A)

        // Status colours. Red appears only for irreversible things (and the hold ring); amber means "needs you" / "looks stuck".
        val red = Rgba.hex(0xF26D6D)
        val amber = Rgba.hex(0xF5B14C)
        val yellow = Rgba.hex(0xF2C94C)
        val green = Rgba.hex(0x34D399)
        val teal = Rgba.hex(0x5EEAD4)
        val sky = Rgba.hex(0x38BDF8)
        val violet = Rgba.hex(0xA78BFA)

        /** The tint of a glass card's optional glow (see `CardGlow`). */
        val glass = Rgba.hex(0x5FD0C8)

        /** Star white: the pulse when everything is quiet. */
        val star = Rgba.hex(0xFFF6E0)

        val white = Rgba(1.0, 1.0, 1.0, 1.0)
    }

    // MARK: type (Roboto / Droid Sans Mono, in sp so the user's font size applies)

    object Typo {
        private val monoFamily = FontFamily.Monospace

        /** "2 need you": the Horizon sentence. */
        val hero = TextStyle(fontSize = 32.sp, lineHeight = 36.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.4).sp)

        /** A card title: "Delete every Dev build?". */
        val headline = TextStyle(fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.Bold)
        val title = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold)
        val subline = TextStyle(fontSize = 16.sp, lineHeight = 22.sp, fontWeight = FontWeight.Normal)
        val body = TextStyle(fontSize = 15.sp, lineHeight = 21.sp, fontWeight = FontWeight.Normal)
        val bodyStrong = TextStyle(fontSize = 15.sp, lineHeight = 21.sp, fontWeight = FontWeight.SemiBold)
        val button = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold)
        val caption = TextStyle(fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.Normal)
        val captionStrong = TextStyle(fontSize = 12.sp, lineHeight = 16.sp, fontWeight = FontWeight.SemiBold)

        /** Commands and session names. */
        val mono = TextStyle(fontSize = 16.sp, lineHeight = 22.sp, fontFamily = monoFamily, fontWeight = FontWeight.SemiBold)
        val monoBody = TextStyle(fontSize = 13.sp, lineHeight = 18.sp, fontFamily = monoFamily, fontWeight = FontWeight.Normal)
        val monoSmall = TextStyle(fontSize = 12.sp, lineHeight = 16.sp, fontFamily = monoFamily, fontWeight = FontWeight.Medium)
        val monoMicro = TextStyle(fontSize = 11.sp, lineHeight = 15.sp, fontFamily = monoFamily, fontWeight = FontWeight.Medium)

        /** Small all-caps tracked label: IRREVERSIBLE, DECIDE. */
        val label = TextStyle(fontSize = 11.sp, lineHeight = 14.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = 1.0.sp)
        val labelLarge = TextStyle(fontSize = 13.sp, lineHeight = 17.sp, fontWeight = FontWeight.Bold)
    }

    // MARK: space and shape

    object Space {
        val xs = 4.dp
        val sm = 8.dp
        val md = 12.dp
        val lg = 16.dp
        val xl = 20.dp
        val xxl = 28.dp

        /** Side gutter of the Now stream. */
        val gutter = 16.dp
    }

    object Radius {
        val card = 22.dp
        val row = 18.dp
        val inset = 14.dp
        val button = 16.dp
        val chip = 6.dp
        val capsule = 32.dp
    }

    /** Minimum height of a Night Watch button (iOS 52 pt; Android's touch target floor is 48 dp). */
    val buttonHeight = 52.dp
}

// MARK: - aurora

/**
 * Colours and strength of a header aurora. `intensity` 0 draws only the sky (dusk has no curtains).
 */
@Immutable
data class AuroraPalette(
    val c1: Rgba,
    val c2: Rgba,
    val c3: Rgba,
    /** Top and bottom of the sky behind the curtains. */
    val skyTop: Rgba,
    val skyBottom: Rgba,
    val intensity: Double,
    /** Curtain speed (1 = the boards' u_speed 0.4). */
    val speed: Double,
) {
    /** Part-way from this palette to [other] (0 = self, 1 = other): how the aurora settles after the last item clears, fades to dusk and comes back at dawn, as one sky rather than a cut. */
    fun mixed(other: AuroraPalette, t: Double): AuroraPalette {
        val k = t.coerceIn(0.0, 1.0)
        if (k == 0.0) return this
        if (k == 1.0) return other
        return AuroraPalette(
            c1.mixed(other.c1, k), c2.mixed(other.c2, k), c3.mixed(other.c3, k),
            skyTop.mixed(other.skyTop, k), skyBottom.mixed(other.skyBottom, k),
            intensity + (other.intensity - intensity) * k, speed + (other.speed - speed) * k,
        )
    }

    /**
     * The same mix, perceptually ([PerceptualMix]): how the needs-you aurora settles in the exhale. The curtains
     * keep their chroma, the sky behind them meets at a neutral night, and the light lifts a little through the
     * middle, the one long breath out. Dusk and dawn keep the plain blend.
     */
    fun mixedPerceptual(other: AuroraPalette, t: Double): AuroraPalette {
        val k = t.coerceIn(0.0, 1.0)
        if (k == 0.0) return this
        if (k == 1.0) return other
        val lift = 0.2 * Math.sin(Math.PI * k)
        return AuroraPalette(
            c1.mixedPerceptual(other.c1, k), c2.mixedPerceptual(other.c2, k), c3.mixedPerceptual(other.c3, k),
            skyTop.mixedPerceptual(other.skyTop, k, keepChroma = false), skyBottom.mixedPerceptual(other.skyBottom, k, keepChroma = false),
            intensity + (other.intensity - intensity) * k + lift, speed + (other.speed - speed) * k,
        )
    }

    companion object {
        /** Something needs you: amber. */
        val needsYou = AuroraPalette(
            Rgba.hex(0xF5B14C), Rgba.hex(0xF2C94C), Rgba.hex(0xB45309),
            Rgba.hex(0x1A1306), Rgba.hex(0x05070D), 1.0, 1.0,
        )

        /** Agents working, nothing needs you: teal over a violet tail, half strength. */
        val working = AuroraPalette(
            Rgba.hex(0x5EEAD4), Rgba.hex(0x38BDF8), Rgba.hex(0x6D5BD0),
            Rgba.hex(0x0B1B24), Rgba.hex(0x05070D), 0.5, 0.4,
        )

        /** Nothing running: the same teal, barely there. */
        val quiet = AuroraPalette(
            Rgba.hex(0x5EEAD4), Rgba.hex(0x38BDF8), Rgba.hex(0x6D5BD0),
            Rgba.hex(0x0A141C), Rgba.hex(0x05070D), 0.3, 0.3,
        )

        /** Paused for battery: a flat dusk gradient, no curtains. */
        val dusk = AuroraPalette(
            Rgba.hex(0x6D5BD0), Rgba.hex(0x3B2A6A), Rgba.hex(0x3B2A6A),
            Rgba.hex(0x3B2A6A), Rgba.hex(0x120E22), 0.0, 0.0,
        )

        /** The Mac is asleep or gone: cold slate sky, no curtains. */
        val asleep = AuroraPalette(
            Rgba.hex(0x4B5670), Rgba.hex(0x2B3550), Rgba.hex(0x2B3550),
            Rgba.hex(0x182033), Rgba.hex(0x05070D), 0.0, 0.0,
        )

        /** Something needs fixing (relay, pairing): a low amber glow. */
        val problem = AuroraPalette(
            Rgba.hex(0xB07A2C), Rgba.hex(0x6B4A18), Rgba.hex(0x4A3010),
            Rgba.hex(0x1F1608), Rgba.hex(0x05070D), 0.28, 0.2,
        )

        /**
         * The mood's aurora at a time of day ([DaypartTone]): the hour sets the curtains and the sky, the mood their
         * strength. Nighttime is the statics above, exactly. Needs-you keeps its amber curtains at every hour (only
         * its sky takes the hour's hue); dusk is never tinted.
         */
        fun of(mood: NowModel.Mood, daypart: DaypartWeights = DaypartWeights.NIGHTTIME): AuroraPalette {
            if (mood == NowModel.Mood.DUSK) return dusk
            if (daypart.only == Daypart.NIGHTTIME) {
                return when (mood) {
                    NowModel.Mood.NEEDS_YOU -> needsYou
                    NowModel.Mood.WORKING -> working
                    else -> quiet
                }
            }
            val tone = DaypartTone.blended(daypart)
            return of(
                when (mood) {
                    NowModel.Mood.NEEDS_YOU -> tone.needsYou
                    NowModel.Mood.WORKING -> tone.working
                    else -> tone.quiet
                },
            )
        }

        fun of(a: DaypartTone.Aurora): AuroraPalette {
            fun c(x: DaypartTone.Colour) = Rgba(x.r, x.g, x.b)
            return AuroraPalette(c(a.c1), c(a.c2), c(a.c3), c(a.skyTop), c(a.skyBottom), a.intensity, a.speed)
        }

        /** The sunrise the dawn sweeps in: gold over a warm brown, no curtains of its own (the light is the sweep). Board 07, "power · dawn". (iOS NWDuskDawn.swift.) */
        val dawn = AuroraPalette(
            Rgba.hex(0xF5B14C), Rgba.hex(0xF2C94C), Rgba.hex(0x8A5A22),
            Rgba.hex(0x6B4F2A), Rgba.hex(0x0B0A0C), 0.25, 0.3,
        )

        /** Paused for battery, settled: the dusk gone to near-black, horizon only (board 07, "paused · horizon only"). The same values as the Mac's and the iPhone's. */
        val night = AuroraPalette(
            Rgba.hex(0x2A2440), Rgba.hex(0x16131F), Rgba.hex(0x16131F),
            Rgba.hex(0x0B0B14), Rgba.hex(0x07080D), 0.0, 0.0,
        )

        /** The Brief's sunrise: the working palette, as bright as the absence was productive. */
        fun brief(sunrise: Double): AuroraPalette = working.copy(intensity = 0.25 + 0.75 * sunrise.coerceIn(0.0, 1.0), speed = 0.4)
    }

    /**
     * The sky [duskMix] (0..1) of the way from this palette into the night: the purple dusk half way (board 07,
     * "cutoff · dusk falls"), near-black by the end. The Mac's and the iPhone's are the same.
     */
    fun towardNight(duskMix: Double): AuroraPalette {
        val d = duskMix.coerceIn(0.0, 1.0)
        return if (d < 0.5) mixed(dusk, d * 2) else dusk.mixed(night, (d - 0.5) * 2)
    }
}

/** What is left of the background star field once paused (it fades with the dusk). */
const val PAUSED_STAR_FIELD = 0.05

/**
 * The background star field [duskMix] (0..1) into the dusk, [from] the hour's own ([DaypartWeights.stars]; 1 at
 * night). A lerp, so a settled pause shows the same few stars at every hour, even from an afternoon that had none.
 */
fun starField(duskMix: Double, from: Double = 1.0): Double = from + (PAUSED_STAR_FIELD - from) * duskMix.coerceIn(0.0, 1.0)
