package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import kotlin.math.abs
import kotlin.math.sqrt

/**
 * The five signature motions' timing and phase models, number for number with iOS/Tests/LogicTests.swift
 * ("Signature motion: the timing and phase models" and "Hold ring"). The Mac pins the same pulse table, so a
 * drift in any port shows up here.
 */
class SignatureMotionTest {
    private fun near(a: Double, b: Double, tol: Double = 1e-6) = abs(a - b) <= tol
    private fun assertNear(msg: String, expected: Double, actual: Double, tol: Double = 1e-6) =
        assertTrue("$msg: expected $expected, got $actual", near(actual, expected, tol))

    private val rt0: Instant = Instant.ofEpochSecond(978_307_200) // iOS's reference date
    private fun plus(s: Double): Instant = rt0.plusNanos((s * 1e9).toLong())

    // region The curves

    @Test
    fun curvesAreClampedSmoothAndTheBoardsSpring() {
        assertTrue("clamp01 holds 0..1", MotionCurve.clamp01(-0.5) == 0.0 && MotionCurve.clamp01(1.5) == 1.0)
        assertNear("progress over a segment", 0.5, MotionCurve.progress(0.5, 0.0, 1.0))
        assertEquals("a zero-length segment is a step (before)", 0.0, MotionCurve.progress(1.0, 2.0, 2.0), 0.0)
        assertEquals("a zero-length segment is a step (after)", 1.0, MotionCurve.progress(3.0, 2.0, 2.0), 0.0)
        assertNear("smoothstep half", 0.5, MotionCurve.smooth(0.5))
        assertNear("smoothstep quarter", 0.15625, MotionCurve.smooth(0.25))
        assertNear("ease out is cubic", 0.875, MotionCurve.easeOut(0.5))
        assertNear("ease in is cubic", 0.125, MotionCurve.easeIn(0.5))
        assertNear("the approach spring at 180 ms", 0.7519, MotionCurve.spring(0.18, 0.5, 0.8), 1e-3)
        val overshoot = MotionCurve.spring(0.36, 0.5, 0.8)
        assertTrue("the spring overshoots a little at 360 ms ($overshoot)", near(overshoot, 1.0096, 1e-3) && overshoot > 1)
        assertNear("and has settled by 520 ms", 1.0, MotionCurve.spring(0.52, 0.5, 0.8), 0.01)
        assertNear("critically damped: no overshoot, 0.89 at 300 ms", 0.8900, MotionCurve.spring(0.3, 0.5, 1.0), 1e-3)
        assertTrue("no time, no motion; a zero period is at once", MotionCurve.spring(0.0, 0.5, 0.8) == 0.0 && MotionCurve.spring(2.0, 0.0, 0.8) == 1.0)
        assertNear("one soft shake", 0.7656, MotionCurve.shake(0.0525), 1e-3)
        assertNear("the shake crosses zero", 0.0, MotionCurve.shake(0.105), 1e-9)
        assertTrue("nothing before or after the shake", MotionCurve.shake(0.0) == 0.0 && MotionCurve.shake(0.5) == 0.0)
    }

    // endregion

    // region The pulse

