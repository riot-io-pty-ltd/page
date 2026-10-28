package app.page.android.data

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import app.page.android.model.PhotoCodec
import app.page.android.model.PhotoFormat
import app.page.android.model.PhotoLimits
import app.page.android.model.PhotoMetadata
import app.page.android.model.PhotoRecode
import app.page.android.model.PreparedPhoto
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Turns a picked photo into what goes up: decoded (HEIC too, where the phone can), upright, in sRGB, and re-encoded by
 * the rules in [PhotoRecode] with no metadata at all. The picker's bytes (EXIF, GPS, XMP) are only ever read, never sent.
 * The rules and the checks are pure and tested in model/Photos.kt; this file is the platform's part of them.
 */
object PhotoPrep {
    sealed interface Result {
        class Ok(val photo: PreparedPhoto, val thumbnail: Bitmap) : Result
        data class Failed(val why: String) : Result
    }

    const val CANT_OPEN = "Page couldn't open that photo. Try another."
    const val TOO_LARGE = "That photo is too large to open on this phone. Try another."
    const val UNSUPPORTED = "This phone can't open that kind of photo. Try a JPEG or PNG."

    /** Decodes [uri] and re-encodes it to fit [budget] bytes. Slow: runs off the main thread. */
    suspend fun prepare(resolver: ContentResolver, uri: Uri, budget: Int): Result = withContext(Dispatchers.Default) {
        var decoded: Bitmap? = null
        try {
            decoded = decode(resolver, uri) ?: return@withContext Result.Failed(if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) UNSUPPORTED else CANT_OPEN)
            val codec = BitmapPhotoCodec(decoded, sourceIsPng = isPng(resolver, uri))
            when (val r = PhotoRecode.prepare(codec, budget)) {
                is PhotoRecode.Result.Failed -> Result.Failed(r.why)
                is PhotoRecode.Result.Ok -> Result.Ok(r.photo, thumbnail(decoded))
            }
        } catch (_: OutOfMemoryError) {
            Result.Failed(TOO_LARGE)
        } catch (_: Exception) {
            Result.Failed(CANT_OPEN)
        } finally {
            decoded?.recycle()
        }
    }

    /** The picked file is a PNG (a screenshot, most often), by its own first bytes. */
    private fun isPng(resolver: ContentResolver, uri: Uri): Boolean =
        runCatching {
            resolver.openInputStream(uri)?.use { s ->
                val head = ByteArray(8)
                var n = 0
                while (n < head.size) { val r = s.read(head, n, head.size - n); if (r <= 0) break; n += r }
                n == head.size && PhotoMetadata.format(head) == PhotoFormat.PNG
            } ?: false
        }.getOrDefault(false)

    /** The picture upright and in sRGB, its long edge at most [PhotoLimits.MAX_LONG_EDGE]; null when it can't be read. */
    private fun decode(resolver: ContentResolver, uri: Uri): Bitmap? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) decodeWithImageDecoder(resolver, uri) else decodeWithFactory(resolver, uri)

    // ImageDecoder reads HEIC, applies the orientation (EXIF or the HEIF's own) and can decode straight to a target size.
    private fun decodeWithImageDecoder(resolver: ContentResolver, uri: Uri): Bitmap? =
        try {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(resolver, uri)) { decoder, info, _ ->
                // Software, so the pixels can be compressed (a hardware bitmap can't be).
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                // sRGB, so the encoder writes no colour profile and a wide-gamut photo keeps its look.
                decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
                val w = info.size.width
                val h = info.size.height
                val long = max(w, h)
                if (long > PhotoLimits.MAX_LONG_EDGE) {
                    val scale = PhotoLimits.MAX_LONG_EDGE.toDouble() / long
                    decoder.setTargetSize(max(1, (w * scale).roundToInt()), max(1, (h * scale).roundToInt()))
                }
            }
        } catch (_: ImageDecoder.DecodeException) {
            null
        }

    // Android 8 and 8.1: BitmapFactory, with the orientation read from the file and applied by hand.
    private fun decodeWithFactory(resolver: ContentResolver, uri: Uri): Bitmap? {
        // A bounds-only decode always returns null: whether it read the size is in the options, not the return value.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        val probe = resolver.openInputStream(uri) ?: return null
        probe.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= PhotoLimits.MAX_LONG_EDGE) sample *= 2
        val options = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB)
        }
        val raw = resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) } ?: return null
        val orientation = resolver.openInputStream(uri)?.use { ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL) } ?: ExifInterface.ORIENTATION_NORMAL
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.postRotate(90f); matrix.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.postRotate(270f); matrix.postScale(-1f, 1f) }
        }
        var upright = if (matrix.isIdentity) raw else Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, matrix, true).also { if (it !== raw) raw.recycle() }
        val long = max(upright.width, upright.height)
        if (long > PhotoLimits.MAX_LONG_EDGE) {
            val scale = PhotoLimits.MAX_LONG_EDGE.toDouble() / long
            val scaled = Bitmap.createScaledBitmap(upright, max(1, (upright.width * scale).roundToInt()), max(1, (upright.height * scale).roundToInt()), true)
            if (scaled !== upright) upright.recycle()
            upright = scaled
        }
        return upright
    }

    /**
     * A square thumbnail for the tray: the middle of the picture. Never [source] itself (a square picture already at
     * [size] comes back as the same object from both calls), since the caller recycles the source.
     */
    private fun thumbnail(source: Bitmap, size: Int = 192): Bitmap {
        val side = min(source.width, source.height)
        val cropped = Bitmap.createBitmap(source, (source.width - side) / 2, (source.height - side) / 2, side, side)
        val scaled = Bitmap.createScaledBitmap(cropped, size, size, true)
        if (cropped !== source && cropped !== scaled) cropped.recycle()
        return if (scaled === source) source.copy(Bitmap.Config.ARGB_8888, false) else scaled
    }
}

