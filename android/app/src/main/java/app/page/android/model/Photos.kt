package app.page.android.model

import java.security.MessageDigest
import kotlin.math.min

// Photos from the session room into a Claude session (docs/SESSIONS-PROTOCOL.md "Images (images-v1)"): the limits,
// how a picked photo is re-encoded (long edge, JPEG or PNG, size ladder, no metadata at all), the composer's tray,
// and when the photo button is on offer. Pure Kotlin, like the rest of model/: the decoding and the encoding are the
// platform's job (data/PhotoPrep.kt), driven through [PhotoCodec] so every rule here runs in plain JVM tests.
// The wire pieces are in PhotoUpload.kt.

/** What the phone sends and what the Mac accepts (the Mac checks every point again). */
object PhotoLimits {
    /** Photos per message. */
    const val MAX_PHOTOS = 4

    /** Claude Code's own cap on a photo's long edge. */
    const val MAX_LONG_EDGE = 2000

    /** One re-encoded photo. */
    const val MAX_EACH_BYTES = 1024 * 1024

    /** All photos of a message together: 4 of them don't each get the full [MAX_EACH_BYTES]. */
    const val MAX_TOTAL_BYTES = 2_621_440

    /** Below this a photo is not worth sending: the picture would be mush. */
    const val MIN_BUDGET_BYTES = 96 * 1024

    /**
     * How many bytes the next photo may take: its own cap, or what is left of the message's total once the photos
     * already in the tray have taken theirs. [alreadyBytes] is the sum of the ready ones. Pure.
     */
    fun budgetFor(alreadyBytes: Int): Int = min(MAX_EACH_BYTES, MAX_TOTAL_BYTES - alreadyBytes)
}

enum class PhotoFormat(val mime: String, val extension: String) {
    JPEG("image/jpeg", "jpg"), PNG("image/png", "png");
}

/** A photo, re-encoded and ready to go: its bytes carry no metadata, and [sha256] is of exactly these bytes. */
class PreparedPhoto(
    val bytes: ByteArray,
    val format: PhotoFormat,
    val width: Int,
    val height: Int,
    val sha256: String = PhotoChunks.sha256Hex(bytes),
) {
    val size: Int get() = bytes.size
    val mime: String get() = format.mime
}

/** One photo decoded by the platform: it can be re-encoded at any long edge and quality, always without metadata. */
interface PhotoCodec {
    /** The decoded picture's size (already upright: the orientation is baked in). */
    val width: Int
    val height: Int

    /** Any pixel is not fully opaque. */
    val hasAlpha: Boolean

    /** The picked file was a PNG (a screenshot, most often): it goes as PNG when that fits. */
    val sourceIsPng: Boolean get() = false

    /**
     * The picture scaled so its long edge is at most [longEdge] (never enlarged), encoded as [format]. [quality] is
     * 1..100 and means nothing for PNG. A JPEG of a picture with alpha is flattened onto white. Null if the platform
     * can't encode it.
     */
    fun encode(format: PhotoFormat, longEdge: Int, quality: Int): ByteArray?
}

/** How a photo is re-encoded: the ladder, and what the result must satisfy. Pure. */
object PhotoRecode {
    /** One try: a long edge and a JPEG quality. */
    data class Step(val longEdge: Int, val quality: Int)

    /**
     * JPEG: 2000 px at 80, stepping down to 60, then a 1600 and a 1280 px long edge, and one last try at 1024 px and
     * 50 for a photo that is mostly noise. The first step that fits the budget wins. The same steps as iOS
     * `PhotoEncoder.ladder`.
     */
    val ladder = listOf(Step(2000, 80), Step(2000, 60), Step(1600, 60), Step(1280, 60), Step(1024, 50))

    /** A screenshot whose PNG doesn't fit goes as JPEG at 90 first (docs: "else JPEG at 0.9"), then down the ladder. */
    val screenshotStep = Step(2000, 90)

    sealed interface Result {
        data class Ok(val photo: PreparedPhoto) : Result
        data class Failed(val why: String) : Result
    }

