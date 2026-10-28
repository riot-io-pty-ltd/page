package app.page.android.model

import java.time.Instant

/**
 * Port of iOS/Page/Models/ReceiptThread.swift. THE RECEIPT THREAD: delivery truth made visible, the same on
 * every surface. Three nodes, the card (phone), the relay and the Mac, joined by a thin thread of light:
 *
 * - ARM (0-1.2 s): a ring winds round the card's dot. Nothing has left the phone; a tap cancels. (An Irreversible
 *   approve's hold plus biometrics is its arm, so it starts at SEND.)
 * - SEND: the thread leaves the card. While the request is in flight it reaches towards the relay; once the relay
 *   has it ("sent") it rests at the relay node and only a faint glint travels on. It cannot be cancelled, and
 *   nothing says it can.
 * - RESOLVE, only when the Mac confirms the keystroke landed ([ReplyDelivery.Delivered]): the thread runs on to
 *   the Mac ("typed"), then "verified ✓"; the dot turns from amber to teal, its rings contract into it, and a card
 *   that has left the stream folds into a hairline and drifts into Settled. The phone has no separate "typed"
 *   report, so "typed" and "verified" are both played after the one confirmation, in order, and never on a timer
 *   before it.
 * - FAILURE (failed, answered at the Mac, prompt closed, a local problem): the thread snaps back, the card shakes
 *   once, softly, and the outcome is said in words.
 *
 * Pure: [derive] maps the real delivery state and the seconds since it last changed to a frame.
 */
