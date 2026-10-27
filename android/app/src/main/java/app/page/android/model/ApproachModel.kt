package app.page.android.model

import kotlin.math.min

/**
 * Port of iOS/Page/Models/ApproachModel.swift. FINAL APPROACH: a new decision descends from the pulse into its
 * ranked slot on spring(response 0.5, damping 0.8), trailing a faint contrail; it lands at about 360 ms and by
 * 520 ms has settled and its glow is off. In flight it is an empty outline (as board 07 draws it), growing out of
 * the pulse; its words fade in only as it lands, so they are never drawn over the Horizon's headline or the
 * Runway. The Mac's `ApproachModel` uses the same `content` curve. Only the cards below its slot move, easing
 * down by exactly one card height on the same spring; nothing above moves. While a finger is on the stream
 * nothing arrives at all: new rows wait behind the "New ↑ 1" pill ([StableOrder]), and the approach plays when
 * the pill is tapped.
 *
 * Pure: [frame] is the whole choreography at any moment.
 */
object ApproachModel {
    const val response = 0.5
    const val damping = 0.8

    /** Board 07: leaves the pulse at 0, contrail at 180, lands at 360, settled at 520. */
    const val lands: Double = 0.36
    const val duration: Double = 0.52

    /** When several rows arrive together, each leaves this long after the last. */
    const val stagger: Double = 0.09

    /** More than this many arrivals at once just appear (a flood is not news). */
    const val maxAnimated = 3

    /** The card's content fades in over this stretch of its travel (about 200 to 290 ms): before it, the card is only its outline. */
    const val contentFrom = 0.8
    const val contentTo = 0.97

    /** The outline leaves the pulse this small and has grown to the card's size by the time its content starts to show. */
    const val startScale = 0.35

    data class Frame(
        /** 0 at the pulse .. 1 in the slot (the spring; overshoots a hair). */
        val travel: Double,
        /** The outline grows from [startScale] as it comes down (it leaves the pulse small), and is full size before any content shows. */
        val scale: Double,
        /** The whole arrival's alpha: it fades up as it leaves the pulse. */
        val opacity: Double,
        /** 0..1 how much of the card's content shows. */
        val content: Double,
        /** 0..1 strength of the outline that stands in for the card in flight. */
        val edge: Double,
        /** The contrail from the pulse to the card's top edge: 0..1 alpha. */
        val contrail: Double,
        /** The amber glow round the card: up as it leaves, off once settled. */
        val glow: Double,
        val finished: Boolean,
    )

    /** How much of the card shows at [travel] (0 = on the pulse, 1 = in its slot). Pure. */
    fun content(travel: Double): Double = MotionCurve.smooth(MotionCurve.progress(travel, contentFrom, contentTo))

    /** The arriving card at [t] seconds. Pure. */
    fun frame(t: Double): Frame {
        if (!(t < duration)) return Frame(1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0, true)
        val x = MotionCurve.spring(t, response, damping)
        val fadeIn = MotionCurve.easeOut(t / 0.12)
        val content = content(x)
        val grown = MotionCurve.easeOut(MotionCurve.clamp01(x) / contentFrom)
        // The contrail draws in as the card leaves and fades from landing to settled.
        val contrail = min(MotionCurve.easeOut(t / 0.12), 1 - MotionCurve.smooth(MotionCurve.progress(t, lands, duration)))
        val glow = min(MotionCurve.easeOut(t / 0.18), 1 - MotionCurve.smooth(MotionCurve.progress(t, lands, duration)))
        // Faint but there as it leaves the pulse (board 07, "0 ms · leaves pulse").
        return Frame(
            x, startScale + (1 - startScale) * grown, 0.4 + 0.6 * fadeIn,
            content, 0.6 * (1 - content), maxOf(0.0, contrail) * 0.8, maxOf(0.0, glow), false,
        )
    }

    /** Vertical offset of the arriving card from its slot (negative is up), [distance] points below the pulse. Pure. */
    fun offset(distance: Double, elapsed: Double): Double = -distance * (1 - frame(elapsed).travel)

    /**
     * Offset of a card below the slot: it starts one card height up (where it was) and eases down on the same
     * spring. [height] is the arriving card's height plus the stack's spacing. Pure.
     */
    fun pushOffset(height: Double, elapsed: Double): Double {
        if (!(elapsed < duration)) return 0.0
        return -height * (1 - MotionCurve.spring(elapsed, response, damping))
    }

    /**
     * The ids that just arrived: in [current] but not in [previous]. Nothing arrives on the first look
     * ([previous] null), so a launch is not a flood of approaches. Order follows [current]. Pure.
     */
    fun arrivals(previous: List<String>?, current: List<String>): List<String> {
        if (previous == null) return emptyList()
        val known = previous.toSet()
        return current.filter { it !in known }
    }

    /** When each arrival leaves the pulse, [stagger] apart from [start], in rank order. Beyond [maxAnimated] they get no approach (empty). Pure. */
    fun schedule(ids: List<String>, start: Double): Map<String, Double> {
        if (ids.size > maxAnimated) return emptyMap()
        val out = LinkedHashMap<String, Double>()
        for ((i, id) in ids.withIndex()) out[id] = start + i * stagger
        return out
    }
}