    const val TOO_BIG = "That photo is too large to send. Try a smaller one."
    const val CANT_ENCODE = "Page couldn't read that photo."
    const val LEFT_METADATA = "Page couldn't remove the photo's hidden details, so it wasn't used."

    /**
     * Re-encodes [codec]'s picture to at most [budget] bytes. A screenshot (a PNG source) or a picture with real
     * transparency goes as PNG if that fits (long edge 2000 at most), else as JPEG starting at 90; anything else is a
     * JPEG down the ladder. Every result is cleaned of metadata and checked (a photo that still carries any is never
     * returned), and its SHA-256 is taken last. A photo that would fit alone but not beside the ones already added is
     * [TOO_MUCH], as iOS's `overTotal`.
     */
    fun prepare(codec: PhotoCodec, budget: Int): Result {
        if (budget < PhotoLimits.MIN_BUDGET_BYTES) return Result.Failed(TOO_MUCH)
        var sawBytes = false
        val pngFirst = codec.hasAlpha || codec.sourceIsPng
        if (pngFirst) {
            val png = codec.encode(PhotoFormat.PNG, PhotoLimits.MAX_LONG_EDGE, 100)
            if (png != null) {
                sawBytes = true
                if (png.size <= budget) finish(png, PhotoFormat.PNG, codec, PhotoLimits.MAX_LONG_EDGE)?.let { return it }
            }
        }
        for (step in if (pngFirst) listOf(screenshotStep) + ladder else ladder) {
            val jpeg = codec.encode(PhotoFormat.JPEG, step.longEdge, step.quality) ?: continue
            sawBytes = true
            if (jpeg.size <= budget) finish(jpeg, PhotoFormat.JPEG, codec, step.longEdge)?.let { return it }
        }
        return Result.Failed(
            when {
                !sawBytes -> CANT_ENCODE
                budget < PhotoLimits.MAX_EACH_BYTES -> TOO_MUCH
                else -> TOO_BIG
            },
        )
    }

    const val TOO_MUCH = "The photos are too large together (2.5 MB at most). Remove one and try again."

    private fun finish(bytes: ByteArray, format: PhotoFormat, codec: PhotoCodec, longEdge: Int): Result? {
        val clean = PhotoMetadata.strip(bytes, format) ?: return Result.Failed(CANT_ENCODE)
        if (PhotoMetadata.scan(clean, format).hasAny) return Result.Failed(LEFT_METADATA)
        val scale = min(1.0, longEdge.toDouble() / maxOf(codec.width, codec.height, 1))
        return Result.Ok(PreparedPhoto(clean, format, (codec.width * scale).toInt().coerceAtLeast(1), (codec.height * scale).toInt().coerceAtLeast(1)))
    }
}

/**
 * Looks for what a photo can carry besides its picture (EXIF, GPS, XMP, comments, text chunks), and removes it. The
 * encoders write none of it; this is the check that says so about the bytes that are about to be sent. Pure.
 */
object PhotoMetadata {
    data class Findings(
        /** An Exif block (camera, time, orientation). */
        val exif: Boolean = false,
        /** A GPS block: inside the Exif, or a location tag in XMP. */
        val gps: Boolean = false,
        val xmp: Boolean = false,
        /** Anything else that is not picture: comments, text chunks, profiles, other application blocks. */
        val other: Boolean = false,
        /** The bytes are not a JPEG or a PNG that parses. */
        val malformed: Boolean = false,
    ) {
        val hasAny: Boolean get() = exif || gps || xmp || other || malformed
    }

    private val pngSignature = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

    /** PNG chunks that are picture (or its transparency and colour meaning); everything else is dropped. */
    private val pngKeep = setOf("IHDR", "PLTE", "IDAT", "IEND", "tRNS", "sRGB", "gAMA")

    fun format(bytes: ByteArray): PhotoFormat? = when {
        bytes.size >= 3 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte() && bytes[2] == 0xFF.toByte() -> PhotoFormat.JPEG
        bytes.size >= 8 && (0 until 8).all { bytes[it] == pngSignature[it] } -> PhotoFormat.PNG
        else -> null
    }

