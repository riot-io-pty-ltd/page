package app.page.android.model

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

class PairingTest {
    private fun ok(text: String): ValidatedPairing = when (val r = PairingValidator.validate(text)) {
        is PairingResult.Success -> r.pairing
        is PairingResult.Failure -> { fail("expected success, got ${r.error}"); throw IllegalStateException() }
    }

    private fun err(text: String): PairingValidationError? = (PairingValidator.validate(text) as? PairingResult.Failure)?.error

    @Test
    fun goodPayloadNormalisesTheRelay() {
        val p = ok("""{"v":1,"token":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG","relay":"wss://page.example.workers.dev/ws","host":"Roy's Mac"}""")
        assertEquals("https://page.example.workers.dev", p.relayBaseUrl)
        assertEquals("Roy's Mac", p.macName)
        assertEquals("page.example.workers.dev", p.relayHost)
    }

    @Test
    fun curlyQuotesAndDefaultName() {
        val curly = "{\u201Cv\u201D:1,\u201Ctoken\u201D:\u201Cabcdefghijklmnopqrstuvwxyz\u201D,\u201Crelay\u201D:\u201Chttps://r.example.com/\u201D}"
        val p = ok(curly)
        assertEquals("https://r.example.com", p.relayBaseUrl)
        assertEquals("Your Mac", p.macName)
    }

    @Test
    fun rejections() {
        assertEquals(PairingValidationError.Empty, err(""))
        assertEquals(PairingValidationError.NotPageCode, err("https://example.com"))
        assertEquals(PairingValidationError.NotPageCode, err("""{"ssid":"x"}"""))
        assertEquals(PairingValidationError.UnsupportedVersion(2), err("""{"v":2,"token":"abcdefghijklmnopqrstuvwxyz","relay":"https://a.b"}"""))
        assertEquals(PairingValidationError.MissingToken, err("""{"v":1,"token":"short","relay":"https://a.b"}"""))
        assertEquals(PairingValidationError.MissingToken, err("""{"v":1,"token":"abcdefghij klmnopqrstuvwxyz","relay":"https://a.b"}"""))
        assertEquals(PairingValidationError.InsecureRelay, err("""{"v":1,"token":"abcdefghijklmnopqrstuvwxyz","relay":"http://a.b"}"""))
        assertEquals(PairingValidationError.PlaceholderRelay, err("""{"v":1,"token":"abcdefghijklmnopqrstuvwxyz","relay":"https://your-page-relay.workers.dev"}"""))
        assertEquals(PairingValidationError.InvalidRelay, err("""{"v":1,"token":"abcdefghijklmnopqrstuvwxyz","relay":"nonsense"}"""))
        assertEquals(PairingValidationError.InvalidRelay, err("""{"v":1,"token":"abcdefghijklmnopqrstuvwxyz"}"""))
    }

    @Test
    fun versionAsString() {
        ok("""{"v":"1","token":"abcdefghijklmnopqrstuvwxyz","relay":"https://r.example.com"}""")
    }

    private val skGood = Base64Url.encode(ByteArray(32) { 9 })

    private fun pairingJson(sk: String?): String {
        var s = """{"v":1,"token":"abcdefghijklmnopqrstuvwxyz","relay":"https://r.example.com""""
        if (sk != null) s += ""","sk":$sk"""
        return "$s}"
    }

    @Test
    fun sessionKeyIsOptionalAndExactly32Bytes() {
        assertArrayEquals(ByteArray(32) { 9 }, ok(pairingJson("\"$skGood\"")).sessionKey)
        assertEquals(32, ok(pairingJson("\"$skGood=\"")).sessionKey?.size)
        assertNull("no sk: still pairs", ok(pairingJson(null)).sessionKey)
        assertNull("31 bytes ignored", ok(pairingJson("\"${Base64Url.encode(ByteArray(31) { 1 })}\"")).sessionKey)
        assertNull("33 bytes ignored", ok(pairingJson("\"${Base64Url.encode(ByteArray(33) { 1 })}\"")).sessionKey)
        assertNull("garbage ignored", ok(pairingJson("\"not base64 !!\"")).sessionKey)
        assertNull("numeric ignored", ok(pairingJson("12345")).sessionKey)
        assertNull(SessionCrypto.validRootKey(null))
        assertArrayEquals(ByteArray(32), SessionCrypto.validRootKey(ByteArray(32)))
    }

    @Test
    fun toStringNeverLeaksSecrets() {
        val p = ok(pairingJson("\"$skGood\""))
        org.junit.Assert.assertFalse(p.toString().contains("abcdefghijklmnopqrstuvwxyz"))
        org.junit.Assert.assertFalse(p.toString().contains(skGood))
    }
}
