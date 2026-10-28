package app.page.android.model

import app.page.android.testkit.JvmImages
import java.io.ByteArrayOutputStream

// Test-only: images generated in the JVM (java.awt lives in :photo-testkit; the app's tests compile against
// android.jar, which has none), and hand-built metadata to put into them.

/** Re-encodes a picture the way the phone's codec does: scaled to the long edge, JPEG on white, PNG as is. ImageIO writes no EXIF. */
class ImageIoCodec(private val image: JvmImages.Img) : PhotoCodec {
    override val width: Int get() = image.width()
    override val height: Int get() = image.height()
    override val hasAlpha: Boolean by lazy { image.hasAlpha() }

    override fun encode(format: PhotoFormat, longEdge: Int, quality: Int): ByteArray = image.encode(format == PhotoFormat.PNG, longEdge, quality)
}

object PhotoFixtures {
    /** A smooth picture with a little noise: it compresses like a photo does. */
    fun photo(w: Int, h: Int, seed: Long = 7, noise: Int = 18): JvmImages.Img = JvmImages.photo(w, h, seed, noise)

    /** Pure noise: the worst case for a JPEG. */
    fun noisy(w: Int, h: Int, seed: Long = 3): JvmImages.Img = JvmImages.photo(w, h, seed, 127)

    /** A picture with a transparent half. */
    fun transparent(w: Int, h: Int): JvmImages.Img = JvmImages.transparent(w, h)

    fun jpeg(img: JvmImages.Img, quality: Int = 80): ByteArray = img.encode(false, 100_000, quality)
    fun png(img: JvmImages.Img): ByteArray = img.encode(true, 100_000, 100)

    fun decode(bytes: ByteArray): JvmImages.Img = JvmImages.decode(bytes)

    private fun u16(v: Int) = byteArrayOf((v shr 8).toByte(), v.toByte())
    private fun u32(v: Int) = byteArrayOf((v shr 24).toByte(), (v shr 16).toByte(), (v shr 8).toByte(), v.toByte())

    /** "Exif\0\0" and a big-endian TIFF whose IFD0 points at a GPS IFD (tag 0x8825) with a latitude reference. */
    val exifWithGps: ByteArray = "Exif\u0000\u0000".toByteArray(Charsets.ISO_8859_1) +
        "MM".toByteArray() + u16(0x2A) + u32(8) +
        u16(1) + u16(0x8825) + u16(4) + u32(1) + u32(26) + u32(0) +
        u16(1) + u16(1) + u16(2) + u32(2) + byteArrayOf('N'.code.toByte(), 0, 0, 0) + u32(0)

    /** An Exif with a camera make and no GPS. */
    val exifNoGps: ByteArray = "Exif\u0000\u0000".toByteArray(Charsets.ISO_8859_1) +
        "II".toByteArray() + byteArrayOf(0x2A, 0) + byteArrayOf(8, 0, 0, 0) +
        byteArrayOf(1, 0) + byteArrayOf(0x0F, 0x01, 2, 0, 2, 0, 0, 0, 'X'.code.toByte(), 0, 0, 0) + byteArrayOf(0, 0, 0, 0)

    val xmpWithGps: ByteArray = "http://ns.adobe.com/xap/1.0/\u0000<x:xmpmeta><exif:GPSLatitude>51,30N</exif:GPSLatitude></x:xmpmeta>".toByteArray(Charsets.ISO_8859_1)

    /** Puts marker segments straight after SOI. */
    fun withSegments(jpeg: ByteArray, vararg segments: Pair<Int, ByteArray>): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(jpeg, 0, 2)
        for ((marker, payload) in segments) {
            out.write(0xFF); out.write(marker)
            out.write(u16(payload.size + 2)); out.write(payload)
        }
        out.write(jpeg, 2, jpeg.size - 2)
        return out.toByteArray()
    }

    private fun crc(type: String, data: ByteArray): ByteArray {
        val c = java.util.zip.CRC32()
        c.update(type.toByteArray(Charsets.ISO_8859_1)); c.update(data)
        return u32(c.value.toInt())
    }

    private fun chunk(type: String, data: ByteArray): ByteArray = u32(data.size) + type.toByteArray(Charsets.ISO_8859_1) + data + crc(type, data)

    /** Puts chunks right after IHDR. */
    fun withChunks(png: ByteArray, vararg chunks: Pair<String, ByteArray>): ByteArray {
        val afterIhdr = 8 + 12 + 13
        val out = ByteArrayOutputStream()
        out.write(png, 0, afterIhdr)
        for ((t, d) in chunks) out.write(chunk(t, d))
        out.write(png, afterIhdr, png.size - afterIhdr)
        return out.toByteArray()
    }

    /** A structurally valid JPEG of [size] bytes (no decodable picture): for the policy tests' fake codecs. */
    fun fakeJpeg(size: Int): ByteArray {
        val body = maxOf(0, size - 2 - 4 - 2)
        return byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xDA.toByte(), 0, 2) + ByteArray(body) + byteArrayOf(0xFF.toByte(), 0xD9.toByte())
    }

    /** A structurally valid PNG of about [size] bytes. */
    fun fakePng(size: Int): ByteArray {
        val sig = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
        val ihdr = chunk("IHDR", ByteArray(13))
        val iend = chunk("IEND", ByteArray(0))
        return sig + ihdr + chunk("IDAT", ByteArray(maxOf(0, size - sig.size - ihdr.size - iend.size - 12))) + iend
    }
}
