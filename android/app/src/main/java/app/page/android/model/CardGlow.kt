package app.page.android.model

// Port of iOS/Page/Models/CardGlow.swift. The "Card glow" setting: how much of
// a soft teal light glass cards and panels draw along their bottom edge. Off
// by default, because the original hard band looked cut off. Every glass
// surface reads it through one composition local (LocalCardGlow); nothing
// draws a glow of its own. Pure, so the persistence and the numbers can be tested.
enum class CardGlow(val raw: String, val label: String, val strength: Double) {
    OFF("off", "Off", 0.0),
    SUBTLE("subtle", "Subtle", 0.5),
    FULL("full", "Full", 1.0);

    val isOn: Boolean get() = this != OFF

    /** Alpha of the light at the very bottom of a card, for the colour the card passes in (the glow is a tint, so this stays below the fill). */
    val bottomAlpha: Double get() = 0.34 * strength

    /** How far up the card the light reaches, as a share of its height. */
    val reach: Double get() = 0.30 + 0.20 * strength

    /**
     * Alpha of the glow along the rim at [t] (0 top, 1 bottom): an eased ramp, zero over the top half, with
     * no step anywhere. Pure.
     */
    fun rimAlpha(t: Double): Double {
        if (!isOn) return 0.0
        val x = minOf(1.0, maxOf(0.0, (t - 0.5) / 0.5))
        return 0.42 * strength * x * x * (3 - 2 * x)
    }

    /**
     * Alpha of the inner light at [t] (0 at the light's far edge, 1 at the card's bottom edge):
     * smoothstep-squared, so it starts at exactly zero with zero slope. Pure.
     */
    fun lightAlpha(t: Double): Double {
        if (!isOn) return 0.0
        val x = minOf(1.0, maxOf(0.0, t))
        val s = x * x * (3 - 2 * x)
        return bottomAlpha * s * s
    }

    companion object {
        val default: CardGlow = OFF

        /** The phone's own preference key (never synced). */
        const val storageKey = "page.cardGlow"

        /** Anything unknown or missing is Off, never a glow. */
        fun stored(raw: String?): CardGlow = entries.firstOrNull { it.raw == raw } ?: OFF

        /** `page_glow off|subtle|full` for the render harness; null when absent or unknown. */
        fun argument(raw: String?): CardGlow? = raw?.let { r -> entries.firstOrNull { it.raw == r.lowercase() } }
    }
}
