package app.page.android.model

// The "Gestures & shortcuts" list in Settings: every gesture and action the app
// has, in plain words, so a first-time user never has to guess. Kept as data so
// a test can check nothing is missing or empty.

data class GuideEntry(val gesture: String, val result: String)

data class GuideSection(val title: String, val entries: List<GuideEntry>)

object LegacyGestureGuide {
    val sections: List<GuideSection> = listOf(
        GuideSection(
            "ANYWHERE",
            listOf(
                GuideEntry("Pull down", "Refresh the list from your Mac."),
                GuideEntry("Press and hold a page or an In flight row", "Open a shortcut menu: the reply screen, the session, its screen, or typing."),
                GuideEntry("Back button or back gesture", "Close the open page or session."),
            ),
        ),
        GuideSection(
            "PAGE: WAITING FOR YOU",
            listOf(
                GuideEntry("Tap a page", "Open its reply screen to approve, deny, carry on or type a reply."),
                GuideEntry("Open session (on the reply screen)", "Follow what the agent is doing, with its conversation and terminal."),
                GuideEntry("Approve, Deny or Reply on the notification", "Answer without opening Page."),
            ),
        ),
        GuideSection(
            "IN FLIGHT: WORKING NOW",
            listOf(
                GuideEntry("Tap a row", "Open the session: its conversation, plus the message box."),
                GuideEntry("Screen", "Open the session on its Terminal view. Shown only for terminals your Mac can read (tmux, cmux, WezTerm, kitty, Herdr, Claude Squad)."),
                GuideEntry("Type", "Open the session with the keyboard up, ready to message the agent. Shown only where Page can type."),
            ),
        ),
        GuideSection(
            "INSIDE A SESSION",
            listOf(
                GuideEntry("Conversation, Terminal, Workflows", "Switch what you're looking at, when the Mac has sent more than the conversation."),
                GuideEntry("Send (arrow)", "Type your message into the session on your Mac. Under it you'll see Sending, Typed or Queued."),
                GuideEntry("Stop (square)", "Press Esc in the session so the agent stops its current turn."),
                GuideEntry("Changes", "See the files the session changed."),
                GuideEntry("Press and hold message text", "Select and copy it."),
                GuideEntry("Jump to latest (arrow)", "Return to the newest message after scrolling up."),
            ),
        ),
        GuideSection(
            "TALKBACK",
            listOf(
                GuideEntry("Actions menu on a page", "Open the reply screen, or open its session."),
                GuideEntry("Actions menu on an In flight row", "Open the session, show its screen, or type a message."),
            ),
        ),
    )
}
