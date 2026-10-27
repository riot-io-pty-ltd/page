package app.page.android.ui.nw.components

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import app.page.android.ui.nw.theme.LocalFixedNow
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.time.Instant
import kotlinx.coroutines.delay
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle

/**
 * "Now" for a view, as state. Ticks every [fastMs] while [until] is in the future (an arm ring or a thread is
 * moving) and every [slowMs] otherwise, so a screen with nothing moving costs almost nothing. The render
 * harness pins it ([LocalFixedNow]). (iOS NWLiveClock.)
 */
@Composable
fun rememberNWNow(until: Instant? = null, fastMs: Long = 60, slowMs: Long = 5_000): State<Instant> {
    val fixed = LocalFixedNow.current
    val now = remember { mutableStateOf(fixed ?: Instant.now()) }
    if (fixed != null) {
        now.value = fixed
        return now
    }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(until, lifecycle) {
        // Nothing ticks while the app is in the background.
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                val n = Instant.now()
                now.value = n
                delay(if (until != null && n.isBefore(until.plusMillis(50))) fastMs else slowMs)
            }
        }
    }
    return now
}

/** `collectAsStateWithLifecycle` under a shorter name for the components that read a store. */
@Composable
fun <T> kotlinx.coroutines.flow.StateFlow<T>.collectAsStateWithLifecycleCompat(): State<T> =
    this.collectAsStateWithLifecycle()