    @Test
    fun pulseQuietIsStillWorkingBreathesWaitingRingsPauseDims() {
        val quiet = PulseModel(0, 0)
        assertTrue("quiet runs no clock", quiet.mode == PulseModel.Mode.QUIET && !quiet.isAnimated && quiet.framesPerSecond == 0.0 && quiet.staticCount == null)
        val paused = PulseModel(3, 2, paused = true)
        assertTrue("a battery pause wins, and is still", paused.mode == PulseModel.Mode.DUSK && !paused.isAnimated && paused.ringCount == 0)
        val waiting = PulseModel(3, 3, longestWait = 300.0)
        assertTrue("waiting rings at 30 fps at most", waiting.mode == PulseModel.Mode.WAITING && waiting.staticCount == 3 && waiting.framesPerSecond == 30.0)
        val working = PulseModel(3, 0)
        assertTrue("working breathes at 20 fps", working.mode == PulseModel.Mode.WORKING && working.isAnimated && working.framesPerSecond == 20.0)
        assertNear("breath with one", 4.0, PulseModel(1, 0).breathPeriod)
        assertNear("breath with five", 3.4, PulseModel(5, 0).breathPeriod)
        assertNear("breath floor", 3.0, PulseModel(20, 0).breathPeriod)
        val one = PulseModel(1, 0)
        assertTrue(
            "out, half, in, out over one breath",
            near(one.breath(0.0), 0.0) && near(one.breath(1.0), 0.5) && near(one.breath(2.0), 1.0) && near(one.breath(4.0), 0.0),
        )
        assertNear("not working: the resting half", 0.5, quiet.breath(1.0))
        assertNear("fresh wait", 3.0, PulseModel(0, 1, longestWait = 0.0).rippleInterval)
        assertNear("five minutes", 2.25, PulseModel(0, 1, longestWait = 300.0).rippleInterval)
        assertNear("capped at 1.5 s", 1.5, PulseModel(0, 1, longestWait = 3600.0).rippleInterval)
        assertTrue(
            "one ring per waiting item, at most four",
            PulseModel(0, 1).ringCount == 1 && PulseModel(0, 3).ringCount == 3 && PulseModel(0, 9).ringCount == 4,
        )
        assertNear("three waiting: ring life", 4.5, PulseModel(0, 3, longestWait = 300.0).ringLifetime)
        assertNear("three waiting: a ring every 1.5 s, the cap", 1.5, PulseModel(0, 3, longestWait = 300.0).emissionInterval)
        val spread = PulseModel(0, 3).ripples(0.0)
        assertEquals(3, spread.size)
        assertNear("evenly spread", 1.0 / 3, spread[1].progress)
        assertNear("fading in", 0.5443, spread[1].opacity, 1e-3)
        assertNear("then out as they open", 0.1925, spread[2].opacity, 1e-3)
        assertNear("the newest has not shown yet", 0.0, spread[0].opacity)
        val half = PulseModel(0, 1, longestWait = 0.0).ripples(1.5)
        assertTrue("one ring half way out at 1.5 s", half.size == 1 && near(half[0].progress, 0.5) && near(half[0].opacity, 0.3536, 1e-3))
        assertTrue(
            "only the last item clearing exhales, not the battery pause",
            PulseModel.exhales(PulseModel.Mode.WAITING, PulseModel.Mode.WORKING) && PulseModel.exhales(PulseModel.Mode.WAITING, PulseModel.Mode.QUIET) &&
                !PulseModel.exhales(PulseModel.Mode.WAITING, PulseModel.Mode.DUSK) && !PulseModel.exhales(PulseModel.Mode.WORKING, PulseModel.Mode.QUIET),
        )
        val ex0 = PulseModel.exhale(0.0)
        assertTrue("the exhale starts amber and still", near(ex0.colour, 0.0) && near(ex0.swell, 0.0) && near(ex0.aurora, 0.0) && !ex0.finished)
        val ex4 = PulseModel.exhale(0.4)
        assertTrue("half way: half turned, the swell at its peak", near(ex4.colour, 0.5) && near(ex4.swell, 0.8017, 1e-3) && near(ex4.aurora, 0.1562, 1e-3))
        val ex8 = PulseModel.exhale(0.8)
        assertTrue("teal by 800 ms, the long settle still going", near(ex8.colour, 1.0) && near(ex8.swell, 0.8648, 1e-3) && near(ex8.aurora, 0.5))
        assertTrue(
            "the aurora settles by 1.6 s, and not before",
            !PulseModel.exhale(1.5).finished && PulseModel.exhale(1.6).finished && near(PulseModel.exhale(1.6).aurora, 1.0),
        )
        assertNear("the oldest waiting item sets the ripple pace", 100.0, PulseModel.longestWait(listOf(NOW.minusSeconds(100), NOW.minusSeconds(40)), NOW))
        assertEquals(0.0, PulseModel.longestWait(emptyList(), NOW), 0.0)
        assertTrue(
            "every pulse counts the decisions, else the looks",
            NowModel.pulseWaiting(2, 1) == 2 && NowModel.pulseWaiting(0, 3) == 3 && NowModel.pulseWaiting(0, 0) == 0,
        )
    }