    fun scan(bytes: ByteArray, format: PhotoFormat = format(bytes) ?: PhotoFormat.JPEG): Findings =
        when (format) {
            PhotoFormat.JPEG -> scanJpeg(bytes)
            PhotoFormat.PNG -> scanPng(bytes)
        }

    /** The same picture with no metadata, or null when the bytes don't parse as [format]. */
    fun strip(bytes: ByteArray, format: PhotoFormat = format(bytes) ?: PhotoFormat.JPEG): ByteArray? =
        when (format) {
            PhotoFormat.JPEG -> stripJpeg(bytes)
            PhotoFormat.PNG -> stripPng(bytes)
        }

    // region JPEG

    private class Segment(val marker: Int, val start: Int, val end: Int)

    /** The marker segments up to the scan, then null for the rest (entropy-coded data to the end, kept whole). */
    private fun jpegSegments(b: ByteArray): Pair<List<Segment>, Int>? {
        if (format(b) != PhotoFormat.JPEG) return null
        val out = ArrayList<Segment>()
        var i = 2
        while (i + 1 < b.size) {
            if (b[i] != 0xFF.toByte()) return null
            var marker = b[i + 1].toInt() and 0xFF
            // Fill bytes before a marker.
            while (marker == 0xFF && i + 2 < b.size) { i += 1; marker = b[i + 1].toInt() and 0xFF }
            if (marker == 0xD9) return out to i // EOI before any scan: nothing left to keep
            if (marker == 0x01 || marker in 0xD0..0xD8) { out.add(Segment(marker, i, i + 2)); i += 2; continue }
            if (i + 3 >= b.size) return null
            val len = ((b[i + 2].toInt() and 0xFF) shl 8) or (b[i + 3].toInt() and 0xFF)
            if (len < 2 || i + 2 + len > b.size) return null
            if (marker == 0xDA) return out to i // start of scan: the rest is the picture
            out.add(Segment(marker, i, i + 2 + len))
            i += 2 + len
        }
        return null
    }

    private fun scanJpeg(b: ByteArray): Findings {
        val (segments, _) = jpegSegments(b) ?: return Findings(malformed = true)
        var f = Findings()
        for (s in segments) {
            val body = s.start + 4
            when (s.marker) {
                0xE1 -> {
                    if (startsWith(b, body, s.end, "Exif\u0000\u0000")) {
                        f = f.copy(exif = true, gps = f.gps || exifHasGps(b, body + 6, s.end))
                    } else if (startsWith(b, body, s.end, "http://ns.adobe.com/xap/1.0/")) {
                        f = f.copy(xmp = true, gps = f.gps || xmpHasGps(b, body, s.end))
                    } else f = f.copy(other = true)
                }
                0xE0 -> if (!startsWith(b, body, s.end, "JFIF\u0000")) f = f.copy(other = true)
                in 0xE2..0xEF, 0xFE -> f = f.copy(other = true)
            }
        }
        return f
    }

    private fun stripJpeg(b: ByteArray): ByteArray? {
        val (segments, scanStart) = jpegSegments(b) ?: return null
        val out = java.io.ByteArrayOutputStream(b.size)
        out.write(b, 0, 2)
        for (s in segments) {
            val body = s.start + 4
            // Keep everything that is picture. APP0 JFIF stays; every other application block and comments go.
            val drop = when (s.marker) {
                0xE0 -> !startsWith(b, body, s.end, "JFIF\u0000")
                in 0xE1..0xEF, 0xFE -> true
                else -> false
            }
            if (!drop) out.write(b, s.start, s.end - s.start)
        }
        out.write(b, scanStart, b.size - scanStart)
        return out.toByteArray()
    }

