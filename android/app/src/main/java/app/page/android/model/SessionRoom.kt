package app.page.android.model

import java.time.Instant
import java.time.ZoneId

// Port of iOS/Page/Models/SessionRoom.swift. The Session Room as plain values:
// who the agent is, which lenses the room offers, what the header says, what
// the composer may do right now and what it will type, and the Story built
// from the Mac's transcript. No clock, no services.
//
// Trust model: while a session is waiting on a prompt, free text never goes to
// the terminal as text plus Enter (that would approve the highlighted "Yes").
// The only way to write to a waiting session is "Tell it instead", which the
// page sends as Esc, then the text, then Return. Steering a busy session is
// text plus Return, which queues. Nothing here types anything: the composer
// hands its text to a closure and the container picks the one existing path.

// MARK: - Who the agent is

/**
 * What kind of agent a room is for. Each keeps its own character: Claude narrates and runs steps, Codex shows
 * plans and patches, a local model streams an answer and costs nothing.
 */
data class AgentCharacter(
    val kind: Kind,
    /** "Claude", "Codex", "Ollama", or the agent's own name. */
    val name: String,
    /** A semantic icon name (the views map it to an icon). */
    val symbol: String,
    /** Set for a local model: "Private · nothing leaves this Mac". */
    val privacyTitle: String?,
    val privacyNote: String?,
    /** The local runtime's own name when the model runs locally ("Ollama"). */
    val runtime: String?,
) {
    enum class Kind(val raw: String) { CLAUDE("claude"), CODEX("codex"), LOCAL("local"), OTHER("other") }

    /** "Claude · cmux", "Claude · on Ollama · cmux", "Ollama · via opencode · cmux". */
    fun subtitle(backend: AgentBackend, provider: String?, host: String): String {
        val parts = ArrayList<String>()
        if (kind == Kind.LOCAL && runtime != null) {
            when (backend) {
                is AgentBackend.Known -> { parts.add(backend.backend.displayName); parts.add("on $runtime") }
                is AgentBackend.Other -> if (backend.raw == "unknown") parts.add(runtime) else { parts.add(runtime); parts.add("via ${backend.displayName}") }
            }
        } else {
            parts.add(name)
        }
        val h = Sw.trimWs(host)
        if (h.isNotEmpty() && h.lowercase() != "unknown host" && h.lowercase() != "unknown") parts.add(h)
        return parts.joinToString(" · ")
    }

    companion object {
        /** Providers the Mac reports for models that run on the Mac itself. */
        val localProviders: Set<String> = setOf("ollama", "lmStudio", "otherLocal")

        fun runtimeName(provider: String?): String? = when (provider) {
            "ollama" -> "Ollama"
            "lmStudio" -> "LM Studio"
            "otherLocal" -> "A local model"
            else -> null
        }

        fun from(backend: AgentBackend, provider: String?): AgentCharacter {
            val runtime = runtimeName(provider)
            if (provider != null && provider in localProviders && runtime != null) {
                // Claude or Codex pointed at a local model, or a harness (opencode, aider) around one.
                val harness: String? = when (backend) {
                    is AgentBackend.Known -> backend.backend.displayName
                    is AgentBackend.Other -> if (backend.raw == "unknown") null else backend.displayName
                }
                return AgentCharacter(
                    Kind.LOCAL, if (harness == null) runtime else (if (runtime == "A local model") harness else runtime),
                    "cpu", "Private · nothing leaves this Mac",
                    "No usage limits or cost. Page keeps the Mac awake only while it's generating.", runtime,
                )
            }
            return when (backend) {
                is AgentBackend.Known -> when (backend.backend) {
                    InterventionBackend.CLAUDE -> AgentCharacter(Kind.CLAUDE, "Claude", "sparkle", null, null, null)
                    InterventionBackend.CODEX -> AgentCharacter(Kind.CODEX, "Codex", "hexagon", null, null, null)
                }
                is AgentBackend.Other -> AgentCharacter(Kind.OTHER, backend.displayName, "questionmark.circle", null, null, null)
            }
        }
    }
}

// MARK: - Lenses

/** The four ways into a session. Story is the default; Screen, Changes and Workflows appear only when there is something behind them. */
enum class RoomLens(val raw: String, val title: String) {
    STORY("story", "Story"), SCREEN("screen", "Screen"), CHANGES("changes", "Changes"), WORKFLOWS("workflows", "Workflows");

    data class Inputs(
        val character: AgentCharacter,
        /** The Mac has sent this session's terminal mirror (tmux and cmux only). */
        val hasScreen: Boolean,
        /** The session's dynamic workflows (Claude Code only). */
        val workflowCount: Int,
        /** The room can ask the Mac for this session's changes (a live session, a ready relay). */
        val canAskForChanges: Boolean,
    )