    /** testPulseTimingsMatchTheMac: the same table the Mac's SignatureMotionTests and the iPhone's pin. */
    @Test
    fun pulseTimingsMatchTheMac() {
        for ((agents, period) in listOf(1 to 4.0, 5 to 3.4, 20 to 3.0)) {
            assertNear("breath with $agents working matches the Mac", period, PulseModel(agents, 0).breathPeriod)
        }
        val emission = listOf(Triple(1, 0.0, 3.0), Triple(1, 300.0, 2.25), Triple(1, 3600.0, 1.5), Triple(3, 0.0, 1.5), Triple(3, 300.0, 1.5), Triple(3, 3600.0, 1.5))
        for ((waiting, wait, interval) in emission) {
            assertNear("a ring every $interval s with $waiting waiting for $wait s", interval, PulseModel(0, waiting, longestWait = wait).emissionInterval)
        }
        for ((waiting, wait, life) in listOf(Triple(1, 0.0, 3.0), Triple(3, 0.0, 4.5), Triple(4, 3600.0, 6.0))) {
            assertNear("ring life with $waiting waiting matches the Mac", life, PulseModel(0, waiting, longestWait = wait).ringLifetime)
        }
        assertNear("ring fade in", 0.46297, PulseModel.ringOpacity(0.05), 1e-4)
        assertNear("ring half way", 0.35355, PulseModel.ringOpacity(0.5), 1e-4)
    }

    @Test
    fun exhaleColoursBlendThroughOklch() {
        val amber = PerceptualMix.Rgb(245.0 / 255, 177.0 / 255, 76.0 / 255)
        val teal = PerceptualMix.Rgb(94.0 / 255, 234.0 / 255, 212.0 / 255)
        assertEquals("exactly its start at 0", amber, PerceptualMix.mix(amber, teal, 0.0))
        assertEquals("exactly its end at 1", teal, PerceptualMix.mix(amber, teal, 1.0))
        assertEquals("clamped below", amber, PerceptualMix.mix(amber, teal, -2.0))
        fun chroma(c: PerceptualMix.Rgb): Double = PerceptualMix.oklab(c).let { sqrt(it.a * it.a + it.b * it.b) }
        val mid = PerceptualMix.mix(amber, teal, 0.5)
        val plain = PerceptualMix.Rgb((amber.r + teal.r) / 2, (amber.g + teal.g) / 2, (amber.b + teal.b) / 2)
        assertTrue(
            "half way it keeps its colour (green), where an sRGB blend goes khaki",
            chroma(mid) > 1.3 * chroma(plain) && chroma(mid) > 0.9 * minOf(chroma(amber), chroma(teal)) && mid.g > mid.r,
        )
        val lab = PerceptualMix.oklab(amber)
        val back = PerceptualMix.srgb(lab.l, lab.a, lab.b)
        assertTrue("Oklab round-trips", near(back.r, amber.r) && near(back.g, amber.g) && near(back.b, amber.b))
        val dark = PerceptualMix.mix(PerceptualMix.Rgb(26.0 / 255, 19.0 / 255, 6.0 / 255), PerceptualMix.Rgb(11.0 / 255, 27.0 / 255, 36.0 / 255), 0.5, keepChroma = false)
        assertTrue("the sky behind the curtains meets at a neutral night", chroma(dark) < 0.02)
    }

    // endregion

    // region Final approach

