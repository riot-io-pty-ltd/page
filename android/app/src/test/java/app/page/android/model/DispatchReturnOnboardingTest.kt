package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Dispatch (start a session from the phone), the Return Brief and the away tracker, and the first-run, paired and
 * problem states, ported from the "Dispatch", "Return Brief" and "First run, problem states and paired welcome"
 * checks in iOS/Tests/LogicTests.swift.
 */
class DispatchReturnOnboardingTest {
    private val folders = listOf(
        StartFolder("/Users/me/a", "a", nwNow.minusSeconds(7200)),
        StartFolder("/Users/me/b", "bottle", null),
        StartFolder("/Users/me/c", "Page", nwNow.minusSeconds(60)),
    )

    // MARK: dispatch

    @Test fun `folders are most recent first and never used last, search ignores case and matches the path`() {
        var draft = DispatchDraft()
        assertEquals(listOf("Page", "a", "bottle"), draft.visibleFolders(folders, nwNow).map { it.name })
        draft = draft.copy(search = "PAG")
        assertEquals(listOf("Page"), draft.visibleFolders(folders, nwNow).map { it.name })
        draft = draft.copy(search = "users/me/b")
        assertEquals(listOf("bottle"), draft.visibleFolders(folders, nwNow).map { it.name })
    }

    @Test fun `the most recent folder is picked and a vanished folder is replaced`() {
        var draft = DispatchDraft().ensuringSelection(folders, nwNow)
        assertEquals("/Users/me/c", draft.selectedPath)
        draft = draft.copy(selectedPath = "/gone").ensuringSelection(folders, nwNow)
        assertEquals("/Users/me/c", draft.selectedPath)
    }

    @Test fun `a ready Mac with a folder can start, loading or sending cannot, and only Claude starts from the phone`() {
        val draft = DispatchDraft().ensuringSelection(folders, nwNow)
        assertTrue(draft.canStart(DispatchAvailability.Ready, sending = false))
        assertFalse(draft.canStart(DispatchAvailability.Loading, sending = false))
        assertFalse(draft.canStart(DispatchAvailability.Ready, sending = true))
        assertFalse(draft.copy(agent = DispatchAgent.CODEX).canStart(DispatchAvailability.Ready, sending = false))
    }

    @Test fun `a prompt over the composer limit cannot start, and exactly the limit fits`() {
        val draft = DispatchDraft().ensuringSelection(folders, nwNow)
        val long = draft.copy(prompt = "a".repeat(SessionComposer.MAX_CHARACTERS + 1))
        assertFalse(long.promptProblem == null)
        assertFalse(long.canStart(DispatchAvailability.Ready, sending = false))
        val fits = draft.copy(prompt = "a".repeat(SessionComposer.MAX_CHARACTERS))
        assertNull(fits.promptProblem)
    }

    @Test fun `the start title and footer name the Mac`() {
        val draft = DispatchDraft()
        assertEquals("Start on Studio MBP", draft.startTitle("Studio MBP"))
        assertEquals("Start on your Mac", draft.startTitle(" "))
        assertTrue(DispatchDraft.footer("Studio MBP").contains("Studio MBP"))
    }

    @Test fun `availability reads disabled, no folders, failed, loading, or ready from the Mac's list`() {
        assertEquals(DispatchAvailability.DisabledOnMac, DispatchAvailability.from(StartFolders(null, false, emptyList(), folders), null))
        assertEquals(DispatchAvailability.NoFolders, DispatchAvailability.from(StartFolders(null, true, emptyList(), emptyList()), null))
        assertEquals(DispatchAvailability.Failed("boom"), DispatchAvailability.from(null, "boom"))
        assertEquals(DispatchAvailability.Loading, DispatchAvailability.from(null, null))
        assertEquals(DispatchAvailability.Ready, DispatchAvailability.from(StartFolders(null, true, emptyList(), folders), null))
    }

