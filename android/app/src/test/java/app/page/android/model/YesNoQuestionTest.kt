package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The yes/no detector, on a table shared with iOS (YesNoQuestionTests in LogicTests.swift): the same strings and the
 * same expected question (null: no chips). A false positive puts words in the user's mouth, so the table is mostly
 * the things that must stay quiet.
 */
class YesNoQuestionTest {
    private val vectors: List<Pair<String, String?>> = listOf(
        "I've finished the refactor. Should I run the full test suite now?" to "Should I run the full test suite now?",
        "All done.\n\nShould I go ahead and commit?" to "Should I go ahead and commit?",
        "Do you want me to run the tests?" to "Do you want me to run the tests?",
        "Want me to fix it?" to "Want me to fix it?",
        "Shall I proceed?" to "Shall I proceed?",
        "Fixed the bug in parser.swift. Want me to fix the other two warnings as well?" to "Want me to fix the other two warnings as well?",
        "I can add a migration for this.\nWould you like me to?" to "Would you like me to?",
        "**Should I commit these changes?**" to "Should I commit these changes?",
        "Everything passes.   \n\n  Shall I push?  \n\n" to "Shall I push?",
        "Done — should I open a PR?" to "should I open a PR?",
        "Quick question: do you want me to keep the old API?" to "do you want me to keep the old API?",
        "Is it ok if I delete the unused files?" to "Is it ok if I delete the unused files?",
        "Ready to proceed?" to "Ready to proceed?",
        "Okay to commit?" to "Okay to commit?",
        "That's the plan. Sound good?" to "Sound good?",
        "Does that sound good?" to "Does that sound good?",
        "Ok, should I run the linter too?" to "Ok, should I run the linter too?",
        "So do you want me to go ahead?" to "So do you want me to go ahead?",
        "Can I go ahead and delete the build folder?" to "Can I go ahead and delete the build folder?",
        "Would it be okay if I renamed the module?" to "Would it be okay if I renamed the module?",
        "Should I use `npm test` here?" to "Should I use `npm test` here?",
        "Proceed?" to "Proceed?",
        "Are you ready for me to merge?" to "Are you ready for me to merge?",
        "Should we split this into two PRs?" to "Should we split this into two PRs?",
        "Does that work for you?" to "Does that work for you?",
        "Shall I?" to "Shall I?",
        "" to null,
        "All done." to null,
        "What should I do next?" to null,
        "Which file should I edit?" to null,
        "How do you want me to handle the error?" to null,
        "Why did the test fail?" to null,
        "Where should I put the config?" to null,
        "When should I run it?" to null,
        "Who owns this module?" to null,
        "Should I commit or push?" to null,
        "Do you want me to run the tests or the linter?" to null,
        "Should I commit, and with which message?" to null,
        "Should I fix what's broken?" to null,
        "```\nShould I run the tests?\n```" to null,
        "Here is the code:\n```swift\nlet x = 1 // should I?\n```" to null,
        "Do you want me to run the tests?\n```\nnpm test\n```" to null,
        "Should I run the tests?\n```\nnpm test" to null,
        "> Should I commit?" to null,
        "The prompt says: \"Should I run the tests?\"" to null,
        "She asked \"Should I commit?" to null,
        "Should I commit? Let me know." to null,
        "Should I commit?\n\nI'll wait here." to null,
        "- Should I commit?\n- Should I push?" to null,
        "1. Should I commit?" to null,
        "Should I go ahead\nand commit?" to null,
        "Can you share the error log?" to null,
        "Could you paste the stack trace?" to null,
        "Will you be at the Mac later?" to null,
        "Is the build green?" to null,
        "Are there any other changes?" to null,
        "Do the tests pass?" to null,
        "Should the tests run first?" to null,
        "Does this make sense?" to null,
        "Do you prefer tabs?" to null,
        "I wonder whether I should commit?" to null,
        "Should I run the full suite? Or only the unit tests?" to null,
        "Do you want me to run the tests" to null,
        "Want me to fix it? 🙂" to null,
        "Should I run `npm test?" to null,
        "Should I use Postgres vs SQLite?" to null,
        "Should I keep the old API versus the new one?" to null,
        "Should I run the tests? Should I also commit?" to null,
        "Would you like me to make any other changes?" to null,
        "Do you need anything else?" to null,
        "Want me to look at anything else?" to null,
    )