    /** IFD0 of the Exif's TIFF block has the GPS pointer (tag 0x8825). */
    private fun exifHasGps(b: ByteArray, tiff: Int, end: Int): Boolean {
        if (tiff + 8 > end) return false
        val little = when {
            b[tiff] == 'I'.code.toByte() && b[tiff + 1] == 'I'.code.toByte() -> true
            b[tiff] == 'M'.code.toByte() && b[tiff + 1] == 'M'.code.toByte() -> false
            else -> return false
        }
        fun u16(at: Int): Int = if (at + 2 > end) -1 else if (little) (b[at].toInt() and 0xFF) or ((b[at + 1].toInt() and 0xFF) shl 8) else ((b[at].toInt() and 0xFF) shl 8) or (b[at + 1].toInt() and 0xFF)
        fun u32(at: Int): Long = if (at + 4 > end) -1 else if (little) (0..3).fold(0L) { acc, k -> acc or ((b[at + k].toLong() and 0xFF) shl (8 * k)) } else (0..3).fold(0L) { acc, k -> (acc shl 8) or (b[at + k].toLong() and 0xFF) }
        val ifd = u32(tiff + 4)
        if (ifd < 8 || tiff + ifd + 2 > end) return false
        val count = u16(tiff + ifd.toInt())
        if (count <= 0) return false
        for (n in 0 until count) {
            val entry = tiff + ifd.toInt() + 2 + n * 12
            if (u16(entry) == 0x8825) return true
        }
        return false
    }

    private fun xmpHasGps(b: ByteArray, from: Int, to: Int): Boolean = indexOf(b, from, to, "GPS") >= 0

    // endregion

    // region PNG

    private class Chunk(val type: String, val start: Int, val end: Int)

    private fun pngChunks(b: ByteArray): List<Chunk>? {
        if (format(b) != PhotoFormat.PNG) return null
        val out = ArrayList<Chunk>()
        var i = 8
        while (i + 12 <= b.size) {
            val len = ((b[i].toLong() and 0xFF) shl 24) or ((b[i + 1].toLong() and 0xFF) shl 16) or ((b[i + 2].toLong() and 0xFF) shl 8) or (b[i + 3].toLong() and 0xFF)
            if (len < 0 || len > b.size) return null
            val total = 12 + len.toInt()
            if (i + total > b.size) return null
            out.add(Chunk(String(b, i + 4, 4, Charsets.ISO_8859_1), i, i + total))
            i += total
            if (out.last().type == "IEND") return out
        }
        return null
    }

    private fun scanPng(b: ByteArray): Findings {
        val chunks = pngChunks(b) ?: return Findings(malformed = true)
        var f = Findings()
        for (c in chunks) {
            if (c.type in pngKeep) continue
            f = when (c.type) {
                "eXIf" -> f.copy(exif = true, gps = f.gps || exifHasGps(b, c.start + 8, c.end - 4))
                // XMP rides in an iTXt chunk keyed "XML:com.adobe.xmp".
                "iTXt" -> if (indexOf(b, c.start + 8, c.end - 4, "XML:com.adobe.xmp") >= 0) f.copy(xmp = true, gps = f.gps || xmpHasGps(b, c.start + 8, c.end - 4)) else f.copy(other = true)
                else -> f.copy(other = true)
            }
        }
        return f
    }

    private fun stripPng(b: ByteArray): ByteArray? {
        val chunks = pngChunks(b) ?: return null
        val out = java.io.ByteArrayOutputStream(b.size)
        out.write(b, 0, 8)
        for (c in chunks) if (c.type in pngKeep) out.write(b, c.start, c.end - c.start)
        return out.toByteArray()
    }

    // endregion

    private fun startsWith(b: ByteArray, from: Int, to: Int, text: String): Boolean {
        if (from + text.length > to) return false
        for (k in text.indices) if (b[from + k] != text[k].code.toByte()) return false
        return true
    }

    private fun indexOf(b: ByteArray, from: Int, to: Int, text: String): Int {
        val n = text.length
        var i = from
        while (i + n <= to) {
            var k = 0
            while (k < n && b[i + k] == text[k].code.toByte()) k++
            if (k == n) return i
            i++
        }
        return -1
    }
}

