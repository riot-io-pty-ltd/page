package app.page.android.ui.inbox

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DesktopAccessDisabled
import androidx.compose.material.icons.filled.KeyOff
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.PairingStore
import app.page.android.data.RelayClient
import app.page.android.model.MacPresence
import app.page.android.model.RelativeTime
import app.page.android.notify.NotificationAccess
import app.page.android.ui.components.BannerTone
import app.page.android.ui.components.ConfirmDialog
import app.page.android.ui.components.DialogChoice
import app.page.android.ui.components.StatusBanner
import app.page.android.ui.theme.Space
import java.time.Instant
import kotlinx.coroutines.launch

/** The set of banners that apply right now, most important first. */
@Composable
fun InboxBanners(now: Instant) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val authRejected by RelayClient.authRejected.collectAsStateWithLifecycle()
    val inboxLoad by RelayClient.inboxLoad.collectAsStateWithLifecycle()
    val connection by RelayClient.connection.collectAsStateWithLifecycle()
    val macStatus by RelayClient.macStatus.collectAsStateWithLifecycle()
    val authorization by NotificationAccess.authorization.collectAsStateWithLifecycle()
    var confirmingRepair by remember { mutableStateOf(false) }

    Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
        val failure = inboxLoad.failureMessage
        when {
            authRejected -> StatusBanner(
                BannerTone.ERROR, Icons.Filled.KeyOff,
                title = "This pairing no longer works",
                message = "Your relay rejected this phone's pairing token — the Mac probably generated a new one. Unpair and scan the new code.",
                actionTitle = "Re-pair…",
            ) { confirmingRepair = true }
            failure != null && connection != RelayClient.ConnectionState.CONNECTED -> StatusBanner(
                BannerTone.ERROR, Icons.Filled.WifiOff,
                title = "Can't reach your relay",
                message = "$failure The inbox may be out of date.",
                actionTitle = "Try again",
            ) { scope.launch { RelayClient.refreshAll() } }
            else -> PresenceBanner(MacPresence.evaluate(macStatus, now), now) { confirmingRepair = true }
        }
        if (authorization == NotificationAccess.Authorization.DENIED) {
            StatusBanner(
                BannerTone.WARNING, Icons.Filled.NotificationsOff,
                title = "Notifications are off",
                message = "You won't be paged while Page is closed.",
                actionTitle = "Open settings",
            ) { NotificationAccess.openSettings(context) }
        }
    }

    if (confirmingRepair) {
        ConfirmDialog(
            title = "Unpair this Mac?",
            message = "You'll go back to the pairing screen. On your Mac, open Page → Pair phone… and scan the code.",
            choices = listOf(DialogChoice("Unpair", destructive = true) { PairingStore.unpair() }),
            onDismiss = { confirmingRepair = false },
        )
    }
}

@Composable
private fun PresenceBanner(presence: MacPresence, now: Instant, onRepair: () -> Unit) {
    when (presence) {
        MacPresence.NeverConnected -> StatusBanner(
            BannerTone.ERROR, Icons.Filled.KeyOff,
            title = "Your Mac hasn't connected with this pairing",
            message = "The relay has never seen Page on your Mac use this pairing code, so no pages can reach this phone. If you regenerated the token on your Mac, re-pair with the new code.",
            actionTitle = "Re-pair…",
            action = onRepair,
        )
        is MacPresence.Offline -> {
            // An abandoned token still answers like an offline Mac, so after a
            // long silence offer the re-pair a regenerated token needs.
            val repair = presence.suggestsRepair(now)
            StatusBanner(
                BannerTone.WARNING, Icons.Filled.DesktopAccessDisabled,
                title = "Your Mac is offline",
                message = (presence.lastSeen?.let { "Last seen ${RelativeTime.ago(it, now)}. " } ?: "") +
                    "New pages can't reach you until Page on your Mac reconnects to the relay." +
                    if (repair) " If you regenerated the token on your Mac, re-pair this phone." else "",
                actionTitle = if (repair) "Re-pair…" else null,
                action = if (repair) onRepair else null,
            )
        }
        is MacPresence.Stale -> StatusBanner(
            BannerTone.WARNING, Icons.Filled.DesktopAccessDisabled,
            title = "Your Mac stopped checking in",
            message = "Last heartbeat ${RelativeTime.ago(presence.lastSeen, now)}. It may be asleep or busy; pages may be delayed.",
        )
        else -> Unit
    }
}
