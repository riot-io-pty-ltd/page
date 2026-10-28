package app.page.android.model

import java.time.Instant

// Port of iOS/Page/Models/DispatchModel.swift. Dispatch: the sheet that rises
// from the pulse to start new work. Where (a folder from the Mac's known
// list), who (Claude: the only agent the phone can start), what (an optional
// prompt) and when (now: there is no queue yet). Pure values; the sheet draws
// them and the live container sends through `SessionStore.startSession`, the
// existing path.

/**
 * The agents Dispatch shows. The `start` request has no agent field, so only Claude can be started from the
 * phone; the others are shown plainly as unavailable here rather than hidden or faked.
 */
enum class DispatchAgent(val raw: String, val agentName: String, val note: String, val symbol: String) {
    CLAUDE("claude", "Claude", "runs claude in cmux", "sparkle"),
    CODEX("codex", "Codex", "start it on your Mac", "hexagon"),
    OLLAMA("ollama", "Ollama", "start it on your Mac", "cpu");

    /** Whether the phone can start it. */
    val canStartFromPhone: Boolean get() = this == CLAUDE
}

/** One project chip. */
data class DispatchFolder(
    val path: String,
    val name: String,
    val hue: ProjectHue,
    /** "2 h ago", or null. */
    val lastUsed: String?,
)

/** Whether Dispatch can start anything yet, from what the Mac said. */
sealed interface DispatchAvailability {
    data object Loading : DispatchAvailability

    /** "Let my phone start new Claude sessions" is off on the Mac. */
    data object DisabledOnMac : DispatchAvailability
    data object NoFolders : DispatchAvailability
    data class Failed(val why: String) : DispatchAvailability
    data object Ready : DispatchAvailability

    companion object {
        fun from(folders: StartFolders?, error: String?): DispatchAvailability {
            if (folders != null) {
                if (!folders.enabled) return DisabledOnMac
                return if (folders.folders.isEmpty()) NoFolders else Ready
            }
            if (error != null) return Failed(error)
            return Loading
        }
    }
}

/** What the person has chosen so far. */
data class DispatchDraft(
    val search: String = "",
    val selectedPath: String? = null,
    val prompt: String = "",
    val agent: DispatchAgent = DispatchAgent.CLAUDE,
) {
    /** Chips most recently used first, narrowed by the search. Pure. */
    fun visibleFolders(folders: List<StartFolder>, now: Instant): List<DispatchFolder> {
        val q = Sw.trimWs(search).lowercase()
        return folders
            .filter { q.isEmpty() || it.name.lowercase().contains(q) || it.path.lowercase().contains(q) }
            .sortedWith { a, b ->
                val x = a.lastUsedAt
                val y = b.lastUsedAt
                when {
                    x != null && y != null && x != y -> y.compareTo(x)
                    x != null && y == null -> -1
                    x == null && y != null -> 1
                    else -> a.name.lowercase().compareTo(b.name.lowercase())
                }
            }
            .map { DispatchFolder(it.path, it.name, ProjectHue.of(it.path), it.lastUsedAt?.let { d -> RelativeTime.ago(d, now) }) }
    }

    /** Picks the most recent folder when nothing is chosen, or when the choice has gone. */
    fun ensuringSelection(folders: List<StartFolder>, now: Instant): DispatchDraft {
        val p = selectedPath
        if (p != null && folders.any { it.path == p }) return this
        return copy(selectedPath = visibleFolders(folders, now).firstOrNull()?.path)
    }

    val trimmedPrompt: String get() = Sw.trimWsNl(prompt)

    /** The prompt is optional (a session can start empty). Too long is not allowed, the same limit as a message. Pure. */
    val promptProblem: String?
        get() = if (Sw.count(trimmedPrompt) > SessionComposer.MAX_CHARACTERS) SessionComposer.Problem.TooLong(Sw.count(trimmedPrompt)).message else null

    /** Ready to start: a folder, an agent the phone can start, a prompt that fits, and not already sending. */
    fun canStart(availability: DispatchAvailability, sending: Boolean): Boolean =
        availability == DispatchAvailability.Ready && selectedPath != null && agent.canStartFromPhone && promptProblem == null && !sending

    /** "Start on Studio MBP": always names the Mac. */
    fun startTitle(mac: String): String = "Start on ${DeliveryPreview.macLabel(mac)}"

    companion object {
        /** Under the button. */
        fun footer(mac: String): String =
            "Opens a new cmux workspace on ${DeliveryPreview.macLabel(mac)} and runs claude there. Starting from the phone is off until you allow it on the Mac."
    }
}

/** Where a start stands, in words. */
data class DispatchStatus(
    val text: String,
    val tone: Tone,
    /** The spinner is still going. */
    val waiting: Boolean,
) {
    enum class Tone { WORKING, GOOD, PROBLEM, WARN }

    companion object {
        fun from(state: SessionDeliveryState?, startWaitExpired: Boolean): DispatchStatus? {
            if (state == null) return null
            return when (state) {
                SessionDeliveryState.Sending -> DispatchStatus("Asking your Mac to start it…", Tone.WORKING, true)
                is SessionDeliveryState.Typed, is SessionDeliveryState.Queued -> {
                    val detail = if (state is SessionDeliveryState.Typed) state.detail else (state as SessionDeliveryState.Queued).detail
                    if (startWaitExpired) {
                        DispatchStatus("Started, but it hasn't shown up here yet. Look for it in Lanes, or in cmux on your Mac.", Tone.WARN, false)
                    } else {
                        DispatchStatus((detail ?: "Started") + ". Opening it here as soon as it appears. On your Mac it's a new cmux workspace.", Tone.GOOD, true)
                    }
                }
                is SessionDeliveryState.Refused -> DispatchStatus(state.message, Tone.PROBLEM, false)
                is SessionDeliveryState.Failed -> DispatchStatus(state.message, Tone.PROBLEM, false)
                SessionDeliveryState.NoAnswer -> DispatchStatus("No answer from your Mac", Tone.WARN, false)
                // A start is never held or deleted; if one is ever reported so, say it can't be confirmed.
                is SessionDeliveryState.CheckSession -> DispatchStatus(state.message, Tone.WARN, false)
                is SessionDeliveryState.Held, is SessionDeliveryState.Deleted -> DispatchStatus("No answer from your Mac", Tone.WARN, false)
            }
        }
    }
}