/** A path-only caption line would be taken by Claude Code as another photo; the Mac refuses it, and so does the phone first. */
object PhotoCaption {
    /** The Mac's own sentence (ImageDelivery.pathLineMessage). */
    const val PATH_LINE = "A line of your message is a photo's file path, which Claude would try to open as a photo — add a word before it"

    private val splitter = Regex(""" (?=["']?(?:/|[A-Za-z]:\\))""")
    private val imageExtension = Regex("""\.(png|jpe?g|gif|webp)$""", RegexOption.IGNORE_CASE)
    private val drivePath = Regex("""^[A-Za-z]:\\""")

    /**
     * Why the caption can't go in, or null. A line is split the way Claude Code splits one (on a space before "/" or a
     * drive letter, optionally quoted); it is refused when every piece is an absolute path and one of them is an
     * image file. Port of ImageDelivery.captionRefusal. Pure.
     */
    fun refusal(caption: String): String? {
        for (raw in caption.split("\n")) {
            val line = raw.trim(' ', '\t')
            if (line.isEmpty()) continue
            val pieces = splitter.split(line)
            fun unquoted(p: String): String {
                var t = p.trim(' ', '\t')
                if (t.length >= 2 && (t.first() == '\'' || t.first() == '"') && t.first() == t.last()) t = t.substring(1, t.length - 1)
                return t.replace("\\ ", " ")
            }
            val paths = pieces.map(::unquoted)
            val allPaths = paths.all { it.startsWith("/") || it.startsWith("~/") || drivePath.containsMatchIn(it) }
            val anyImage = paths.any { imageExtension.containsMatchIn(it) }
            if (allPaths && anyImage) return PATH_LINE
        }
        return null
    }
}

/** The photo button: whether it is there, whether it works, and the lines that explain it. */
data class PhotoOffer(
    /** The button is drawn at all. */
    val shown: Boolean,
    /** Why it does nothing right now (shown when it is tapped); null when it works. */
    val disabledReason: String? = null,
    /** `attach: "path"`: the terminal can't paste a photo, so Claude is given where the file is. */
    val pathNote: String? = null,
    /** The row's `attachBlocker`: why this session takes no photos, said quietly. */
    val blockerNote: String? = null,
) {
    val enabled: Boolean get() = shown && disabledReason == null

    companion object {
        const val WORKING = "Claude is working — send the photo when it finishes"
        const val WAITING = "Answer the prompt first"

        /** Photos are staged but the Mac stopped offering them (an older Page, or the terminal changed): the button stays, dimmed. */
        const val GONE = "Your Mac can't take photos any more"
        const val PATH_NOTE = "Terminal can't paste photos — Claude gets the file's location and opens it itself"
        const val ACCESSIBILITY_LABEL = "Add photo"
        val none = PhotoOffer(shown = false)

        /**
         * One pure decision from what the Mac advertises (the header's `caps`, the row's `attach` and `attachBlocker`)
         * and the composer's mode. The button needs `images-v1` and an `attach`; it works only where a message is typed
         * at once (an idle session), and says why not for a working one ("send the photo when it finishes") and for one
         * waiting on a prompt ("Answer the prompt first"). Anywhere else there is no composer to hang it on. [staged]
         * photos already in the tray keep the button when the Mac stops offering them, dimmed with [GONE] (not once the
         * session has [ended]); the iOS order: the missing cap or route is looked at before the composer's mode.
         */
        fun evaluate(caps: Set<String>, session: LiveSession, mode: RoomComposerMode, staged: Int = 0, ended: Boolean = false): PhotoOffer {
            val gone = if (staged > 0 && !ended) PhotoOffer(shown = true, disabledReason = GONE) else null
            if (SessionCaps.IMAGES !in caps) return gone ?: none
            val attach = session.attach
            if (attach == null) {
                if (gone != null) return gone
                // A quiet line where the composer takes the session's own input and the Mac said why photos aren't an
                // option (not under "Tell it instead", which goes through the page: the same rule as iOS).
                val blocker = session.attachBlocker?.takeIf { mode.acceptsText && !mode.routesThroughPage }
                return if (blocker == null) none else PhotoOffer(shown = false, blockerNote = blocker)
            }
            val path = if (attach == LiveSession.ATTACH_PATH) PATH_NOTE else null
            return when (mode) {
                RoomComposerMode.NextTask -> PhotoOffer(true, null, path, null)
                RoomComposerMode.Steer -> PhotoOffer(true, WORKING, path, null)
                is RoomComposerMode.TellInstead, is RoomComposerMode.Locked -> PhotoOffer(true, WAITING, path, null)
                else -> none
            }
        }
    }
}

