package app.page.android.ui.nw.components

import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalView

/**
 * The haptics of the hold ring: a tick at 25%, 50% and 75% and a firm one when full, a light one when something
 * arms. Gated by API level; on a device with no haptics they do nothing. (iOS NWHaptics.)
 */
@Stable
class NWHaptics(private val view: View) {
    /** A tick on the way up the ring. */
    fun tick() {
        view.performHapticFeedback(if (Build.VERSION.SDK_INT >= 27) HapticFeedbackConstants.CLOCK_TICK else HapticFeedbackConstants.KEYBOARD_TAP)
    }

    /** The firm one, ring full. */
    fun full() {
        view.performHapticFeedback(
            if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.LONG_PRESS,
        )
    }

    /** Something arms (a swipe commits). */
    fun arm() {
        view.performHapticFeedback(if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.GESTURE_START else HapticFeedbackConstants.KEYBOARD_TAP)
    }
}

@Composable
fun rememberHaptics(): NWHaptics {
    val view = LocalView.current
    return remember(view) { NWHaptics(view) }
}