    companion object {
        /**
         * Which lenses to offer, in order. Workflows is Claude's alone and only once a run exists; Changes needs
         * a live session to ask; an agent Page has no adapter for gets Story only. Pure.
         */
        fun available(i: Inputs): List<RoomLens> {
            val out = arrayListOf(STORY)
            if (i.hasScreen && i.character.kind != AgentCharacter.Kind.OTHER) out.add(SCREEN)
            if (i.canAskForChanges && i.character.kind != AgentCharacter.Kind.OTHER) out.add(CHANGES)
            if (i.workflowCount > 0 && i.character.kind == AgentCharacter.Kind.CLAUDE) out.add(WORKFLOWS)
            return out
        }

        /**
         * Story by default (the board shows a waiting session on Story, with the decision pinned in it). The lens
         * a room was last on stays if it is still offered. Pure.
         */
        fun resolve(wanted: RoomLens?, offered: List<RoomLens>): RoomLens = if (wanted != null && wanted in offered) wanted else STORY

        /** The small count on a lens: files changed, workflows running. Pure. */
        fun badge(lens: RoomLens, changedFiles: Int?, runningWorkflows: Int): Int? = when (lens) {
            CHANGES -> if ((changedFiles ?: 0) > 0) changedFiles else null
            WORKFLOWS -> if (runningWorkflows > 0) runningWorkflows else null
            else -> null
        }
    }
}

// MARK: - Header

/** A chip under the room's title: the state, then what the agent can tell us. */
data class RoomChip(
    val text: String,
    val tone: Tone,
    /** A semantic icon name, when the chip has one. */
    val symbol: String?,
) {
    enum class Tone { WORKING, NEEDS_YOU, QUIET, WARM, LOCAL }

    val id: String get() = text
}

object RoomHeader {
    /**
     * The state chip and the signals the wire really carries. There is no model name, turn number or context
     * figure on the wire, so none is invented: the working chip says how long since the agent last did
     * something, and the usage chip is the Mac's 5-hour reading.
     *
     * [waitingSince] is when the open page was raised (for "NEEDS YOU · 1m").
     */
    fun chips(
        session: LiveSession, character: AgentCharacter, ended: Boolean, waitingSince: Instant?,
        hasReviewPage: Boolean, fiveHourPct: Double?, now: Instant,
    ): List<RoomChip> {
        val out = ArrayList<RoomChip>()
        val since: Int? = session.lastActivityAt?.let { maxOf(0, now.secondsSince(it).toInt()) }
        fun age(s: Int?): String? = s?.let { RelativeTime.compact(it.toLong()) }

        if (ended) {
            out.add(RoomChip("ENDED", RoomChip.Tone.QUIET, null))
        } else {
            when (session.state) {
                LiveSessionState.ACTIVE -> {
                    val word = if (character.kind == AgentCharacter.Kind.LOCAL) "GENERATING" else "WORKING"
                    if (since != null && since >= 30) {
                        out.add(RoomChip("$word · quiet ${RelativeTime.compact(since.toLong())}", RoomChip.Tone.WORKING, null))
                    } else {
                        out.add(RoomChip(word, RoomChip.Tone.WORKING, null))
                    }
                }
                LiveSessionState.WAITING_ON_APPROVAL, LiveSessionState.WAITING_ON_USER -> {
                    val waited = (waitingSince ?: session.lastActivityAt)?.let { RelativeTime.compact(maxOf(0, now.secondsSince(it).toInt()).toLong()) }
                    out.add(RoomChip("NEEDS YOU" + (waited?.let { " · $it" } ?: ""), RoomChip.Tone.NEEDS_YOU, null))
                }
                LiveSessionState.IDLE -> {
                    val word = if (hasReviewPage) "FINISHED" else "IDLE"
                    out.add(RoomChip(word + (age(since)?.let { " · $it ago" } ?: ""), RoomChip.Tone.QUIET, null))
                }
                LiveSessionState.RATE_LIMITED -> out.add(RoomChip("RATE LIMITED", RoomChip.Tone.WARM, null))
                LiveSessionState.INTERRUPTED -> out.add(RoomChip("INTERRUPTED" + (age(since)?.let { " · $it ago" } ?: ""), RoomChip.Tone.QUIET, null))
                LiveSessionState.FAILED -> out.add(RoomChip("FAILED", RoomChip.Tone.WARM, null))
                LiveSessionState.OFFLINE -> out.add(RoomChip("OFFLINE", RoomChip.Tone.QUIET, null))
                LiveSessionState.UNKNOWN -> out.add(RoomChip("STATE UNKNOWN", RoomChip.Tone.QUIET, null))
            }
        }
        if (character.kind == AgentCharacter.Kind.LOCAL) {
            out.add(RoomChip("on-device", RoomChip.Tone.LOCAL, "lock"))
        } else if (character.kind == AgentCharacter.Kind.CLAUDE && fiveHourPct != null) {
            out.add(RoomChip("5h ${Math.round(fiveHourPct).toInt()}%", if (fiveHourPct >= 80) RoomChip.Tone.WARM else RoomChip.Tone.QUIET, "gauge.with.needle"))
        }
        return out
    }
}

// MARK: - The composer

/** What the room's composer does right now. This is the trust model in one switch: a waiting session is never typed into as text plus Enter. */
sealed interface RoomComposerMode {
    /** The session is ended, or the Mac cannot be reached. */
    data class Disabled(val why: String) : RoomComposerMode

