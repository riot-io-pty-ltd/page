package app.page.android.model

import java.time.Instant
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Photos into the session chat (docs/SESSIONS-PROTOCOL.md "Images (images-v1)"): the re-encode rules, that nothing
 * about where a photo was taken can leave the phone, the tray, the button's gating, the caption pre-check and the wire.
 */
class PhotosTest {
    // MARK: limits and the ladder

    @Test fun `the budget is a photo's own cap, or what is left of the message's total`() {
        assertEquals(1024 * 1024, PhotoLimits.budgetFor(0))
        assertEquals(1024 * 1024, PhotoLimits.budgetFor(PhotoLimits.MAX_TOTAL_BYTES - 1024 * 1024))
        assertEquals(500_000, PhotoLimits.budgetFor(PhotoLimits.MAX_TOTAL_BYTES - 500_000))
        assertTrue("nothing left", PhotoLimits.budgetFor(PhotoLimits.MAX_TOTAL_BYTES) < PhotoLimits.MIN_BUDGET_BYTES)
    }

    private class FakeCodec(
        override val width: Int, override val height: Int, override val hasAlpha: Boolean = false,
        val jpegSize: (Int, Int) -> Int = { _, _ -> 100_000 }, val pngSize: Int = 100_000, override val sourceIsPng: Boolean = false,
    ) : PhotoCodec {
        val tried = mutableListOf<String>()
        override fun encode(format: PhotoFormat, longEdge: Int, quality: Int): ByteArray {
            tried += "${format.extension}@$longEdge/$quality"
            return if (format == PhotoFormat.PNG) PhotoFixtures.fakePng(pngSize) else PhotoFixtures.fakeJpeg(jpegSize(longEdge, quality))
        }
    }

    @Test fun `a photo that fits at 2000 px and 80 goes at once`() {
        val codec = FakeCodec(4000, 3000)
        val ok = PhotoRecode.prepare(codec, PhotoLimits.MAX_EACH_BYTES) as PhotoRecode.Result.Ok
        assertEquals(listOf("jpg@2000/80"), codec.tried)
        assertEquals(PhotoFormat.JPEG, ok.photo.format)
        assertEquals("image/jpeg", ok.photo.mime)
        assertEquals(2000, ok.photo.width)
        assertEquals(1500, ok.photo.height)
        assertEquals(PhotoChunks.sha256Hex(ok.photo.bytes), ok.photo.sha256)
    }

    @Test fun `a small photo is never enlarged`() {
        val ok = PhotoRecode.prepare(FakeCodec(640, 480), PhotoLimits.MAX_EACH_BYTES) as PhotoRecode.Result.Ok
        assertEquals(640, ok.photo.width)
        assertEquals(480, ok.photo.height)
    }

    @Test fun `quality steps down 80, 60, then the long edge to 1600 and 1280 (iOS's ladder)`() {
        val codec = FakeCodec(4000, 3000, jpegSize = { edge, q -> if (edge == 1280) 900_000 else 2_000_000 + q })
        val ok = PhotoRecode.prepare(codec, PhotoLimits.MAX_EACH_BYTES) as PhotoRecode.Result.Ok
        assertEquals(listOf("jpg@2000/80", "jpg@2000/60", "jpg@1600/60", "jpg@1280/60"), codec.tried)
        assertEquals(1280, ok.photo.width)
        assertTrue(ok.photo.size <= PhotoLimits.MAX_EACH_BYTES)
    }

    @Test fun `a photo that never fits is refused with a reason, and so is a budget too small to bother`() {
        val huge = FakeCodec(4000, 3000, jpegSize = { _, _ -> 5_000_000 })
        assertEquals(PhotoRecode.Result.Failed(PhotoRecode.TOO_BIG), PhotoRecode.prepare(huge, PhotoLimits.MAX_EACH_BYTES))
        assertEquals(PhotoRecode.Result.Failed(PhotoRecode.TOO_MUCH), PhotoRecode.prepare(FakeCodec(10, 10), 1000))
        assertEquals("fits alone, not beside the others: too large together (iOS overTotal)", PhotoRecode.Result.Failed(PhotoRecode.TOO_MUCH), PhotoRecode.prepare(huge, 500_000))
    }

    @Test fun `a screenshot (a PNG source) goes as PNG when it fits, else JPEG at 90 then the ladder`() {
        val shot = FakeCodec(1000, 1000, sourceIsPng = true, pngSize = 300_000)
        assertEquals(PhotoFormat.PNG, (PhotoRecode.prepare(shot, PhotoLimits.MAX_EACH_BYTES) as PhotoRecode.Result.Ok).photo.format)
        val big = FakeCodec(1000, 1000, sourceIsPng = true, pngSize = 3_000_000, jpegSize = { _, q -> if (q == 90) 2_000_000 else 500_000 })
        assertEquals(PhotoFormat.JPEG, (PhotoRecode.prepare(big, PhotoLimits.MAX_EACH_BYTES) as PhotoRecode.Result.Ok).photo.format)
        assertEquals(listOf("png@2000/100", "jpg@2000/90", "jpg@2000/80"), big.tried)
    }

