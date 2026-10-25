package app.page.android.model

import java.text.BreakIterator
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// Lenient, type-strict reading of Worker and Mac payloads (the Kotlin side of
// iOS WireDecoding.swift). Pure Kotlin, so all of it runs in plain JVM tests.
//
// kotlinx's `booleanOrNull` / `intOrNull` parse a primitive's *content*, so a
// JSON string "true" or "5" would pass for a bool or a number. Swift's
// Decodable never does that, and the safety rules depend on it ("canType":
// "yes" must not mean yes), so every reader here checks the JSON type first.

/** The one JSON parser for the app. Never throws on unknown keys. */
val PageJson: Json = Json { ignoreUnknownKeys = true; isLenient = false }

/** Parses [text] as JSON, or null when it isn't. */
fun parseJson(text: String): JsonElement? =
    try { PageJson.parseToJsonElement(text) } catch (_: Exception) { null }

/** Parses [text] as a JSON object, or null for anything else. */
fun parseJsonObject(text: String): JsonObject? = parseJson(text) as? JsonObject

/** A string if present and actually a JSON string; null for missing, null or the wrong type. */
fun JsonObject.str(key: String): String? = this[key].asString()

/** A bool if present and actually a JSON bool. */
fun JsonObject.bool(key: String): Boolean? = this[key].asBool()

/** A number if present and actually a JSON number (never a numeric string or a bool). */
fun JsonObject.num(key: String): Double? = this[key].asNumber()

/** A whole number that fits an Int, like Swift's `decodeIfPresent(Int.self)`. */
fun JsonObject.int(key: String): Int? = this[key].asInt()

fun JsonObject.long(key: String): Long? = this[key].asLong()

fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject

fun JsonObject.arr(key: String): JsonArray? = this[key] as? JsonArray

fun JsonElement?.asString(): String? =
    (this as? JsonPrimitive)?.takeIf { it !is JsonNull && it.isString }?.content

fun JsonElement?.asBool(): Boolean? {
    val p = (this as? JsonPrimitive)?.takeIf { it !is JsonNull && !it.isString } ?: return null
    return when (p.content) {
        "true" -> true
        "false" -> false
        else -> null
    }
}

fun JsonElement?.asNumber(): Double? {
    val p = (this as? JsonPrimitive)?.takeIf { it !is JsonNull && !it.isString } ?: return null
    if (p.content == "true" || p.content == "false") return null
    return p.content.toDoubleOrNull()?.takeIf { it.isFinite() }
}

fun JsonElement?.asLong(): Long? {
    val p = (this as? JsonPrimitive)?.takeIf { it !is JsonNull && !it.isString } ?: return null
    p.content.toLongOrNull()?.let { return it }
    val d = asNumber() ?: return null
    // 28.0 is a whole number; 28.5 isn't an Int.
    return if (d == Math.floor(d) && Math.abs(d) < 9.0e18) d.toLong() else null
}

fun JsonElement?.asInt(): Int? = asLong()?.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt()

/** Decodes a JSON array element by element, dropping elements that fail. */
data class LossyList<T>(val elements: List<T>, val droppedCount: Int)

/**
 * Null when [element] isn't an array; otherwise every element [decode] could
 * read. One odd element never blanks the whole list.
 */
fun <T> lossyList(element: JsonElement?, decode: (JsonElement) -> T?): LossyList<T>? {
    val array = element as? JsonArray ?: return null
    val out = ArrayList<T>(array.size)
    var dropped = 0
    for (item in array) {
        val decoded = try { decode(item) } catch (_: Exception) { null }
        if (decoded != null) out.add(decoded) else dropped++
    }
    return LossyList(out, dropped)
}

/**
 * ISO-8601 parsing that accepts what every producer actually sends: the
 * Worker's whole-second timestamps, fractional seconds from older Workers,
 * and offsets from hook `date` output.
 */
object PageDate {
    fun parse(raw: String): Instant? = try {
        OffsetDateTime.parse(raw.trim(), DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant()
    } catch (_: Exception) {
        null
    }

    /**
     * Accepts an ISO string, or a number of seconds / milliseconds since the
     * epoch (anything above 1e12 is treated as milliseconds).
     */
    fun parseAny(value: JsonElement?): Instant? {
        value.asString()?.let { return parse(it) }
        val n = value.asNumber() ?: return null
        if (n <= 0) return null
        return ofEpochSeconds(if (n > 1e12) n / 1000 else n)
    }

    fun ofEpochSeconds(seconds: Double): Instant =
        Instant.ofEpochMilli(Math.round(seconds * 1000))

    fun ofEpochMillis(ms: Double): Instant = Instant.ofEpochMilli(Math.round(ms))
}

/** Seconds from [other] to this instant (negative when this is earlier). */
fun Instant.secondsSince(other: Instant): Double = (toEpochMilli() - other.toEpochMilli()) / 1000.0

fun Instant.plusSeconds(seconds: Double): Instant = Instant.ofEpochMilli(toEpochMilli() + Math.round(seconds * 1000))

/**
 * User-perceived characters, like Swift's `String.count`: a family emoji or
 * a flag is one character, not four UTF-16 units.
 */
fun String.graphemeCount(): Int {
    if (isEmpty()) return 0
    val it = BreakIterator.getCharacterInstance()
    it.setText(this)
    var n = 0
    while (it.next() != BreakIterator.DONE) n++
    return n
}

/**
 * At most [max] UTF-16 units, never splitting a surrogate pair. Used for the
 * protocol's length caps, which only need to bound size.
 */
fun String.capped(max: Int): String {
    if (length <= max) return this
    var end = max
    if (end > 0 && Character.isHighSurrogate(this[end - 1])) end--
    return substring(0, end)
}