data class ReceiptThread(
    val stage: Stage,
    /** The arm ring round the dot, 0..1. */
    val arm: Double = 0.0,
    /** How far the solid thread reaches: 0 at the card, 0.5 at the relay, 1 at the Mac. */
    val reach: Double = 0.0,
    /** A faint glint travelling past the relay while the Mac is awaited (0.5..1), else null. */
    val glint: Double? = null,
    /** The relay node is lit (it has the reply). */
    val relayLit: Boolean = false,
    /** The Mac node is lit (it confirmed). */
    val macLit: Boolean = false,
    /** The card's dot: 0 amber .. 1 teal. */
    val dotTeal: Double = 0.0,
    /** The dot's rings: 1 open .. 0 contracted into the dot. */
    val rings: Double = 1.0,
    /** A card that has left the stream folds into a hairline: 0 .. 1. */
    val fold: Double = 0.0,
    /** ...then drifts down into Settled and fades: 0 .. 1. */
    val drift: Double = 0.0,
    /** One soft shake: -1 .. 1 (multiply by a few points). */
    val shake: Double = 0.0,
    /** The stage in the board's words: "arm", "sent", "typed", "verified ✓", or the failure in words. */
    val word: String = "",
    /** Something on it is still moving: the view needs a clock. */
    val moving: Boolean = false,
) {
    sealed interface Stage {
        data object Idle : Stage
        data object Arming : Stage

        /** The request is on its way to the relay. */
        data object Sending : Stage

        /** The relay has it; waiting on the Mac. */
        data object Sent : Stage

        /** The relay holds it until the Mac is back online. */
        data object Queued : Stage

        /** A delete is waiting for its answer. */
        data object Deleting : Stage

        /** Deleted before anything was typed: the thread has snapped back, and says so. */
        data object Deleted : Stage

        /** The Mac holds it until a rate limit resets. */
        data object Held : Stage

        /** Confirmed by the Mac: the thread has reached it. */
        data object Typed : Stage

        /** Confirmed by the Mac, and the receipt has settled. */
        data object Verified : Stage
        data class Failed(val why: String) : Stage
    }

    val isSuccess: Boolean get() = stage == Stage.Typed || stage == Stage.Verified
    val isFailure: Boolean get() = stage is Stage.Failed

    companion object {
        // MARK: timings

        /** SEND: the thread reaches towards the relay over this long. */
        const val reachRelay: Double = 0.5

        /** RESOLVE: relay to Mac ("typed") ... */
        const val reachMac: Double = 0.36

        /** ... "verified ✓" ... */
        const val verifiedAt: Double = 0.6

        /** ... the dot turns teal and its rings contract by ... */
        const val contracted: Double = 1.0

        /** ... the card folds into a hairline by ... */
        const val folded: Double = 1.3

        /** ... and has drifted into Settled by. */
        const val resolveDuration: Double = 1.6

        /** FAILURE: snap back and shake. */
        const val snapBack: Double = 0.24
        const val shakeDuration: Double = 0.42

        /** The glint stops travelling after this long (the words carry on). */
        const val glintFor: Double = 12.0
        const val glintPeriod: Double = 1.4

        // MARK: derive

        /**
         * The thread for one action. [changedAt] is when the delivery last changed on this phone
         * (`RelayClient.deliveryTimes`); unknown means the change is old news and the frame is drawn settled.
         * Success is only ever drawn from Delivered. Pure.
         */
        fun derive(pending: PendingAction?, delivery: ReplyDelivery?, localProblem: String? = null, changedAt: Instant?, now: Instant): ReceiptThread {
            val since = changedAt?.let { maxOf(0.0, now.secondsSince(it)) } ?: Double.POSITIVE_INFINITY
            if (localProblem != null) return failed(localProblem, since)
            val phase = pending?.phase(now)
            if (pending != null && phase is PendingAction.Phase.Arming) {
                return ReceiptThread(Stage.Arming, arm = phase.progress, word = "arm", moving = true)
            }
            return when (delivery) {
                null -> {
                    if (pending == null) return ReceiptThread(Stage.Idle)
                    // Fired, and the request has not been answered yet. An approve behind biometrics sent the
                    // moment it passed; anything else sent when its arm ran out.
                    val biometric = ActionGate.requiresBiometrics(pending.kind, pending.commit)
                    val start = if (biometric) pending.startedAt else pending.startedAt.plusSeconds(ArmSpec.duration)
                    sending(maxOf(0.0, now.secondsSince(start)))
                }
                ReplyDelivery.Sending -> sending(since)
                is ReplyDelivery.Sent -> {
                    if (delivery.queued) return ReceiptThread(Stage.Queued, arm = 1.0, reach = 0.5, relayLit = true, word = "queued · Mac offline")
                    val waited = maxOf(0.0, now.secondsSince(delivery.at))
                    val moving = waited < glintFor
                    val glint = if (moving) 0.5 + 0.5 * (waited / glintPeriod).rem(1.0) else null
                    ReceiptThread(
                        Stage.Sent, arm = 1.0, reach = 0.5, glint = glint, relayLit = true,
                        word = if (waited > ReplyConfirmation.SLOW_AFTER) "sent · waiting for your Mac" else "sent", moving = moving,
                    )
                }
                is ReplyDelivery.Delivered -> resolved(since)
                is ReplyDelivery.Failed -> failed(delivery.message.ifEmpty { "Couldn't deliver the reply" }, since)
                ReplyDelivery.AlreadyReplied -> failed("Already answered at the Mac", since)
                ReplyDelivery.Gone -> failed("Prompt closed before your answer", since)
                ReplyDelivery.Retracting -> sending(since).copy(stage = Stage.Deleting, word = "deleting")
                is ReplyDelivery.Retracted -> deleted(since)
                is ReplyDelivery.HeldOnMac -> ReceiptThread(Stage.Held, arm = 1.0, reach = 0.5, relayLit = true, word = "held on your Mac")
            }
        }

        /** DELETED, [t] seconds after: the thread snaps back, quietly (no shake: nothing went wrong). */
        fun deleted(t: Double): ReceiptThread {
            val reach = 0.5 * (1 - MotionCurve.easeIn(t / snapBack))
            return ReceiptThread(Stage.Deleted, arm = 0.0, reach = reach, word = "deleted · not sent", moving = t < snapBack)
        }

        fun sending(t: Double): ReceiptThread {
            // It reaches towards the relay but never touches it until the relay answers.
            val r = 0.42 * MotionCurve.easeOut(t / reachRelay)
            return ReceiptThread(Stage.Sending, arm = 1.0, reach = r, word = "sending", moving = t < reachRelay)
        }

        /** RESOLVE, [t] seconds after the Mac's confirmation reached the phone. Pure. */
        fun resolved(t: Double): ReceiptThread {
            val reach = 0.5 + 0.5 * MotionCurve.easeOut(t / reachMac)
            val teal = MotionCurve.smooth(MotionCurve.progress(t, verifiedAt, contracted))
            val fold = MotionCurve.smooth(MotionCurve.progress(t, contracted, folded))
            val drift = MotionCurve.easeIn(MotionCurve.progress(t, 1.15, resolveDuration))
            val verified = t >= verifiedAt
            return ReceiptThread(
                if (verified) Stage.Verified else Stage.Typed, arm = 1.0, reach = reach, relayLit = true, macLit = t >= reachMac,
                dotTeal = teal, rings = 1 - teal, fold = fold, drift = drift,
                word = if (verified) "verified ✓" else "typed", moving = t < resolveDuration,
            )
        }

        /** FAILURE, [t] seconds after it was reported. Pure. */
        fun failed(why: String, t: Double): ReceiptThread {
            val reach = 0.5 * (1 - MotionCurve.easeIn(t / snapBack))
            return ReceiptThread(
                Stage.Failed(why), arm = 0.0, reach = reach, shake = MotionCurve.shake(t, shakeDuration),
                word = why, moving = t < maxOf(snapBack, shakeDuration),
            )
        }
    }
}

