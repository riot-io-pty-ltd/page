package app.page.android.model

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The same differential gate as ReversibilityGoldenTest, run on the device's own regex engine (ICU, without
 * UNICODE_CHARACTER_CLASS). The phone decides which gestures are offered from this classifier, so the golden rows
 * produced by compiling the iOS classifier must agree on a real Android runtime too.
 * Run: `./gradlew connectedDebugAndroidTest` with an emulator attached.
 */
@RunWith(AndroidJUnit4::class)
class ReversibilityGoldenInstrumentedTest {
    @Test fun every_golden_row_matches_the_Swift_classifier_on_the_device_regex_engine() {
        val text = javaClass.classLoader!!.getResourceAsStream("reversibility-golden.tsv")!!.bufferedReader(Charsets.UTF_8).readText()
        val result = ReversibilityGoldenCheck.run(text)
        assertTrue("only ${result.rows} rows read", result.rows > 8000)
        assertEquals(
            "Device classifier disagrees with Swift on ${result.mismatches.size} of ${result.rows} rows:\n" + result.mismatches.take(8).joinToString("\n"),
            0, result.mismatches.size,
        )
    }
}