    @Test fun `a start's status waits, warns when started but not shown, and is good when typed`() {
        assertTrue(DispatchStatus.from(SessionDeliveryState.Sending, startWaitExpired = false)?.waiting == true)
        assertEquals(DispatchStatus.Tone.WARN, DispatchStatus.from(SessionDeliveryState.Typed(null), startWaitExpired = true)?.tone)
        assertEquals(DispatchStatus.Tone.GOOD, DispatchStatus.from(SessionDeliveryState.Typed("ok"), startWaitExpired = false)?.tone)
        assertNull(DispatchStatus.from(null, startWaitExpired = false))
    }

    @Test fun `only Claude starts from the phone`() {
        assertTrue(DispatchAgent.CLAUDE.canStartFromPhone)
        assertFalse(DispatchAgent.CODEX.canStartFromPhone)
        assertFalse(DispatchAgent.OLLAMA.canStartFromPhone)
    }

    // MARK: the Return Brief

    @Test fun `no brief under forty-five minutes away, a brief at forty-five, and a dismissed absence stays dismissed`() {
        assertFalse(AwayTracker.shouldShowBrief(nwNow.minusSeconds(44L * 60), null, nwNow))
        assertTrue(AwayTracker.shouldShowBrief(nwNow.minusSeconds(45L * 60), null, nwNow))
        assertFalse(AwayTracker.shouldShowBrief(nwNow.minusSeconds(45L * 60), nwNow.minusSeconds(45L * 60), nwNow))
        assertFalse(AwayTracker.shouldShowBrief(null, null, nwNow))
    }

    @Test fun `an absence under ten minutes is not one, and its handover lasts ten minutes after return`() {
        assertNull(Absence.make(nwNow.minusSeconds(9L * 60), nwNow))
        val abs = Absence.make(nwNow.minusSeconds(10L * 60), nwNow)
        assertEquals(600.0, abs?.duration ?: -1.0, 0.0)
        assertTrue(abs?.showsHandover(nwNow.plusSeconds(9L * 60)) == true)
        assertFalse(abs?.showsHandover(nwNow.plusSeconds(11L * 60)) == true)
        val long = Absence(nwNow.minusSeconds(45L * 60), nwNow)
        assertTrue(long.shouldShowBrief(null))
        assertFalse(long.shouldShowBrief(long.since))
    }

    @Test fun `the brief durations and the handover sentence read as the iOS copy`() {
        assertEquals("1h 52m", ReturnBrief.brief(6720.0))
        assertEquals("45m", ReturnBrief.brief(2700.0))
        assertEquals("2h", ReturnBrief.brief(7200.0))
        assertEquals("While you were away (1h 52m) · 3 finished · 2 need you", ReturnBrief.handoverSentence(6720.0, 3, 2))
        assertNull(ReturnBrief.handoverSentence(500.0, 3, 2))
        assertNull(ReturnBrief.handoverSentence(6720.0, 0, 0))
    }

    private fun briefFixture(open: List<Intervention> = emptyList(), status: MacStatusSnapshot? = null): ReturnBrief {
        val a1 = nwIv("h1", InterventionKind.APPROVAL, "[Bash] ls", t = NW_T0 - 3600, session = "w1")
            .copy(repliedAt = nwNow.minusSeconds(3000), repliedAction = "approve")
        val a2 = nwIv("h2", InterventionKind.APPROVAL, "[Bash] ls", t = NW_T0 - 2500, session = "w1")
            .copy(repliedAt = nwNow.minusSeconds(2000), repliedAction = "deny")
        val a3 = nwIv("h3", InterventionKind.USER_INPUT, "Which?", t = NW_T0 - 1500, session = "w1")
            .copy(repliedAt = nwNow.minusSeconds(1000), repliedAction = "custom")
        val f1 = nwIv("f1", InterventionKind.IDLE, "Changed 3 files · tests passed\n\nAll done.", t = NW_T0 - 900, session = "w1")
            .copy(closedAt = nwNow.minusSeconds(500))
        val f2 = nwIv("f2", InterventionKind.IDLE, "Changed 1 file · tests failed\n\nOops", t = NW_T0 - 800, session = "w1")
            .copy(closedAt = nwNow.minusSeconds(400))
        return ReturnBrief.build(
            since = nwNow.minusSeconds(6720), now = nwNow, history = listOf(a1, a2, a3, f1, f2), open = open,
            sessions = emptyList(), hasSessionList = false, status = status, zone = NW_ZONE,
        )
    }

