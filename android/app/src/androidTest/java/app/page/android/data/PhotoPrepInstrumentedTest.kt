package app.page.android.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.media.ExifInterface
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import app.page.android.model.PhotoFormat
import app.page.android.model.PhotoLimits
import app.page.android.model.PhotoMetadata
import java.io.ByteArrayInputStream
import java.io.File
import java.util.Random
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The real encoder on a real phone: a photo that carries GPS comes out with none, at most 2000 px, at most 1 MiB, upright.
 * Run on one emulator only: `adb -s emulator-5560 shell am instrument -w app.page.android.debug.test/androidx.test.runner.AndroidJUnitRunner`.
 */
@RunWith(AndroidJUnit4::class)
class PhotoPrepInstrumentedTest {
    private val context: Context get() = InstrumentationRegistry.getInstrumentation().targetContext

    private fun picture(w: Int, h: Int, noise: Int = 24): Bitmap {
        val rnd = Random(5)
        val px = IntArray(w * h)
        for (y in 0 until h) for (x in 0 until w) {
            fun c(base: Int) = (base + rnd.nextInt(noise * 2 + 1) - noise).coerceIn(0, 255)
            px[y * w + x] = Color.rgb(c(x * 255 / w), c(y * 255 / h), c((x + y) * 255 / (w + h)))
        }
        return Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888)
    }

    private fun write(name: String, bitmap: Bitmap, jpeg: Boolean): File {
        val f = File(context.cacheDir, name)
        f.outputStream().use { bitmap.compress(if (jpeg) Bitmap.CompressFormat.JPEG else Bitmap.CompressFormat.PNG, 92, it) }
        return f
    }

    private fun withGps(f: File, orientation: Int = ExifInterface.ORIENTATION_NORMAL): File {
        val exif = ExifInterface(f.absolutePath)
        exif.setAttribute(ExifInterface.TAG_GPS_LATITUDE, "51/1,30/1,0/1")
        exif.setAttribute(ExifInterface.TAG_GPS_LATITUDE_REF, "N")
        exif.setAttribute(ExifInterface.TAG_GPS_LONGITUDE, "0/1,7/1,0/1")
        exif.setAttribute(ExifInterface.TAG_GPS_LONGITUDE_REF, "W")
        exif.setAttribute(ExifInterface.TAG_MAKE, "TestCam")
        exif.setAttribute(ExifInterface.TAG_ORIENTATION, orientation.toString())
        exif.saveAttributes()
        return f
    }

    private fun prepare(f: File): PhotoPrep.Result.Ok {
        val r = runBlocking { PhotoPrep.prepare(context.contentResolver, Uri.fromFile(f), PhotoLimits.MAX_EACH_BYTES) }
        assertTrue("prepare gave $r", r is PhotoPrep.Result.Ok)
        return r as PhotoPrep.Result.Ok
    }

    @Test fun aPhotoWithGpsComesOutWithNoMetadataAtMost2000pxAndOneMiB() {
        val file = withGps(write("src-gps.jpg", picture(4000, 3000), jpeg = true))
        // The source really carries what must not leave the phone.
        assertNotNull(ExifInterface(file.absolutePath).getAttribute(ExifInterface.TAG_GPS_LATITUDE))
        assertTrue(PhotoMetadata.scan(file.readBytes()).gps)

        val ok = prepare(file)
        val bytes = ok.photo.bytes
        assertEquals(PhotoFormat.JPEG, ok.photo.format)
        assertTrue("size ${bytes.size}", bytes.size <= PhotoLimits.MAX_EACH_BYTES)
        val f = PhotoMetadata.scan(bytes)
        assertFalse("gps", f.gps)
        assertEquals(PhotoMetadata.Findings(), f)
        // And the platform's own reader agrees: no location, no make, no orientation.
        val exif = ExifInterface(ByteArrayInputStream(bytes))
        assertNull(exif.getLatLong(FloatArray(2)).let { if (it) "has a location" else null })
        assertNull(exif.getAttribute(ExifInterface.TAG_MAKE))
        assertNull(exif.getAttribute(ExifInterface.TAG_GPS_LATITUDE))
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        assertEquals(2000, maxOf(decoded.width, decoded.height))
        assertEquals(1500, minOf(decoded.width, decoded.height))
        assertEquals(ok.photo.sha256.length, 64)
    }

    @Test fun theOrientationIsBakedInSoThePhotoIsUpright() {
        // 400 x 200 stored sideways with "rotate 90": upright it is 200 x 400.
        val file = withGps(write("src-rot.jpg", picture(400, 200), jpeg = true), ExifInterface.ORIENTATION_ROTATE_90)
        val ok = prepare(file)
        val decoded = BitmapFactory.decodeByteArray(ok.photo.bytes, 0, ok.photo.bytes.size)
        assertEquals(200, decoded.width)
        assertEquals(400, decoded.height)
        assertEquals(PhotoMetadata.Findings(), PhotoMetadata.scan(ok.photo.bytes))
    }

    @Test fun aTransparentPngStaysAPngWithItsTransparency() {
        val bmp = Bitmap.createBitmap(300, 200, Bitmap.Config.ARGB_8888)
        for (y in 0 until 200) for (x in 150 until 300) bmp.setPixel(x, y, Color.rgb(51, 102, 204))
        val ok = prepare(write("src-alpha.png", bmp, jpeg = false))
        assertEquals(PhotoFormat.PNG, ok.photo.format)
        val decoded = BitmapFactory.decodeByteArray(ok.photo.bytes, 0, ok.photo.bytes.size)
        assertEquals(0, Color.alpha(decoded.getPixel(10, 10)))
        assertEquals(255, Color.alpha(decoded.getPixel(250, 10)))
        assertEquals(PhotoMetadata.Findings(), PhotoMetadata.scan(ok.photo.bytes))
    }

    @Test fun anOpaquePngGoesAsAJpeg() {
        val ok = prepare(write("src-opaque.png", picture(800, 600), jpeg = false))
        assertEquals(PhotoFormat.JPEG, ok.photo.format)
        assertEquals(PhotoMetadata.Findings(), PhotoMetadata.scan(ok.photo.bytes))
    }

    @Test fun aNoisyPhotoStepsDownUntilItFits() {
        val ok = prepare(write("src-noise.png", picture(3000, 2000, noise = 127), jpeg = false))
        assertTrue("size ${ok.photo.size}", ok.photo.size <= PhotoLimits.MAX_EACH_BYTES)
        assertTrue(ok.photo.width <= 2000)
    }

    @Test fun aFileThatIsNotAPictureIsRefusedWithAReason() {
        val f = File(context.cacheDir, "not-a-photo.jpg").apply { writeText("hello") }
        val r = runBlocking { PhotoPrep.prepare(context.contentResolver, Uri.fromFile(f), PhotoLimits.MAX_EACH_BYTES) }
        assertTrue(r is PhotoPrep.Result.Failed)
    }
}