    @Test
    fun finalApproachDropsFromThePulseAndTheRowsBelowEaseDown() {
        val a0 = ApproachModel.frame(0.0)
        assertTrue(
            "the card leaves the pulse small and faint: an empty outline",
            near(a0.travel, 0.0) && near(a0.scale, 0.35) && near(a0.opacity, 0.4) && near(a0.contrail, 0.0) && near(a0.glow, 0.0) &&
                near(a0.content, 0.0) && near(a0.edge, 0.6) && !a0.finished,
        )
        val a18 = ApproachModel.frame(0.18)
        assertTrue(
            "at 180 ms it is mid-air, full size, with its contrail and glow, still empty (board 07)",
            near(a18.travel, 0.7519, 1e-3) && near(a18.scale, 0.9999, 1e-3) && near(a18.contrail, 0.8) && near(a18.glow, 1.0) && near(a18.content, 0.0),
        )
        assertNear("at 90 ms it is passing the Horizon's words: no words of its own", 0.0, ApproachModel.frame(0.09).content)
        assertTrue("landed at 360 ms with its words", near(ApproachModel.frame(0.36).content, 1.0) && near(ApproachModel.frame(0.36).edge, 0.0))
        assertTrue(
            "it is full size before any of its words show",
            (0..52).map { ApproachModel.frame(it * 0.01) }.all { it.content == 0.0 || near(it.scale, 1.0) },
        )
        assertTrue(
            "the same content curve as the Mac's",
            near(ApproachModel.content(0.8), 0.0) && near(ApproachModel.content(0.885), 0.5) && near(ApproachModel.content(0.97), 1.0),
        )
        val a45 = ApproachModel.frame(0.45)
        assertTrue("after landing, the contrail and glow fade", near(a45.contrail, 0.3254, 1e-3) && near(a45.glow, 0.4067, 1e-3))
        val a52 = ApproachModel.frame(0.52)
        assertTrue(
            "settled in its slot with the glow off by 520 ms",
            a52.finished && near(a52.travel, 1.0) && near(a52.scale, 1.0) && near(a52.opacity, 1.0) && near(a52.contrail, 0.0) && near(a52.glow, 0.0),
        )
        assertTrue(
            "the card drops from the pulse to its slot",
            near(ApproachModel.offset(400.0, 0.0), -400.0) && near(ApproachModel.offset(400.0, 0.18), -99.2, 0.2) && near(ApproachModel.offset(400.0, 1.0), 0.0),
        )
        assertTrue(
            "the rows below ease down by one card height",
            near(ApproachModel.pushOffset(100.0, 0.0), -100.0) && near(ApproachModel.pushOffset(100.0, 0.18), -24.8, 0.1) && near(ApproachModel.pushOffset(100.0, 0.6), 0.0),
        )
        assertTrue("the first look is never a flood of approaches", ApproachModel.arrivals(null, listOf("a")).isEmpty())
        assertEquals("only new ids, in ranked order", listOf("c", "d"), ApproachModel.arrivals(listOf("a", "b"), listOf("c", "a", "d", "b")))
        val sch = ApproachModel.schedule(listOf("c", "d"), 0.0)
        assertTrue("two arrivals leave a stagger apart", near(sch["c"] ?: -1.0, 0.0) && near(sch["d"] ?: -1.0, 0.09))
        assertTrue("more than three at once just appear", ApproachModel.schedule(listOf("a", "b", "c", "d"), 0.0).isEmpty())
    }

    // endregion

    // region The receipt thread

    private fun pendingAt(kind: RowAction.Kind, commit: CommitGesture?, armed: Boolean = true) = PendingAction("r1", kind, "", commit, rt0, armed)

