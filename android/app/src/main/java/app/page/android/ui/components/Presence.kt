package app.page.android.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import app.page.android.model.MacPresence
import app.page.android.model.RelativeTime
import app.page.android.ui.theme.colors
import java.time.Instant

/** One-line status, e.g. "Online · heartbeat 12s ago". */
fun MacPresence.summary(now: Instant): String = when (this) {
    MacPresence.Unknown -> "Checking…"
    is MacPresence.Online -> lastSeen?.let { "Online · heartbeat ${RelativeTime.ago(it, now)}" } ?: "Online"
    is MacPresence.Stale -> "Not responding · last heartbeat ${RelativeTime.ago(lastSeen, now)}"
    is MacPresence.Offline -> lastSeen?.let { "Offline · last seen ${RelativeTime.ago(it, now)}" } ?: "Offline"
    MacPresence.NeverConnected -> "Never connected with this pairing"
}

val MacPresence.dotColor: Color
    @Composable get() = when (this) {
        is MacPresence.Online -> colors.success
        is MacPresence.Stale -> colors.warning
        is MacPresence.Offline, MacPresence.NeverConnected -> colors.destructiveText
        MacPresence.Unknown -> colors.textMuted
    }