/**
 * A decoded bitmap as a [PhotoCodec]. `Bitmap.compress` writes pixels and nothing else (no EXIF, GPS or XMP), and the
 * result is checked again by [app.page.android.model.PhotoMetadata] before it can be sent.
 */
class BitmapPhotoCodec(private val source: Bitmap, override val sourceIsPng: Boolean = false) : PhotoCodec {
    override val width: Int get() = source.width
    override val height: Int get() = source.height

    override val hasAlpha: Boolean by lazy {
        if (!source.hasAlpha()) return@lazy false
        val row = IntArray(source.width)
        for (y in 0 until source.height) {
            source.getPixels(row, 0, source.width, 0, y, source.width, 1)
            for (p in row) if ((p ushr 24) != 0xFF) return@lazy true
        }
        false
    }

    override fun encode(format: PhotoFormat, longEdge: Int, quality: Int): ByteArray? {
        val long = max(source.width, source.height)
        val scale = min(1.0, longEdge.toDouble() / long)
        val scaled = if (scale < 1.0) Bitmap.createScaledBitmap(source, max(1, (source.width * scale).roundToInt()), max(1, (source.height * scale).roundToInt()), true) else source
        var flat: Bitmap? = null
        return try {
            // JPEG has no transparency: what was clear becomes white, not black.
            val toEncode = if (format == PhotoFormat.JPEG && hasAlpha) {
                Bitmap.createBitmap(scaled.width, scaled.height, Bitmap.Config.ARGB_8888).also { out ->
                    Canvas(out).apply { drawColor(Color.WHITE); drawBitmap(scaled, 0f, 0f, null) }
                    flat = out
                }
            } else scaled
            val out = ByteArrayOutputStream(256 * 1024)
            val ok = toEncode.compress(if (format == PhotoFormat.JPEG) Bitmap.CompressFormat.JPEG else Bitmap.CompressFormat.PNG, quality, out)
            if (ok) out.toByteArray() else null
        } finally {
            flat?.recycle()
            if (scaled !== source) scaled.recycle()
        }
    }
}
