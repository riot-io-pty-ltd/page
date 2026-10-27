package app.page.android.model

import java.time.Instant

// Port of iOS/Page/Models/MacPresenceCopy.swift.

/** One-line status, e.g. "Online · heartbeat 12s ago". */
fun MacPresence.summary(now: Instant): String = when (this) {
    MacPresence.Unknown -> "Checking…"
    is MacPresence.Online -> lastSeen?.let { "Online · heartbeat ${RelativeTime.ago(it, now)}" } ?: "Online"
    is MacPresence.Stale -> "Not responding · last heartbeat ${RelativeTime.ago(lastSeen, now)}"
    is MacPresence.Offline -> lastSeen?.let { "Offline · last seen ${RelativeTime.ago(it, now)}" } ?: "Offline"
    MacPresence.NeverConnected -> "Never connected with this pairing"
}
