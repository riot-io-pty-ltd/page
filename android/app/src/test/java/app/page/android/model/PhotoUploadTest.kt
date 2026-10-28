package app.page.android.model

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The upload state machine (docs/SESSIONS-PROTOCOL.md "Images (images-v1)", "Upload"): at most 3 pieces in flight,
 * a new clientId for every retried piece, 429 backs off, 503 stops, `inputImages` only after every piece got its
 * 202, one resend of what the Mac says is missing, and a 30 s wait for the result. Driven by a scripted transport.
 */
class PhotoUploadTest {
    private fun photo(size: Int): PreparedPhoto = PreparedPhoto(PhotoFixtures.fakeJpeg(size), PhotoFormat.JPEG, 10, 10)

    private fun uploads(vararg sizes: Int) = sizes.mapIndexed { i, s -> UploadPhoto("img_000$i", photo(s)) }

    private fun result(json: String, clientId: String = "ignored"): CommandResult =
        (SessionsPlaintext.decode("""{"kind":"result","seq":1,"ts":1761300000000,"clientId":"$clientId",$json}""")!!.update as SessionsUpdate.Result).result

    private class Sent(val command: SessionCommand, val clientId: String, val inFlight: Int)

    /** A transport that answers pieces from [pieceAnswer] and inputImages with the next of [results] (or silence). */
    private class Fake(
        val pieceAnswer: (SessionCommand.ImagePart, Int) -> SessionCommandOutcome = { _, _ -> SessionCommandOutcome.Accepted },
        val inputAnswer: SessionCommandOutcome = SessionCommandOutcome.Accepted,
        val results: MutableList<CommandResult?> = mutableListOf(),
    ) : PhotoTransport {
        val log = mutableListOf<Sent>()
        var inFlight = 0
        var maxInFlight = 0
        val tries = HashMap<String, Int>()
        val expected = mutableListOf<String>()

        override suspend fun post(command: SessionCommand, clientId: String): SessionCommandOutcome {
            inFlight += 1
            maxInFlight = maxOf(maxInFlight, inFlight)
            log += Sent(command, clientId, inFlight)
            try {
                // Let the other workers start: pieces overlap the way real POSTs do.
                repeat(3) { kotlinx.coroutines.yield() }
                return when (command) {
                    is SessionCommand.ImagePart -> {
                        val key = "${command.imageId}/${command.index}"
                        val n = (tries[key] ?: 0) + 1
                        tries[key] = n
                        pieceAnswer(command, n)
                    }
                    is SessionCommand.InputImages -> inputAnswer
                    else -> error("unexpected $command")
                }
            } finally {
                inFlight -= 1
            }
        }

        override fun expect(clientId: String): ResultWaiter {
            expected += clientId
            val next = if (results.isEmpty()) null else results.removeAt(0)
            return object : ResultWaiter {
                override suspend fun await(timeoutMillis: Long): CommandResult? = next?.copy(clientId = clientId)
                override fun cancel() {}
            }
        }

        val parts: List<SessionCommand.ImagePart> get() = log.map { it.command }.filterIsInstance<SessionCommand.ImagePart>()
        val inputs: List<Sent> get() = log.filter { it.command is SessionCommand.InputImages }
    }

    private var ids = 0
    private fun uploader(t: Fake, pauses: MutableList<Long> = mutableListOf()) =
        PhotoUploader(t, { "c${++ids}" }, { pauses += it })

    private fun run(t: Fake, vararg sizes: Int, pauses: MutableList<Long> = mutableListOf(), progress: MutableList<PhotoProgress> = mutableListOf()): UploadOutcome = runBlocking {
        uploader(t, pauses).run("s1", uploads(*sizes), "caption", null) { progress += it }
    }

    private val delivered = result(""""ok":true,"code":"delivered","detail":"Sent 2 photos","attached":2""")

    @Test fun `every piece is accepted before inputImages goes, then the result is the answer`() {
        val t = Fake(results = mutableListOf(delivered))
        val progress = mutableListOf<PhotoProgress>()
        val out = run(t, 70_000, 20_000, progress = progress)
        // 70_000 -> 3 pieces, 20_000 -> 1 piece.
        assertEquals(4, t.parts.size)
        assertEquals(setOf("img_0000/0", "img_0000/1", "img_0000/2", "img_0001/0"), t.parts.map { "${it.imageId}/${it.index}" }.toSet())
        assertTrue("inputImages is last", t.log.last().command is SessionCommand.InputImages)
        assertEquals(1, t.inputs.size)
        val answered = out as UploadOutcome.Answered
        assertEquals(t.inputs[0].clientId, answered.clientId)
        assertTrue(answered.result.ok)
        assertEquals(2, answered.result.attached)
        val input = t.inputs[0].command as SessionCommand.InputImages
        assertEquals("caption", input.text)
        assertEquals(listOf("img_0000", "img_0001"), input.images.map { it.id })
        assertEquals(listOf(70_000, 20_000), input.images.map { it.bytes })
        assertTrue(progress.any { it.phase == PhotoProgress.Phase.UPLOADING && it.piecesDone == 4 })
        assertEquals(PhotoProgress.Phase.WAITING, progress.last().phase)
        assertEquals(4, progress.last().piecesTotal)
    }

