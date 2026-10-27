package app.page.android.model

// One-time tips: small dismissible cards that explain something the first time
// it's on screen. Each shows once ever, then never again (until "Show tips
// again" in Settings). Pure Kotlin; AppPrefs stores the ledger.

enum class Tip(val wire: String, val title: String, val body: String) {
    /** The first page in the Inbox. */
    PAGE_ACTIONS(
        "pageActions", "Tap a page to answer it",
        "Approve, deny or type a note from there. Press and hold a page for shortcuts, like opening its session to watch what the agent is doing.",
    ),

    /** The first "In flight" row. */
    IN_FLIGHT(
        "inFlight", "Working sessions, one tap away",
        "Tap a row to follow along and message the agent. Screen shows its terminal, Type opens the keyboard. Press and hold a row for the same shortcuts.",
    ),

    /** The session composer. */
    COMPOSER(
        "composerDelivery", "Your message goes into the terminal",
        "Page types it into the session on your Mac. Under each message you'll see Sending, then Typed once it lands, or Queued if your Mac is offline.",
    ),
}

/** What has been dismissed. Immutable, so it's trivial to test and to hold in a state flow. */
data class TipLedger(val dismissed: Set<String> = emptySet()) {
    fun shouldShow(tip: Tip): Boolean = tip.wire !in dismissed

    fun dismiss(tip: Tip): TipLedger = if (shouldShow(tip)) TipLedger(dismissed + tip.wire) else this

    fun encode(): String = dismissed.sorted().joinToString("\n")

    companion object {
        val EMPTY = TipLedger()

        /** Unknown or garbled entries are ignored, so a newer build's tips never break this one. */
        fun decode(raw: String?): TipLedger =
            TipLedger((raw ?: "").split('\n').map { it.trim() }.filter { w -> Tip.entries.any { it.wire == w } }.toSet())
    }
}