    /** Waiting on a prompt with no page to answer it from. */
    data class Locked(val why: String) : RoomComposerMode

    /** Waiting on a prompt that has a page: a written reply goes Esc, then the text, then Return, through that page. */
    data class TellInstead(val pageId: String) : RoomComposerMode

    /** Page cannot type in this session's terminal. */
    data class Blocked(val why: String) : RoomComposerMode

    /** Busy: text plus Return, which queues behind the current step. */
    data object Steer : RoomComposerMode

    /** Idle: the next task. */
    data object NextTask : RoomComposerMode

    data class Inputs(
        val state: LiveSessionState,
        val canType: Boolean,
        val typeBlocker: String? = null,
        /** The open page for this session, as a row the phone holds. Null when the page has not arrived (or there is none). */
        val pageId: String? = null,
        /** That page is a decision (Approve, Deny, a question): the session is blocked on you, whatever its state says while the list catches up. */
        val pageIsDecide: Boolean = false,
        /** The page offers a written reply (Esc, then your message). */
        val pageAcceptsReply: Boolean = true,
        /** The session says it is waiting on a page that has not loaded yet. */
        val pageArriving: Boolean = false,
        val ended: Boolean = false,
        /** Live sessions are available (the Mac is connected and sending). */
        val ready: Boolean = true,
    )

    data class Copy(
        val placeholder: String,
        /** Under the field, in words ("queues after the current step"). */
        val hint: String,
        val sendLabel: String,
    )

    /** The composer takes text at all. */
    val acceptsText: Boolean get() = this is TellInstead || this == Steer || this == NextTask

    /** A written reply goes through the page (Esc, text, Return), never as session input. */
    val routesThroughPage: Boolean get() = this is TellInstead

    /** Send as the session's own input (text plus Return). */
    val usesSessionInput: Boolean get() = this == Steer || this == NextTask

    /** Placeholder and hint, in the agent's own voice. Codex reads a message when its turn ends; a local model when generation stops. */
    fun copy(character: AgentCharacter): Copy {
        val who = if (character.kind == AgentCharacter.Kind.LOCAL) "the model" else character.name
        return when (this) {
            is TellInstead -> Copy("Tell it instead…", "sends Esc first, then your words — never answers the menu", "Send, after Esc")
            Steer -> when (character.kind) {
                AgentCharacter.Kind.CODEX -> Copy("Message Codex…", "delivered when this turn ends", "Send message")
                AgentCharacter.Kind.LOCAL -> Copy("Message the model…", "sent when generation stops", "Send message")
                else -> Copy("Steer $who…", "queues after the current step", "Send message")
            }
            NextTask -> Copy(
                if (character.kind == AgentCharacter.Kind.LOCAL) "Message the model…" else "Message $who…",
                "typed into the session", "Send message",
            )
            is Blocked -> Copy("Can't type here", why, "Send message")
            is Locked -> Copy("Locked while it waits", why, "Send message")
            is Disabled -> Copy("Not available", why, "Send message")
        }
    }

    /** The delivery preview: what will be typed, where, on which Mac. null when nothing would be sent. Pure. */
    fun preview(character: AgentCharacter, route: String?, mac: String, pagePreview: String? = null): String? = when (this) {
        // The page knows how its answer is delivered: through a hook, or Esc then your words.
        is TellInstead -> pagePreview ?: DeliveryPreview.tellInstead(route, mac)
        Steer -> {
            val tail = when (character.kind) {
                AgentCharacter.Kind.CODEX -> "delivered when this turn ends"
                AgentCharacter.Kind.LOCAL -> "sent when generation stops"
                else -> "queues after this step"
            }
            DeliveryPreview.line("Your message, then Return · $tail", route, mac)
        }
        NextTask -> DeliveryPreview.message(route, mac)
        is Blocked -> DeliveryPreview.cannotType(why, mac)
        is Locked, is Disabled -> null
    }

    /** Quick replies belong where a message is the next thing: idle or steering. */
    val offersQuickReplies: Boolean get() = this == Steer || this == NextTask

    companion object {
        /**
         * The trust model in one switch. A session that is waiting (or has a decision pinned) is never typed
         * into as text plus Enter; a written reply needs the page's own row, so Send can never do nothing quietly.
         */
        fun resolve(i: Inputs): RoomComposerMode {
            if (i.ended) return Disabled("This session has ended.")
            if (!i.ready) return Disabled("Waiting for your Mac.")
            if (i.state.isWaiting || i.pageIsDecide) {
                if (i.pageId != null && i.pageAcceptsReply) return TellInstead(i.pageId)
                if (i.pageId != null) return Locked("Answer this prompt from its decision above.")
                if (i.pageArriving) return Locked("Its decision is still arriving. Answer on your Mac, or wait a moment.")
                return Locked("Answer the prompt on your Mac. Page won't type over a prompt.")
            }
            if (!i.canType) return Blocked(i.typeBlocker ?: LiveSession.DEFAULT_BLOCKER)
            return if (i.state == LiveSessionState.ACTIVE) Steer else NextTask
        }

        /** A line under a Codex or local agent's story that says when a message lands. */
        fun timingNote(character: AgentCharacter, busy: Boolean): String? {
            if (!busy) return null
            return when (character.kind) {
                AgentCharacter.Kind.CODEX -> "Codex reads your message when this turn ends — or right away in a cmux pane with an empty composer."
                AgentCharacter.Kind.LOCAL -> "A local model reads your message when generation stops."
                else -> null
            }
        }

        /** Standing replies that fill the composer (never send on their own). */
        val quickReplies = listOf("Carry on", "Run the tests, then stop", "Summarise what you did", "Stop and explain what's failing")
    }
}

