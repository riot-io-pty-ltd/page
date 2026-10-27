package app.page.android.model

// Port of iOS/Page/Models/FirstTimeTips.swift. First-time tips and the
// "Gestures & shortcuts" page. One list of gestures ([GestureGuide]) is the
// single source of their copy: the Tower prints all of it, and each tip is the
// one line of one entry. A tip is shown once, never blocks anything, and is
// remembered on the phone ([TipBook]). Pure. (The older Android guide, from the
// first in-flight work, is [LegacyGestureGuide]; the screens stage retires it.)

// MARK: - Gestures

/** The tips Page can show, in the order of [TipBook.priority]. */
enum class NWTip(val raw: String) {
    SWIPE_TO_APPROVE("swipeToApprove"), HOLD_TO_APPROVE("holdToApprove"), IN_FLIGHT("inFlight"), WILL_TYPE("willType");

    val id: String get() = raw

    /** The tip's line, from the gesture list. [biometry] is how this phone confirms ("fingerprint", "face", "screen lock"). */
    fun text(biometry: String = "fingerprint"): String =
        (GestureGuide.entry(this)?.tipText ?: "").replace("{biometry}", biometry)

    /** A semantic icon name (the views map it to an icon). */
    val symbol: String get() = GestureGuide.entry(this)?.symbol ?: "lightbulb"
}

/** One gesture and what it does. */
data class GestureEntry(
    val id: String,
    /** A semantic icon name (the views map it to an icon). */
    val symbol: String,
    /** "Swipe right". */
    val gesture: String,
    /** Where: "On an undoable row". */
    val context: String,
    /** What it does: "Approves it. You can undo it for a moment." */
    val effect: String,
    /** The tip this entry is the source of, and its line (`{biometry}` is filled in). */
    val tip: NWTip? = null,
    val tipText: String? = null,
)

object GestureGuide {
    const val title = "Gestures & shortcuts"

    val entries: List<GestureEntry> = listOf(
        GestureEntry(
            "swipe", "arrow.right", "Swipe right", "on an undoable row",
            "Approves it. Nothing is sent for 1.2 seconds, and Cancel stops it.",
            NWTip.SWIPE_TO_APPROVE, "Swipe right to approve — it can be undone",
        ),
        GestureEntry(
            "hold", "hand.tap", "Hold", "on an irreversible approval",
            "Fill the ring, then your phone confirms it. Only then is it approved.",
            NWTip.HOLD_TO_APPROVE, "Hold to approve — {biometry} confirms",
        ),
        GestureEntry(
            "tap-card", "rectangle.and.hand.point.up.left", "Tap a card", "in Decide, Look or Review",
            "Opens the full decision, with exactly what will be typed.",
        ),
        GestureEntry(
            "in-flight", "waveform", "Tap a card", "in In flight",
            "See what it is doing, how long, and what it ran. Open shows its terminal; Steer types to it.",
            NWTip.IN_FLIGHT, "Tap to watch it work · Steer to guide it",
        ),
        GestureEntry(
            "touch-hold", "hand.point.up.left", "Touch and hold", "an In flight card",
            "Open, Steer or Stop. Stop opens the session, where you hold the stop button.",
        ),
        GestureEntry(
            "will-type", "keyboard", "Will type …", "on a decision",
            "Says exactly what lands on your Mac, in which terminal.",
            NWTip.WILL_TYPE, "Will type … shows exactly what lands on your Mac",
        ),
        GestureEntry("cancel", "xmark.circle", "Tap Cancel", "while the ring runs", "Takes an approval back before anything leaves the phone."),
        GestureEntry("stop", "stop.circle", "Hold Stop", "in a session", "Presses Esc in that session after a 0.6 second hold."),
        GestureEntry("plus", "plus.circle", "Tap +", "on the bottom bar", "Starts new work on your Mac."),
        GestureEntry("stop-all", "stop.circle.fill", "Hold +", "on the bottom bar", "Stops every working agent, once your phone confirms it."),
        GestureEntry("sides", "arrow.left.arrow.right", "Swipe sideways", "on the top or the bottom bar", "Goes between Now and Lanes."),
        GestureEntry("pull", "arrow.down", "Pull down", "on Now", "Checks in with your Mac again."),
        GestureEntry("chip", "bolt.horizontal", "Tap the Mac chip or the Runway", "on Now", "Opens this Tower, at Budget for the Runway."),
    )