    @Test fun `the brief title, window, counts and sunrise`() {
        val brief = briefFixture()
        assertEquals("While you were away · 1h 52m", brief.title)
        assertEquals("06:08 to 08:00", brief.window)
        assertEquals(2, brief.finished)
        assertEquals(0, brief.counts.first { it.kind == ReturnBrief.Count.Kind.NEED_YOU }.value)
        assertTrue(brief.sunrise > 0.33 && brief.sunrise < 0.34)
        assertFalse("nothing open is not urgent", brief.hasUrgent)
    }

    @Test fun `the decided and finished lines name the verdicts, files and tests`() {
        val brief = briefFixture()
        val decided = brief.lines.first { it.id == "decided" }
        assertEquals("Decided 3", decided.title)
        assertEquals("1 approved · 1 denied · 1 answered in words", decided.detail)
        val finished = brief.lines.first { it.id == "finished" }
        assertEquals("2 turns · 4 files · tests passing in 1 of 2", finished.detail)
        assertEquals(ReturnBrief.Tone.WARN, finished.tone)
    }

    @Test fun `an open decision is urgent and counted, and the battery line comes from the status`() {
        val open = briefFixture(open = listOf(nwIv("q", InterventionKind.APPROVAL, "[Bash] ls", session = "w1")))
        assertTrue(open.hasUrgent)
        assertEquals(1, open.counts.first { it.kind == ReturnBrief.Count.Kind.NEED_YOU }.value)
        val withBattery = briefFixture(status = nwStatus(connected = true, age = 5.0, battery = 41, onAC = false))
        assertTrue(withBattery.lines.any { it.id == "battery" })
    }

    // MARK: first run and the paired welcome

    @Test fun `a blank Mac is named Your Mac, and the first star reads its subtitle`() {
        assertEquals("Your Mac is paired", PairedWelcome.build("", null, true, NotificationsState.NOT_SET).title)
        val first = PairedWelcome.build("Studio MBP", null, true, NotificationsState.NOT_SET)
        assertEquals("Your first star. Sessions appear as soon as your Mac reports them.", first.subtitle)
        assertEquals(PairedWelcome.Action.ALLOW_NOTIFICATIONS, first.action)
        assertEquals("Not now", first.skipTitle)
    }

    @Test fun `the paired subtitle counts the live sessions`() {
        assertEquals("Your first star. 14 sessions are live right now.", PairedWelcome.subtitle(14, true))
        assertEquals("1 session is live right now.", PairedWelcome.subtitle(1, false))
        assertEquals("Start an agent on your Mac and it appears here.", PairedWelcome.subtitle(0, false))
    }

    @Test fun `allowed continues with no skip, and off opens Settings`() {
        val allowed = PairedWelcome.build("M", 0, false, NotificationsState.ALLOWED)
        assertEquals(PairedWelcome.Action.CONTINUE_TO_NOW, allowed.action)
        assertNull(allowed.skipTitle)
        assertEquals(PairedWelcome.Action.OPEN_SETTINGS, PairedWelcome.build("M", 0, false, NotificationsState.OFF).action)
        assertEquals(3, PairedWelcome.promiseLines.size)
    }

