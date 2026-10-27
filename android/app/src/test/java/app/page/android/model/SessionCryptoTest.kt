package app.page.android.model

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** docs/SESSIONS-PROTOCOL.md §2: both implementations must reproduce the vector exactly. */
class SessionCryptoTest {
    private val vecRoot = bytes(0..31)
    private val vecNonce = bytes(0xa0..0xab)
    private val vecListPT = """{"kind":"list","seq":1,"ts":1761300000000,"sessions":[]}"""
    private val vecListC = "izpLGj9N9Rpxuzq00howYI0D93aMC4vbU3Un38nzkzaX6rpd2wEiAvuseOahsZ9_zyivF1z2cuLwWX3k6Coa8QEvrfguLaN3"
    private val vecCmdPT = """{"op":"input","clientId":"c1","ts":1761300000000,"sessionId":"s1","text":"hi","viewer":"v1"}"""
    private val vecCmdC = "sfJ3_bSsO7l16uEp6oH6PFnwlSLI8D_5PtVk8-InyYs-UxcC40NUQDmbHrttBjpm5nJaeQFIgITtiHUF1c6EvBs3hEB0DiBSSIlItp7XAqPjYgLckNcOihF1sKMrZVv8vgUfNIaRAtrMrd_k"

    @Test
    fun base64Url() {
        assertEquals("-_8", Base64Url.encode(byteArrayOf(0xfb.toByte(), 0xff.toByte())))
        assertArrayEquals(byteArrayOf(0xfb.toByte(), 0xff.toByte()), Base64Url.decode("-_8"))
        assertArrayEquals(byteArrayOf(0xfb.toByte(), 0xff.toByte()), Base64Url.decode("-_8="))
        assertArrayEquals("standard alphabet accepted", byteArrayOf(0xfb.toByte(), 0xff.toByte()), Base64Url.decode("+/8="))
        assertNull("impossible length", Base64Url.decode("A"))
    }

    @Test
    fun vectorRootAndNonce() {
        assertEquals("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8", Base64Url.encode(vecRoot))
        assertEquals("oKGio6Slpqeoqaqr", Base64Url.encode(vecNonce))
    }

    @Test
    fun vectorSubkeys() {
        assertEquals("ofSfPY2KtPqbs29ecqGVJzfSrP61BvMETQTitpTwtYE", Base64Url.encode(SessionCrypto.subkey(vecRoot, SessionCrypto.Direction.MAC_TO_PHONE)))
        assertEquals("s_XovkSs3InwR9tqHVrGlT_dVvTJeDPPtd0r-wC1qp4", Base64Url.encode(SessionCrypto.subkey(vecRoot, SessionCrypto.Direction.PHONE_TO_MAC)))
    }

    @Test
    fun vectorCiphertexts() {
        val e = SessionCrypto.seal(vecListPT.toByteArray(), vecRoot, SessionCrypto.Direction.MAC_TO_PHONE, SessionFrameType.UPDATE, vecNonce)
        assertEquals(vecListC, Base64Url.encode(e.sealed))
        assertEquals("oKGio6Slpqeoqaqr", e.json.str("n"))
        assertEquals(1.0, e.json.num("v")!!, 0.0)
        val c = SessionCrypto.seal(vecCmdPT.toByteArray(), vecRoot, SessionCrypto.Direction.PHONE_TO_MAC, SessionFrameType.COMMAND, vecNonce)
        assertEquals(vecCmdC, Base64Url.encode(c.sealed))
    }

    private fun env(n: Any, c: String, v: Int = 1) = JsonObject(
        mapOf("v" to JsonPrimitive(v), "n" to if (n is String) JsonPrimitive(n) else JsonPrimitive(n as Int), "c" to JsonPrimitive(c))
    )

    @Test
    fun openingTheVectorAndEveryWrongWay() {
        val e = SessionCrypto.Envelope.fromJson(env("oKGio6Slpqeoqaqr", vecListC))
        assertNotNull(e)
        e!!
        assertArrayEquals(vecListPT.toByteArray(), SessionCrypto.open(e, vecRoot, SessionCrypto.Direction.MAC_TO_PHONE, SessionFrameType.UPDATE))
        assertNull("wrong direction", SessionCrypto.open(e, vecRoot, SessionCrypto.Direction.PHONE_TO_MAC, SessionFrameType.UPDATE))
        assertNull("relabelled frame type", SessionCrypto.open(e, vecRoot, SessionCrypto.Direction.MAC_TO_PHONE, SessionFrameType.COMMAND))
        assertNull("wrong key", SessionCrypto.open(e, ByteArray(32) { 7 }, SessionCrypto.Direction.MAC_TO_PHONE, SessionFrameType.UPDATE))
        val tampered = e.sealed.copyOf().also { it[0] = (it[0].toInt() xor 1).toByte() }
        assertNull("tampered", SessionCrypto.open(SessionCrypto.Envelope(e.nonce, tampered), vecRoot, SessionCrypto.Direction.MAC_TO_PHONE, SessionFrameType.UPDATE))
    }

    @Test
    fun envelopeShape() {
        assertNotNull("padded envelope accepted", SessionCrypto.Envelope.fromJson(env("oKGio6Slpqeoqaqr=", "$vecListC==")))
        assertNull("v2 rejected", SessionCrypto.Envelope.fromJson(env("oKGio6Slpqeoqaqr", vecListC, v = 2)))
        assertNull("short nonce", SessionCrypto.Envelope.fromJson(env("oKGio6Sl", vecListC)))
        assertNull("shorter than a tag", SessionCrypto.Envelope.fromJson(env("oKGio6Slpqeoqaqr", "AAAA")))
        assertNull("non-string nonce", SessionCrypto.Envelope.fromJson(env(5, vecListC)))
    }