/** Everything a card's thread is drawn from, so a view can re-derive the frame on its own clock while something moves. */
data class ReceiptThreadInput(
    val pending: PendingAction?,
    val delivery: ReplyDelivery?,
    val localProblem: String? = null,
    /** When the delivery last changed on this phone. */
    val changedAt: Instant? = null,
) {
    /** Nothing to draw: no action under way and no delivery news. */
    val isEmpty: Boolean get() = pending == null && delivery == null && localProblem == null

    fun frame(now: Instant): ReceiptThread = ReceiptThread.derive(pending, delivery, localProblem, changedAt, now)

    /** Until when the thread keeps moving (a view runs a clock until then and no longer); null or a past date when it is still. Pure. */
    fun movingUntil(now: Instant): Instant? {
        val t = ReceiptThread
        if (localProblem != null) return changedAt?.plusSeconds(maxOf(t.snapBack, t.shakeDuration))
        if (pending != null && pending.phase(now) is PendingAction.Phase.Arming) return pending.startedAt.plusSeconds(ArmSpec.duration)
        return when (delivery) {
            null -> {
                val p = pending ?: return null
                val biometric = ActionGate.requiresBiometrics(p.kind, p.commit)
                (if (biometric) p.startedAt else p.startedAt.plusSeconds(ArmSpec.duration)).plusSeconds(t.reachRelay)
            }
            ReplyDelivery.Sending -> changedAt?.plusSeconds(t.reachRelay)
            is ReplyDelivery.Sent -> if (delivery.queued) null else delivery.at.plusSeconds(t.glintFor)
            is ReplyDelivery.Delivered -> changedAt?.plusSeconds(t.resolveDuration)
            is ReplyDelivery.Failed, ReplyDelivery.AlreadyReplied, ReplyDelivery.Gone -> changedAt?.plusSeconds(maxOf(t.snapBack, t.shakeDuration))
            ReplyDelivery.Retracting -> changedAt?.plusSeconds(t.reachRelay)
            is ReplyDelivery.Retracted -> changedAt?.plusSeconds(t.snapBack)
            is ReplyDelivery.HeldOnMac -> null
        }
    }
}

/**
 * A card whose reply the Mac just confirmed leaves the inbox at the same moment (the page closes as "replied"),
 * which would cut the RESOLVE short. Such a row stays in the stream as a ghost, in its old place, for the length
 * of the resolve, then goes. Pure.
 */
object DepartingRows {
    data class Merged(val rows: List<NowRow>, val ghosts: Set<String>)

    /**
     * [previous] is the stream as last drawn; [current] the fresh one. A row that left with a confirmed delivery
     * changed less than [ReceiptThread.resolveDuration] ago comes back at its old index. Returns the rows to draw
     * and the ids that are ghosts.
     */
    fun merge(previous: List<NowRow>, current: List<NowRow>, deliveries: Map<String, ReplyDelivery>, changedAt: Map<String, Instant>, now: Instant): Merged {
        val live = current.map { it.id }.toSet()
        val rows = current.toMutableList()
        val ghosts = LinkedHashSet<String>()
        for ((index, row) in previous.withIndex()) {
            if (row.id in live) continue
            if (deliveries[row.id] !is ReplyDelivery.Delivered) continue
            val at = changedAt[row.id] ?: continue
            val age = now.secondsSince(at)
            if (!(age >= 0 && age < ReceiptThread.resolveDuration)) continue
            rows.add(minOf(index, rows.size), row)
            ghosts.add(row.id)
        }
        return Merged(rows, ghosts)
    }

    /** When the next ghost expires, for a timer: null with none. Pure. */
    fun nextExpiry(ghosts: Set<String>, changedAt: Map<String, Instant>): Instant? =
        ghosts.mapNotNull { changedAt[it]?.plusSeconds(ReceiptThread.resolveDuration) }.minOrNull()
}