    @Test
    fun receiptThreadSucceedsOnlyOnTheMacsConfirmation() {
        val arming = ReceiptThread.derive(pendingAt(RowAction.Kind.DENY, CommitGesture.TAP), null, changedAt = null, now = plus(0.6))
        assertTrue("the arm ring winds round the dot", arming.stage == ReceiptThread.Stage.Arming && near(arming.arm, 0.5) && arming.word == "arm" && arming.moving)
        val fired = pendingAt(RowAction.Kind.DENY, CommitGesture.TAP, armed = false)
        val afterArm = ReceiptThread.derive(fired, null, changedAt = null, now = plus(1.45))
        assertTrue("after the arm it reaches towards the relay", afterArm.stage == ReceiptThread.Stage.Sending && near(afterArm.reach, 0.3675, 1e-3))
        val inFlight = ReceiptThread.derive(fired, ReplyDelivery.Sending, changedAt = rt0, now = plus(0.25))
        assertTrue("a delivery still sending keeps reaching", inFlight.stage == ReceiptThread.Stage.Sending && near(inFlight.reach, 0.3675, 1e-3))
        val biometric = ReceiptThread.derive(pendingAt(RowAction.Kind.APPROVE, CommitGesture.HOLD, armed = false), null, changedAt = null, now = plus(0.25))
        assertTrue(
            "an Irreversible approve sends the moment biometrics passed, with no second arm",
            biometric.stage == ReceiptThread.Stage.Sending && near(biometric.reach, 0.3675, 1e-3),
        )

        val onRelay = ReceiptThread.derive(null, ReplyDelivery.Sent(false, rt0), changedAt = null, now = plus(0.7))
        assertTrue(
            "the relay has it; the Mac has not confirmed",
            onRelay.stage == ReceiptThread.Stage.Sent && near(onRelay.reach, 0.5) && onRelay.relayLit && !onRelay.macLit && onRelay.word == "sent",
        )
        assertNear("a glint travels past the relay", 0.75, onRelay.glint ?: -1.0, 1e-3)
        val longWait = ReceiptThread.derive(null, ReplyDelivery.Sent(false, rt0), changedAt = null, now = plus(61.0))
        assertTrue("after a minute it says so and stops moving", longWait.word == "sent · waiting for your Mac" && longWait.glint == null && !longWait.moving)
        val queued = ReceiptThread.derive(null, ReplyDelivery.Sent(true, rt0), changedAt = null, now = plus(1.0))
        assertTrue("a queued reply is not a success", queued.stage == ReceiptThread.Stage.Queued && queued.word == "queued · Mac offline" && !queued.isSuccess)

        fun confirmed(s: Double) = ReceiptThread.derive(null, ReplyDelivery.Delivered(null), changedAt = rt0, now = plus(s))
        assertTrue(
            "typed once the Mac has confirmed, and not a moment before",
            confirmed(0.18).stage == ReceiptThread.Stage.Typed && near(confirmed(0.18).reach, 0.9375, 1e-3) && !confirmed(0.18).macLit,
        )
        assertTrue(
            "then the Mac lights, then verified",
            confirmed(0.36).macLit && confirmed(0.6).stage == ReceiptThread.Stage.Verified && confirmed(0.6).word == "verified ✓",
        )
        assertTrue("the dot turns teal and the rings draw in", near(confirmed(0.8).dotTeal, 0.5, 1e-3) && near(confirmed(0.8).rings, 0.5, 1e-3))
        assertTrue(
            "the card folds, drifts into Settled, and stops",
            near(confirmed(1.15).fold, 0.5, 1e-3) && near(confirmed(1.6).fold, 1.0) && near(confirmed(1.6).drift, 1.0) && !confirmed(1.6).moving,
        )
        assertEquals("an old confirmation is drawn settled", ReceiptThread.Stage.Verified, ReceiptThread.derive(null, ReplyDelivery.Delivered(null), changedAt = null, now = rt0).stage)

        fun failedAt(s: Double) = ReceiptThread.derive(null, ReplyDelivery.Failed("nope"), changedAt = rt0, now = plus(s))
        assertTrue(
            "a failure starts where the thread was, and says why",
            near(failedAt(0.0).reach, 0.5) && near(failedAt(0.0).shake, 0.0) && failedAt(0.0).isFailure && failedAt(0.0).word == "nope",
        )
        assertTrue("it snaps back and shakes once", near(failedAt(0.12).reach, 0.4375, 1e-3) && near(failedAt(0.12).shake, -0.2214, 1e-3))
        assertTrue("snapped back, and still once the shake is over", near(failedAt(0.24).reach, 0.0) && !failedAt(0.5).moving)
        assertEquals("an empty failure still says something", "Couldn't deliver the reply", ReceiptThread.derive(null, ReplyDelivery.Failed(""), changedAt = rt0, now = rt0).word)
        assertEquals("Prompt closed before your answer", ReceiptThread.derive(null, ReplyDelivery.Gone, changedAt = rt0, now = rt0).word)
        assertEquals("Already answered at the Mac", ReceiptThread.derive(null, ReplyDelivery.AlreadyReplied, changedAt = rt0, now = rt0).word)
        assertEquals(
            "a problem on this phone beats the Mac's news", "No passcode",
            ReceiptThread.derive(null, ReplyDelivery.Delivered(null), localProblem = "No passcode", changedAt = rt0, now = rt0).word,
        )
        assertEquals("nothing under way draws nothing", ReceiptThread.Stage.Idle, ReceiptThread.derive(null, null, changedAt = null, now = rt0).stage)
    }

    /** The invariant: no delivery other than a confirmed one ever draws a success, at any moment. */
    @Test
    fun noSuccessIsDrawnWithoutAConfirmedDelivery() {
        val fired = pendingAt(RowAction.Kind.DENY, CommitGesture.TAP, armed = false)
        val never: List<ReplyDelivery?> = listOf(null, ReplyDelivery.Sending, ReplyDelivery.Sent(false, rt0), ReplyDelivery.Sent(true, rt0), ReplyDelivery.Failed("x"), ReplyDelivery.AlreadyReplied, ReplyDelivery.Gone)
        var leaked = 0
        for (d in never) {
            var step = 0.0
            while (step <= 120.0) {
                val f = ReceiptThread.derive(fired, d, changedAt = rt0, now = plus(step))
                if (f.isSuccess || f.stage == ReceiptThread.Stage.Verified || f.stage == ReceiptThread.Stage.Typed) leaked++
                step += 0.5
            }
        }
        assertEquals("no success is drawn without a confirmed delivery", 0, leaked)
    }