    private fun inputs(
        presence: MacPresence = MacPresence.Online(null),
        authRejected: Boolean = false,
        connected: Boolean = true,
        inboxFailure: String? = null,
        battery: Int? = null,
        onAC: Boolean? = null,
        cutoff: Int? = null,
        pausedSessions: Int = 0,
        relayHost: String? = null,
    ) = ProblemState.Inputs(
        macName = "Studio MBP", presence = presence, authRejected = authRejected, inboxFailure = inboxFailure,
        connected = connected, relayHost = relayHost, battery = battery, onAC = onAC, cutoff = cutoff,
        pausedSessions = pausedSessions, lastKnownAt = null, now = nwNow,
    )

    @Test fun `a healthy online Mac has no problem state`() {
        assertNull(ProblemState.build(inputs()))
    }

    @Test fun `a replaced pairing is amber with a repair and replaces the auth and never banners`() {
        val replaced = ProblemState.build(inputs(authRejected = true))!!
        assertEquals(ProblemState.Kind.PAIRING_REPLACED, replaced.kind)
        assertEquals(ProblemState.Tone.AMBER, replaced.tone)
        assertEquals(ProblemState.Action.REPAIR, replaced.action)
        assertEquals(setOf("auth", "never"), replaced.replacesBanners)
        assertEquals("This pairing was replaced", replaced.title)
        assertEquals("Your Mac hasn't used this pairing", ProblemState.build(inputs(presence = MacPresence.NeverConnected))?.title)
    }

    @Test fun `an unreachable relay rechecks and names the host`() {
        val relay = ProblemState.build(inputs(connected = false, inboxFailure = "timeout", relayHost = "page.example.workers.dev"))!!
        assertEquals(ProblemState.Kind.RELAY_UNREACHABLE, relay.kind)
        assertEquals(ProblemState.Action.RECHECK, relay.action)
        assertEquals("page.example.workers.dev isn't answering · retrying", relay.subtitle)
        assertEquals(setOf("relay"), relay.replacesBanners)
    }

    @Test fun `an offline Mac is slate, names its last heartbeat, and explains a stop near the cutoff`() {
        val off = ProblemState.build(inputs(presence = MacPresence.Offline(nwNow.minusSeconds(14L * 60))))!!
        assertEquals(ProblemState.Kind.MAC_ASLEEP, off.kind)
        assertEquals(ProblemState.Tone.SLATE, off.tone)
        assertEquals("Studio MBP is offline", off.title)
        assertEquals("Last heartbeat 14m ago", off.subtitle)
        assertNull("no re-pair for a recent offline Mac", off.secondaryTitle)
        val near = ProblemState.build(inputs(presence = MacPresence.Offline(nwNow.minusSeconds(14L * 60)), battery = 12, onAC = false, cutoff = 10))!!
        assertTrue(near.details.any { it.text == "It was at 12% — probably the cutoff" })
        val well = ProblemState.build(inputs(presence = MacPresence.Offline(nwNow.minusSeconds(14L * 60)), battery = 20, onAC = false, cutoff = 10))!!
        assertFalse(well.details.any { it.text.startsWith("It was at") })
        val paused = ProblemState.build(inputs(presence = MacPresence.Offline(nwNow.minusSeconds(14L * 60)), pausedSessions = 3))!!
        assertTrue(paused.details.any { it.text == "Your 3 sessions were paused with summaries" })
    }

    @Test fun `a Mac gone for over an hour offers a re-pair, and a stale one is named as stopped checking in`() {
        val gone = ProblemState.build(inputs(presence = MacPresence.Offline(nwNow.minusSeconds(2L * 3600))))!!
        assertEquals(ProblemState.Action.REPAIR, gone.secondaryAction)
        assertEquals("Re-pair…", gone.secondaryTitle)
        val stale = ProblemState.build(inputs(presence = MacPresence.Stale(nwNow.minusSeconds(300))))!!
        assertEquals("Studio MBP stopped checking in", stale.title)
    }
}