    /** Quick Settings, widgets and the like (the screens stage fills this in as they ship). */
    val shortcuts: List<GestureEntry> = listOf(
        GestureEntry("tile", "square.grid.2x2", "Quick Settings tile", "in the quick settings panel", "Shows how many need you and opens Now. It never acts on its own."),
        GestureEntry("widget", "rectangle.3.group", "Home-screen widget", "on your home screen", "Counts and the runway, never a project or a command. Tap it to open Now."),
        GestureEntry("live", "waveform", "Live notification", "with Stay connected on", "One ongoing line: what needs you, what is working and the runway. Tap it to open Now."),
    )

    fun entry(tip: NWTip): GestureEntry? = entries.firstOrNull { it.tip == tip }

    const val showAgainLabel = "Show the tips again"
}

// MARK: - The tip that shows

/** Where a tip points: the row it sits under. */
data class NowTipTarget(
    val tip: NWTip,
    /** The row it explains: a Now row's id, or an In flight session's id. */
    val anchorId: String,
)

/** What the rows say, for [TipBook.nowTip]. */
data class NowTipInputs(
    /** The rows in the order drawn: id and chip. A row with an action under way is left out by the caller. */
    val rows: List<Pair<String, ChipKind>> = emptyList(),
    /** The In flight rows, in the order drawn. */
    val inFlight: List<String> = emptyList(),
    /** Rows with an arm ring, a send or a result on them: no tip points at them. */
    val busy: Set<String> = emptySet(),
)

/** Which tips this phone has already shown or used. Each is shown once. */
data class TipBook(val seen: Set<NWTip> = emptySet()) {
    fun hasSeen(tip: NWTip): Boolean = tip in seen

    /** The tip is dismissed, or its gesture was used. */
    fun retire(tip: NWTip): TipBook = copy(seen = seen + tip)

    /** Every tip comes back (the Tower's "Show the tips again"). */
    fun reset(): TipBook = TipBook()

    /**
     * The one tip Now shows, and the row it points at: at most one at a time, in [priority] order, on the first
     * row of its kind that has nothing under way. A tip already seen never returns. Pure.
     */
    fun nowTip(i: NowTipInputs): NowTipTarget? {
        for (tip in priority) {
            if (tip in seen) continue
            val anchor: String? = when (tip) {
                NWTip.HOLD_TO_APPROVE -> i.rows.firstOrNull { it.second == ChipKind.IRREVERSIBLE && it.first !in i.busy }?.first
                NWTip.SWIPE_TO_APPROVE -> i.rows.firstOrNull { it.second == ChipKind.UNDOABLE && it.first !in i.busy }?.first
                NWTip.IN_FLIGHT -> i.inFlight.firstOrNull { it !in i.busy }
                NWTip.WILL_TYPE -> null
            }
            if (anchor != null) return NowTipTarget(tip, anchor)
        }
        return null
    }

    /** The Decision sheet's tip: only while the sheet has a delivery preview to point at. Pure. */
    fun decisionTip(hasPreview: Boolean): NWTip? = if (hasPreview && NWTip.WILL_TYPE !in seen) NWTip.WILL_TYPE else null

    companion object {
        /** The one that shows when several could: the safest explanation first. */
        val priority: List<NWTip> = listOf(NWTip.HOLD_TO_APPROVE, NWTip.SWIPE_TO_APPROVE, NWTip.IN_FLIGHT, NWTip.WILL_TYPE)
        const val keyPrefix = "page.tip."

        fun key(tip: NWTip): String = keyPrefix + tip.raw
    }
}
