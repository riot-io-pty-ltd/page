package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The two quote shapes that used to hide commands from the parser: a partly quoted heredoc delimiter
 * (`E"OF"`, `'E'OF`, `E\OF`: the shell removes the quotes, so the line `EOF` ends the body) and ANSI-C /
 * locale quoting (`$'\x72m'` is `rm`). Mirrors the rows added to `rvTable` in iOS/Tests/LogicTests.swift
 * and ReversibilityTests.swift; ReversibilityGoldenTest holds the same rows against the Swift verdicts.
 */
class ReversibilityQuotingTest {
    private fun level(command: String): Reversibility = Reversibility.classify("[Bash] $command", null).level

    @Test fun `a partly quoted heredoc delimiter still ends at its line so the next command is classified`() {
        assertEquals(Reversibility.IRREVERSIBLE, level("cat <<E\"OF\"\nhi\nEOF\ngit push --force"))
        assertEquals(Reversibility.IRREVERSIBLE, level("git push --force"))
        assertEquals(Reversibility.IRREVERSIBLE, level("cat <<'E'OF\nhi\nEOF\nrm -rf y"))
        assertEquals(Reversibility.IRREVERSIBLE, level("cat <<E\\OF\nhi\nEOF\nrm -rf y"))
        assertEquals(Reversibility.IRREVERSIBLE, level("cat <<\"EOF\"\nhi\nEOF\nrm -rf y"))
        assertEquals(Reversibility.IRREVERSIBLE, level("cat <<-'X'\nhi\nX\nrm -rf y"))
        assertEquals(Reversibility.IRREVERSIBLE, level("cat <<\$'EOF'\nhi\nEOF\nrm -rf y"))
        assertEquals(Reversibility.CONSIDERED, level("cat <<'EOF'\nhi\nEOF"))
        for (cmd in listOf("cat <<E\"OF\"\nhi\nEOF\nrm x", "cat <<'E'OF\nhi\nEOF\nrm x", "cat <<E\\OF\nhi\nEOF\nrm x", "cat <<-'X'\nhi\nX\nrm x")) {
            val p = ShellParse.parse(cmd)
            assertEquals(cmd, listOf(listOf("cat"), listOf("rm", "x")), p.segments.map { it.words })
            assertFalse(cmd, p.hasOpaqueHeredoc)
        }
    }

    @Test fun `a heredoc with no delimiter line is opaque and its text is judged as commands`() {
        val open = ShellParse.parse("cat <<EOF\nhi\nrm -rf x")
        assertTrue(open.hasOpaqueHeredoc)
        assertEquals(listOf("hi\nrm -rf x"), open.substitutions)
        assertTrue(ShellParse.parse("cat <<E\"OF\"\nhi").hasOpaqueHeredoc)
        assertFalse(ShellParse.parse("cat <<'EOF'\nhi\nEOF").hasOpaqueHeredoc)
        assertEquals(Reversibility.IRREVERSIBLE, level("cat <<EOF\nrm -rf x"))
        assertEquals(Reversibility.CONSIDERED, level("cat <<EOF\nhi"))
    }

    @Test fun `ANSI-C and locale quoted words are never undoable`() {
        assertEquals(Reversibility.CONSIDERED, level("echo \$'\\x72m'"))
        assertEquals(Reversibility.CONSIDERED, level("\$'\\x72m' -rf x"))
        assertEquals(Reversibility.IRREVERSIBLE, level("\$'rm' -rf x"))
        assertEquals(Reversibility.CONSIDERED, level("ls \$\"a\""))
        assertEquals(Reversibility.CONSIDERED, level("ls > \$'/tmp/x'"))
        for (cmd in listOf("echo \$'\\x72m'", "\$'\\x72m' -rf x", "echo \$\"a\"", "ls > \$'f'", "cat <<\$'EOF'\nx\nEOF")) {
            assertTrue(cmd, ShellParse.parse(cmd).hasOpaqueHeredoc)
        }
    }

    @Test fun `an escaped quote inside an ANSI-C string does not close it`() {
        assertEquals(Reversibility.IRREVERSIBLE, level("echo \$'a\\'b' ; rm -rf x"))
        assertEquals(
            listOf(listOf("echo", "a\\'b"), listOf("rm", "x")),
            ShellParse.parse("echo \$'a\\'b' ; rm x").segments.map { it.words },
        )
    }

    @Test fun `a redirect target gets the same quote removal so the next command is classified`() {
        assertEquals(Reversibility.IRREVERSIBLE, level("cat < x\$'a b'; rm -rf x"))
        assertEquals(Reversibility.IRREVERSIBLE, level("cat < x'a b' ; rm -rf x #'"))
        assertEquals(Reversibility.IRREVERSIBLE, level("cat < \"a\\\" b\" ; rm -rf x ; echo \"y\""))
        assertEquals(Reversibility.IRREVERSIBLE, level("cat < a\\'b ; rm -rf x #'"))
        assertEquals(Reversibility.IRREVERSIBLE, level("ls > x\$'y\\'' ; rm -rf x #'"))
        assertEquals(Reversibility.IRREVERSIBLE, level("cat > \"a\\\" b\" ; rm -rf x #\""))
        assertEquals(Reversibility.CONSIDERED, level("ls > x\\; rm -rf x")) // writes a file named `x;`
        for (cmd in listOf("cat < x'a b' ; rm x", "cat < \"a\\\" b\" ; rm x", "cat < a\\'b ; rm x")) {
            assertEquals(cmd, listOf(listOf("cat"), listOf("rm", "x")), ShellParse.parse(cmd).segments.map { it.words })
        }
        assertTrue(ShellParse.parse("cat < x\$'a b' ; rm x").hasOpaqueHeredoc)
    }

    @Test fun `plain quoted dollars are untouched`() {
        assertEquals(Reversibility.UNDOABLE, level("echo '\$'"))
        assertEquals(Reversibility.UNDOABLE, level("echo \"\$'x'\""))
        assertFalse(ShellParse.parse("echo '\$' \"\$'x'\"").hasOpaqueHeredoc)
    }
}