    @Test fun `a PNG source at exactly the budget stays PNG, one byte over goes JPEG at 90, then the whole ladder in order`() {
        val budget = PhotoLimits.MAX_EACH_BYTES
        val exact = FakeCodec(1000, 1000, sourceIsPng = true, pngSize = budget)
        assertEquals(PhotoFormat.PNG, (PhotoRecode.prepare(exact, budget) as PhotoRecode.Result.Ok).photo.format)
        val over = FakeCodec(1000, 1000, sourceIsPng = true, pngSize = budget + 1, jpegSize = { _, _ -> 5_000_000 })
        assertEquals(PhotoRecode.Result.Failed(PhotoRecode.TOO_BIG), PhotoRecode.prepare(over, budget))
        assertEquals(
            "PNG first, then JPEG 0.9, then 0.8, 0.6, 1600 px, 1280 px, and 1024 px at 0.5",
            listOf("png@2000/100", "jpg@2000/90", "jpg@2000/80", "jpg@2000/60", "jpg@1600/60", "jpg@1280/60", "jpg@1024/50"), over.tried,
        )
        // A plain photo never tries PNG, and starts at 0.8 (the doc: "photos: quality 0.8").
        val photo = FakeCodec(4000, 3000, jpegSize = { _, _ -> 5_000_000 })
        PhotoRecode.prepare(photo, budget)
        assertEquals(listOf("jpg@2000/80", "jpg@2000/60", "jpg@1600/60", "jpg@1280/60", "jpg@1024/50"), photo.tried)
        // A PNG that is bigger than what is left of the message's 2.5 MiB goes JPEG, whatever it would take alone.
        val beside = FakeCodec(1000, 1000, sourceIsPng = true, pngSize = 700_000, jpegSize = { _, _ -> 200_000 })
        assertEquals(PhotoFormat.JPEG, (PhotoRecode.prepare(beside, 500_000) as PhotoRecode.Result.Ok).photo.format)
    }

    @Test fun `only a picture with real transparency goes as PNG, and only if it fits`() {
        val fits = FakeCodec(1000, 1000, hasAlpha = true, pngSize = 300_000)
        val png = PhotoRecode.prepare(fits, PhotoLimits.MAX_EACH_BYTES) as PhotoRecode.Result.Ok
        assertEquals(PhotoFormat.PNG, png.photo.format)
        assertEquals("image/png", png.photo.mime)
        assertEquals(listOf("png@2000/100"), fits.tried)

        val tooBig = FakeCodec(1000, 1000, hasAlpha = true, pngSize = 3_000_000)
        val jpeg = PhotoRecode.prepare(tooBig, PhotoLimits.MAX_EACH_BYTES) as PhotoRecode.Result.Ok
        assertEquals(PhotoFormat.JPEG, jpeg.photo.format)
        assertEquals("a PNG that doesn't fit goes as JPEG at 90 first", listOf("png@2000/100", "jpg@2000/90"), tooBig.tried)

        val opaque = FakeCodec(1000, 1000, hasAlpha = false)
        assertEquals(PhotoFormat.JPEG, (PhotoRecode.prepare(opaque, PhotoLimits.MAX_EACH_BYTES) as PhotoRecode.Result.Ok).photo.format)
        assertEquals(listOf("jpg@2000/80"), opaque.tried)
    }

    // MARK: real pixels (ImageIO stands in for the phone's encoder)

    @Test fun `a big photo comes out at most 2000 px on the long edge, a JPEG, at most 1 MiB`() {
        val source = PhotoFixtures.photo(4000, 3000)
        val ok = PhotoRecode.prepare(ImageIoCodec(source), PhotoLimits.MAX_EACH_BYTES) as PhotoRecode.Result.Ok
        val decoded = PhotoFixtures.decode(ok.photo.bytes)
        assertTrue("long edge ${maxOf(decoded.width(), decoded.height())}", maxOf(decoded.width(), decoded.height()) <= 2000)
        assertEquals(2000, decoded.width())
        assertEquals(1500, decoded.height())
        assertEquals(ok.photo.width, decoded.width())
        assertEquals(ok.photo.height, decoded.height())
        assertTrue("size ${ok.photo.size}", ok.photo.size <= PhotoLimits.MAX_EACH_BYTES)
        assertEquals(PhotoFormat.JPEG, PhotoMetadata.format(ok.photo.bytes))
        assertEquals(PhotoFormat.JPEG, ok.photo.format)
    }

    @Test fun `a noisy photo steps down the ladder until it fits`() {
        val source = PhotoFixtures.noisy(2000, 1500)
        val ok = PhotoRecode.prepare(ImageIoCodec(source), PhotoLimits.MAX_EACH_BYTES) as PhotoRecode.Result.Ok
        assertTrue("size ${ok.photo.size}", ok.photo.size <= PhotoLimits.MAX_EACH_BYTES)
        assertTrue(maxOf(ok.photo.width, ok.photo.height) < 2000)
    }

    @Test fun `four photos are held to 2_5 MiB in all by the budget each one is given`() {
        var draft = PhotoDraft()
        val sources = (1..4).map { PhotoFixtures.noisy(2400, 1800, seed = it.toLong()) }
        for ((i, source) in sources.withIndex()) {
            val (next, _) = draft.adding(listOf("p$i"))
            val budget = next.nextBudget
            draft = when (val r = PhotoRecode.prepare(ImageIoCodec(source), budget)) {
                is PhotoRecode.Result.Ok -> next.with("p$i", PhotoStatus.Ready(r.photo))
                is PhotoRecode.Result.Failed -> next.with("p$i", PhotoStatus.Failed(r.why))
            }
        }
        assertTrue("total ${draft.readyBytes}", draft.readyBytes <= PhotoLimits.MAX_TOTAL_BYTES)
        assertTrue(draft.ready.all { it.size <= PhotoLimits.MAX_EACH_BYTES })
    }

