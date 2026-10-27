package app.page.android.model

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

// Port of iOS/Page/Models/TowerModel.swift. The Tower: the sheet that drops
// from the Mac chip. Power, Budget, Macs, Attention, Pairing, Appearance and
// About, as pure values. The phone can read the Mac's power and usage but not
// change them (those switches live in Page on the Mac), so Power is a readout
// that says where to change it, never a switch that does nothing. Android
// keeps one pairing, so "Macs" is one row (no SavedMacs).

enum class TowerSection(val raw: String) {
    POWER("power"), BUDGET("budget"), MACS("macs"), ATTENTION("attention"), GESTURES("gestures"),
    TERMINALS("terminals"), PAIRING("pairing"), APPEARANCE("appearance"), ABOUT("about");

    val id: String get() = raw

    /** "Power" etc., as the section label. */
    val title: String
        get() = when (this) {
            POWER -> "Power"
            BUDGET -> "Budget"
            MACS -> "Macs"
            ATTENTION -> "Attention"
            GESTURES -> GestureGuide.title
            TERMINALS -> "Works with"
            PAIRING -> "Pairing & encryption"
            APPEARANCE -> "Appearance"
            ABOUT -> "About"
        }
}

// MARK: - Works with

/**
 * The terminals the Mac can type into for you, as a read-only list. Static: the Mac's Terminals page
 * (Page ▸ Tower ▸ Terminals) is where each one is set up and where its live status shows, so nothing here is a switch.
 */
object TowerHosts {
    /**
     * Whether the phone's answer sheet can press a question's keys in that terminal. Mirrors the Mac's
     * `TerminalCatalog.AnswerSupport` (measured end to end on Claude Code 2.1.311). Only a display: whether the
     * answer sheet is offered for one session is the Mac's call (it sends `ask` only for a terminal that takes
     * answer keys), never this list's.
     */
    sealed interface Answer {
        data object Yes : Answer

        /** Works, with a stated limit. */
        data class Limited(val why: String) : Answer

        /** Refused up front: why, and what to use instead. */
        data class NotYet(val why: String) : Answer

        val line: String
            get() = when (this) {
                Yes -> "Answer questions: yes"
                is Limited -> "Answer questions: with limits — $why"
                is NotYet -> "Answer questions: not yet — $why"
            }
    }

    data class Host(
        val name: String,
        /** A semantic icon name (the views map it to an icon). */
        val symbol: String,
        /** What the phone can do there, in a line. */
        val line: String,
        val answer: Answer,
    ) {
        val id: String get() = name
    }

    val hosts: List<Host> = listOf(
        Host("Terminal", "macwindow", "reply and approve; the Mac asks macOS for permission once", Answer.NotYet("Terminal adds a Return to every key Page types; use tmux or iTerm2")),
        Host("iTerm2", "terminal", "reply, approve and stop; the Mac asks macOS for permission once", Answer.Yes),
        Host("tmux", "rectangle.split.3x1", "reply, approve, stop and see the screen, in any terminal app", Answer.Yes),
        Host("cmux", "square.grid.2x2", "everything, and start new sessions from here", Answer.Yes),
        Host("WezTerm", "terminal.fill", "reply, approve, stop and see the screen; nothing to set up", Answer.Yes),
        Host("kitty", "pawprint", "reply, approve, stop and see the screen; one click turns on remote control", Answer.Yes),
        Host("Herdr", "rectangle.3.group", "reply, approve, stop and see the screen; nothing to set up", Answer.Yes),
        Host("Claude Squad", "person.3", "each agent is a tmux pane, so it works like tmux", Answer.Yes),
    )

    /** Where to set them up. */
    const val setUpLine = "Set them up on your Mac in Page ▸ Tower ▸ Terminals. Each one shows there whether it is installed, in use or needs a step."

    /** For anything else. */
    const val othersLine = "Ghostty, Warp and VS Code’s terminal can’t be typed into yet: run Claude inside tmux, or use Page’s hooks for approvals."
}

// MARK: - The Mac chip

/**
 * The chip at the top-left of Now: "Studio MBP · on battery · 41%". It turns amber when the cutoff is under 30
 * minutes, and offline when the Mac isn't answering. Tapping it opens the Tower.
 */
data class MacChipModel(val text: String, val tone: Tone) {
    enum class Tone { OK, WARN, OFFLINE }

