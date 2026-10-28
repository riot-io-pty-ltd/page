package app.page.android.ui.nw.components

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import app.page.android.model.DaypartClock
import app.page.android.model.DaypartWeights
import app.page.android.ui.nw.theme.LocalFixedNow
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.time.Instant
import java.time.ZoneId
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

/**
 * The time of day for the Now and Lanes skies ([app.page.android.ui.nw.theme.LocalDaypart]): read off the local clock
 * when the app comes to the foreground (drawn at once, no catch-up blend), then every two minutes on the wall-clock
 * grid while it is there, and again whenever the clock or the time zone changes. Outside a blend window the weights
 * compare equal, so a tick redraws nothing. Remove animations keeps it: it is colour, not motion. (iOS NWDaypartTicker.)
 */
@Composable
fun rememberDaypartTicker(): State<DaypartWeights> {
    val context = LocalContext.current
    val weights = remember { mutableStateOf(DaypartWeights.at(Instant.now(), ZoneId.systemDefault())) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                val now = Instant.now()
                // The zone is read each time: the user may have moved since.
                val w = DaypartWeights.at(now, ZoneId.systemDefault())
                if (w != weights.value) weights.value = w
                delay(maxOf(1_000L, DaypartClock.nextTick(now).toEpochMilli() - now.toEpochMilli()))
            }
        }
    }
    DisposableEffect(context) {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, intent: Intent?) {
                weights.value = DaypartWeights.at(Instant.now(), ZoneId.systemDefault())
            }
        }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_TIME_CHANGED)
            addAction(Intent.ACTION_TIMEZONE_CHANGED)
        }
        // System broadcasts still reach a receiver that is not exported.
        ContextCompat.registerReceiver(context, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        onDispose { runCatching { context.unregisterReceiver(receiver) } }
    }
    return weights
}

/** `collectAsStateWithLifecycle` under a shorter name for the components that read a store. */
@Composable
fun <T> kotlinx.coroutines.flow.StateFlow<T>.collectAsStateWithLifecycleCompat(): State<T> =
    this.collectAsStateWithLifecycle()
