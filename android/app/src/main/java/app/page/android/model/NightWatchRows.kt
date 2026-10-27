package app.page.android.model

import java.time.Instant
import java.util.regex.Pattern

// Port of iOS/Page/Models/NightWatchRows.swift. The Night Watch "Now" stream,
// row by row: what each page is, how reversible answering it is, which actions
// the phone offers, and the delivery preview that names what will be typed,
// where and on which Mac. Pure (no clock, no services), mirroring the Mac's
// NowModel for the phone. Copy matches iOS word for word (trust model).

// MARK: - Chips

/** The label on a row: how reversible a pending action is, or why it is here. */
enum class ChipKind(val raw: String) {
    IRREVERSIBLE("irreversible"), CONSIDERED("considered"), UNDOABLE("undoable"),
    LOOKS_STUCK("looksStuck"), QUESTION("question"), FORECAST("forecast"), RATE_LIMITED("rateLimited"), REVIEW("review");

    /** All caps, as drawn. */
    val title: String
        get() = when (this) {
            IRREVERSIBLE -> "IRREVERSIBLE"
            CONSIDERED -> "CONSIDERED"
            UNDOABLE -> "UNDOABLE"
            LOOKS_STUCK -> "LOOKS STUCK"
            QUESTION -> "QUESTION"
            FORECAST -> "HEADS UP"
            RATE_LIMITED -> "RATE LIMITED"
            REVIEW -> "FINISHED"
        }

    companion object {
        fun of(r: Reversibility): ChipKind = when (r) {
            Reversibility.UNDOABLE -> UNDOABLE
            Reversibility.CONSIDERED -> CONSIDERED
            Reversibility.IRREVERSIBLE -> IRREVERSIBLE
        }
    }
}

// MARK: - Reversibility on the phone

/**
 * Which pages get a Reversibility class on the phone, and which class. The phone sees only the page's `context`
 * text (the same text the Mac's classifier reads), so it runs the same classifier; when the text says nothing
 * about the action the answer is CONSIDERED, never UNDOABLE.
 */
object PhoneReversibility {
    /**
     * null for pages with nothing to approve (questions, finished turns, forecasts). Non-Claude agents' prompts
     * are not written in the `[Tool] input` shape the classifier reads: those are CONSIDERED (see [NowRowBuilder]),
     * never guessed at.
     */
    fun verdict(iv: Intervention): Reversibility.Verdict? {
        if (iv.kind != InterventionKind.APPROVAL) return null
        if (iv.hasUnknownBackend) {
            return Reversibility.Verdict(Reversibility.CONSIDERED, emptyList(), DeliveryPreview.unreadableNote)
        }
        if ((iv.backend ?: InterventionBackend.CLAUDE) != InterventionBackend.CLAUDE) {
            return Reversibility.Verdict(Reversibility.CONSIDERED, emptyList(), "${iv.agentName}'s prompt isn't one Page can read")
        }
        if (iv.subtype == "plan") {
            return Reversibility.Verdict(Reversibility.CONSIDERED, emptyList(), "plan approval")
        }
        // The page's own (absolute) cwd, not a session's home-abbreviated one.
        return Reversibility.classify(iv.context, if (iv.cwd.isEmpty()) null else iv.cwd)
    }
}

// MARK: - Actions and delivery previews

/** How a row's approve is committed: swipe (Undoable), tap (Considered) or press-and-hold plus biometrics (Irreversible). */
enum class CommitGesture(val raw: String) {
    SWIPE("swipe"), TAP("tap"), HOLD("hold");

    /** The hint under the button. */
    val hint: String
        get() = when (this) {
            SWIPE -> "swipe to approve"
            TAP -> "tap to approve"
            HOLD -> "hold to approve"
        }

    companion object {
        fun of(r: Reversibility): CommitGesture = when (r) {
            Reversibility.UNDOABLE -> SWIPE
            Reversibility.CONSIDERED -> TAP
            Reversibility.IRREVERSIBLE -> HOLD
        }
    }
}

