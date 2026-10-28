import Foundation

// The curves the signature motions share, as plain maths so a frame at any
// time can be computed (and tested) without running an animation. The views
// use the same numbers as SwiftUI's own springs, so a frame the render
// harness pins at 180 ms is the frame the phone shows at 180 ms.

enum MotionCurve {
    /// 0...1, clamped.
    static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }

    /// Where `t` falls between `start` and `end`, clamped to 0...1. Pure.
    static func progress(_ t: Double, from start: Double, to end: Double) -> Double {
        guard end > start else { return t >= end ? 1 : 0 }
        return clamp01((t - start) / (end - start))
    }

    /// Smoothstep: eases in and out with zero slope at both ends. Pure.
    static func smooth(_ x: Double) -> Double {
        let t = clamp01(x)
        return t * t * (3 - 2 * t)
    }

    /// Ease out (cubic): fast start, gentle landing. Pure.
    static func easeOut(_ x: Double) -> Double {
        let t = 1 - clamp01(x)
        return 1 - t * t * t
    }

    /// Ease in (cubic): gentle start, fast finish. Pure.
    static func easeIn(_ x: Double) -> Double {
        let t = clamp01(x)
        return t * t * t
    }

    /// The step response of SwiftUI's `.spring(response:dampingFraction:)`:
    /// 0 at `t` = 0, settling on 1 (an underdamped spring overshoots a
    /// little first). `response` is the period of the undamped spring, as in
    /// SwiftUI. Pure.
    static func spring(_ t: Double, response: Double, damping: Double) -> Double {
        guard t > 0 else { return 0 }
        guard response > 0 else { return 1 }
        let omega = 2 * Double.pi / response
        let zeta = max(0, damping)
        if zeta >= 1 {
            // Critically damped (and over): no overshoot.
            return 1 - exp(-omega * t) * (1 + omega * t)
        }
        let decay = zeta * omega
        let wd = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-decay * t) * (cos(wd * t) + (decay / wd) * sin(wd * t))
    }

    /// One soft shake: a decaying sine, -1...1, over `duration` seconds
    /// (two swings), 0 before and after. Pure.
    static func shake(_ t: Double, duration: Double = 0.42) -> Double {
        guard t > 0, t < duration else { return 0 }
        let x = t / duration
        return sin(x * 2 * 2 * Double.pi) * (1 - x) * (1 - x)
    }
}

/// The clock as a shader takes it. The views run on reference-date seconds
/// (about 8.2e8 now), and a 32-bit float that large moves only in 64 s
/// steps: handed over as it is, the aurora, its stars and the pulse's ring
/// wobble stand still. Wrapped to a day where it goes into the shader it
/// moves in steps of about 8 ms, with one jump a day (at midnight UTC). The
/// clock itself is never rebased: the Horizon measures its one-shots
/// against it. The harness's small pinned times pass through unchanged.
enum ShaderClock {
    static let wrap: Double = 86_400

    /// `t` seconds as the shader's `time` argument. Pure.
    static func seconds(_ t: Double) -> Float {
        let r = t.truncatingRemainder(dividingBy: wrap)
        return Float(r < 0 ? r + wrap : r)
    }
}

/// When each one-shot first started, by key: the first ask records `now`,
/// every later ask gets that same moment back, so a motion keyed by it
/// plays once however often its view is rebuilt (the Return Brief's sunrise,
/// once per absence). Pure.
struct OneShotBook: Equatable {
    private(set) var starts: [String: Double] = [:]

    mutating func start(_ key: String, now: Double) -> Double {
        if let s = starts[key] { return s }
        starts[key] = now
        return now
    }
}

/// Colour blends for the exhale, through OKLCH (lightness, chroma, hue) the
/// shorter way round the hue wheel. A plain sRGB blend between two colours
/// from opposite sides of the wheel, amber and teal, sinks through khaki and
/// grey half way; this one keeps its chroma, so amber turns to teal by way of
/// an aurora green. Pure; channels are sRGB 0...1. The Mac has the same
/// function (Sources/ClaudePowerMode/UI/SignatureMotion.swift).
enum PerceptualMix {
    typealias RGB = (r: Double, g: Double, b: Double)

    /// Below this chroma a colour has no hue worth keeping (greys, star-white):
    /// it takes the other colour's.
    static let achromatic = 0.02

    /// `t` (clamped to 0...1) of the way from `a` to `b`; exactly `a` at 0 and
    /// `b` at 1. Out-of-gamut results are clipped to 0...1. With `keepChroma`
    /// false it is a straight line through Oklab instead, which suits the
    /// near-black sky behind the curtains: a dark brown and a dark teal meet
    /// at a neutral night, not an olive one. Pure.
    static func mix(_ a: RGB, _ b: RGB, _ t: Double, keepChroma: Bool = true) -> RGB {
        let k = MotionCurve.clamp01(t)
        if k <= 0 { return a }
        if k >= 1 { return b }
        let p = oklab(a), q = oklab(b)
        if !keepChroma {
            return srgb(l: p.l + (q.l - p.l) * k, a: p.a + (q.a - p.a) * k, b: p.b + (q.b - p.b) * k)
        }
        let ca = (p.a * p.a + p.b * p.b).squareRoot(), cb = (q.a * q.a + q.b * q.b).squareRoot()
        var ha = atan2(p.b, p.a), hb = atan2(q.b, q.a)
        if ca < achromatic { ha = hb }
        if cb < achromatic { hb = ha }
        var dh = hb - ha
        if dh > .pi { dh -= 2 * .pi }
        if dh < -.pi { dh += 2 * .pi }
        let l = p.l + (q.l - p.l) * k, c = ca + (cb - ca) * k, h = ha + dh * k
        return srgb(l: l, a: c * cos(h), b: c * sin(h))
    }

    /// sRGB 0...1 to Oklab. Pure.
    static func oklab(_ c: RGB) -> (l: Double, a: Double, b: Double) {
        func lin(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let r = lin(c.r), g = lin(c.g), b = lin(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// Oklab to sRGB 0...1, clipped to the gamut. Pure.
    static func srgb(l: Double, a: Double, b: Double) -> RGB {
        func enc(_ x: Double) -> Double {
            let v = MotionCurve.clamp01(x)
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        let l3 = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m3 = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s3 = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (enc(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
                enc(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
                enc(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3))
    }
}
