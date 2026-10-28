package app.page.android.model

import kotlin.math.max
import kotlin.math.min

/**
 * Port of iOS/Page/Models/HoldRing.swift. The press-and-hold ring that commits the two deliberate actions: an
 * Irreversible approve and Stop-all (the pulse's long press). Pure timing and copy, so the views only draw it
 * and the tests drive it with elapsed times.
 *
 * Trust model (board 07, "The hold ring"): nothing is drawn for 300 ms, then the ring fills clockwise over
 * 1.2 s, amber warming to red only in its final third, with haptic ticks at 25%, 50% and 75% and a firmer one
 * when full; then biometrics, and a burst once they pass. Letting go early unwinds the ring backwards and
 * nothing is sent. (The spec's prose says ticks at 33/66/100%; the board's 25/50/75% wins, with 100% kept as
 * the completion haptic.)
 */
data class HoldRingSpec(
    /** Nothing happens (and nothing is drawn) for this long, so a slow tap never starts a ring. */
    val deadZone: Double,
    /** Time to fill from empty to full once the dead zone has passed. */
    val fill: Double,
) {
    /** Progress 0..1 after holding for [elapsed]. Pure. */
    fun progress(elapsed: Double): Double {
        if (!(elapsed > deadZone)) return 0.0
        return min(1.0, (elapsed - deadZone) / fill)
    }

    /** True once the ring is drawn at all. */
    fun isVisible(elapsed: Double): Boolean = elapsed > deadZone

    fun isComplete(elapsed: Double): Boolean = elapsed >= deadZone + fill

    /**
     * Progress while the ring unwinds after an early release: it runs back at the speed it filled, but never
     * slower than an empty-to-full in [maxUnwind] (a 10 s Stop ring lets go in about a second, not ten).
     * [released] is the progress at release. Pure.
     */
    fun unwound(released: Double, since: Double): Double = max(0.0, released - since / min(fill, maxUnwind))

    companion object {
        /** Hold the pulse (Stop-all): appears after 300 ms, fills over 9.7 s, full at 10 s. Esc in every session is never something to do by accident. */
        val stopAll = HoldRingSpec(0.3, 9.7)

        /** The longest an unwind from full takes. */
        const val maxUnwind = 1.2

        /** Hold to approve an Irreversible action: the same ring, the same timing. */
        val irreversible = HoldRingSpec(0.3, 1.2)

        /** Where the haptic ticks fall: 25%, 50%, 75%, and the full one at 100%. */
        val ticks: List<Double> = listOf(0.25, 0.5, 0.75, 1.0)

        /** The ticks passed between two progress values (rising only). */
        fun ticksCrossed(from: Double, to: Double): List<Double> {
            if (!(to > from)) return emptyList()
            return ticks.filter { from < it - 1e-9 && to >= it - 1e-9 }
        }

        /** 0 = amber .. 1 = red. Red only in the final third. Pure. */
        fun warmth(progress: Double): Double = max(0.0, min(1.0, (progress - 2.0 / 3.0) * 3))

        // MARK: the burst

        /** How long the burst lasts once biometrics pass. */
        const val burstDuration: Double = 0.6

        data class Burst(val scale: Double, val opacity: Double, val flash: Double)

        /**
         * The burst after biometrics pass, [elapsed] seconds in: a ring of light leaves the full ring and opens
         * out (scale 1 .. 1.45) as it fades, and the core flashes once. It means "committed, sending", never
         * "delivered": the receipt thread says that. Pure.
         */
        fun burst(elapsed: Double): Burst {
            if (!(elapsed >= 0 && elapsed < burstDuration)) return Burst(1.0, 0.0, 0.0)
            val x = elapsed / burstDuration
            val flash = if (x < 0.25) MotionCurve.smooth(x / 0.25) else 1 - MotionCurve.smooth((x - 0.25) / 0.75)
            return Burst(1 + 0.45 * MotionCurve.easeOut(x), 0.9 * (1 - MotionCurve.easeIn(x)), flash)
        }

        // MARK: copy

        /** The line under the ring: "Keep holding · Face ID next" (here "Fingerprint next"). */
        fun prompt(progress: Double, biometry: String): String {
            if (progress >= 1) return "$biometry next"
            if (progress > 0) return "Keep holding · $biometry next"
            return "Hold to confirm"
        }

        /** The scope Stop-all names before biometrics: "Press Esc in 4 busy sessions". */
        fun stopScope(busy: Int): String = when {
            busy <= 0 -> "No busy sessions to stop"
            busy == 1 -> "Press Esc in 1 busy session"
            else -> "Press Esc in $busy busy sessions"
        }

        /** The same scope, naming the Mac it will act on. With nothing busy there is no Mac to name. */
        fun stopScope(busy: Int, mac: String): String =
            if (busy > 0) "${stopScope(busy)} on ${DeliveryPreview.macLabel(mac)}" else stopScope(busy)

        /** The reason shown in the biometric sheet: it names the scope and the Mac, and says what will be pressed. */
        fun biometricReasonStopping(busy: Int, mac: String): String =
            "Stop $busy busy session${if (busy == 1) "" else "s"} on ${DeliveryPreview.macLabel(mac)}. Presses Esc in each."

        fun biometricReasonApproving(subject: String, mac: String): String =
            "Approve $subject on ${DeliveryPreview.macLabel(mac)}"
    }
}