/** One thing the phone can do with a row. */
data class RowAction(
    val kind: Kind,
    /** Button text. */
    val label: String,
    /** "Will type 1 · cmux › page · Studio MBP"; null when nothing would be sent. */
    val preview: String?,
) {
    enum class Kind(val raw: String) {
        /** Approve: option 1, or the hook's allow. */
        APPROVE("approve"),

        /** Deny: Esc, or the hook's deny. */
        DENY("deny"),

        /** Stop a stuck session: Esc. */
        STOP("stop"),

        /** A written reply. On an open prompt it is Esc, then the text, then Return. */
        TELL_INSTEAD("tellInstead"),

        /** "Carry on" on a finished turn. */
        CARRY_ON("carryOn"),

        /** Page cannot answer this from the phone. */
        OPEN_ON_MAC("openOnMac"),
    }

    val id: String get() = kind.raw
}

/** The delivery preview strings. Every one names the Mac, so with several Macs paired you cannot act on the wrong one. */
object DeliveryPreview {
    /** "your Mac" when the name is blank, so a preview never omits the Mac. */
    fun macLabel(name: String): String {
        val t = Sw.trimWsNl(name)
        return if (t.isEmpty()) "your Mac" else t
    }

    /** "cmux › page": the terminal and the project. null when neither is known. */
    fun route(host: String?, project: String?): String? {
        val h = Sw.trimWsNl(host ?: "")
        val hostName = if (h.isEmpty() || h.lowercase() == "unknown") null else h
        val p = Sw.trimWsNl(project ?: "")
        val proj = if (p.isEmpty()) null else p
        return when {
            hostName != null && proj != null -> "$hostName › $proj"
            hostName != null -> hostName
            proj != null -> proj
            else -> null
        }
    }

    /** "<action> · <route> · <Mac>". */
    fun line(action: String, route: String?, mac: String): String =
        listOf<String?>(action, route, macLabel(mac)).filterNotNull().filter { it.isNotEmpty() }.joinToString(" · ")

    fun typeOne(route: String?, mac: String): String = line("Will type 1", route, mac)
    fun pressEsc(route: String?, mac: String): String = line("Will press Esc", route, mac)
    fun tellInstead(route: String?, mac: String): String = line("Esc, then your message", route, mac)

    /** A message to a busy or finished session: queued behind the turn; never Esc or 1. */
    fun message(route: String?, mac: String): String = line("Your message, then Return", route, mac)
    fun carryOn(route: String?, mac: String): String = line("Will type your carry-on message, then Return", route, mac)
    fun cannotType(why: String, mac: String): String = line("Can't type here · $why", null, mac)

    /** Phone-approval hook pages: nothing is typed, the hook receives the answer. */
    fun hookAllow(mac: String): String = line("Will allow it through Claude's permission hook", null, mac)
    fun hookDeny(mac: String): String = line("Will deny it through Claude's permission hook", null, mac)
    fun hookTell(mac: String): String = line("Deny, with your message, through the hook", null, mac)

    /** Codex answers approvals through its own adapter; Page does not type 1. */
    fun codexAccept(mac: String): String = line("Asks Codex to accept", null, mac)
    fun codexDecline(mac: String): String = line("Asks Codex to decline", null, mac)

    /** What the one option Page never offers reads as. */
    const val openInTerminal = "Open in terminal to choose this"

    /** An agent Page has no adapter for: nothing is typed, and the sheet says so. */
    const val unreadableNote = "Couldn't tell what's on screen · Open on Mac"

    /** The same, as an action preview, which always names the Mac. */
    fun unreadable(mac: String): String = line("Couldn't tell what's on screen", null, mac)

    private val standingNeedles = listOf(
        "don't ask again", "dont ask again", "do not ask again", "don’t ask again",
        "allow all", "always allow", "for this session", "during this session", "and remember",
        "don't ask me again",
    )