    companion object {
        const val warnMinutes = 30

        fun build(macName: String, status: MacStatusSnapshot?, now: Instant): MacChipModel {
            val name = DeliveryPreview.macLabel(macName)
            when (MacPresence.evaluate(status, now)) {
                is MacPresence.Offline, MacPresence.NeverConnected -> return MacChipModel("$name · offline", Tone.OFFLINE)
                is MacPresence.Stale -> return MacChipModel("$name · not checking in", Tone.OFFLINE)
                MacPresence.Unknown -> return MacChipModel(name, Tone.OK)
                is MacPresence.Online -> Unit
            }
            val parts = arrayListOf(name)
            if (status?.onAC == true) parts.add("on AC") else if (status?.onAC == false) parts.add("on battery")
            status?.batteryPercent?.let { parts.add("$it%") }
            var tone = Tone.OK
            val f = status?.forecast
            if (status?.onAC == false && f != null && f.minutes < warnMinutes) tone = Tone.WARN
            return MacChipModel(parts.joinToString(" · "), tone)
        }
    }
}

// MARK: - Power

data class TowerPower(
    /** "41% · cutoff in about 1 h 50 min". */
    val headline: String,
    /** "on battery", "on power". */
    val state: String,
    /** "Pause agents at 10% · set in Page on your Mac". */
    val note: String,
    /** 0..1 battery level, null when unknown. */
    val fraction: Double?,
    /** Where the cutoff sits on the bar, 0..1. */
    val cutoffFraction: Double?,
    val warn: Boolean,
) {
    companion object {
        fun build(status: MacStatusSnapshot?): TowerPower {
            if (status == null) {
                return TowerPower("No reading from your Mac", "unknown", "Power is read from Page on your Mac.", null, null, false)
            }
            val pct = status.batteryPercent
            val cutoff = status.forecast?.cutoff
            val onAC = status.onAC == true
            var headline = pct?.let { "$it%" } ?: "Battery not reported"
            val f = status.forecast
            if (onAC) {
                headline += " · agents keep running on power"
            } else if (f != null) {
                headline += if (f.minutes == 0) " · at the ${f.cutoff}% cutoff" else " · cutoff in about ${BatteryForecast.duration(f.minutes)}"
            } else if (status.onAC == false) {
                headline += " · on battery"
            }
            val note = cutoff?.let { "Pause agents at $it% · set in Page on your Mac" } ?: "Cutoff and keep-awake are set in Page on your Mac."
            return TowerPower(
                headline, if (onAC) "on power" else (if (status.onAC == false) "on battery" else "unknown"),
                note, pct?.let { it / 100.0 }, cutoff?.let { it / 100.0 },
                !onAC && (status.forecast?.minutes ?: 99) < MacChipModel.warnMinutes,
            )
        }
    }
}

// MARK: - Macs

/** The one pairing this phone has, as a Tower row. */
data class TowerMacRow(
    val id: String,
    val name: String,
    /** "live · paired 3 Oct". */
    val subtitle: String,
    val isActive: Boolean,
    /** "Active". */
    val trailing: String,
) {
    companion object {
        fun build(macName: String, pairedAt: Instant?, status: MacStatusSnapshot?, now: Instant, zone: ZoneId = ZoneId.systemDefault()): List<TowerMacRow> {
            val state = when (MacPresence.evaluate(status, now)) {
                is MacPresence.Online -> "live"
                is MacPresence.Stale -> "not checking in"
                is MacPresence.Offline, MacPresence.NeverConnected -> "offline"
                MacPresence.Unknown -> "checking…"
            }
            val paired = pairedAt?.let { " · paired ${pairedDate(it, zone)}" } ?: ""
            return listOf(TowerMacRow("this-mac", DeliveryPreview.macLabel(macName), state + paired, true, "Active"))
        }

        /** "3 Oct". */
        fun pairedDate(d: Instant, zone: ZoneId): String = DateTimeFormatter.ofPattern("d MMM", Locale.UK).withZone(zone).format(d)
    }
}

// MARK: - Budget

/** The Budget section: the 5-hour and 7-day rings and the verdict line. */
data class TowerBudget(
    val model: UsageCardModel?,
    /** Shown instead of rings when the Mac isn't sending usage. */
    val emptyNote: String,
) {
    companion object {
        fun build(usage: ClaudeUsage?, now: Instant): TowerBudget =
            TowerBudget(UsageCardModel.from(usage, now), "Turn on usage tracking in Page on your Mac to see your 5-hour and 7-day limits here.")
    }
}

// MARK: - Scroll target

object TowerScroll {
    enum class Source { CHIP, RUNWAY, MOON }

    /** The Runway opens the Tower at Budget; the moon on Lanes opens it at Power. */
    fun target(source: Source): TowerSection? = when (source) {
        Source.RUNWAY -> TowerSection.BUDGET
        Source.MOON -> TowerSection.POWER
        Source.CHIP -> null
    }
}