/** What the tray holds for one picked photo. */
sealed interface PhotoStatus {
    data object Encoding : PhotoStatus
    data class Ready(val photo: PreparedPhoto) : PhotoStatus
    data class Failed(val why: String) : PhotoStatus
}

data class PhotoDraftItem(val id: String, val status: PhotoStatus)

/** The composer's tray of photos: up to four, each encoding, ready or failed. Immutable, so the room holds it and tests drive it. */
data class PhotoDraft(val items: List<PhotoDraftItem> = emptyList()) {
    val isEmpty: Boolean get() = items.isEmpty()
    val count: Int get() = items.size
    val remaining: Int get() = (PhotoLimits.MAX_PHOTOS - items.size).coerceAtLeast(0)
    val isEncoding: Boolean get() = items.any { it.status is PhotoStatus.Encoding }
    val failed: List<PhotoDraftItem> get() = items.filter { it.status is PhotoStatus.Failed }
    val ready: List<PreparedPhoto> get() = items.mapNotNull { (it.status as? PhotoStatus.Ready)?.photo }
    val readyBytes: Int get() = ready.sumOf { it.size }

    /** What the next photo to be encoded may take. */
    val nextBudget: Int get() = PhotoLimits.budgetFor(readyBytes)

    /** New picks join the tray (up to the limit); returns the tray and how many of [ids] fit. */
    fun adding(ids: List<String>): Pair<PhotoDraft, Int> {
        val taken = ids.take(remaining)
        return PhotoDraft(items + taken.map { PhotoDraftItem(it, PhotoStatus.Encoding) }) to taken.size
    }

    fun with(id: String, status: PhotoStatus): PhotoDraft = PhotoDraft(items.map { if (it.id == id) it.copy(status = status) else it })
    fun removing(id: String): PhotoDraft = PhotoDraft(items.filter { it.id != id })

    /** Every photo is encoded, none failed, at least one: the tray can go. */
    val isSendable: Boolean get() = items.isNotEmpty() && items.all { it.status is PhotoStatus.Ready }

    /** "Photo 1 of 2, remove" for TalkBack; the one-based position of [id]. */
    fun removeLabel(id: String): String {
        val n = items.indexOfFirst { it.id == id } + 1
        return "Photo $n of ${items.size}, remove"
    }

    /** "2 photos, 640 KB" under the tray while it holds some. */
    fun summary(): String? {
        if (items.isEmpty()) return null
        val n = items.size
        return if (isEncoding) "Preparing $n photo${if (n == 1) "" else "s"}…" else "$n photo${if (n == 1) "" else "s"} · ${PhotoSize.label(readyBytes)}"
    }

    companion object {
        const val LIMIT_NOTE = "Up to 4 photos in a message."
    }
}

object PhotoSize {
    fun label(bytes: Int): String = if (bytes >= 1024 * 1024) String.format(java.util.Locale.US, "%.1f MB", bytes / 1048576.0) else "${maxOf(1, (bytes + 512) / 1024)} KB"
}

/** Whether the tray and caption may go now. */
object PhotoSend {
    sealed interface Decision {
        data object Send : Decision
        data class Refuse(val why: String) : Decision
    }