    /**
     * True for a prompt option such as "Yes, and don't ask again" or "Yes, allow all edits during this session":
     * options that change what the agent may do from now on. Page never sends the key for these (and never sends
     * 2); the phone shows [openInTerminal] instead. Pure.
     */
    fun isStandingPermissionOption(text: String): Boolean {
        val t = text.lowercase()
        return standingNeedles.any { t.contains(it) }
    }
}

// MARK: - Rows

/** One line in the Now stream: something that needs a decision, a look, or a review. */
data class NowRow(
    val id: String,
    val sessionId: String,
    val projectName: String,
    val agentName: String,
    val section: Section,
    val chip: ChipKind,
    /** Verb-first title: "Delete every Dev build?". */
    val headline: String,
    /** The command, or a one-line summary: "rm -rf Builds/Dev/(star).app". */
    val summary: String,
    val actions: List<RowAction>,
    /** How Approve is committed; null when the row has no approve. */
    val commit: CommitGesture?,
    /** Return/primary is only ever Approve on an Undoable row. */
    val waitingSince: Instant,
    val reversibility: Reversibility?,
    val tags: List<Reversibility.Tag>,
    val reason: String,
) {
    enum class Section(val rank: Int) {
        /** Approvals, plan approvals, questions: the agent is blocked on you. */
        DECIDE(0),

        /** Stuck, rate-limited, battery or usage forecasts. */
        LOOK(1),

        /** A finished turn waiting for you. */
        REVIEW(2);

        val title: String
            get() = when (this) {
                DECIDE -> "DECIDE"
                LOOK -> "LOOK"
                REVIEW -> "REVIEW"
            }
    }

    fun action(kind: RowAction.Kind): RowAction? = actions.firstOrNull { it.kind == kind }

    /**
     * Whether the row can be approved with a swipe: it is Undoable AND it really has an Approve action. A row the
     * phone cannot type into (a blocker, an agent Page has no adapter for) keeps its Undoable chip but offers only
     * Open on Mac, so it never gets the swipe or the TalkBack "Approve".
     */
    val canSwipeApprove: Boolean get() = commit == CommitGesture.SWIPE && action(RowAction.Kind.APPROVE) != null

    /** The preview shown under the focused row: the approve line, else the first action that sends something. */
    val focusPreview: String? get() = action(RowAction.Kind.APPROVE)?.preview ?: actions.firstNotNullOfOrNull { it.preview }
}

object NowRowBuilder {
    /** Which section a page belongs to. */
    fun section(iv: Intervention): NowRow.Section = when (iv.kind) {
        InterventionKind.APPROVAL, InterventionKind.USER_INPUT -> NowRow.Section.DECIDE
        InterventionKind.RATE_LIMIT -> NowRow.Section.LOOK
        InterventionKind.IDLE ->
            if (PageSubtype.isStuck(iv.subtype) || iv.subtype == "low_battery") NowRow.Section.LOOK else NowRow.Section.REVIEW
    }