    @Test
    fun productionNoncesAreRandom() {
        val r1 = SessionCrypto.seal("x".toByteArray(), vecRoot, SessionCrypto.Direction.PHONE_TO_MAC, SessionFrameType.COMMAND)
        val r2 = SessionCrypto.seal("x".toByteArray(), vecRoot, SessionCrypto.Direction.PHONE_TO_MAC, SessionFrameType.COMMAND)
        assertEquals(12, r1.nonce.size)
        assertFalse(r1.nonce.contentEquals(r2.nonce))
        assertArrayEquals("x".toByteArray(), SessionCrypto.open(r1, vecRoot, SessionCrypto.Direction.PHONE_TO_MAC, SessionFrameType.COMMAND))
    }

    @Test
    fun commandPlaintexts() {
        val inputPT = SessionCommand.Input("s1", "hi").plaintext("c1", "v1", CMD_NOW)
        val o = parseJsonObject(inputPT.toString(Charsets.UTF_8))!!
        assertTrue(o.str("op") == "input" && o.str("text") == "hi" && o.str("sessionId") == "s1")
        assertTrue(o.long("ts") == 1_761_300_000_000L && o.str("viewer") == "v1" && o.str("clientId") == "c1")
        // Keys sorted: deterministic bytes.
        assertEquals(listOf("clientId", "op", "sessionId", "text", "ts", "viewer"), o.keys.toList())

        val watchNull = parseJsonObject(SessionCommand.Watch(null).plaintext("c", "v", CMD_NOW).toString(Charsets.UTF_8))!!
        assertTrue("watch null stops viewing", watchNull["sessionId"] is JsonNull && watchNull.str("op") == "watch")
        val refresh = parseJsonObject(SessionCommand.Refresh.plaintext("c", "v", CMD_NOW).toString(Charsets.UTF_8))!!
        assertTrue(refresh.str("op") == "refresh" && refresh["sessionId"] == null)
        val interrupt = parseJsonObject(SessionCommand.Interrupt("s9").plaintext("c", "v", CMD_NOW).toString(Charsets.UTF_8))!!
        assertTrue(interrupt.str("op") == "interrupt" && interrupt.str("sessionId") == "s9")
        val wa = parseJsonObject(SessionCommand.WatchAgent("S", "wf_1", "a1").plaintext("c", "v", CMD_NOW).toString(Charsets.UTF_8))!!
        assertTrue(wa.str("op") == "watch" && wa.str("runId") == "wf_1" && wa.str("agentId") == "a1" && wa.str("sessionId") == "S")
    }

    private fun live(cwd: String, title: String) = LiveSession(
        id = "abcdef1234567890", backend = AgentBackend.Known(InterventionBackend.CLAUDE), title = title, cwd = cwd,
        state = LiveSessionState.ACTIVE, host = "tmux", canType = true, typeBlocker = null, canInterrupt = true,
        provider = null, lastActivityAt = null, interventionId = null, preview = "",
    )

    @Test
    fun inputCarriesTheExpectedTargetWhenGiven() {
        val target = SessionTarget.of(live("~/projects/page", "page"))
        val o = parseJsonObject(
            SessionCommand.Input("s1", "hi", target).plaintext("c1", "v1", CMD_NOW).toString(Charsets.UTF_8)
        )!!
        assertEquals("~/projects/page", o.str("expectCwd"))
        assertEquals("page", o.str("expectTitle"))
        assertEquals(listOf("clientId", "expectCwd", "expectTitle", "op", "sessionId", "text", "ts", "viewer"), o.keys.toList())
        // Optional: absent or empty fields are left out, so the wire stays as before.
        val bare = parseJsonObject(
            SessionCommand.Input("s1", "hi", SessionTarget.of(live("", "Session abcdef12"))).plaintext("c1", "v1", CMD_NOW).toString(Charsets.UTF_8)
        )!!
        assertEquals(listOf("clientId", "op", "sessionId", "text", "ts", "viewer"), bare.keys.toList())
    }

    @Test
    fun sessionTargetIsTheMacsFolderAndTitleVerbatim() {
        val t = SessionTarget.of(live("~/projects/page", "page"))
        assertEquals("~/projects/page", t.expectCwd)
        assertEquals("page", t.expectTitle)
        // A title Page made up (no folder, no title from the Mac) isn't sent.
        val made = SessionTarget.of(live("", "Session abcdef12"))
        assertEquals(null, made.expectCwd)
        assertEquals(null, made.expectTitle)
    }

    @Test
    fun requestBodyRoundTrips() {
        val inputPT = SessionCommand.Input("s1", "hi").plaintext("c1", "v1", CMD_NOW)
        val body = parseJsonObject(SessionCommand.requestBody(inputPT, vecRoot))!!
        assertEquals("body is only {e}", 1, body.size)
        val e = SessionCrypto.Envelope.fromJson(body.obj("e")!!)!!
        assertArrayEquals(inputPT, SessionCrypto.open(e, vecRoot, SessionCrypto.Direction.PHONE_TO_MAC, SessionFrameType.COMMAND))
    }
}