    @Test fun `a transparent picture goes as PNG and keeps its transparency, and as JPEG it flattens onto white`() {
        val source = PhotoFixtures.transparent(300, 200)
        val codec = ImageIoCodec(source)
        assertTrue(codec.hasAlpha)
        val ok = PhotoRecode.prepare(codec, PhotoLimits.MAX_EACH_BYTES) as PhotoRecode.Result.Ok
        assertEquals(PhotoFormat.PNG, ok.photo.format)
        assertEquals(0, PhotoFixtures.decode(ok.photo.bytes).argb(10, 10) ushr 24)
        val jpeg = PhotoFixtures.decode(codec.encode(PhotoFormat.JPEG, 2000, 80)!!)
        val corner = jpeg.argb(10, 10)
        assertTrue("white, not black: ${Integer.toHexString(corner)}", (corner and 0xFF) > 240 && ((corner shr 8) and 0xFF) > 240)
        assertFalse("an opaque picture is not 'alpha'", ImageIoCodec(PhotoFixtures.photo(40, 40)).hasAlpha)
    }

    // MARK: metadata

    @Test fun `the scanner finds Exif, GPS, XMP and comments in a JPEG, and nothing in a clean one`() {
        val clean = PhotoFixtures.jpeg(PhotoFixtures.photo(120, 80))
        assertEquals(PhotoMetadata.Findings(), PhotoMetadata.scan(clean))

        val gps = PhotoFixtures.withSegments(clean, 0xE1 to PhotoFixtures.exifWithGps)
        val f = PhotoMetadata.scan(gps)
        assertTrue(f.exif && f.gps)

        val noGps = PhotoMetadata.scan(PhotoFixtures.withSegments(clean, 0xE1 to PhotoFixtures.exifNoGps))
        assertTrue(noGps.exif)
        assertFalse(noGps.gps)

        val xmp = PhotoMetadata.scan(PhotoFixtures.withSegments(clean, 0xE1 to PhotoFixtures.xmpWithGps))
        assertTrue(xmp.xmp && xmp.gps)

        val comment = PhotoMetadata.scan(PhotoFixtures.withSegments(clean, 0xFE to "shot at home".toByteArray()))
        assertTrue(comment.other)

        assertTrue(PhotoMetadata.scan(byteArrayOf(1, 2, 3)).malformed)
    }

    @Test fun `stripping a JPEG leaves the same picture and no metadata at all`() {
        val clean = PhotoFixtures.jpeg(PhotoFixtures.photo(200, 120))
        val dirty = PhotoFixtures.withSegments(
            clean, 0xE1 to PhotoFixtures.exifWithGps, 0xE1 to PhotoFixtures.xmpWithGps, 0xFE to "hello".toByteArray(), 0xED to "Photoshop 3.0".toByteArray(), 0xE2 to "ICC_PROFILE".toByteArray(),
        )
        assertTrue(PhotoMetadata.scan(dirty).hasAny)
        val stripped = PhotoMetadata.strip(dirty)!!
        assertEquals(PhotoMetadata.Findings(), PhotoMetadata.scan(stripped))
        assertTrue(stripped.size <= clean.size + 32)
        val a = PhotoFixtures.decode(clean)
        val b = PhotoFixtures.decode(stripped)
        assertEquals(a.width(), b.width())
        assertEquals(a.height(), b.height())
        assertEquals(a.argb(50, 50), b.argb(50, 50))
    }

    @Test fun `stripping a PNG drops Exif, XMP and text chunks and keeps transparency`() {
        val clean = PhotoFixtures.png(PhotoFixtures.transparent(60, 40))
        val dirty = PhotoFixtures.withChunks(
            clean, "eXIf" to PhotoFixtures.exifWithGps.copyOfRange(6, PhotoFixtures.exifWithGps.size),
            "iTXt" to ("XML:com.adobe.xmp".toByteArray() + byteArrayOf(0, 0, 0, 0, 0) + "<exif:GPSLatitude/>".toByteArray()),
            "tEXt" to "Comment\u0000hello".toByteArray(), "tIME" to ByteArray(7),
        )
        val f = PhotoMetadata.scan(dirty)
        assertTrue(f.exif && f.gps && f.xmp && f.other)
        val stripped = PhotoMetadata.strip(dirty)!!
        assertEquals(PhotoMetadata.Findings(), PhotoMetadata.scan(stripped))
        val img = PhotoFixtures.decode(stripped)
        assertEquals(60, img.width())
        assertEquals(0, img.argb(5, 5) ushr 24)
        assertEquals(0xFF, img.argb(50, 5) ushr 24)
    }

