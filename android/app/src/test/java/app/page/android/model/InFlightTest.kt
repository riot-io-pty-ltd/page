package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InFlightTest {
    private fun s(
        id: String, state: LiveSessionState, t: Double?, title: String = id, host: String = "tmux",
        canType: Boolean = true, preview: String = "Bash: ls",
    ) = LiveSession(
        id = id, backend = AgentBackend.Known(InterventionBackend.CLAUDE), title = title, cwd = "~/$title", state = state,
        host = host, canType = canType, typeBlocker = if (canType) null else "Page can't type into $host yet",
        canInterrupt = true, provider = null, lastActivityAt = t?.let(::at), interventionId = null, preview = preview,
    )

    @Test
    fun onlyWorkingSessionsAreInFlight() {
        val rows = InFlight.rows(
            listOf(
                s("a", LiveSessionState.ACTIVE, 10.0),
                s("w", LiveSessionState.WAITING_ON_APPROVAL, 20.0),
                s("i", LiveSessionState.IDLE, 30.0),
                s("r", LiveSessionState.RATE_LIMITED, 40.0),
                s("u", LiveSessionState.UNKNOWN, 50.0),
            )
        )
        assertEquals(listOf("a"), rows.map { it.session.id })
    }

    @Test
    fun stableOrderTitleThenIdNeverActivity() {
        val sessions = listOf(
            s("old", LiveSessionState.ACTIVE, 10.0, title = "zed"),
            s("none", LiveSessionState.ACTIVE, null, title = "Bravo"),
            s("new", LiveSessionState.ACTIVE, 99.0, title = "alpha"),
            s("tie-b", LiveSessionState.ACTIVE, 50.0, title = "same"),
            s("tie-a", LiveSessionState.ACTIVE, 50.0, title = "same"),
        )
        val expected = listOf("new", "none", "tie-a", "tie-b", "old")
        assertEquals(expected, InFlight.rows(sessions).map { it.session.id })
        // Activity ticking, or the Mac listing in another order, moves nothing.
        val ticked = sessions.map { it.copy(lastActivityAt = at(1000.0 - (it.lastActivityAt?.epochSecond ?: 0))) }.reversed()
        assertEquals(expected, InFlight.rows(ticked).map { it.session.id })
    }

    @Test
    fun noSessionsMeansNoRows() {
        assertTrue(InFlight.rows(emptyList()).isEmpty())
        assertEquals("In flight · 0", InFlight.title(0))
        assertEquals("In flight · 2", InFlight.title(2))
    }

    @Test
    fun stepIsThePreviewOrAPlaceholder() {
        val rows = InFlight.rows(
            listOf(s("a", LiveSessionState.ACTIVE, 2.0, preview = "Edit: Theme.kt"), s("b", LiveSessionState.ACTIVE, 1.0, preview = "  "))
        )
        assertEquals("Edit: Theme.kt", rows[0].step)
        assertEquals(InFlight.NO_STEP, rows[1].step)
    }

    @Test
    fun screenIsOfferedOnlyWhereTheMacCanReadTheTerminal() {
        for (host in listOf("tmux", "cmux", "WezTerm", "kitty", "Herdr", "Claude Squad", " TMUX ")) {
            assertTrue(host, SessionHosts.canMirror(host))
        }
        for (host in listOf("Terminal", "iTerm", "VS Code", "Ghostty", "unknown", "desktop", "")) {
            assertFalse(host, SessionHosts.canMirror(host))
        }
        val rows = InFlight.rows(
            listOf(s("a", LiveSessionState.ACTIVE, 1.0, host = "tmux"), s("b", LiveSessionState.ACTIVE, 2.0, host = "Ghostty"))
        )
        assertTrue(rows[0].canShowScreen)
        assertFalse(rows[1].canShowScreen)
    }

    @Test
    fun aScreenAlreadyReceivedCountsEvenOnAnUnlistedHost() {
        val rows = InFlight.rows(listOf(s("g", LiveSessionState.ACTIVE, 1.0, host = "Ghostty")), screenIds = setOf("g"))
        assertTrue(rows[0].canShowScreen)
    }

    @Test
    fun typeFollowsTheSessionsCapability() {
        val rows = InFlight.rows(
            listOf(s("a", LiveSessionState.ACTIVE, 2.0, canType = true), s("b", LiveSessionState.ACTIVE, 1.0, canType = false))
        )
        assertTrue(rows[0].canType)
        assertFalse(rows[1].canType)
    }

    @Test
    fun aMacClockAheadOfThePhoneNeverShowsANegativeAge() {
        // The Mac stamps lastActivityAt by its own clock; a few seconds ahead must read as "just now".
        val rows = InFlight.rows(listOf(s("ahead", LiveSessionState.ACTIVE, NOW.epochSecond.toDouble() + 3.0)))
        assertEquals("Active just now", rows[0].activity(NOW))
    }

    @Test
    fun screenOfferedForAnotherSessionsScreenDoesNotLeakOntoThisRow() {
        val rows = InFlight.rows(
            listOf(s("a", LiveSessionState.ACTIVE, 2.0, host = "Ghostty"), s("b", LiveSessionState.ACTIVE, 1.0, host = "Ghostty")),
            screenIds = setOf("b"),
        )
        assertFalse(rows.first { it.session.id == "a" }.canShowScreen)
        assertTrue(rows.first { it.session.id == "b" }.canShowScreen)
    }

    @Test
    fun activityReadsAsRelativeTimeOrFallsBackToTheState() {
        val rows = InFlight.rows(listOf(s("a", LiveSessionState.ACTIVE, 9_988.0), s("b", LiveSessionState.ACTIVE, null)))
        assertEquals("Active 12s ago", rows[0].activity(NOW))
        assertEquals("Working", rows[1].activity(NOW))
    }
}