// MARK: - Stop

/**
 * Stop in the room: a 0.6 s hold, because Esc interrupts the turn. No biometrics (this is one session's Esc,
 * not Stop-all), and a mis-hold is undone by letting go early.
 */
data class SessionStopPlan(val canStop: Boolean, val scope: String, val preview: String) {
    companion object {
        /** The hold that confirms a Stop. */
        val spec = HoldRingSpec(0.0, 0.6)

        /** Offered only mid-turn, where the Mac says Esc works, with the relay ready. */
        fun build(session: LiveSession, ready: Boolean, ended: Boolean, macName: String): SessionStopPlan {
            // The folder's name, not the title: the same words the receipt and the header use.
            val project = SessionTarget.of(session, macName).project
            val route = DeliveryPreview.route(session.host, project)
            return SessionStopPlan(session.isStoppable && ready && !ended, "Press Esc in $project", DeliveryPreview.pressEsc(route, macName))
        }
    }
}

// MARK: - The plan for a room

/**
 * What a room does about the page behind its session and the composer, as one pure decision: which page is
 * pinned in the Story, which belongs to Changes, what the composer may do and the preview it shows.
 */
data class RoomPlan(
    /** A decision or look, pinned in the Story. */
    val pinned: NowRow?,
    /** A finished turn: its actions live in Changes. */
    val review: NowRow?,
    val mode: RoomComposerMode,
    val preview: String?,
) {
    data class Inputs(
        val session: LiveSession,
        val character: AgentCharacter,
        val pageRow: NowRow?,
        val ended: Boolean,
        val ready: Boolean,
        val macName: String,
    )

    companion object {
        fun build(i: Inputs): RoomPlan {
            val s = i.session
            val pinned = i.pageRow?.takeIf { it.section != NowRow.Section.REVIEW }
            val review = i.pageRow?.takeIf { it.section == NowRow.Section.REVIEW }
            val mode = RoomComposerMode.resolve(
                RoomComposerMode.Inputs(
                    state = s.state, canType = s.canType, typeBlocker = s.typeBlocker,
                    pageId = pinned?.id, pageIsDecide = pinned?.section == NowRow.Section.DECIDE,
                    pageAcceptsReply = pinned?.action(RowAction.Kind.TELL_INSTEAD) != null,
                    pageArriving = s.interventionId != null && pinned == null,
                    ended = i.ended, ready = i.ready,
                ),
            )
            val route = DeliveryPreview.route(s.host, SessionTarget.of(s, i.macName).project)
            val preview = mode.preview(i.character, route, i.macName, pinned?.action(RowAction.Kind.TELL_INSTEAD)?.preview)
            return RoomPlan(pinned, review, mode, preview)
        }
    }
}

// MARK: - Banners

/** What the room says above the story when something is off. */
data class RoomBanner(
    val id: String,
    val tone: Tone,
    val symbol: String,
    val title: String,
    val message: String,
    val actionTitle: String?,
    val action: Action?,
) {
    enum class Tone { INFO, WARNING, ERROR }

    sealed interface Action {
        data object Retry : Action
        data object Repair : Action
        data class OpenDecision(val pageId: String) : Action
    }

    companion object {
        /**
         * Most important first. [pageShownInStory] says the open page's decision card is already pinned in the
         * story, so no banner repeats it.
         */
        fun build(ended: Boolean, availability: SessionAvailability, session: LiveSession, agent: String, pageShownInStory: Boolean): List<RoomBanner> {
            if (ended) {
                return listOf(
                    RoomBanner(
                        "ended", Tone.INFO, "checkmark.circle", "This session has ended",
                        "It's no longer on your Mac's list. The story below is the last one Page received.", null, null,
                    ),
                )
            }
            if (availability != SessionAvailability.Ready) {
                val c = SessionAvailabilityCopy.of(availability)
                return listOf(
                    RoomBanner(
                        "availability", if (c.tone == SessionAvailabilityCopy.Tone.ERROR) Tone.ERROR else (if (c.tone == SessionAvailabilityCopy.Tone.INFO) Tone.INFO else Tone.WARNING),
                        c.systemImage, c.title, c.message.ifEmpty { "Waiting for your Mac…" },
                        if (c.action == SessionAvailabilityCopy.Action.RETRY || c.action == SessionAvailabilityCopy.Action.REPAIR) c.actionTitle else null,
                        when (c.action) {
                            SessionAvailabilityCopy.Action.RETRY -> Action.Retry
                            SessionAvailabilityCopy.Action.REPAIR -> Action.Repair
                            null -> null
                        },
                    ),
                )
            }
            if (pageShownInStory) return emptyList()
            val page = session.openPageId
            if (page != null) {
                return listOf(
                    RoomBanner(
                        "page", Tone.WARNING, "bell.badge",
                        if (session.state == LiveSessionState.WAITING_ON_APPROVAL) "$agent needs your approval" else "$agent is waiting for you",
                        "Answer the prompt from its decision. Page won't type over a prompt.", "Open decision", Action.OpenDecision(page),
                    ),
                )
            }
            if (session.state.isWaiting) {
                return listOf(
                    RoomBanner(
                        "prompt", Tone.WARNING, "bell.badge", "$agent is showing a prompt",
                        "There's no decision for it yet. Answer it on your Mac, or wait a moment for it to arrive.", null, null,
                    ),
                )
            }
            return emptyList()
        }
    }
}

