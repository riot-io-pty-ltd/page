package app.page.android.model

import org.junit.Assert.assertTrue
import org.junit.Test

class GestureGuideTest {
    private val all get() = LegacyGestureGuide.sections.flatMap { it.entries }

    @Test
    fun noSectionOrEntryIsEmpty() {
        assertTrue(LegacyGestureGuide.sections.isNotEmpty())
        for (s in LegacyGestureGuide.sections) {
            assertTrue(s.title, s.title.isNotBlank() && s.entries.isNotEmpty())
            for (e in s.entries) assertTrue(e.gesture, e.gesture.isNotBlank() && e.result.isNotBlank())
        }
    }

    @Test
    fun theInFlightActionsAndEveryTipTopicAreExplained() {
        val text = (LegacyGestureGuide.sections.map { it.title } + all.map { it.gesture + " " + it.result }).joinToString(" ").lowercase()
        for (word in listOf("screen", "type", "press and hold", "pull down", "stop", "talkback", "approve", "typed", "queued")) {
            assertTrue(word, word in text)
        }
    }
}