    @Test fun `every piece repeats the photo's metadata and its bytes add up`() {
        val t = Fake(results = mutableListOf(delivered))
        val photos = uploads(100_000)
        runBlocking { uploader(t).run("s1", photos, "", null) }
        val parts = t.parts.sortedBy { it.index }
        assertEquals(4, parts.size)
        assertTrue(parts.all { it.total == 4 && it.bytes == 100_000 && it.sha256 == photos[0].photo.sha256 && it.mime == "image/jpeg" && it.sessionId == "s1" })
        assertEquals(photos[0].photo.bytes.toList(), parts.flatMap { it.data.toList() })
        assertEquals("", (t.inputs[0].command as SessionCommand.InputImages).text)
    }

    @Test fun `at most three pieces are in flight at once, and every POST has its own clientId`() {
        val t = Fake(results = mutableListOf(delivered))
        run(t, 600_000) // 19 pieces
        assertEquals(19, t.parts.size)
        assertEquals(3, t.maxInFlight)
        assertEquals(t.log.size, t.log.map { it.clientId }.toSet().size)
    }

    @Test fun `429 backs off and retries the piece under a new clientId`() {
        val pauses = mutableListOf<Long>()
        val t = Fake(pieceAnswer = { p, n -> if (p.index == 1 && n <= 2) SessionCommandOutcome.RateLimited else SessionCommandOutcome.Accepted }, results = mutableListOf(delivered))
        val out = run(t, 100_000, pauses = pauses)
        assertTrue(out is UploadOutcome.Answered)
        val piece1 = t.log.filter { (it.command as? SessionCommand.ImagePart)?.index == 1 }
        assertEquals(3, piece1.size)
        assertEquals(3, piece1.map { it.clientId }.toSet().size)
        assertEquals(listOf(500L, 1000L), pauses)
        assertEquals("inputImages only after the retried piece got its 202", 1, t.inputs.size)
        assertTrue(t.log.indexOf(t.inputs[0]) == t.log.lastIndex)
    }

    @Test fun `a piece that is rate limited for ever gives up with the relay's words`() {
        val t = Fake(pieceAnswer = { _, _ -> SessionCommandOutcome.RateLimited })
        val out = run(t, 10_000) as UploadOutcome.Stopped
        assertEquals(SessionCommandOutcome.RateLimited.failureMessage, out.message)
        assertFalse(out.macOffline)
        assertTrue(t.inputs.isEmpty())
    }

    @Test fun `503 stops the upload, says the Mac went offline and sends nothing more`() {
        val t = Fake(pieceAnswer = { p, _ -> if (p.index == 2) SessionCommandOutcome.MacOffline else SessionCommandOutcome.Accepted })
        val out = run(t, 900_000) as UploadOutcome.Stopped
        assertTrue(out.macOffline)
        assertEquals("Your Mac went offline", out.message)
        assertTrue("no inputImages", t.inputs.isEmpty())
        assertTrue("it stopped early", t.parts.size < 28)
    }

    @Test fun `a network failure is retried with a new clientId, then stops`() {
        val retried = Fake(pieceAnswer = { p, n -> if (p.index == 0 && n == 1) SessionCommandOutcome.Failed("timeout") else SessionCommandOutcome.Accepted }, results = mutableListOf(delivered))
        val retryPauses = mutableListOf<Long>()
        assertTrue(run(retried, 10_000, pauses = retryPauses) is UploadOutcome.Answered)
        assertEquals("a piece lost in transit goes again at once: no pause of its own", emptyList<Long>(), retryPauses)
        assertEquals(2, retried.parts.size)
        assertEquals(2, retried.log.filter { it.command is SessionCommand.ImagePart }.map { it.clientId }.toSet().size)

        val dead = Fake(pieceAnswer = { _, _ -> SessionCommandOutcome.Failed("no route to host") })
        val out = run(dead, 10_000) as UploadOutcome.Stopped
        assertEquals("no route to host", out.message)
        assertEquals(PhotoUploader.MAX_FAILURES, dead.parts.size)
    }

    @Test fun `a relay that refuses a piece stops it with its message`() {
        val t = Fake(pieceAnswer = { _, _ -> SessionCommandOutcome.Unauthorized })
        val out = run(t, 10_000) as UploadOutcome.Stopped
        assertEquals(SessionCommandOutcome.Unauthorized.failureMessage, out.message)
        assertEquals(1, t.parts.size)
    }

    @Test fun `when inputImages itself is not accepted nothing waits for a result`() {
        val offline = Fake(inputAnswer = SessionCommandOutcome.MacOffline)
        val out = run(offline, 10_000) as UploadOutcome.Stopped
        assertTrue(out.macOffline)
        val refused = Fake(inputAnswer = SessionCommandOutcome.TooLarge)
        assertEquals(SessionComposer.Problem.TooLarge.message, (run(refused, 10_000) as UploadOutcome.Stopped).message)
    }