// MARK: - Screen

/**
 * How fresh the terminal mirror is. The mirror is re-read every few seconds; if frames stop for 30 s while the
 * agent is busy, the live dot slows and turns amber.
 */
data class ScreenFreshness(val tone: Tone, /** "LIVE · 2s", "SLOW · 34s", "1m ago". */ val label: String) {
    enum class Tone { LIVE, SLOW, QUIET }

    companion object {
        const val liveBelow: Double = 10.0
        const val slowAfter: Double = 30.0

        fun evaluate(frameAt: Instant, now: Instant, busy: Boolean): ScreenFreshness {
            val s = maxOf(0, now.secondsSince(frameAt).toInt())
            val t = RelativeTime.compact(s.toLong())
            if (s.toDouble() < liveBelow) return ScreenFreshness(Tone.LIVE, "LIVE · $t")
            if (busy && s.toDouble() >= slowAfter) return ScreenFreshness(Tone.SLOW, "SLOW · $t")
            return ScreenFreshness(Tone.QUIET, if (busy) "LIVE · $t" else "$t ago")
        }
    }
}

// MARK: - Story

/**
 * One step of a turn, read off a tool one-liner ("Bash: npm test", "Edit: Sources/App.swift"). The wire has no
 * result for a step, so nothing like "+42 -6" or an exit code is invented.
 */
data class StoryStep(
    val id: String,
    val kind: Kind,
    /** What the step did, as one line: "Read SessionsView.swift", "swift build". */
    val title: String,
    /** Shown in monospace (commands, file names). */
    val mono: Boolean,
) {
    enum class Kind(val raw: String) { READ("read"), SEARCH("search"), EDIT("edit"), SHELL("shell"), WEB("web"), PLAN("plan"), AGENT("agent"), OTHER("other") }

    /** A semantic icon name (the views map it to an icon). */
    val symbol: String
        get() = when (kind) {
            Kind.READ -> "doc.text"
            Kind.SEARCH -> "magnifyingglass"
            Kind.EDIT -> "square.and.pencil"
            Kind.SHELL -> "terminal"
            Kind.WEB -> "globe"
            Kind.PLAN -> "checklist"
            Kind.AGENT -> "person.2"
            Kind.OTHER -> "wrench.and.screwdriver"
        }

    companion object {
        fun kindForTool(name: String): Kind = when (name.lowercase()) {
            "read" -> Kind.READ
            "grep", "glob", "ls", "search" -> Kind.SEARCH
            "edit", "multiedit", "write", "notebookedit", "apply_patch" -> Kind.EDIT
            "bash", "shell", "container.exec", "exec_command", "local_shell", "bashoutput", "killshell" -> Kind.SHELL
            "webfetch", "websearch", "web_search" -> Kind.WEB
            "update_plan", "todowrite", "exitplanmode" -> Kind.PLAN
            "task", "agent" -> Kind.AGENT
            else -> Kind.OTHER
        }

        /** Splits "Name: rest" and picks the kind. [tool] is the wire's own tool name when it carries one. */
        fun parse(id: String, text: String, tool: String?): StoryStep {
            val t = Sw.trimWsNl(text)
            var head: String? = null
            var rest = t
            val colon = Sw.firstIndexOf(t, ":")
            if (colon >= 0) {
                val h = Sw.trimWs(t.substring(0, colon))
                val tail = Sw.trimWs(t.substring(colon + 1))
                // "Bash: npm test", "Edit: Sources/App.swift", "fetch · web: url".
                if (h.isNotEmpty() && Sw.count(h) <= 40 && !h.contains("/") && !h.contains("(")) {
                    head = h
                    rest = if (tail.isEmpty()) h else tail
                }
            }
            val k = kindForTool(tool ?: head ?: "")
            val label = head ?: tool ?: ""
            return when (k) {
                Kind.SHELL -> StoryStep(id, k, rest, true)
                Kind.READ -> StoryStep(id, k, if (head == null) rest else "Read $rest", true)
                Kind.SEARCH -> StoryStep(id, k, if (head == null) rest else "$label $rest", true)
                Kind.EDIT -> StoryStep(id, k, if (head == null) rest else "${if (label == "Write") "Write" else "Edit"} $rest", true)
                Kind.WEB, Kind.PLAN, Kind.AGENT -> StoryStep(id, k, if (head == null) rest else "$label $rest", false)
                Kind.OTHER -> StoryStep(id, k, if (head == null) rest else "$label $rest", true)
            }
        }

        fun parse(e: TranscriptEntry): StoryStep = parse(e.id, e.text, e.tool)
    }
}