    @Test
    fun receiptInputRunsAClockOnlyWhileItMoves() {
        val moving = ReceiptThreadInput(null, ReplyDelivery.Delivered(null), changedAt = rt0)
        assertEquals("a confirmed card moves for 1.6 s", plus(1.6), moving.movingUntil(rt0))
        val arm = ReceiptThreadInput(pendingAt(RowAction.Kind.DENY, CommitGesture.TAP), null)
        assertEquals("the arm ring runs its 1.2 s", plus(1.2), arm.movingUntil(plus(0.3)))
        assertNull("a queued reply does not move", ReceiptThreadInput(null, ReplyDelivery.Sent(true, rt0), changedAt = rt0).movingUntil(rt0))
        assertTrue("nothing to draw is empty; a delivery is not", ReceiptThreadInput(null, null).isEmpty && !moving.isEmpty)
    }

    @Test
    fun aConfirmedRowKeepsItsPlaceWhileItFolds() {
        fun row(id: String) = NowRowBuilder.row(
            Intervention(id = id, sessionId = "w$id", cwd = "/p", projectName = "p", kind = InterventionKind.APPROVAL, openedAt = rt0, context = "[Bash] ls"),
            null, "M",
        )
        val a = row("a")
        val b = row("b")
        val c = row("c")
        val shown = listOf(a, b, c)
        val fresh = listOf(a, c)
        val folding = DepartingRows.merge(shown, fresh, mapOf("b" to ReplyDelivery.Delivered(null)), mapOf("b" to rt0), plus(0.5))
        assertEquals("a confirmed row keeps its place while it folds", listOf("a", "b", "c"), folding.rows.map { it.id })
        assertEquals(setOf("b"), folding.ghosts)
        val folded = DepartingRows.merge(shown, fresh, mapOf("b" to ReplyDelivery.Delivered(null)), mapOf("b" to rt0), plus(1.6))
        assertTrue("then it is gone", folded.rows.map { it.id } == listOf("a", "c") && folded.ghosts.isEmpty())
        val refused = DepartingRows.merge(shown, fresh, mapOf("b" to ReplyDelivery.Failed("x")), mapOf("b" to rt0), plus(0.5))
        assertTrue("a failed row is not kept as a ghost", refused.ghosts.isEmpty() && refused.rows.map { it.id } == listOf("a", "c"))
        assertEquals("the next expiry is the end of the fold", plus(1.6), DepartingRows.nextExpiry(setOf("b"), mapOf("b" to rt0)))
    }

    // endregion

    // region Dusk and dawn

