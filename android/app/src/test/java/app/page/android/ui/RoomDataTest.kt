package app.page.android.ui

import app.page.android.model.AgentBackend
import app.page.android.model.InterventionBackend
import app.page.android.model.LiveSession
import app.page.android.model.LiveSessionState
import app.page.android.model.RoomComposerMode
import app.page.android.model.RoomLens
import app.page.android.model.SessionTranscript
import app.page.android.model.TranscriptEntry
import app.page.android.model.TranscriptRole
import app.page.android.ui.nw.room.SessionRoomData
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Session Room's data is one pure decision: what it offers follows the session, and the target is the session it shows. */
class RoomDataTest {
    private val now = Instant.ofEpochSecond(1_800_000_000)
    private fun session(state: LiveSessionState, canType: Boolean = true) = LiveSession(
        id = "w1", backend = AgentBackend.Known(InterventionBackend.CLAUDE), title = "relay", cwd = "~/projects/page", state = state, host = "cmux",
        canType = canType, typeBlocker = if (canType) null else "Page can't type into Ghostty yet", canInterrupt = true, provider = null, lastActivityAt = now.minusSeconds(4),
        interventionId = null, preview = "Bash: vitest",
    )

    @Test fun `a busy session is steered, not answered, and Stop is offered`() {
        val d = SessionRoomData.make(SessionRoomData.Inputs(session = session(LiveSessionState.ACTIVE), macName = "Studio MBP", now = now))
        assertEquals(RoomComposerMode.Steer, d.composer)
        assertTrue(d.stop.canStop)
        assertEquals("w1", d.target?.sessionId)
        assertTrue(d.preview!!.contains("Studio MBP"))
    }

    @Test fun `a session Page cannot type into blocks the composer and says why`() {
        val d = SessionRoomData.make(SessionRoomData.Inputs(session = session(LiveSessionState.IDLE, canType = false), macName = "Studio MBP", now = now))
        assertTrue(d.composer is RoomComposerMode.Blocked)
        assertNull(d.preview?.takeIf { it.startsWith("Will type 1") })
    }

    @Test fun `an ended room is read-only`() {
        val d = SessionRoomData.make(SessionRoomData.Inputs(session = session(LiveSessionState.IDLE), ended = true, macName = "Studio MBP", now = now))
        assertTrue(d.composer is RoomComposerMode.Disabled)
        assertTrue(!d.stop.canStop)
        assertTrue(d.banners.any { it.id == "ended" })
    }

    @Test fun `lenses appear only when there is something behind them`() {
        val bare = SessionRoomData.make(SessionRoomData.Inputs(session = session(LiveSessionState.ACTIVE), macName = "m", now = now))
        assertEquals(listOf(RoomLens.STORY, RoomLens.CHANGES), bare.lenses)
        val withStory = SessionRoomData.make(
            SessionRoomData.Inputs(
                session = session(LiveSessionState.ACTIVE), macName = "m", now = now,
                transcript = SessionTranscript("w1", listOf(TranscriptEntry("1", TranscriptRole.USER, "hi", now, null)), false),
            ),
        )
        assertEquals(1, withStory.story.count { it is app.page.android.model.StoryBlock.User })
    }

    private fun entries(vararg e: Pair<TranscriptRole, String>) =
        SessionTranscript("w1", e.mapIndexed { n, (r, t) -> TranscriptEntry("e$n", r, t, now, null) }, false)

    private val question = TranscriptRole.ASSISTANT to "I've finished the refactor. Should I run the full test suite now?"

    @Test fun `an idle session whose last message asks yes or no offers Yes and No`() {
        val d = SessionRoomData.make(SessionRoomData.Inputs(session = session(LiveSessionState.IDLE), macName = "m", now = now, transcript = entries(TranscriptRole.USER to "Refactor it", question)))
        assertEquals("Should I run the full test suite now?", d.yesNo)
    }

    @Test fun `nothing is offered mid-turn, where Page cannot type, once the user has answered, or after a tool step`() {
        fun yesNo(state: LiveSessionState, canType: Boolean = true, t: SessionTranscript = entries(question), sent: List<app.page.android.model.SentSessionCommand> = emptyList()) =
            SessionRoomData.make(SessionRoomData.Inputs(session = session(state, canType), macName = "m", now = now, transcript = t, sent = sent)).yesNo
        assertNull(yesNo(LiveSessionState.ACTIVE))
        assertNull(yesNo(LiveSessionState.IDLE, canType = false))
        assertNull(yesNo(LiveSessionState.WAITING_ON_APPROVAL))
        assertNull(yesNo(LiveSessionState.IDLE, t = entries(question, TranscriptRole.USER to "Yes")))
        assertNull(yesNo(LiveSessionState.IDLE, t = entries(question, TranscriptRole.TOOL to "Bash: swift test")))
        val sent = app.page.android.model.SentSessionCommand("c1", "w1", app.page.android.model.SessionCommandKind.INPUT, "Yes", now, app.page.android.model.SessionDeliveryState.Sending)
        assertNull(yesNo(LiveSessionState.IDLE, sent = listOf(sent)))
        assertNull(SessionRoomData.make(SessionRoomData.Inputs(session = session(LiveSessionState.IDLE), ended = true, macName = "m", now = now, transcript = entries(question))).yesNo)
    }
}