    /**
     * The row for a page. [session] is the live session behind it, when the phone has the list: it names the
     * terminal and says whether Page can type there. [macName] is always shown in previews.
     */
    fun row(iv: Intervention, session: LiveSession?, macName: String): NowRow {
        val mac = DeliveryPreview.macLabel(macName)
        val section = section(iv)
        val backend = iv.backend ?: InterventionBackend.CLAUDE
        val host = session?.host ?: iv.source?.let { if (it == InterventionSource.UNKNOWN) null else it.label }
        // A page from "/" has no folder to name it: the session's own name stands in, never a bare slash.
        val projectName = if (ProjectLabel.isBare(iv.cwd) || iv.projectName == "Unknown project") {
            ProjectLabel.name(iv.cwd, session?.title ?: "")
        } else iv.projectName
        val route = DeliveryPreview.route(host, session?.title ?: projectName)
        val blocker: String? = if (session != null && !session.canType) session.blockerText else null
        val hook = iv.isBlockingHook
        // An agent Page has no adapter for (the relay named a backend that is not Claude or Codex, or the live
        // session says so): it never types there, and says what to do instead.
        val unknownAgent = iv.hasUnknownBackend || (session?.backend is AgentBackend.Other)

        fun act(k: RowAction.Kind, label: String, preview: String?) = RowAction(k, label, preview)
        val chip: ChipKind
        var verdict: Reversibility.Verdict? = null
        var actions: List<RowAction> = emptyList()
        var commit: CommitGesture? = null

        when (iv.kind) {
            InterventionKind.APPROVAL -> {
                val v = PhoneReversibility.verdict(iv)
                verdict = v
                val level = v?.level ?: Reversibility.CONSIDERED
                chip = ChipKind.of(level)
                commit = CommitGesture.of(level)
                val planned = iv.subtype == "plan"
                val approveLabel = if (planned) "Approve plan" else "Approve"
                val denyLabel = if (planned) "Keep planning" else "Deny"
                if (unknownAgent && !hook) {
                    actions = listOf(act(RowAction.Kind.OPEN_ON_MAC, "Open on Mac", DeliveryPreview.unreadable(mac)))
                    commit = null
                } else if (hook) {
                    val l = arrayListOf(
                        act(RowAction.Kind.APPROVE, approveLabel, DeliveryPreview.hookAllow(mac)),
                        act(RowAction.Kind.DENY, denyLabel, DeliveryPreview.hookDeny(mac)),
                    )
                    if (!iv.acceptsDecisionsOnly) l.add(act(RowAction.Kind.TELL_INSTEAD, "Tell it instead…", DeliveryPreview.hookTell(mac)))
                    actions = l
                } else if (backend == InterventionBackend.CODEX) {
                    actions = listOf(
                        act(RowAction.Kind.APPROVE, approveLabel, DeliveryPreview.codexAccept(mac)),
                        act(RowAction.Kind.DENY, denyLabel, DeliveryPreview.codexDecline(mac)),
                    )
                } else if (blocker != null) {
                    actions = listOf(act(RowAction.Kind.OPEN_ON_MAC, "Open on Mac", DeliveryPreview.cannotType(blocker, mac)))
                    commit = null
                } else {
                    actions = listOf(
                        act(RowAction.Kind.APPROVE, approveLabel, DeliveryPreview.typeOne(route, mac)),
                        act(RowAction.Kind.DENY, denyLabel, DeliveryPreview.pressEsc(route, mac)),
                        act(RowAction.Kind.TELL_INSTEAD, "Tell it instead…", DeliveryPreview.tellInstead(route, mac)),
                    )
                }
            }
            InterventionKind.USER_INPUT -> {
                chip = ChipKind.QUESTION
                actions = if (unknownAgent && !hook) {
                    listOf(act(RowAction.Kind.OPEN_ON_MAC, "Open on Mac", DeliveryPreview.unreadable(mac)))
                } else if (backend == InterventionBackend.CLAUDE && (blocker == null || hook)) {
                    // A written answer to a Claude prompt is Esc, then the text, then Return.
                    listOf(act(RowAction.Kind.TELL_INSTEAD, "Answer", if (hook) DeliveryPreview.hookTell(mac) else DeliveryPreview.tellInstead(route, mac)))
                } else if (blocker != null) {
                    listOf(act(RowAction.Kind.OPEN_ON_MAC, "Open on Mac", DeliveryPreview.cannotType(blocker, mac)))
                } else {
                    listOf(act(RowAction.Kind.TELL_INSTEAD, "Answer", DeliveryPreview.line("Your answer, as Codex takes it", route, mac)))
                }
            }
            InterventionKind.IDLE -> {
                if (PageSubtype.isStuck(iv.subtype)) {
                    chip = ChipKind.LOOKS_STUCK
                    if (unknownAgent) {
                        actions = listOf(act(RowAction.Kind.OPEN_ON_MAC, "Open on Mac", DeliveryPreview.unreadable(mac)))
                    } else if (blocker != null) {
                        actions = listOf(act(RowAction.Kind.OPEN_ON_MAC, "Open on Mac", DeliveryPreview.cannotType(blocker, mac)))
                    } else {
                        val l = ArrayList<RowAction>()
                        if (PageSubtype.canStop(iv.subtype)) l.add(act(RowAction.Kind.STOP, "Stop it", DeliveryPreview.pressEsc(route, mac)))
                        l.add(act(RowAction.Kind.TELL_INSTEAD, "Steer", DeliveryPreview.message(route, mac)))
                        actions = l
                    }
                } else if (iv.subtype == "low_battery") {
                    chip = ChipKind.FORECAST
                    actions = emptyList()
                } else {
                    chip = ChipKind.REVIEW
                    actions = if (unknownAgent) {
                        listOf(act(RowAction.Kind.OPEN_ON_MAC, "Open on Mac", DeliveryPreview.unreadable(mac)))
                    } else if (blocker != null) {
                        listOf(act(RowAction.Kind.OPEN_ON_MAC, "Open on Mac", DeliveryPreview.cannotType(blocker, mac)))
                    } else {
                        listOf(
                            act(RowAction.Kind.CARRY_ON, "Carry on", DeliveryPreview.carryOn(route, mac)),
                            act(RowAction.Kind.TELL_INSTEAD, "Steer", DeliveryPreview.message(route, mac)),
                        )
                    }
                }
            }
            InterventionKind.RATE_LIMIT -> {
                if (PageSubtype.isForecast(iv.subtype)) {
                    chip = ChipKind.FORECAST
                    actions = emptyList()
                } else {
                    chip = ChipKind.RATE_LIMITED
                    actions = if (backend == InterventionBackend.CLAUDE) {
                        listOf(act(RowAction.Kind.TELL_INSTEAD, "Send after reset", DeliveryPreview.line("Your message, typed when the limit resets", route, mac)))
                    } else emptyList()
                }
            }
        }

        return NowRow(
            id = iv.id, sessionId = iv.sessionId, projectName = projectName, agentName = iv.agentName,
            section = section, chip = chip, headline = headline(iv), summary = summaryLine(iv),
            actions = actions, commit = commit, waitingSince = iv.openedAt,
            reversibility = if (iv.kind == InterventionKind.APPROVAL) (verdict?.level ?: Reversibility.CONSIDERED) else null,
            tags = verdict?.tags ?: emptyList(), reason = verdict?.reason ?: "",
        )
    }