    @Test
    fun duskDimsTogetherAndEachStarRelightsOnlyOnceConfirmed() {
        val d0 = DawnModel.dusk(0.0)
        assertTrue("the pause begins at the working sky", near(d0.aurora, 0.0) && near(d0.stars, 1.0) && near(d0.band, 0.0))
        val d24 = DawnModel.dusk(0.24)
        assertTrue("the stars swell once as they breathe out", near(d24.stars, 1.12, 1e-3) && near(d24.aurora, 0.0607, 1e-3))
        val d12 = DawnModel.dusk(1.2)
        assertTrue("then dim together to 30%, and the grey band holds", near(d12.stars, 0.3, 1e-3) && near(d12.starScale, 0.9, 1e-3) && near(d12.band, 0.6995, 1e-3))
        assertTrue("dusk has settled by 1.6 s", near(DawnModel.dusk(1.6).band, 1.0) && near(DawnModel.dusk(1.6).aurora, 1.0))
        assertTrue(
            "the light reaches the horizon first and the top last",
            near(DawnModel.sweepReaches(1.0), 0.0) && near(DawnModel.sweepReaches(0.0), 1.8) && near(DawnModel.sweepReaches(0.5), 0.3713, 1e-3),
        )
        assertNear("the sweep eases out", 0.875, DawnModel.sweep(0.9))

        val times = DawnModel.relightTimes(
            listOf(
                DawnModel.StarInput("a", 0.9, 0.3), DawnModel.StarInput("b", 0.9, 0.3),
                DawnModel.StarInput("c", 0.1, 0.2), DawnModel.StarInput("d", 0.5, null),
            ),
        )
        assertNull("an unconfirmed star stays dim", times["d"])
        assertTrue("two stars confirmed together relight one by one", near(times["a"] ?: -1.0, 0.3) && near(times["b"] ?: -1.0, 0.46))
        val reachC = DawnModel.sweepReaches(0.1)
        assertTrue("the top star waits for the sweep", near(times["c"] ?: -1.0, reachC, 1e-9) && near(DawnModel.sweep(reachC), 0.9, 1e-6))
        val ordered = listOf("a", "b", "c").mapNotNull { times[it] }.sorted()
        assertTrue("never two stars at once", ordered.zipWithNext().all { (x, y) -> y - x >= DawnModel.stagger - 1e-9 })

        assertTrue("a star stays dim until its moment", near(DawnModel.starBrightness(0.2, 0.3), 0.3) && near(DawnModel.starBrightness(0.3, 0.3), 0.3))
        assertTrue("then comes up to full", near(DawnModel.starBrightness(0.5, 0.3), 0.9572, 1e-3) && near(DawnModel.starBrightness(0.63, 0.3), 1.0, 1e-3))
        assertNear("a star never confirmed stays dim however long the dawn runs", 0.3, DawnModel.starBrightness(5.0, null))
        assertTrue("the flare stays within its bound", DawnModel.starBrightness(0.63, 0.3) <= 1.15)

        val w0 = DawnModel.dawn(0.0, 1.1)
        assertTrue("dawn starts at the horizon, in the dusk", near(w0.sweep, 0.0) && near(w0.warmth, 0.0) && near(w0.band, 1.0) && near(w0.aurora, 1.0) && !w0.finished)
        val w54 = DawnModel.dawn(0.54, 1.1)
        assertTrue("the sun rises and the band fades", near(w54.sweep, 0.657, 1e-3) && near(w54.warmth, 0.5, 1e-3) && near(w54.band, 0.352, 1e-3))
        val w18 = DawnModel.dawn(1.8, 1.1)
        assertTrue(
            "at the top the gold is full and the working aurora is coming back",
            near(w18.sweep, 1.0) && near(w18.warmth, 1.0) && near(w18.band, 0.0) && near(w18.aurora, 0.4818, 1e-3),
        )
        assertTrue("with no star to wait for, the dawn ends after its settle", !DawnModel.dawn(2.99, null).finished && DawnModel.dawn(3.01, null).finished)
        assertTrue("a late relight holds the dawn open until it has settled", !DawnModel.dawn(4.0, 2.4).finished && DawnModel.dawn(4.2, 2.4).finished)
        val br = DawnModel.briefSunrise(0.9, 0.5)
        assertTrue("the Brief's sunrise is as bright as the absence was finished", near(br.sweep, 0.875) && near(br.strength, 0.625))
        val brFull = DawnModel.briefSunrise(5.0, 2.0)
        assertTrue("and clamps to full", near(brFull.sweep, 1.0) && near(brFull.strength, 1.0))
    }

    @Test
    fun duskDawnLogRemembersThePauseAndTheConfirmedResumes() {
        val base = rt0
        val log = DuskDawnLog()
        log.observe(false, setOf("a", "b"), base)
        log.observe(true, emptySet(), base.plusSeconds(10))
        assertTrue("a pause remembers what was working the moment before", log.isPaused && log.duskAt == base.plusSeconds(10) && log.affected == setOf("a", "b"))
        log.observe(true, setOf("c"), base.plusSeconds(20))
        assertEquals("a session that comes back during the pause joins the affected", setOf("a", "b", "c"), log.affected)
        log.observe(false, emptySet(), base.plusSeconds(30))
        assertTrue("power back: the dawn begins", !log.isPaused && log.duskAt == null && log.dawnAt == base.plusSeconds(30))
        log.observe(false, setOf("b", "z"), base.plusSeconds(31))
        assertEquals("only an affected session that is seen working counts", mapOf("b" to base.plusSeconds(31)), log.resumedAt)
        val stars = log.dawnStars(mapOf("b" to 0.2)).associateBy { it.id }
        assertTrue(
            "the dawn carries each star's height and its confirmation",
            near(stars["b"]?.confirmedAt ?: -1.0, 1.0) && stars["a"]?.confirmedAt == null && stars["c"]?.confirmedAt == null && near(stars["b"]?.y ?: -1.0, 0.2),
        )

        val cold = DuskDawnLog()
        cold.observe(true, setOf("x"), base)
        assertTrue("a pause already under way is drawn settled, not replayed", cold.duskAt == DuskDawnLog.DISTANT_PAST && cold.affected == setOf("x"))

        val slow = DuskDawnLog()
        slow.observe(false, setOf("a"), base)
        slow.observe(true, emptySet(), base.plusSeconds(10))
        slow.observe(false, emptySet(), base.plusSeconds(30))
        slow.observe(false, emptySet(), base.plusSeconds(121))
        assertNull("a dawn that never confirms stops after 90 s", slow.dawnAt)

        val full = DuskDawnLog()
        full.observe(false, setOf("a", "b"), base)
        full.observe(true, emptySet(), base.plusSeconds(10))
        full.observe(false, emptySet(), base.plusSeconds(30))
        full.observe(false, setOf("a", "b"), base.plusSeconds(31))
        assertTrue("all back, but the dawn plays out first", full.dawnAt != null)
        full.observe(false, setOf("a", "b"), base.plusMillis(35_200))
        assertNull("once everyone is back and the sweep has settled, the dawn clears", full.dawnAt)
    }

