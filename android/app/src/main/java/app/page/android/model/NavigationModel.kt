package app.page.android.model

import kotlin.math.abs

// Port of iOS/Page/Models/NavigationModel.swift. Navigation, as plain values:
// the two destinations (Now and Sky), the Sky mode that is remembered, and the
// one-at-a-time sheet queue. Sheets and rooms are never tabs.

/**
 * The two top-level destinations. Now is where you act; Sky is where you are aware. Now is the launch default
 * and the target of every deep link.
 */
enum class NWDestination(val raw: String) {
    NOW("now"), SKY("sky");

    /** The other one (the nav bar's drag, a swipe on the Horizon). */
    val other: NWDestination get() = if (this == NOW) SKY else NOW

    companion object {
        /**
         * A drag counts as horizontal only when it is clearly more sideways than vertical (|dx| at least 1.5
         * times |dy|), so scrolling a list that drifts a little sideways never swipes a card or switches place. Pure.
         */
        fun isHorizontal(dx: Double, dy: Double): Boolean = abs(dx) >= 1.5 * abs(dy)

        /**
         * Where a horizontal drag of [translation] points lands. Sky lies to the right of Now, so dragging left
         * reveals Sky and dragging right goes back to Now. Short drags stay where they are. Pure.
         */
        fun afterDrag(from: NWDestination, translation: Double, vertical: Double = 0.0, threshold: Double = 40.0): NWDestination {
            // A mostly-vertical drag is a scroll or a pull to refresh, never a switch.
            if (!isHorizontal(translation, vertical)) return from
            if (translation <= -threshold) return SKY
            if (translation >= threshold) return NOW
            return from
        }
    }
}

/** Sky's two modes: constellations, and Lanes (the accessible list). The last one used is remembered. */
enum class SkyMode(val raw: String, val label: String) {
    SKY("sky", "Sky"), LANES("lanes", "Lanes");

    companion object {
        val default: SkyMode = SKY
        const val storageKey = "page.skyMode"

        /** Anything unknown or missing is the default. */
        fun stored(raw: String?): SkyMode = entries.firstOrNull { it.raw == raw } ?: default
    }
}

/** What a sheet is showing. Sessions are rooms you zoom into, never tabs. */
sealed interface NWSheet {
    /** A page's Decision sheet. */
    data class Decision(val pageId: String) : NWSheet

    /** A live session's room. How it opens (Story, Screen, the composer, Stop) is [RoomEntry], held by the router. */
    data class Session(val sessionId: String) : NWSheet

    /** The Tower, optionally scrolled to a section (the Runway opens Budget). */
    data class Tower(val section: TowerSection?) : NWSheet

    /** Dispatch: start new work. */
    data object Dispatch : NWSheet

    /** Everything Page has settled, and the day stats. */
    data object History : NWSheet

    val id: String
        get() = when (this) {
            is Decision -> "decision:$pageId"
            is Session -> "session:$sessionId"
            is Tower -> "tower:${section?.raw ?: "-"}"
            Dispatch -> "dispatch"
            History -> "history"
        }
}

/**
 * One sheet at a time. Asking for another while one is up closes the first, and the new one appears once the
 * first has finished dismissing. Pure.
 */
data class SheetQueue(val current: NWSheet? = null, val pending: NWSheet? = null) {
    /** Asks for a sheet. Asking for the one already up does nothing. */
    fun request(sheet: NWSheet): SheetQueue {
        if (current == sheet) return copy(pending = null)
        return if (current != null) SheetQueue(null, sheet) else SheetQueue(sheet, null)
    }

    /** The host finished dismissing a sheet: bring up whatever was waiting. */
    fun dismissed(): SheetQueue = pending?.let { SheetQueue(it, null) } ?: this

    /** The user dismissed the sheet (back, a swipe down, a close button). */
    fun close(): SheetQueue = SheetQueue(null, null)

    /** Setting null closes (unless one is waiting). */
    fun set(sheet: NWSheet?): SheetQueue = if (sheet != null) request(sheet) else if (pending == null) SheetQueue(null, null) else this
}

/** Where a `page://` link goes. */
sealed interface NWDeepLink {
    data object Now : NWDeepLink
    data object Sky : NWDeepLink
    data class Decision(val pageId: String) : NWDeepLink
    data object Tower : NWDeepLink

    companion object {
        /**
         * `page://intervention/<id>` opens that page's Decision sheet over Now; `page://sessions` (the widget)
         * opens Sky, where sessions live; `page://now`, `page://sky` and `page://tower` open those. Anything
         * else is null. Pure.
         */
        fun parse(url: String): NWDeepLink? {
            val uri = try { java.net.URI(url) } catch (_: Exception) { return null }
            if (uri.scheme?.lowercase() != "page") return null
            return when (uri.host?.lowercase()) {
                "sessions", "sky" -> Sky
                "now" -> Now
                "tower" -> Tower
                else -> DeepLink.interventionId(url)?.let { Decision(it) }
            }
        }
    }
}
