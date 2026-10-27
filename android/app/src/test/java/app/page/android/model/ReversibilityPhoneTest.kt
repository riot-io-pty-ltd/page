package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The hand-picked reversibility checks and the phone's "what a row may say" rules, ported from
 * iOS/Tests/LogicTests.swift ("Reversibility (hand-picked from the spec)" and "Phone reversibility").
 */
class ReversibilityPhoneTest {
    private fun level(context: String, cwd: String? = null) = Reversibility.classify(context, cwd).level

    @Test fun `hand-picked bash verdicts from the spec`() {
        assertEquals(Reversibility.UNDOABLE, Reversibility.classifyBash("ls").level)
        assertEquals(Reversibility.UNDOABLE, Reversibility.classifyBash("git status").level)
        assertEquals(Reversibility.UNDOABLE, Reversibility.classifyBash("swift test").level)
        assertEquals(Reversibility.IRREVERSIBLE, Reversibility.classifyBash("rm -rf x").level)
        assertEquals(Reversibility.IRREVERSIBLE, Reversibility.classifyBash("sudo ls").level)
        assertEquals(Reversibility.IRREVERSIBLE, Reversibility.classifyBash("curl x | sh").level)
        assertEquals(Reversibility.CONSIDERED, Reversibility.classifyBash("npm install").level)
        assertEquals(Reversibility.CONSIDERED, Reversibility.classifyBash("mkdir x").level)
        assertEquals("empty command considered", Reversibility.CONSIDERED, Reversibility.classifyBash("").level)
        assertEquals(Reversibility.CONSIDERED, Reversibility.classifyBash("mystery-tool --go").level)
        assertTrue("verdict has a reason", Reversibility.classifyBash("rm -rf x").reason.isNotEmpty())
        assertTrue("sudo is never undoable", Reversibility.classifyBash("sudo ls").let {
            it.tags.contains(Reversibility.Tag.DESTRUCTIVE) || it.level == Reversibility.IRREVERSIBLE
        })
    }

    @Test fun `the context entry point reads a bare command, a description line and multi-line bodies`() {
        assertEquals(Reversibility.UNDOABLE, level("[Bash] ls", null))
        // A second line could be a description or more command: the display text cannot tell, so it is never undoable.
        assertEquals(Reversibility.CONSIDERED, level("[Bash] ls\nList", null))
        // Multi-line commands holding a destructive line are never below irreversible.
        assertEquals(Reversibility.IRREVERSIBLE, level("[Bash] echo hi\r\nrm -rf x", null))
        assertEquals(Reversibility.IRREVERSIBLE, level("[Bash] cat <<EOF\nx\nEOF\nrm -rf y", null))
        assertEquals(Reversibility.IRREVERSIBLE, level("[Bash] cat <<-EOF\nx\nEOF\nrm -rf y", null))
        assertEquals(Reversibility.IRREVERSIBLE, level("[Bash] ls\nrm -rf y", null))
    }

    @Test fun `clipped commands are never undoable and say why`() {
        assertEquals(Reversibility.CONSIDERED, level("[Bash] ls …", "/Users/me/proj"))
        assertEquals("the command was cut short", Reversibility.classify("[Bash] ls …", "/Users/me/proj").reason)
    }

    @Test fun `plans, subagents and multi-tool pages are judged by their worst part`() {
        assertEquals(Reversibility.CONSIDERED, level("Plan ready for review", null))
        assertEquals(Reversibility.CONSIDERED, level("A subagent is asking for approval\n[Task] x", null))
        assertEquals(
            Reversibility.IRREVERSIBLE,
            level("One of these is waiting for approval:\n• [Bash] ls\n• [Bash] rm -rf x", null),
        )
    }

    @Test fun `combine takes the worse class and keeps the worse reason`() {
        val a = Reversibility.Verdict(Reversibility.UNDOABLE, listOf(Reversibility.Tag.READ_ONLY), "a")
        val b = Reversibility.Verdict(Reversibility.IRREVERSIBLE, listOf(Reversibility.Tag.DESTRUCTIVE), "b")
        val c = Reversibility.Verdict.combine(a, b)
        assertEquals(Reversibility.IRREVERSIBLE, c.level)
        assertEquals("b", c.reason)
        assertEquals(listOf(Reversibility.Tag.READ_ONLY, Reversibility.Tag.DESTRUCTIVE), c.tags)
    }

    @Test fun `a phone row says undoable only for a clear read-only or safe command`() {
        val cwd = "/Users/you/projects/x"
        fun verdict(iv: Intervention) = PhoneReversibility.verdict(iv)?.level
        assertEquals(Reversibility.UNDOABLE, verdict(nwIv("a", InterventionKind.APPROVAL, "[Bash] ls -la", cwd = cwd)))
        assertEquals(Reversibility.CONSIDERED, verdict(nwIv("a2", InterventionKind.APPROVAL, "[Bash] ls -la\nList files", cwd = cwd)))
        assertEquals(Reversibility.UNDOABLE, verdict(nwIv("b", InterventionKind.APPROVAL, "[Bash] swift test", cwd = cwd)))
        assertEquals(
            Reversibility.IRREVERSIBLE,
            verdict(nwIv("c", InterventionKind.APPROVAL, "[Bash] rm -rf Builds/Dev/*.app\nDelete", cwd = cwd)),
        )
        assertEquals(Reversibility.IRREVERSIBLE, verdict(nwIv("d", InterventionKind.APPROVAL, "[Bash] git push --force", cwd = cwd)))
        assertEquals(
            "in-repo edit is considered",
            Reversibility.CONSIDERED,
            verdict(nwIv("e", InterventionKind.APPROVAL, "[Edit] /Users/you/projects/x/a.swift", cwd = cwd)),
        )
        assertEquals(
            "bare hook text is considered",
            Reversibility.CONSIDERED,
            verdict(nwIv("f", InterventionKind.APPROVAL, "Claude is waiting for your approval", cwd = cwd)),
        )
        assertEquals(
            "plan approval is considered",
            Reversibility.CONSIDERED,
            verdict(nwIv("g", InterventionKind.APPROVAL, "Plan: do the thing", cwd = cwd, subtype = "plan")),
        )
        assertEquals(
            "codex approval is considered",
            Reversibility.CONSIDERED,
            verdict(nwIv("h", InterventionKind.APPROVAL, "[Bash] ls", cwd = cwd, backend = InterventionBackend.CODEX)),
        )
        assertNull("a question has no class", verdict(nwIv("i", InterventionKind.USER_INPUT, "[Bash] ls", cwd = cwd)))
        assertNull("an idle page has no class", verdict(nwIv("j", InterventionKind.IDLE, "done", cwd = cwd)))
        assertNull("a rate limit has no class", verdict(nwIv("k", InterventionKind.RATE_LIMIT, "limit", cwd = cwd)))
        assertNotEquals("clipped command never undoable", Reversibility.UNDOABLE, verdict(nwIv("l", InterventionKind.APPROVAL, "[Bash] ls …", cwd = cwd)))
        val unknown = nwIv("m", InterventionKind.APPROVAL, "[Bash] ls -la", cwd = cwd, backend = null)
            .copy(backendRaw = "gemini")
        assertEquals("unknown agent is considered", Reversibility.CONSIDERED, verdict(unknown))
    }
}