/** A block of the Story, top to bottom. */
sealed interface StoryBlock {
    val id: String

    /** "12:04" (and "from phone" for a message sent from here), before a user turn. */
    data class Divider(val blockId: String, val label: String) : StoryBlock {
        override val id: String get() = "d:$blockId"
    }

    data class User(val entry: TranscriptEntry, val delivery: SentSessionCommand?) : StoryBlock {
        override val id: String get() = "u:${entry.id}"
    }

    data class Pending(val command: SentSessionCommand) : StoryBlock {
        override val id: String get() = "p:${command.clientId}"
    }

    data class Assistant(val entry: TranscriptEntry) : StoryBlock {
        override val id: String get() = "a:${entry.id}"
    }

    /** Consecutive tool calls, grouped. [live] is the trailing group of a busy session. */
    data class Steps(val blockId: String, val steps: List<StoryStep>, val live: Boolean) : StoryBlock {
        override val id: String get() = "s:$blockId"
    }

    /** "Interrupted", "Conversation compacted". */
    data class Marker(val blockId: String, val text: String) : StoryBlock {
        override val id: String get() = "m:$blockId"
    }
}

object StoryBuilder {
    /**
     * Turns the merged transcript into blocks. Tool calls between two other entries become one steps block; a
     * user entry starts a new turn with a time divider; [active] marks the trailing steps block as live. Pure.
     */
    fun build(items: List<TranscriptTimeline.Item>, active: Boolean, zone: ZoneId = ZoneId.systemDefault()): List<StoryBlock> {
        val out = ArrayList<StoryBlock>()
        var run = ArrayList<StoryStep>()
        var runId = ""

        fun flush() {
            if (run.isEmpty()) return
            out.add(StoryBlock.Steps(runId, run, false))
            run = ArrayList()
        }
        fun stamp(at: Instant?, fromPhone: Boolean): String? {
            if (at == null && !fromPhone) return null
            val clock = at?.let { NowFormat.clock(it, zone = zone) }
            return listOfNotNull(clock, if (fromPhone) "from phone" else null).joinToString(" · ")
        }

        for (item in items) {
            when (item) {
                is TranscriptTimeline.Item.Entry -> {
                    val e = item.entry
                    when (e.role) {
                        TranscriptRole.TOOL -> {
                            if (run.isEmpty()) runId = e.id
                            run.add(StoryStep.parse(e))
                        }
                        TranscriptRole.USER -> {
                            flush()
                            stamp(e.at, item.delivery != null)?.let { out.add(StoryBlock.Divider(e.id, it)) }
                            out.add(StoryBlock.User(e, item.delivery))
                        }
                        TranscriptRole.ASSISTANT -> {
                            flush()
                            out.add(StoryBlock.Assistant(e))
                        }
                        TranscriptRole.SYSTEM -> {
                            flush()
                            out.add(StoryBlock.Marker(e.id, e.text))
                        }
                    }
                }
                is TranscriptTimeline.Item.Pending -> {
                    val c = item.command
                    flush()
                    stamp(c.sentAt, true)?.let { out.add(StoryBlock.Divider(c.clientId, it)) }
                    out.add(StoryBlock.Pending(c))
                }
            }
        }
        flush()
        val last = out.lastOrNull()
        if (active && last is StoryBlock.Steps) out[out.size - 1] = StoryBlock.Steps(last.blockId, last.steps, true)
        return out
    }

    /**
     * The line at the foot of a busy story: what the agent is doing now. The Mac's preview is the last tool
     * one-liner while active. When the trailing block is a live steps card, that card already names what is
     * running, so the line only says it is still going.
     */
    fun liveLine(session: LiveSession, character: AgentCharacter, trailingStepsAreLive: Boolean = false): String? {
        if (session.state != LiveSessionState.ACTIVE) return null
        if (trailingStepsAreLive) return if (character.kind == AgentCharacter.Kind.LOCAL) "Generating…" else "Working…"
        val p = Sw.trimWsNl(session.preview)
        if (p.isEmpty()) return if (character.kind == AgentCharacter.Kind.LOCAL) "Generating…" else "Working…"
        return p
    }
}

// MARK: - Workflows

/**
 * A workflow run drawn as a ring of agent nodes. The centre is "4/7" as the footer counts it (finished over
 * started), the nodes are the run's agents.
 */