    /**
     * Decide rows first, Irreversible before anything else, then the longest wait first; then Look, then Review,
     * each longest wait first. (The Mac's ranking; `Intervention.urgencySorted` is untouched.)
     */
    fun ranked(rows: List<NowRow>): List<NowRow> {
        fun rank(r: NowRow): Int = r.reversibility?.raw ?: (if (r.chip == ChipKind.QUESTION) Reversibility.CONSIDERED.raw else -1)
        return rows.sortedWith { a, b ->
            if (a.section != b.section) return@sortedWith a.section.rank.compareTo(b.section.rank)
            // A question has no class; it ranks with the Considered items.
            if (rank(a) != rank(b)) return@sortedWith rank(b).compareTo(rank(a))
            if (a.waitingSince != b.waitingSince) return@sortedWith a.waitingSince.compareTo(b.waitingSince)
            a.id.compareTo(b.id)
        }
    }

    // MARK: copy

    private val failedTimes = Rx.compile("""failed (\d+) times""")
    private val noProgress = Rx.compile("""^No progress for \d+ min""")

    private fun contextLines(text: String): List<String> =
        text.split("\n").map { Sw.trimWs(it) }.filter { it.isNotEmpty() }

    /**
     * Verb-first title. A Bash approval uses the model's own one-line description when the page carries one
     * ("Delete every Dev build?").
     */
    fun headline(iv: Intervention): String {
        if (iv.kind == InterventionKind.IDLE && iv.subtype == "low_battery") return "Paused for battery"
        // A finished turn waiting for review.
        if (iv.kind == InterventionKind.IDLE && !PageSubtype.isStuck(iv.subtype) && iv.subtype != "workflow_stalled") {
            return "${(iv.backend ?: InterventionBackend.CLAUDE).displayName} finished a turn"
        }
        if (iv.kind == InterventionKind.APPROVAL && iv.subtype != "plan") {
            val lines = contextLines(iv.context)
            if (lines.size >= 2 && Sw.hasPrefix(lines[0], "[Bash]")) {
                val d = lines[1]
                if (Sw.count(d) <= 60 && !Sw.hasSuffix(d, "?") && d.isNotEmpty()) {
                    val type = Character.getType(d.codePointAt(0))
                    if (type == Character.UPPERCASE_LETTER.toInt() || type == Character.TITLECASE_LETTER.toInt()) {
                        return if (Sw.hasSuffix(d, ".")) Sw.dropLast(d) + "?" else "$d?"
                    }
                }
            }
        }
        return ReplyCopy.headline(iv)
    }