    @Test
    fun sharedVectors() {
        for ((text, expected) in vectors) assertEquals("for: $text", expected, YesNoQuestion.detect(text))
    }

    // Where it is offered: the same checks as iOS's YesNoReply cases in LogicTests.swift.
    private fun asst(id: String, text: String) = TranscriptTimeline.Item.Entry(TranscriptEntry(id, TranscriptRole.ASSISTANT, text, null, null), null)
    private fun user(id: String, text: String) = TranscriptTimeline.Item.Entry(TranscriptEntry(id, TranscriptRole.USER, text, null, null), null)
    private fun sent(state: SessionDeliveryState) =
        TranscriptTimeline.Item.Pending(SentSessionCommand("c1", "s1", SessionCommandKind.INPUT, YesNoReply.YES, java.time.Instant.EPOCH, state))
    private fun offer(
        mode: RoomComposerMode = RoomComposerMode.NextTask, state: LiveSessionState = LiveSessionState.IDLE, ended: Boolean = false,
        ready: Boolean = true, ask: Boolean = false, items: List<TranscriptTimeline.Item>,
    ) = YesNoReply.roomOffer(mode, state, ended, ready, ask, items)

    @Test
    fun theRoomOffersItOnlyForAnIdleSessionWhoseStoryEndsOnTheQuestion() {
        val q = asst("a1", "Tests pass.\n\nShould I commit?")
        assertEquals("Should I commit?", offer(items = listOf(user("u1", "fix it"), q)))
        assertNull("mid-turn", offer(mode = RoomComposerMode.Steer, state = LiveSessionState.ACTIVE, items = listOf(q)))
        assertNull("a prompt waits", offer(mode = RoomComposerMode.TellInstead("p1"), state = LiveSessionState.WAITING_ON_APPROVAL, items = listOf(q)))
        for (m in listOf(RoomComposerMode.Blocked("x"), RoomComposerMode.Locked("x"), RoomComposerMode.Disabled("x"))) assertNull("where Page cannot type", offer(mode = m, items = listOf(q)))
        assertNull("rate-limited", offer(state = LiveSessionState.RATE_LIMITED, items = listOf(q)))
        assertNull("ended", offer(ended = true, items = listOf(q)))
        assertNull("Mac unreachable", offer(ready = false, items = listOf(q)))
        assertNull("the picker answers it", offer(ask = true, items = listOf(q)))
        assertNull("answered in the terminal", offer(items = listOf(q, user("u2", "Yes"))))
        assertNull("sending from here", offer(items = listOf(q, sent(SessionDeliveryState.Sending))))
        assertNull("typed from here", offer(items = listOf(q, sent(SessionDeliveryState.Typed(null)))))
        assertNull("a tool call after it", offer(items = listOf(q, TranscriptTimeline.Item.Entry(TranscriptEntry("t1", TranscriptRole.TOOL, "Bash", null, "Bash"), null))))
        assertNull("no question", offer(items = listOf(asst("a2", "All done."))))
        assertNull("no story", offer(items = emptyList()))
    }

    @Test
    fun theReviewSheetTakesThePageQuestionBehindTheSteerGate() {
        assertEquals("Want me to run the tests?", YesNoReply.reviewOffer("Want me to run the tests?", takesReply = true, open = true))
        assertNull(YesNoReply.reviewOffer("Want me to run the tests?", takesReply = false, open = true))
        assertNull("once sent or resolved", YesNoReply.reviewOffer("Want me to run the tests?", takesReply = true, open = false))
        assertNull(YesNoReply.reviewOffer(null, takesReply = true, open = true))
    }

    @Test
    fun theRepliesAreExactlyYesAndNo() {
        assertEquals("Yes", YesNoReply.YES)
        assertEquals("No", YesNoReply.NO)
    }

    @Test
    fun theTableHasEnoughCases() {
        assertEquals(71, vectors.size)
        assertTrue(vectors.size >= 40 && vectors.count { it.second != null } >= 20 && vectors.count { it.second == null } >= 20)
    }
}