data class WorkflowOrbit(
    val name: String,
    val nodes: List<Node>,
    val done: Int,
    val total: Int,
    /** "4/7". */
    val centre: String,
    /** "agents done". */
    val caption: String,
    /** "phase Verify · 2m 10s · 184k tokens". */
    val meta: String,
    val statusLabel: String,
    val isRunning: Boolean,
) {
    enum class NodeState { RUNNING, DONE, FAILED, STOPPED }

    data class Node(
        val id: String,
        val label: String,
        val state: NodeState,
        /** Radians, from 12 o'clock, clockwise. */
        val angle: Double,
    )

    companion object {
        /** Most nodes drawn; more would only be dots on dots. */
        const val maxNodes = 24

        fun nodeState(agent: WorkflowRun.Agent): NodeState {
            if (agent.running) return NodeState.RUNNING
            return when (agent.state) {
                "done" -> NodeState.DONE
                "failed" -> NodeState.FAILED
                else -> NodeState.STOPPED
            }
        }

        fun build(run: WorkflowRun, now: Instant): WorkflowOrbit {
            // Running agents first, so the ones to watch sit at the top of the ring.
            val ordered = run.agents.withIndex().sortedWith { a, b ->
                val ra = if (a.value.running) 0 else 1
                val rb = if (b.value.running) 0 else 1
                if (ra != rb) ra.compareTo(rb) else a.index.compareTo(b.index)
            }.map { it.value }.take(maxNodes)
            val n = maxOf(1, ordered.size)
            val nodes = ordered.mapIndexed { i, a -> Node(a.id, a.label, nodeState(a), i.toDouble() / n * 2 * Math.PI) }
            val meta = ArrayList<String>()
            run.phase?.let { meta.add("phase $it") }
            run.startedAt?.let { meta.add(WorkflowRun.duration(((run.endedAt ?: now).secondsSince(it)))) }
            run.tokens?.let { meta.add(WorkflowRun.tokens(it)) }
            return WorkflowOrbit(run.name, nodes, run.done, run.total, "${run.done}/${run.total}", "agents done", meta.joinToString(" · "), run.statusLabel, run.isRunning)
        }

        /** "2 finished today · design-pass ✓ · port-android ✓", or null. */
        fun finishedLine(runs: List<WorkflowRun>, now: Instant, zone: ZoneId = ZoneId.systemDefault()): String? {
            val start = startOfDay(now, zone)
            val finished = runs.filter { !it.isRunning && (it.endedAt ?: Instant.MIN) >= start && it.status == "completed" }
            if (finished.isEmpty()) return null
            val names = finished.take(3).map { "${it.name} ✓" }
            return (listOf("${finished.size} finished today") + names).joinToString(" · ")
        }

        /** Agents of a run, grouped as the run screen lists them: running, then failed or stopped, then done. Pure. */
        fun groups(run: WorkflowRun): List<Pair<String, List<WorkflowRun.Agent>>> {
            val running = run.agents.filter { it.running }
            val other = run.agents.filter { !it.running && it.state != "done" }
            val done = run.agents.filter { it.state == "done" }
            return listOf("Running" to running, "Failed or didn't finish" to other, "Done" to done).filter { it.second.isNotEmpty() }
        }
    }
}

/** A workflow agent's room: the task it was given, then its steps and words. Read-only: workflow agents are never typed into. */
data class AgentRoomModel(
    val task: String?,
    val blocks: List<StoryBlock>,
    /** Older steps were dropped to fit the snapshot. */
    val truncated: Boolean,
) {
    companion object {
        const val readOnlyNote = "Workflow agents are read-only. Steer the parent session instead."

        fun build(entries: List<TranscriptEntry>, finished: Boolean, truncated: Boolean = false): AgentRoomModel {
            val task = entries.firstOrNull { it.role == TranscriptRole.USER }?.text
            // The task is shown once, above the story, wherever it sits in the transcript.
            val rest = entries.filter { !(it.role == TranscriptRole.USER && it.text == task) }
            val blocks = StoryBuilder.build(rest.map { TranscriptTimeline.Item.Entry(it, null) }, !finished)
            return AgentRoomModel(task, blocks, truncated)
        }
    }
}

// MARK: - Changes

/**
 * The Changes lens: the files a turn (or the repository) changed, with +/− counts, as rows, and the patch split
 * into lines of a kind.
 */