    @Test fun `a source photo with GPS comes out with none, whatever the encoder does`() {
        // The picker's bytes carry GPS; the phone decodes the pixels and encodes new bytes from them.
        val source = PhotoFixtures.withSegments(PhotoFixtures.jpeg(PhotoFixtures.photo(900, 600)), 0xE1 to PhotoFixtures.exifWithGps, 0xE1 to PhotoFixtures.xmpWithGps)
        assertTrue(PhotoMetadata.scan(source).gps)
        val ok = PhotoRecode.prepare(ImageIoCodec(PhotoFixtures.decode(source)), PhotoLimits.MAX_EACH_BYTES) as PhotoRecode.Result.Ok
        val f = PhotoMetadata.scan(ok.photo.bytes)
        assertFalse(f.gps)
        assertFalse(f.exif)
        assertFalse(f.xmp)
        assertEquals(PhotoMetadata.Findings(), f)

        // An encoder that did leak GPS is cleaned before anything is sent (and the hash is of the cleaned bytes).
        val leaky = object : PhotoCodec by ImageIoCodec(PhotoFixtures.photo(300, 200)) {
            override fun encode(format: PhotoFormat, longEdge: Int, quality: Int): ByteArray =
                PhotoFixtures.withSegments(PhotoFixtures.jpeg(PhotoFixtures.photo(300, 200)), 0xE1 to PhotoFixtures.exifWithGps)
        }
        val cleaned = PhotoRecode.prepare(leaky, PhotoLimits.MAX_EACH_BYTES) as PhotoRecode.Result.Ok
        assertFalse(PhotoMetadata.scan(cleaned.photo.bytes).hasAny)
        assertEquals(PhotoChunks.sha256Hex(cleaned.photo.bytes), cleaned.photo.sha256)

        // Bytes that don't parse are never sent.
        val broken = object : PhotoCodec by ImageIoCodec(PhotoFixtures.photo(30, 20)) {
            override fun encode(format: PhotoFormat, longEdge: Int, quality: Int): ByteArray = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 9, 9)
        }
        assertTrue(PhotoRecode.prepare(broken, PhotoLimits.MAX_EACH_BYTES) is PhotoRecode.Result.Failed)
    }

    // MARK: the caption pre-check (port of ImageDelivery.captionRefusal)

    @Test fun `a caption line that is only an image path is refused before anything is sent`() {
        assertEquals(PhotoCaption.PATH_LINE, PhotoCaption.refusal("/Users/me/Desktop/shot.png"))
        assertEquals(PhotoCaption.PATH_LINE, PhotoCaption.refusal("what is this?\n/tmp/a.JPG"))
        assertEquals(PhotoCaption.PATH_LINE, PhotoCaption.refusal("'/Users/me/My Pictures/a b.png'"))
        assertEquals(PhotoCaption.PATH_LINE, PhotoCaption.refusal("~/x/y.jpeg"))
        assertEquals(PhotoCaption.PATH_LINE, PhotoCaption.refusal("/a/one.png /a/two.png"))
        assertNull("words before it", PhotoCaption.refusal("compare with /tmp/a.png"))
        assertNull(PhotoCaption.refusal("the file /tmp/notes.txt"))
        assertNull(PhotoCaption.refusal("/usr/bin/env"))
        assertNull(PhotoCaption.refusal(""))
        assertNull(PhotoCaption.refusal("What's wrong with this screen?"))
    }

    // MARK: the photo button

    private fun row(attach: String? = "image", blocker: String? = null, state: String = "idle", canType: Boolean = true): LiveSession =
        LiveSession.decode(
            parseJson(
                """{"id":"s1","backend":"claude","title":"page","cwd":"~/p","state":"$state","host":"tmux","canType":$canType
                   ${attach?.let { ""","attach":"$it"""" } ?: ""}${blocker?.let { ""","attachBlocker":"$it"""" } ?: ""}}""",
            )!!,
        )!!

    private val withImages = setOf("hold-v1", "images-v1")

    @Test fun `the button needs images-v1 and an attach, and only an idle session takes it`() {
        assertEquals(PhotoOffer.none, PhotoOffer.evaluate(emptySet(), row(), RoomComposerMode.NextTask))
        assertEquals(PhotoOffer.none, PhotoOffer.evaluate(setOf("hold-v1"), row(), RoomComposerMode.NextTask))
        assertFalse(PhotoOffer.evaluate(withImages, row(attach = null), RoomComposerMode.NextTask).shown)
        val idle = PhotoOffer.evaluate(withImages, row(), RoomComposerMode.NextTask)
        assertTrue(idle.shown && idle.enabled)
        assertNull(idle.pathNote)
        assertEquals("Add photo", PhotoOffer.ACCESSIBILITY_LABEL)
    }

    @Test fun `a working session shows it off, with the reason, and a waiting one says to answer first`() {
        val busy = PhotoOffer.evaluate(withImages, row(state = "active"), RoomComposerMode.Steer)
        assertTrue(busy.shown)
        assertFalse(busy.enabled)
        assertEquals("Claude is working — send the photo when it finishes", busy.disabledReason)
        val waiting = PhotoOffer.evaluate(withImages, row(state = "waitingOnApproval"), RoomComposerMode.TellInstead("p1"))
        assertTrue(waiting.shown)
        assertEquals("Answer the prompt first", waiting.disabledReason)
        // A prompt with no page to answer it from says the same (iOS `.locked`).
        assertEquals("Answer the prompt first", PhotoOffer.evaluate(withImages, row(state = "waitingOnApproval"), RoomComposerMode.Locked("x")).disabledReason)
        // Under "Tell it instead" the row's blocker isn't said: that reply goes through the page.
        assertNull(PhotoOffer.evaluate(withImages, row(attach = null, blocker = "Page can't send photos to Codex yet"), RoomComposerMode.TellInstead("p1")).blockerNote)
        // No composer to hang it on: ended, blocked, or only a hold on offer.
        for (mode in listOf(RoomComposerMode.Disabled("x"), RoomComposerMode.Blocked("x"), RoomComposerMode.HoldOnly)) {
            assertFalse(PhotoOffer.evaluate(withImages, row(), mode).shown)
        }
    }

    @Test fun `a Mac that stops offering photos while some are staged keeps the button, dimmed, and says so`() {
        val gone = PhotoOffer(shown = true, disabledReason = "Your Mac can't take photos any more")
        assertEquals("Your Mac can't take photos any more", PhotoOffer.GONE)
        // No images-v1 any more (an older Page), or no route for this row: the same line, whatever the composer is doing.
        for (mode in listOf(RoomComposerMode.NextTask, RoomComposerMode.Steer, RoomComposerMode.TellInstead("p1"))) {
            assertEquals(gone, PhotoOffer.evaluate(emptySet(), row(), mode, staged = 2))
            assertEquals(gone, PhotoOffer.evaluate(withImages, row(attach = null), mode, staged = 1))
        }
        assertFalse(PhotoOffer.evaluate(emptySet(), row(), RoomComposerMode.NextTask, staged = 2).enabled)
        // Nothing staged: as before. An ended session has no composer to say it in.
        assertEquals(PhotoOffer.none, PhotoOffer.evaluate(emptySet(), row(), RoomComposerMode.NextTask, staged = 0))
        assertEquals(PhotoOffer.none, PhotoOffer.evaluate(emptySet(), row(), RoomComposerMode.NextTask, staged = 2, ended = true))
        // A Mac that still offers them is not "gone".
        assertTrue(PhotoOffer.evaluate(withImages, row(), RoomComposerMode.NextTask, staged = 2).enabled)
        // And Send says why instead of sending.
        val draft = PhotoDraft(listOf(PhotoDraftItem("a", ready())))
        assertEquals(PhotoSend.Decision.Refuse("Your Mac can't take photos any more"), PhotoSend.decide(draft, "", gone))
    }

    @Test fun `path says so in one line, and a blocker is a quiet note, never a button`() {
        val path = PhotoOffer.evaluate(withImages, row(attach = "path"), RoomComposerMode.NextTask)
        assertTrue(path.enabled)
        assertEquals("Terminal can't paste photos — Claude gets the file's location and opens it itself", path.pathNote)
        val blocked = PhotoOffer.evaluate(withImages, row(attach = null, blocker = "Page can't send photos to Codex yet"), RoomComposerMode.NextTask)
        assertFalse(blocked.shown)
        assertEquals("Page can't send photos to Codex yet", blocked.blockerNote)
        // Without images-v1 nothing is said about photos at all.
        assertEquals(PhotoOffer.none, PhotoOffer.evaluate(setOf("hold-v1"), row(attach = null, blocker = "Page can't send photos to Codex yet"), RoomComposerMode.NextTask))
        // An attach value this build doesn't know is no route.
        assertNull(row(attach = "teleport").attach)
    }

    // MARK: the tray

    private fun ready(size: Int = 1000) = PhotoStatus.Ready(PreparedPhoto(PhotoFixtures.fakeJpeg(size), PhotoFormat.JPEG, 10, 10))

    @Test fun `the tray holds four, says which is which, and is sendable only when every photo is ready`() {
        var d = PhotoDraft()
        assertFalse(d.isSendable)
        val (two, took) = d.adding(listOf("a", "b"))
        d = two
        assertEquals(2, took)
        assertTrue(d.isEncoding)
        assertFalse(d.isSendable)
        assertEquals("Preparing 2 photos…", d.summary())
        d = d.with("a", ready(2048)).with("b", ready(1024))
        assertTrue(d.isSendable)
        assertEquals("2 photos · 3 KB", d.summary())
        assertEquals("Photo 1 of 2, remove", d.removeLabel("a"))
        assertEquals("Photo 2 of 2, remove", d.removeLabel("b"))
        val (full, took2) = d.adding(listOf("c", "d", "e", "f"))
        assertEquals(2, took2)
        assertEquals(4, full.count)
        assertEquals(0, full.remaining)
        assertEquals("Photo 1 of 1, remove", d.removing("a").removeLabel("b"))
        assertEquals(PhotoLimits.MAX_TOTAL_BYTES - 3072, PhotoLimits.MAX_TOTAL_BYTES - d.readyBytes)
        assertFalse(d.with("b", PhotoStatus.Failed("no")).isSendable)
    }

    private val enabled = PhotoOffer(shown = true)

    private fun readyDraft(n: Int = 2): PhotoDraft = (1..n).fold(PhotoDraft()) { d, i -> d.adding(listOf("p$i")).first.with("p$i", ready()) }

    @Test fun `send with photos is refused with its reason until it can go, and an empty caption is fine`() {
        assertEquals(PhotoSend.Decision.Send, PhotoSend.decide(readyDraft(), "", enabled))
        assertEquals(PhotoSend.Decision.Send, PhotoSend.decide(readyDraft(1), "What's wrong with this screen?", enabled))
        assertEquals(PhotoSend.Decision.Refuse("Add a photo first."), PhotoSend.decide(PhotoDraft(), "hi", enabled))
        // A session that turned busy meanwhile refuses; photos never go through the 10 s countdown or a hold.
        assertEquals(PhotoSend.Decision.Refuse(PhotoOffer.WORKING), PhotoSend.decide(readyDraft(), "hi", PhotoOffer(true, PhotoOffer.WORKING)))
        assertEquals(PhotoSend.Decision.Refuse(PhotoOffer.WAITING), PhotoSend.decide(readyDraft(), "hi", PhotoOffer(true, PhotoOffer.WAITING)))
        assertTrue(PhotoSend.decide(readyDraft(), "hi", PhotoOffer.none) is PhotoSend.Decision.Refuse)
        assertEquals(PhotoSend.Decision.Refuse("Your photos are still being prepared."), PhotoSend.decide(readyDraft(1).adding(listOf("x")).first, "", enabled))
        val failed = readyDraft(1).adding(listOf("x")).first.with("x", PhotoStatus.Failed("Page couldn't open that photo. Try another."))
        assertEquals(PhotoSend.Decision.Refuse("Page couldn't open that photo. Try another. Remove it to send the rest."), PhotoSend.decide(failed, "", enabled))
        assertEquals(PhotoSend.Decision.Refuse(PhotoCaption.PATH_LINE), PhotoSend.decide(readyDraft(), "/tmp/a.png", enabled))
        val tooLong = PhotoSend.decide(readyDraft(), "x".repeat(8001), enabled) as PhotoSend.Decision.Refuse
        assertTrue(tooLong.why.contains("8001"))
    }

    // MARK: transcript text

    @Test fun `a photo message in the transcript reads as its words, with a count`() {
        assertEquals("what are these?", PhotoText.caption("[Image #1] [Image #2]what are these?"))
        assertEquals("", PhotoText.caption("[Image]"))
        assertEquals("", PhotoText.caption("[2 images]"))
        assertEquals("look at this", PhotoText.caption("look at this\nPhoto from my phone: /private/var/T/page-images/s/abc.jpg"))
        assertEquals("plain words", PhotoText.caption("plain words"))
        assertEquals(2, PhotoText.count("[Image #1] [Image #2]x", null))
        assertEquals(3, PhotoText.count("whatever", 3))
        assertEquals(1, PhotoText.count("hi\nPhoto from my phone: /x/a.png", null))
        assertEquals(0, PhotoText.count("hello", null))
        assertEquals("2 photos", PhotoText.chip(2))
        assertEquals("1 photo", PhotoText.chip(1))
    }

    private fun entry(id: String, text: String, images: Int? = null, at: Instant = Instant.ofEpochSecond(1_000)) =
        TranscriptEntry(id, TranscriptRole.USER, text, at, null, images)

    private fun sent(text: String, photos: Int, state: SessionDeliveryState = SessionDeliveryState.Typed("Sent")) =
        SentSessionCommand("c1", "s1", SessionCommandKind.INPUT, text, Instant.ofEpochSecond(990), state, photos = photos)

    @Test fun `a photo message finds its transcript entry despite the chips, and a plain one is compared as before`() {
        val e = entry("e1", "[Image #1] [Image #2]what are these?", 2)
        val merged = TranscriptTimeline.merge(listOf(e), listOf(sent("what are these?", 2)))
        assertEquals(1, merged.size)
        assertEquals("c1", (merged[0] as TranscriptTimeline.Item.Entry).delivery?.clientId)

        val noCaption = TranscriptTimeline.merge(listOf(entry("e2", "[2 images]", 2)), listOf(sent("", 2)))
        assertEquals("c1", (noCaption[0] as TranscriptTimeline.Item.Entry).delivery?.clientId)

        // The path route: the caption and one file line per photo.
        val path = TranscriptTimeline.merge(listOf(entry("e3", "look\nPhoto from my phone: /x/a.png")), listOf(sent("look", 1)))
        assertEquals("c1", (path[0] as TranscriptTimeline.Item.Entry).delivery?.clientId)

        // Until the echo arrives it is a pending bubble; a text-only entry is never a photo message's echo.
        val pending = TranscriptTimeline.merge(listOf(entry("e4", "what are these?")), listOf(sent("what are these?", 2)))
        assertTrue(pending.last() is TranscriptTimeline.Item.Pending)

        val text = TranscriptTimeline.merge(listOf(entry("e5", "run the tests")), listOf(sent("run the tests", 0)))
        assertEquals("c1", (text[0] as TranscriptTimeline.Item.Entry).delivery?.clientId)
    }

    // MARK: receipts

    @Test fun `a receipt for photos is the Mac's sentence, with the fallbacks from attached`() {
        fun r(json: String) = (SessionsPlaintext.decode("""{"kind":"result","seq":1,"ts":1761300000000,"clientId":"c1",$json}""")!!.update as SessionsUpdate.Result).result
        assertEquals("Sent 2 photos to Claude in tmux pane %3", PhotoReceipt.detail(r(""""ok":true,"code":"delivered","detail":"Sent 2 photos to Claude in tmux pane %3","attached":2"""), 2))
        assertEquals("Sent 2 photos to Claude", PhotoReceipt.detail(r(""""ok":true,"code":"delivered","attached":2"""), 2))
        assertEquals("Sent, but Claude received 1 of 2 photos", PhotoReceipt.detail(r(""""ok":true,"code":"delivered","attached":1"""), 2))
        assertEquals("Sent as a file location — Claude opens the photo itself (not attached)", PhotoReceipt.detail(r(""""ok":true,"code":"delivered","attached":0"""), 1, "path"))
        assertEquals("Sent, but Claude took the photo as a file location, not an image", PhotoReceipt.detail(r(""""ok":true,"code":"delivered","attached":0"""), 1, "image"))
        assertEquals("Sent the photo to Claude — it hasn't logged it yet", PhotoReceipt.detail(r(""""ok":true,"code":"delivered""""), 1))
        assertEquals("Sent the photos to Claude — it hasn't logged them yet", PhotoReceipt.detail(r(""""ok":true,"code":"delivered""""), 2))
        assertNull(PhotoReceipt.detail(r(""""ok":false,"code":"refused","reason":"draft""""), 1))
        assertTrue(PhotoReceipt.partial(1, 2))
        assertFalse(PhotoReceipt.partial(2, 2))
        assertFalse(PhotoReceipt.partial(0, 2))
        assertFalse(PhotoReceipt.partial(null, 2))
    }

    @Test fun `the new reasons have words, and the Mac's sentence wins`() {
        assertEquals("Claude is working — send the photo when it finishes", SessionResultCopy.refusal("attach_busy", null, "Claude"))
        assertEquals("Part of a photo didn't reach your Mac — send it again", SessionResultCopy.refusal("attachment_missing", null, "Claude"))
        assertEquals("the Mac's words", SessionResultCopy.refusal("attachment_invalid", "the Mac's words", "Claude"))
        assertEquals("This terminal can't take photos from Page.", SessionResultCopy.refusal("attach_unsupported", null, "Claude"))
    }

    @Test fun `a photo status says Sent, not Typed, and the receipt shows the upload`() {
        assertEquals("Sent", SessionDeliveryState.Typed("x").label(SessionCommandKind.INPUT, 2))
        assertEquals("Typed", SessionDeliveryState.Typed("x").label(SessionCommandKind.INPUT, 0))
        assertEquals("Sending photos…", SessionDeliveryState.Sending.label(SessionCommandKind.INPUT, 1))
        val now = Instant.ofEpochSecond(1000)
        val uploading = SendReceipt.build(sent("hi", 2, SessionDeliveryState.Sending), "Claude", now, uploading = PhotoProgress(4, 8, PhotoProgress.Phase.UPLOADING))!!
        assertEquals("Sending photos to the session…", uploading.headline)
        assertEquals("Uploading 4 of 8", uploading.detail)
        assertEquals(SendReceipt.Tone.WORKING, uploading.tone)
        assertEquals(0.5, uploading.progress!!, 0.0001)
        val done = SendReceipt.build(sent("hi", 2, SessionDeliveryState.Typed("Sent 2 photos to Claude in tmux pane %3", 2)), "Claude", now)!!
        assertEquals("Sent 2 photos to Claude in tmux pane %3", done.headline)
        assertEquals(SendReceipt.Tone.GOOD, done.tone)
        val partial = SendReceipt.build(sent("hi", 2, SessionDeliveryState.Typed("Sent, but Claude received 1 of 2 photos", 1)), "Claude", now)!!
        assertEquals(SendReceipt.Tone.PROBLEM, partial.tone)
    }

    // MARK: pieces

    @Test fun `a photo is cut into pieces of 32 KiB, the last one the rest`() {
        assertEquals(1, PhotoChunks.count(1))
        assertEquals(1, PhotoChunks.count(32768))
        assertEquals(2, PhotoChunks.count(32769))
        assertEquals(32, PhotoChunks.count(1024 * 1024))
        val bytes = ByteArray(100_000) { (it * 31).toByte() }
        val pieces = (0 until PhotoChunks.count(bytes.size)).map { PhotoChunks.slice(bytes, it) }
        assertEquals(listOf(32768, 32768, 32768, 1696), pieces.map { it.size })
        assertArrayEquals(bytes, pieces.fold(ByteArray(0)) { a, b -> a + b })
        // 4 photos of 1 MiB would be 128 pieces; the 2.5 MiB total is at most 80.
        assertTrue(4 * PhotoChunks.count(PhotoLimits.MAX_TOTAL_BYTES / 4) <= 80)
    }

    @Test fun `the hash is SHA-256 of the whole photo, the document's vector`() {
        val png8 = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
        assertEquals("4c4b6a3be1314ab86138bef4314dde022e600960d8689a2c8f8631802d20dab6", PhotoChunks.sha256Hex(png8))
    }

    @Test fun `image ids match what the Mac accepts and are new every time`() {
        val ids = (1..50).map { PhotoChunks.newImageId() }
        assertEquals(50, ids.toSet().size)
        assertTrue(ids.all { Regex("[A-Za-z0-9_-]{8,64}").matches(it) })
    }

    // MARK: the wire

    private val vecRoot = ByteArray(32) { it.toByte() }
    private val vecNonce = ByteArray(12) { (0xa0 + it).toByte() }

    @Test fun `the document's imagePart vector gives the same JSON and the same ciphertext`() {
        val doc = """{"op":"imagePart","clientId":"p1","ts":1761300000000,"viewer":"v1","sessionId":"s1","imageId":"img_0001","index":0,"total":1,"bytes":8,"sha256":"4c4b6a3be1314ab86138bef4314dde022e600960d8689a2c8f8631802d20dab6","mime":"image/png","data":"iVBORw0KGgo="}"""
        val png8 = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
        val mine = SessionCommand.ImagePart("s1", "img_0001", 0, 1, 8, PhotoChunks.sha256Hex(png8), "image/png", png8).plaintext("p1", "v1", Instant.ofEpochMilli(1761300000000))
        // Same fields (the document's key order isn't sorted; ours is, so compare parsed).
        assertEquals(parseJsonObject(doc), parseJsonObject(String(mine)))
        val c = "sfJ3_bSsO7l2-_M4mMyqKxe10i_Q0D61cL5j4Popm85vXQ9Hp1dfQj6dH7htBjpm-mAZLF4Zn4LmtnRVzdbV-wg5ihZiEycDG8ROltjZGvf5NleVwJxZyQAh27rd_icoECLTsVeB0dO1byIYo8XlndG-KezuqN-17JSE65Aqpgg-31jI_KaizgNnnPsfF_on_Lfg0ibBnsPwNg2xNJz4GSO8b_2SX1kn36Es7xohPMngqJBCjeKMBY9wpMiFKBeRqKqf_VIC-foBtzPDdgnuD4lX2XIMHhcC6T-z_7YqiViBEha8t23VoCHhAO6F-Bvzy8CmL9jZmO4L2Ck9rm_TTTsE1TF1_uaPBnrB-Q"
        val sealed = SessionCrypto.seal(doc.toByteArray(), vecRoot, SessionCrypto.Direction.PHONE_TO_MAC, SessionFrameType.COMMAND, vecNonce)
        assertEquals(c, Base64Url.encode(sealed.sealed))
        // And ours opens to the same fields.
        val back = SessionCrypto.open(SessionCrypto.seal(mine, vecRoot, SessionCrypto.Direction.PHONE_TO_MAC, SessionFrameType.COMMAND, vecNonce), vecRoot, SessionCrypto.Direction.PHONE_TO_MAC, SessionFrameType.COMMAND)!!
        assertEquals(parseJsonObject(doc), parseJsonObject(String(back)))
    }

    @Test fun `a full 32 KiB piece with the longest ids still fits the relay's 64 KiB body`() {
        val long = "x"
        val part = SessionCommand.ImagePart(
            sessionId = long.repeat(256), imageId = "i".repeat(64), index = 31, total = 32, bytes = 1024 * 1024,
            sha256 = "f".repeat(64), mime = "image/jpeg", data = ByteArray(PhotoChunks.PIECE_BYTES) { (it * 7).toByte() },
        )
        val plaintext = part.plaintext("c".repeat(128), "v".repeat(128), Instant.ofEpochMilli(1761300000000))
        val body = SessionCommand.requestBody(plaintext, vecRoot)
        assertTrue("body ${body.length} bytes", body.toByteArray().size <= SessionComposer.MAX_BODY_BYTES)
        assertTrue(SessionComposer.fitsRelay(body))
        assertTrue("about 59.5 KB", body.length in 58_000..61_000)
    }

    @Test fun `inputImages carries the caption (empty allowed), 1 to 4 photos and the target`() {
        val target = SessionTarget("s1", "page", "page", "~/projects/page", "tmux", "Roy's Mac", "Claude")
        val ref = SessionCommand.ImageRef("img_0001", "ab".repeat(32), 412345, "image/jpeg")
        val cmd = SessionCommand.InputImages("s1", "", listOf(ref), target)
        assertEquals("inputImages", cmd.op)
        val o = parseJsonObject(String(cmd.plaintext("c9", "v1", Instant.ofEpochMilli(1761300000000))))!!
        assertEquals("", o.str("text"))
        assertEquals("s1", o.str("sessionId"))
        assertEquals(1, o.arr("images")!!.size)
        val img = o.arr("images")!![0] as kotlinx.serialization.json.JsonObject
        assertEquals("img_0001", img.str("id"))
        assertEquals(412345, img.int("bytes"))
        assertEquals("image/jpeg", img.str("mime"))
        assertEquals("~/projects/page", o.str("expectCwd"))
    }

    // MARK: decoding

    @Test fun `attach, attachBlocker, attached, missing and images decode, and lie to nobody`() {
        val list = SessionsPlaintext.decode(
            """{"kind":"list","boot":"b","seq":1,"ts":1761300000000,"caps":["images-v1"],"sessions":[
                {"id":"a","state":"idle","canType":true,"attach":"image"},
                {"id":"b","state":"idle","canType":true,"attach":"path"},
                {"id":"c","state":"idle","canType":true,"attachBlocker":"Page can't send photos to Codex yet"},
                {"id":"d","state":"idle","canType":true,"attach":"carrier-pigeon"}]}""",
        )!!.update as SessionsUpdate.ListUpdate
        assertTrue("images-v1" in list.caps)
        assertEquals(listOf("image", "path", null, null), list.sessions.map { it.attach })
        assertEquals("Page can't send photos to Codex yet", list.sessions[2].attachBlocker)
        val r = (SessionsPlaintext.decode("""{"kind":"result","seq":1,"ts":1761300000000,"clientId":"c1","ok":false,"code":"refused","reason":"attachment_missing","missing":["img_a","img_b"]}""")!!.update as SessionsUpdate.Result).result
        assertEquals(listOf("img_a", "img_b"), r.missing)
        assertNull(r.attached)
        val ok = (SessionsPlaintext.decode("""{"kind":"result","seq":1,"ts":1761300000000,"clientId":"c1","ok":true,"code":"delivered","attached":2}""")!!.update as SessionsUpdate.Result).result
        assertEquals(2, ok.attached)
        val t = (SessionsPlaintext.decode(
            """{"kind":"transcript","seq":2,"ts":1761300000000,"sessionId":"s1","entries":[
                {"id":"1","role":"user","text":"[Image #1] [Image #2]hi","images":2},{"id":"2","role":"user","text":"hello"},{"id":"3","role":"user","text":"x","images":99}]}""",
        )!!.update as SessionsUpdate.Transcript).transcript
        assertEquals(listOf(2, null, null), t.entries.map { it.images })
        assertNotNull(t)
    }
}
