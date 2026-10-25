package app.page.android

import org.junit.Assert.assertEquals
import org.junit.Test

class SmokeTest {
    @Test
    fun graphemeClustersCountAsOneCharacter() {
        val family = "👨‍👩‍👧‍👦"
        val it = java.text.BreakIterator.getCharacterInstance()
        it.setText(family)
        var n = 0
        while (it.next() != java.text.BreakIterator.DONE) n++
        assertEquals(1, n)
    }
}
