package app.page.android.ui.sessions

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.DesktopAccessDisabled
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.KeyOff
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.SystemUpdate
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.ui.graphics.vector.ImageVector
import app.page.android.model.SessionAvailability
import app.page.android.ui.components.BannerTone

/** What each availability state tells the user, and the step that fixes it. */
data class SessionAvailabilityCopy(
    val icon: ImageVector,
    val tone: BannerTone,
    val title: String,
    val message: String,
    val actionTitle: String?,
    val action: Action?,
    /** For the uppercase status line. */
    val shortStatus: String,
) {
    enum class Action { REPAIR, RETRY }

    companion object {
        fun of(availability: SessionAvailability): SessionAvailabilityCopy = when (availability) {
            SessionAvailability.RelayTooOld -> SessionAvailabilityCopy(
                Icons.Filled.Sync, BannerTone.WARNING, "Update your relay",
                "Your relay (the Cloudflare Worker) doesn't support live sessions yet. Redeploy it from the latest Page release, then pull down to refresh. Pages keep working meanwhile.",
                "Check again", Action.RETRY, "Relay needs an update",
            )
            is SessionAvailability.NeedsRepair -> if (availability.keyMismatch) {
                SessionAvailabilityCopy(
                    Icons.Filled.KeyOff, BannerTone.ERROR, "Re-pair with your Mac",
                    "Live updates from your Mac can't be unlocked with this phone's key, so the pairing was probably regenerated on the Mac. Unpair, then on your Mac open Page → Pair phone… and scan the code.",
                    "Re-pair…", Action.REPAIR, "Pairing key changed",
                )
            } else {
                SessionAvailabilityCopy(
                    Icons.Filled.Key, BannerTone.WARNING, "Re-pair with your Mac to see live sessions",
                    "This pairing has no session key: it came from an older Page on your Mac, or was made before live sessions existed. Update Page on your Mac, unpair here, then open Page → Pair phone… on the Mac and scan the new code. Pages keep working meanwhile.",
                    "Re-pair…", Action.REPAIR, "Re-pair needed",
                )
            }
            SessionAvailability.MacOffline -> SessionAvailabilityCopy(
                Icons.Filled.DesktopAccessDisabled, BannerTone.WARNING, "Your Mac is offline",
                "Live sessions show up while Page on your Mac is connected to the relay. Wake the Mac, or check that Page is running there.",
                "Try again", Action.RETRY, "Mac offline",
            )
            SessionAvailability.ClockSkew -> SessionAvailabilityCopy(
                Icons.Filled.Schedule, BannerTone.WARNING, "Your clocks disagree",
                "Updates from your Mac arrive more than 10 minutes old by this phone's clock, so they're ignored. Turn on automatic date & time on both your phone and your Mac.",
                "Try again", Action.RETRY, "Clock mismatch",
            )
            SessionAvailability.MacTooOld -> SessionAvailabilityCopy(
                Icons.Filled.SystemUpdate, BannerTone.WARNING, "Update Page on your Mac",
                "Your Mac is online but isn't sending live sessions. Update Page on your Mac to the latest version, and check that remote sessions are turned on in its Preferences.",
                "Check again", Action.RETRY, "Mac needs an update",
            )
            SessionAvailability.MacDisabled -> SessionAvailabilityCopy(
                Icons.Filled.VisibilityOff, BannerTone.WARNING, "Live sessions are off on your Mac",
                "Page on your Mac isn't sharing its sessions. Turn them back on in Page → Preferences → Phone on the Mac.",
                "Check again", Action.RETRY, "Off on your Mac",
            )
            SessionAvailability.Waiting -> SessionAvailabilityCopy(
                Icons.Filled.HourglassEmpty, BannerTone.INFO, "Connecting to your Mac…", "", null, null, "Connecting…",
            )
            SessionAvailability.Ready -> SessionAvailabilityCopy(
                Icons.Filled.CheckCircle, BannerTone.INFO, "Live", "", null, null, "Live",
            )
        }
    }
}