    /** The one line a row shows: the command for a Bash approval, the file for an edit, "cargo test failed 6×" for a loop, and so on. */
    fun summaryLine(iv: Intervention): String {
        val text = Sw.trimWsNl(iv.context)
        val lines = contextLines(text)
        val first = lines.firstOrNull() ?: ""

        when (iv.subtype) {
            "looping" -> {
                // "Looks stuck in a loop: this has failed 6 times.\n<label>"
                val m = failedTimes.matcher(first)
                val count = if (m.find()) Sw.chars(m.group()).filter { Sw.isNumber(it) }.joinToString("").toIntOrNull() else null
                val label = lines.drop(1).firstOrNull()
                if (label != null && count != null) return clip("$label failed $count×")
                if (label != null) return clip(label)
            }
            "stuck" -> {
                val m = noProgress.matcher(first)
                if (m.find()) return "no progress for" + m.group().substring("No progress for".length)
            }
            "plan" -> return "plan ready for review"
            else -> Unit
        }
        if (iv.kind == InterventionKind.IDLE || iv.kind == InterventionKind.RATE_LIMIT || iv.kind == InterventionKind.USER_INPUT) {
            return clip(if (first.isEmpty()) "waiting for you" else first)
        }

        if (Sw.hasPrefix(first, "One of these is waiting for approval")) {
            val n = text.split("\n• ").size - 1
            return "${maxOf(n, 2)} tool calls waiting"
        }
        if (Sw.hasPrefix(first, "Plan ready for review")) return "plan ready for review"
        if (Sw.hasPrefix(first, "A subagent is asking for approval")) {
            return clip(lines.drop(1).firstOrNull()?.let { stripTool(it) } ?: "a subagent is asking")
        }
        if (Sw.hasPrefix(first, "[") && first.contains("]")) return clip(stripTool(first))
        if (first.isEmpty()) return "waiting for you"
        if (first == "Claude is waiting for your approval") return "waiting for your approval"
        return clip(first)
    }

    /** "[Bash] rm -rf x" becomes "rm -rf x"; "[Edit] a.swift" becomes "edit a.swift". */
    fun stripTool(line: String): String {
        if (!Sw.hasPrefix(line, "[")) return line
        val close = Sw.firstIndexOf(line, "]")
        if (close < 0) return line
        val name = line.substring(1, close)
        val rest = Sw.trimWs(line.substring(close + 1))
        return when (name) {
            "Bash" -> rest
            "Edit", "MultiEdit", "NotebookEdit" -> "edit $rest"
            "Write" -> "write $rest"
            "Read" -> "read $rest"
            "WebFetch", "WebSearch" -> rest
            else -> Sw.trimWs("${name.lowercase()} $rest")
        }
    }

    private fun clip(s: String, limit: Int = 96): String =
        if (Sw.count(s) <= limit) s else Sw.prefix(s, limit - 1) + "…"
}