    /**
     * One pure decision for Send with photos in the tray. Photos go only as `inputImages` (never held, never after the
     * 10 s countdown), so a session that turned busy meanwhile refuses and keeps both the photos and the caption.
     * [caption] may be empty. Pure.
     */
    fun decide(draft: PhotoDraft, caption: String, offer: PhotoOffer): Decision {
        if (draft.isEmpty) return Decision.Refuse("Add a photo first.")
        if (!offer.shown) return Decision.Refuse("This session can't take photos right now, so nothing was sent.")
        offer.disabledReason?.let { return Decision.Refuse(it) }
        if (draft.isEncoding) return Decision.Refuse("Your photos are still being prepared.")
        draft.failed.firstOrNull()?.let { return Decision.Refuse((it.status as PhotoStatus.Failed).why + " Remove it to send the rest.") }
        val text = caption.trim()
        if (text.graphemeCount() > SessionComposer.MAX_CHARACTERS) return Decision.Refuse(SessionComposer.Problem.TooLong(text.graphemeCount()).message)
        PhotoCaption.refusal(text)?.let { return Decision.Refuse(it) }
        return Decision.Send
    }
}

/** How a photo message reads in the transcript: the Mac writes Claude Code's own text, chips and all. */
object PhotoText {
    private val chips = Regex("""^\s*(?:\[Image #\d+]\s*)+""")
    private val placeholder = Regex("""^\s*\[(?:Image|\d+ images)]\s*$""")
    private val chipCount = Regex("""\[Image #\d+]""")
    private const val PATH_PREFIX = "Photo from my phone: "

    /** The words without the chips ("[Image #1] [Image #2]what are these?" -> "what are these?"), nor the path route's file lines. */
    fun caption(text: String): String {
        if (placeholder.matches(text)) return ""
        return text.replace(chips, "").lines().filterNot { it.startsWith(PATH_PREFIX) }.joinToString("\n").trim()
    }

    /** How many photos a user entry carries: the Mac's `images`, else what its text shows. */
    fun count(text: String, images: Int?): Int {
        if (images != null) return images
        val n = chipCount.findAll(text).count()
        return if (n > 0) n else text.lines().count { it.startsWith(PATH_PREFIX) }
    }

    /** "2 photos". */
    fun chip(count: Int): String = "$count photo${if (count == 1) "" else "s"}"
}

/** What a receipt says about a photo send, from the Mac's result. */
object PhotoReceipt {
    /**
     * The Mac's own sentence ("Sent 2 photos to Claude in tmux pane %3"); when it sent none, one from `attached` and
     * the route the row named ([attach], `image` or `path`). iOS `PhotoCopy.delivered`.
     */
    fun detail(result: CommandResult, sent: Int, attach: String? = null): String? {
        result.detail?.takeIf { it.isNotBlank() }?.let { return it.trim() }
        if (result.code != CommandResult.Code.DELIVERED) return null
        val attached = result.attached ?: return "Sent the ${if (sent == 1) "photo" else "photos"} to Claude — it hasn't logged ${if (sent == 1) "it" else "them"} yet"
        return when {
            attached >= sent -> "Sent ${PhotoText.chip(sent)} to Claude"
            attached <= 0 ->
                if (attach == LiveSession.ATTACH_PATH) "Sent as a file location — Claude opens the photo itself (not attached)"
                else "Sent, but Claude took the photo as a file location, not an image"
            else -> "Sent, but Claude received $attached of $sent photos"
        }
    }

    /** `attached` is some but not all: worth an amber line rather than a green one. */
    fun partial(attached: Int?, sent: Int): Boolean = attached != null && attached in 1 until sent
}

/** SHA-256 and the pieces a photo travels in. */
object PhotoChunks {
    /** Raw bytes per `imagePart`: 32 KiB, which is 43,692 characters of base64 and keeps the body under the Worker's 64 KiB. */
    const val PIECE_BYTES = 32 * 1024

    fun count(size: Int): Int = (size + PIECE_BYTES - 1) / PIECE_BYTES

    fun slice(bytes: ByteArray, index: Int): ByteArray = bytes.copyOfRange(index * PIECE_BYTES, min(bytes.size, (index + 1) * PIECE_BYTES))

    fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /** `[A-Za-z0-9_-]{8,64}`, unique per photo. */
    fun newImageId(): String = "img_" + java.util.UUID.randomUUID().toString().replace("-", "").take(16)
}
