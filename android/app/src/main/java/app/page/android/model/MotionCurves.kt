package app.page.android.model

import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

// Port of iOS/Page/Models/MotionCurves.swift. The curves the signature
// motions share, as plain maths so a frame at any time can be computed (and
// tested) without running an animation. The views use the same numbers, so a
// frame the render harness pins at 180 ms is the frame the phone shows at 180 ms.

object MotionCurve {
    /** 0..1, clamped. */
    fun clamp01(x: Double): Double = min(1.0, max(0.0, x))

    /** Where [t] falls between [start] and [end], clamped to 0..1. Pure. */
    fun progress(t: Double, start: Double, end: Double): Double {
        if (!(end > start)) return if (t >= end) 1.0 else 0.0
        return clamp01((t - start) / (end - start))
    }

    /** Smoothstep: eases in and out with zero slope at both ends. Pure. */
    fun smooth(x: Double): Double {
        val t = clamp01(x)
        return t * t * (3 - 2 * t)
    }

    /** Ease out (cubic): fast start, gentle landing. Pure. */
    fun easeOut(x: Double): Double {
        val t = 1 - clamp01(x)
        return 1 - t * t * t
    }

    /** Ease in (cubic): gentle start, fast finish. Pure. */
    fun easeIn(x: Double): Double {
        val t = clamp01(x)
        return t * t * t
    }

    /**
     * The step response of a spring with a response (period of the undamped spring) and a damping fraction:
     * 0 at t = 0, settling on 1 (an underdamped spring overshoots a little first). Pure.
     */
    fun spring(t: Double, response: Double, damping: Double): Double {
        if (!(t > 0)) return 0.0
        if (!(response > 0)) return 1.0
        val omega = 2 * PI / response
        val zeta = max(0.0, damping)
        if (zeta >= 1) {
            // Critically damped (and over): no overshoot.
            return 1 - exp(-omega * t) * (1 + omega * t)
        }
        val decay = zeta * omega
        val wd = omega * sqrt(1 - zeta * zeta)
        return 1 - exp(-decay * t) * (cos(wd * t) + (decay / wd) * sin(wd * t))
    }

    /** One soft shake: a decaying sine, -1..1, over [duration] seconds (two swings), 0 before and after. Pure. */
    fun shake(t: Double, duration: Double = 0.42): Double {
        if (!(t > 0 && t < duration)) return 0.0
        val x = t / duration
        return sin(x * 2 * 2 * PI) * (1 - x) * (1 - x)
    }
}

/**
 * Colour blends for the exhale, through OKLCH (lightness, chroma, hue) the shorter way round the hue wheel.
 * A plain sRGB blend between two colours from opposite sides of the wheel, amber and teal, sinks through khaki
 * and grey half way; this one keeps its chroma, so amber turns to teal by way of an aurora green. Pure;
 * channels are sRGB 0..1. The Mac and the iPhone have the same function.
 */
object PerceptualMix {
    data class Rgb(val r: Double, val g: Double, val b: Double)
    data class Lab(val l: Double, val a: Double, val b: Double)

    /** Below this chroma a colour has no hue worth keeping (greys, star-white): it takes the other colour's. */
    const val achromatic = 0.02

    /**
     * [t] (clamped to 0..1) of the way from [a] to [b]; exactly [a] at 0 and [b] at 1. Out-of-gamut results are
     * clipped to 0..1. With [keepChroma] false it is a straight line through Oklab instead, which suits the
     * near-black sky behind the curtains. Pure.
     */
    fun mix(a: Rgb, b: Rgb, t: Double, keepChroma: Boolean = true): Rgb {
        val k = MotionCurve.clamp01(t)
        if (k <= 0) return a
        if (k >= 1) return b
        val p = oklab(a)
        val q = oklab(b)
        if (!keepChroma) {
            return srgb(p.l + (q.l - p.l) * k, p.a + (q.a - p.a) * k, p.b + (q.b - p.b) * k)
        }
        val ca = sqrt(p.a * p.a + p.b * p.b)
        val cb = sqrt(q.a * q.a + q.b * q.b)
        var ha = atan2(p.b, p.a)
        var hb = atan2(q.b, q.a)
        if (ca < achromatic) ha = hb
        if (cb < achromatic) hb = ha
        var dh = hb - ha
        if (dh > PI) dh -= 2 * PI
        if (dh < -PI) dh += 2 * PI
        val l = p.l + (q.l - p.l) * k
        val c = ca + (cb - ca) * k
        val h = ha + dh * k
        return srgb(l, c * cos(h), c * sin(h))
    }

    /** sRGB 0..1 to Oklab. Pure. */
    fun oklab(c: Rgb): Lab {
        fun lin(x: Double): Double = if (x <= 0.04045) x / 12.92 else ((x + 0.055) / 1.055).pow(2.4)
        val r = lin(c.r)
        val g = lin(c.g)
        val b = lin(c.b)
        val l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        val m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        val s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return Lab(
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
        )
    }

    /** Oklab to sRGB 0..1, clipped to the gamut. Pure. */
    fun srgb(l: Double, a: Double, b: Double): Rgb {
        fun enc(x: Double): Double {
            val v = MotionCurve.clamp01(x)
            return if (v <= 0.0031308) 12.92 * v else 1.055 * v.pow(1 / 2.4) - 0.055
        }
        val l3 = (l + 0.3963377774 * a + 0.2158037573 * b).pow(3)
        val m3 = (l - 0.1055613458 * a - 0.0638541728 * b).pow(3)
        val s3 = (l - 0.0894841775 * a - 1.2914855480 * b).pow(3)
        return Rgb(
            enc(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
            enc(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
            enc(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3),
        )
    }
}