    // endregion

    // region The hold ring

    @Test
    fun holdRingTimingTicksWarmthAndCopy() {
        val stop = HoldRingSpec.stopAll
        assertTrue("pulse ring hidden at 300 ms", stop.progress(0.3) == 0.0 && !stop.isVisible(0.3))
        assertNear("pulse ring half at 5.15 s", 0.5, stop.progress(5.15))
        assertTrue("Stop-all completes only after a 10 s hold", stop.isComplete(10.0) && !stop.isComplete(9.99))
        val irr = HoldRingSpec.irreversible
        assertTrue("irreversible ring hidden for 300 ms", irr.progress(0.3) == 0.0 && !irr.isVisible(0.3))
        assertTrue("irreversible ring fills over 1.2 s after the dead zone", near(irr.progress(0.9), 0.5) && irr.isComplete(1.5))
        val ticks = HoldRingSpec.ticksCrossed(0.2, 0.8)
        assertTrue("ticks at 25, 50 and 75% (board 07)", ticks.size == 3 && near(ticks[0], 0.25) && near(ticks[1], 0.5) && near(ticks[2], 0.75))
        assertEquals("a firm tick when full", listOf(1.0), HoldRingSpec.ticksCrossed(0.9, 1.0))
        assertTrue("unwinding crosses no ticks", HoldRingSpec.ticksCrossed(0.7, 0.3).isEmpty())
        assertNear("amber until two thirds", 0.0, HoldRingSpec.warmth(2.0 / 3))
        assertNear("red at full", 1.0, HoldRingSpec.warmth(1.0))
        assertNear("halfway warm at five sixths", 0.5, HoldRingSpec.warmth(5.0 / 6))
        assertNear("unwinds at the fill speed", 0.5, stop.unwound(1.0, 0.6))
        assertEquals("unwound is floored at zero", 0.0, stop.unwound(0.2, 5.0), 0.0)
        assertEquals("Press Esc in 4 busy sessions", HoldRingSpec.stopScope(4))
        assertEquals("Press Esc in 1 busy session", HoldRingSpec.stopScope(1))
        assertEquals("No busy sessions to stop", HoldRingSpec.stopScope(0))
        assertEquals("Hold to confirm", HoldRingSpec.prompt(0.0, "Fingerprint"))
        assertEquals("Keep holding · Fingerprint next", HoldRingSpec.prompt(0.5, "Fingerprint"))
        assertEquals("Fingerprint next", HoldRingSpec.prompt(1.0, "Fingerprint"))
    }

    @Test
    fun holdRingBurstAfterBiometrics() {
        val b0 = HoldRingSpec.burst(0.0)
        assertTrue("the burst opens from the full ring", near(b0.scale, 1.0) && near(b0.opacity, 0.9) && near(b0.flash, 0.0))
        val b15 = HoldRingSpec.burst(0.15)
        assertTrue("the core flashes a quarter of the way through", near(b15.scale, 1.2602, 1e-3) && near(b15.opacity, 0.8859, 1e-3) && near(b15.flash, 1.0))
        val bEnd = HoldRingSpec.burst(0.6)
        assertTrue("and is gone by 600 ms", near(bEnd.scale, 1.0) && near(bEnd.opacity, 0.0) && near(bEnd.flash, 0.0))
        assertEquals("Stop-all and Irreversible share the dead zone", HoldRingSpec.stopAll.deadZone, HoldRingSpec.irreversible.deadZone, 0.0)
        assertEquals("Stop-all is a 10 s hold; Irreversible stays 1.5 s", 10.0, HoldRingSpec.stopAll.deadZone + HoldRingSpec.stopAll.fill, 1e-9)
        assertFalse(HoldRingSpec.stopAll.isVisible(0.0))
    }

    // endregion
}