data class ChangesModel(
    /** "THIS TURN" or "UNCOMMITTED CHANGES". */
    val scopeLabel: String,
    val repo: String?,
    val files: List<FileRow>,
    val sections: List<Section>,
    val added: Int,
    val removed: Int,
    /** Share of the change that is additions, 0..1 (the green part of the bar). */
    val addedFraction: Double,
    val truncated: Boolean,
    val note: String?,
    val emptyText: String?,
) {
    data class FileRow(val path: String, val added: Int?, val removed: Int?, val status: String) {
        val id: String get() = path

        /** A semantic icon name (the views map it to an icon). */
        val symbol: String
            get() = when (status) {
                "added" -> "plus.circle"
                "modified" -> "pencil.circle"
                else -> "circle.dashed"
            }
    }

    enum class LineKind { HUNK, ADDED, REMOVED, CONTEXT }

    /** One file's part of the patch. */
    data class Section(val path: String, val lines: List<String>) {
        val id: String get() = if (path.isEmpty()) "patch" else path
    }

    val fileCountText: String get() = "${files.size} file${if (files.size == 1) "" else "s"}"

    /**
     * Patch sections that no file row names (a path-less patch, a rename, a path with spaces): they are still
     * shown, after the file list, so the diff is never shorter than what the Mac sent.
     */
    val unmatchedSections: List<Section>
        get() {
            val known = files.map { it.path }.toSet()
            return sections.filter { it.path !in known && it.lines.isNotEmpty() }
        }

    /** Where the Changes lens stands while it waits for the Mac. */
    sealed interface Load {
        data object Loading : Load
        data object NoAnswer : Load
        data class Failed(val why: String) : Load
        data object Loaded : Load
    }

    companion object {
        const val noAnswerAfter: Double = 20.0

        /** The patch split per file ("diff --git" headers), for sections (iOS `SessionDiff.sections`). */
        fun patchSections(patch: String): List<Section> {
            val out = ArrayList<Pair<String, MutableList<String>>>()
            for (line in patch.split("\n")) {
                if (Sw.hasPrefix(line, "diff --git ")) {
                    val last = Sw.splitOmittingEmpty(line, " ").lastOrNull()
                    val path = last?.let { Sw.dropFirst(it, 2) } ?: line
                    out.add(Pair(path, ArrayList()))
                } else if (out.isNotEmpty()) {
                    out[out.size - 1].second.add(line)
                } else if (line.isNotEmpty()) {
                    out.add(Pair("", arrayListOf(line)))
                }
            }
            // Drop the patch header lines (index, ---/+++), keep hunks.
            return out.map { (path, lines) ->
                Section(path, lines.filter { !Sw.hasPrefix(it, "index ") && !Sw.hasPrefix(it, "--- ") && !Sw.hasPrefix(it, "+++ ") && it != "new file" })
            }
        }

        fun build(d: SessionDiff): ChangesModel {
            val added = d.files.mapNotNull { it.added }.sum()
            val removed = d.files.mapNotNull { it.removed }.sum()
            val total = added + removed
            return ChangesModel(
                scopeLabel = if (d.scope == "turn") "THIS TURN" else "UNCOMMITTED CHANGES", repo = d.repo,
                files = d.files.map { FileRow(it.path, it.added, it.removed, it.status) },
                sections = patchSections(d.patch),
                added = added, removed = removed, addedFraction = if (total > 0) added.toDouble() / total else 1.0,
                truncated = d.truncated, note = d.note,
                emptyText = if (d.files.isEmpty() && d.note == null) (if (d.scope == "turn") "This turn didn't change any files." else "No uncommitted changes.") else null,
            )
        }

        /** How a patch line is drawn. File headers (+++/---) are context, not changes. Pure. */
        fun lineKind(line: String): LineKind {
            if (Sw.hasPrefix(line, "@@")) return LineKind.HUNK
            if (Sw.hasPrefix(line, "+") && !Sw.hasPrefix(line, "+++")) return LineKind.ADDED
            if (Sw.hasPrefix(line, "-") && !Sw.hasPrefix(line, "---")) return LineKind.REMOVED
            return LineKind.CONTEXT
        }

        /** The text "Ask about this" and a long-press on a file put in the composer. It is only a draft: nothing is sent until you send it. */
        fun question(path: String?): String {
            if (path.isNullOrEmpty()) return "Why did you make these changes?"
            return "Why did you change $path?"
        }

        fun load(hasDiff: Boolean, error: String?, requestedAt: Instant, now: Instant): Load {
            if (hasDiff) return Load.Loaded
            if (error != null) return Load.Failed(error)
            return if (now.secondsSince(requestedAt) > noAnswerAfter) Load.NoAnswer else Load.Loading
        }
    }
}

// MARK: - Terminal mirror

/**
 * How a line of the terminal mirror is tinted, read off Claude Code's own glyphs: a finished tool call green, a
 * spinner line amber, the footer's auto-mode row violet, rules and continuations quiet. Anything else is plain
 * text. Pure.
 */
enum class TerminalTone {
    TOOL, BUSY, FOOTER, PROMPT, QUIET, PLAIN;

    companion object {
        fun classify(line: String): TerminalTone {
            val t = Sw.trimWs(line)
            if (t.isEmpty()) return PLAIN
            val first = t.codePointAt(0)
            if (Sw.count(t) >= 8 && t.codePoints().allMatch { (it in 0x2500..0x257F) || it == '-'.code || it == '='.code || it == '_'.code || it == ' '.code }) return QUIET
            return when (first) {
                0x23FA, 0x25CF -> TOOL // ⏺ ●
                0x273B, 0x2736, 0x2733, 0x2722, 0x00B7, 0x2217 -> if (t.contains("…") || t.contains("esc to interrupt")) BUSY else PLAIN
                0x23F5, 0x25B6, 0x25B8 -> FOOTER // ⏵ ▶ ▸
                0x23BF, 0x2514, 0x2502 -> QUIET // ⎿ └ │
                0x276F, '>'.code -> PROMPT // ❯
                else -> PLAIN
            }
        }
    }
}
