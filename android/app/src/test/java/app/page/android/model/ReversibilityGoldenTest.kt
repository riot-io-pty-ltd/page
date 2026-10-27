package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The differential gate for the phone's reversibility classifier: every row of `reversibility-golden.tsv` was
 * produced by compiling iOS/Page/Models/Reversibility.swift (see tools/reversibility-golden.sh). The phone decides
 * which gestures are offered (swipe, tap, hold plus biometrics, a one-tap notification Approve) from this, so the
 * Kotlin port must agree with it on every row: level, tags (in order) and reason.
 */
class ReversibilityGoldenTest {
    @Test fun `every golden row matches the Swift classifier`() {
        val text = javaClass.classLoader!!.getResourceAsStream("reversibility-golden.tsv")!!.bufferedReader(Charsets.UTF_8).readText()
        val result = ReversibilityGoldenCheck.run(text)
        val rows = result.rows
        val mismatches = result.mismatches
        assertTrue("only $rows rows read", rows > 8000)
        assertEquals("Kotlin classifier disagrees with Swift on ${mismatches.size} of $rows rows:\n" + mismatches.take(8).joinToString("\n"), 0, mismatches.size)
    }

    @Test fun `no terragrunt command is undoable and a hook page never reads as undoable by guesswork`() {
        for (cmd in listOf("terragrunt plan", "terragrunt apply", "terragrunt run-all plan", "terragrunt init")) {
            assertTrue(cmd, Reversibility.classify("[Bash] $cmd", "/Users/me/proj").level != Reversibility.UNDOABLE)
        }
    }
}
