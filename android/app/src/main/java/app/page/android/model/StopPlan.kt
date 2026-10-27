package app.page.android.model

// Port of iOS/Page/Models/StopPlan.swift. The pulse: one verb. A tap starts
// Dispatch; a long press is the Stop ring. These are the pure decisions behind
// it. The hold ring itself is `HoldRingSpec.stopAll` (300 ms dead zone, 1.2 s
// fill, ticks at 25/50/75% and a firm one at full, then biometrics); this adds
// what a press means and what Stop-all will do.

/** What a press on the pulse means, judged by how long it was held. */
enum class PulsePress {
    /** Released inside the dead zone: a tap, which opens Dispatch. */
    TAP,

    /** Held past the dead zone but let go before the ring filled: the ring unwinds, nothing is sent, and Dispatch does not open either. */
    ABANDONED_HOLD,

    /** The ring filled: ask for the fingerprint / face / device credential next. */
    COMPLETED_HOLD;

    companion object {
        /** The outcome of a press released after [held] seconds. Pure. */
        fun onRelease(held: Double, spec: HoldRingSpec = HoldRingSpec.stopAll): PulsePress {
            if (spec.isComplete(held)) return COMPLETED_HOLD
            return if (spec.isVisible(held)) ABANDONED_HOLD else TAP
        }
    }
}

/**
 * What Stop-all will do right now: press Esc in every busy session. The scope is named on the ring and again
 * in the biometric sheet, so a mis-hold costs two deliberate steps. With nothing busy, nothing can be sent.
 */
data class StopPlan(
    /** Sessions the Mac reports as working (Esc interrupts a turn). */
    val busy: Int,
    /** "Press Esc in 4 busy sessions on Studio MBP". */
    val scope: String,
    /** The reason shown in the biometric sheet. */
    val biometricReason: String,
    /** Nothing busy, or the Mac cannot be reached: the ring says so instead of arming. */
    val canStop: Boolean,
    /** Why Stop is unavailable, when it is. */
    val blocker: String?,
    /** Names of up to three busy sessions, for the confirmation ("bottle-flip, relay, +2"). */
    val names: String,
) {
    companion object {
        fun build(sessions: List<LiveSession>, hasSessionList: Boolean, workingFromStatus: Int? = null, macName: String = ""): StopPlan {
            val busy = sessions.filter { it.state == LiveSessionState.ACTIVE }
            // Before the list arrives, the heartbeat's working count is the only scope there is, and Stop-all still reaches them.
            val count = if (hasSessionList) busy.size else (workingFromStatus ?: 0)
            var names = busy.take(3).joinToString(", ") { it.title }
            if (busy.size > 3) names += ", +${busy.size - 3}"
            return StopPlan(
                busy = count, scope = HoldRingSpec.stopScope(count, macName),
                biometricReason = HoldRingSpec.biometricReasonStopping(count, macName),
                canStop = count > 0, blocker = if (count > 0) null else "Nothing is working right now", names = names,
            )
        }
    }
}

/** The result of a Stop-all, in words. */
sealed interface StopOutcome {
    data object Asked : StopOutcome
    data object NothingBusy : StopOutcome
    data object Cancelled : StopOutcome
    data class Unavailable(val why: String) : StopOutcome
    data class Failed(val why: String) : StopOutcome

    val message: String
        get() = when (this) {
            Asked -> "Asked your Mac to stop your working agents."
            NothingBusy -> "Nothing was working, so nothing was sent."
            Cancelled -> "Cancelled. Nothing was sent."
            is Unavailable -> why
            is Failed -> why
        }

    /** Only a send the relay accepted is "asked"; the Mac's own answer comes later. */
    val isSuccess: Boolean get() = this == Asked
}

/**
 * What the Stop overlay is showing. The ring appears after 300 ms, fills over 1.2 s, then the fingerprint /
 * face / device credential asks, naming the scope.
 */
sealed interface StopFlowPhase {
    data object Idle : StopFlowPhase

    /** The ring is drawn, 0..1. */
    data class Holding(val progress: Double) : StopFlowPhase

    /** The ring filled; the owner is being asked. */
    data object Authenticating : StopFlowPhase
    data object Sending : StopFlowPhase
    data class Result(val outcome: StopOutcome) : StopFlowPhase

    val isActive: Boolean get() = this != Idle
}