    @Test fun `missing pieces are sent again once, then a new inputImages under a new clientId`() {
        val missing = result(""""ok":false,"code":"refused","reason":"attachment_missing","detail":"Part of a photo didn't reach your Mac — send it again","missing":["img_0001"]""")
        val t = Fake(results = mutableListOf(missing, delivered))
        val progress = mutableListOf<PhotoProgress>()
        val out = run(t, 70_000, 40_000, progress = progress) // 3 + 2 pieces
        val answered = out as UploadOutcome.Answered
        assertTrue(answered.result.ok)
        assertEquals(2, t.inputs.size)
        assertEquals(2, t.inputs.map { it.clientId }.toSet().size)
        assertEquals(answered.clientId, t.inputs[1].clientId)
        // Only the missing photo's pieces went again: 5 first, then 2 more.
        val resent = t.parts.filter { it.imageId == "img_0001" }
        assertEquals(4, resent.size)
        assertEquals(3, t.parts.count { it.imageId == "img_0000" })
        // The order: all pieces, inputImages, the resend, inputImages.
        val kinds = t.log.map { it.command is SessionCommand.InputImages }
        assertEquals(listOf(5, 8), kinds.withIndex().filter { it.value }.map { it.index })
        assertTrue(progress.any { it.phase == PhotoProgress.Phase.RESENDING })
        // Both inputImages name the same photos with the same ids.
        assertEquals((t.inputs[0].command as SessionCommand.InputImages).images, (t.inputs[1].command as SessionCommand.InputImages).images)
    }

    @Test fun `a second attachment_missing is the answer, never a third try`() {
        val missing = result(""""ok":false,"code":"refused","reason":"attachment_missing","missing":["img_0000"]""")
        val t = Fake(results = mutableListOf(missing, missing, delivered))
        val out = run(t, 10_000) as UploadOutcome.Answered
        assertEquals("attachment_missing", out.result.reason)
        assertEquals(2, t.inputs.size)
    }

    @Test fun `a missing answer that names no photo of this send is just the answer`() {
        val odd = result(""""ok":false,"code":"refused","reason":"attachment_missing","missing":["img_other"]""")
        val t = Fake(results = mutableListOf(odd))
        val out = run(t, 10_000) as UploadOutcome.Answered
        assertEquals("attachment_missing", out.result.reason)
        assertEquals(1, t.inputs.size)
    }

    @Test fun `refusals and other results come straight back`() {
        for (json in listOf(
            """"ok":false,"code":"refused","reason":"attach_busy","detail":"Claude is working — send the photo when it finishes"""",
            """"ok":false,"code":"refused","reason":"attachment_invalid","detail":"Your phone sent location data with the photo, so Page didn't use it"""",
            """"ok":false,"code":"refused","reason":"draft"""",
            """"ok":false,"code":"failed","reason":"error","detail":"Your photo and message are in Claude's input box at your Mac, not sent"""",
        )) {
            val t = Fake(results = mutableListOf(result(json)))
            val out = run(t, 10_000) as UploadOutcome.Answered
            assertEquals(1, t.inputs.size)
            assertFalse(out.result.ok)
        }
    }

    @Test fun `no result in time is no answer, and the wait is 30 seconds`() {
        assertEquals(30_000L, PhotoUploader.RESULT_TIMEOUT_MILLIS)
        val t = Fake(results = mutableListOf(null))
        assertEquals(UploadOutcome.NoAnswer, run(t, 10_000))
        assertEquals(1, t.inputs.size)
    }

    @Test fun `the progress line and fraction read plainly`() {
        assertEquals("Uploading 3 of 8", PhotoProgress(3, 8, PhotoProgress.Phase.UPLOADING).line(2))
        assertEquals(0.375, PhotoProgress(3, 8, PhotoProgress.Phase.UPLOADING).fraction, 1e-9)
        assertEquals("once inputImages is out: iOS's wording, with the host", "Typing into tmux…", PhotoProgress(8, 8, PhotoProgress.Phase.WAITING).line(2, "tmux"))
        assertEquals("Typing into the session…", PhotoProgress(8, 8, PhotoProgress.Phase.WAITING).line(2))
        assertEquals("a blank host is no host", "Typing into the session…", PhotoProgress(8, 8, PhotoProgress.Phase.WAITING).line(2, "  "))
        assertEquals(1.0, PhotoProgress(3, 8, PhotoProgress.Phase.WAITING).fraction, 0.0)
        assertEquals("Resending part of a photo…", PhotoProgress(0, 2, PhotoProgress.Phase.RESENDING).line(1))
    }

    @Test fun `a result waiter that is listening before the POST cannot miss an answer that beats it`() = runBlocking {
        val d = CompletableDeferred<CommandResult>()
        d.complete(delivered) // the result arrives before anyone awaits
        assertNotNull(withTimeoutOrNull(100) { d.await() })
        delay(1)
    }
}
