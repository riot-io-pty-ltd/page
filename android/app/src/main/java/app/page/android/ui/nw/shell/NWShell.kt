package app.page.android.ui.nw.shell

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import app.page.android.model.HoldRingSpec
import app.page.android.model.NWDestination
import app.page.android.model.StopFlowPhase
import app.page.android.model.StopPlan
import app.page.android.ui.nw.components.NWBackdrop
import app.page.android.ui.nw.components.NWNavBar
import app.page.android.ui.nw.components.NWStopOverlay
import app.page.android.ui.nw.theme.LocalReduceMotion

/**
 * The frame of the app: the night sky behind, Now or Sky in front (Sky lies to the right of Now, and they slide
 * as one sky), the bar at the bottom, and the Stop ring over everything while the pulse is held. Pure: the live
 * container and the render harness both fill it in. (iOS NWShell.swift.)
 *
 * Gesture owners: a horizontal drag on the Horizon or on a side of the bar switches destination; cards own their
 * own horizontal swipe (Undoable only); the leftmost 20 dp is the system's back gesture.
 */
@Composable
fun NWShell(
    destination: NWDestination,
    onDestinationChange: (NWDestination) -> Unit,
    decideCount: Int,
    workingCount: Int,
    modifier: Modifier = Modifier,
    /** The bar pulse's count (`NowModel.pulseWaiting`); the Decide count when null. */
    pulseWaiting: Int? = null,
    /** The oldest wait among them (the ripple's pace). */
    pulseLongestWait: Double = 0.0,
    stop: StopFlowPhase = StopFlowPhase.Idle,
    stopPlan: StopPlan,
    biometry: String = "fingerprint",
    /** Seconds the pulse has been held, null when it is not pressed. */
    held: Double? = null,
    onHeld: (Double?) -> Unit = {},
    onPulseTap: () -> Unit = {},
    onPulseHold: () -> Unit = {},
    now: @Composable () -> Unit,
    sky: @Composable () -> Unit,
    overlays: @Composable BoxScope.() -> Unit = {},
) {
    val reduce = LocalReduceMotion.current
    Box(modifier.fillMaxSize()) {
        NWBackdrop()
        AnimatedContent(
            targetState = destination,
            transitionSpec = {
                if (reduce) {
                    fadeIn(tween(0)) togetherWith fadeOut(tween(0))
                } else {
                    val toSky = targetState == NWDestination.SKY
                    (slideInHorizontally(tween(320)) { if (toSky) it / 3 else -it / 3 } + fadeIn(tween(320))) togetherWith
                        (slideOutHorizontally(tween(320)) { if (toSky) -it / 3 else it / 3 } + fadeOut(tween(200)))
                }
            },
            modifier = Modifier.fillMaxSize(),
            label = "destination",
        ) { d -> if (d == NWDestination.NOW) now() else sky() }
        NWNavBar(
            selection = destination, decideCount = decideCount, workingCount = workingCount, onSelect = onDestinationChange,
            modifier = Modifier.align(Alignment.BottomCenter), pulseWaiting = pulseWaiting ?: decideCount, pulseLongestWait = pulseLongestWait,
            onHeld = onHeld, onPulseTap = onPulseTap, onPulseHold = onPulseHold,
        )
        overlays()
        // While the pulse is held past its dead zone and no Stop flow is running, the ring follows the hold.
        val shown: StopFlowPhase = when {
            stop.isActive -> stop
            held != null && HoldRingSpec.stopAll.isVisible(held) -> StopFlowPhase.Holding(HoldRingSpec.stopAll.progress(held))
            else -> StopFlowPhase.Idle
        }
        NWStopOverlay(shown, stopPlan, Modifier.fillMaxSize(), biometry)
    }
}
