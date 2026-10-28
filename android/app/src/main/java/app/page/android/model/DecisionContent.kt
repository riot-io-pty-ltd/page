package app.page.android.model

import java.util.regex.Pattern

// Port of iOS/Page/Models/DecisionContent.swift. What a Decision sheet shows
// for one page, as pure values: the ask, the reversibility reasons, the
// delivery preview, and the notes the trust model requires (a prompt option
// Page never offers; a prompt Page cannot read). Built from the page, its row
// and its live session; the sheet only draws it.

/**
 * One option the prompt itself lists, read out of the page's text. Page never sends a digit for these: Approve
 * types 1 and nothing else does. An option that would change what the agent may do from now on is shown, not offered.
 */
data class PromptOption(
    val number: Int,
    val text: String,
    /** "Yes, and don't ask again", "Yes, allow all edits during this session". */
    val isStanding: Boolean,
) {
    val id: Int get() = number

    /** What the sheet says in place of an action for a standing option. */
    val instead: String? get() = if (isStanding) DeliveryPreview.openInTerminal else null

    companion object {
        private val optionLine = Rx.compile("""^(\d{1,2})[.)]\s+(.+)$""")

        /** Reads "1. Yes", "2) Yes, and don't ask again" style lines. Pure. */
        fun parse(context: String): List<PromptOption> {
            val out = ArrayList<PromptOption>()
            for (raw in context.split("\n")) {
                val line = Sw.trimWs(raw)
                val stripped = if (Sw.hasPrefix(line, "❯")) Sw.trimWs(Sw.dropFirst(line)) else line
                val m = optionLine.matcher(stripped)
                if (!m.find()) continue
                val body = m.group()
                val digits = Sw.chars(body).takeWhile { Sw.isNumber(it) }.joinToString("")
                val n = digits.toIntOrNull() ?: continue
                val text = Sw.trimWs(Sw.dropFirst(body, Sw.count(digits) + 1))
                out.add(PromptOption(n, text, DeliveryPreview.isStandingPermissionOption(text)))
            }
            // A real option list counts up from 1.
            return if (out.withIndex().all { it.value.number == it.index + 1 }) out else emptyList()
        }
    }
}

data class DecisionContent(
    val id: String,
    val sessionId: String,
    val chip: ChipKind,
    val section: NowRow.Section,
    val project: String,
    val agent: String,
    /** "cmux › page", when known. */
    val route: String?,
    val headline: String,
    /** One line above the ask ("Claude wants to do this. It can't be undone from your phone."). */
    val blurb: String?,
    val askKind: AskKind,
    /** The command, the file, the plan or the question, in full. */
    val ask: String,
    /** Smaller text under the ask: the working directory, the reason. */
    val detail: String?,
    /** "~/projects/page". */
    val cwd: String?,
    /** The Mac's turn-summary line ("Changed 3 files (+120 −14) · tests passed") on a finished page. */
    val turnSummary: String?,
    /** Reversibility tags and the reason, with what undo would look like. */
    val tags: List<Reversibility.Tag>,
    val reason: String,
    val undoNote: String?,
    val options: List<PromptOption>,
    /** "Couldn't tell what's on screen · Open on Mac" when Page can't read this agent's prompt. */
    val screenNote: String?,
    /** A v1 hook can only apply Approve or Deny. */
    val decisionsOnly: Boolean,
    val isHook: Boolean,
    /** Under the actions: where Page types, or who gets the answer. */
    val footer: String,
    /** Everything the page said, for Copy. */
    val rawContext: String,
    /** The page is a forecast or a battery pause: nothing to answer. */
    val informational: String?,
    val stoppable: Boolean,
    val canTell: Boolean,
    /** A finished turn's last message ends on a plain yes/no question ([YesNoQuestion]): the sheet offers Yes and No. */
    val yesNo: String? = null,
) {
    enum class AskKind { COMMAND, EDIT, PLAN, QUESTION, NOTE }

    companion object {
        /** What undoing would look like, per class. A hint, never a "safe" badge. Pure. */
        fun undoNote(level: Reversibility?, tags: List<Reversibility.Tag>): String? {
            if (level == null) return null
            return when (level) {
                Reversibility.UNDOABLE -> "Read-only, or easy to take back."
                Reversibility.CONSIDERED ->
                    if (Reversibility.Tag.NETWORK_OUTSIDE in tags) "Reaches outside the project. Check where." else "Changes files in your project. git can usually recover them."
                Reversibility.IRREVERSIBLE -> "No undo from your phone."
            }
        }

        fun build(iv: Intervention, row: NowRow, session: LiveSession?, macName: String): DecisionContent {
            val lines = iv.context.split("\n").map { Sw.trimWs(it) }.filter { it.isNotEmpty() }
            val first = lines.firstOrNull() ?: ""
            val backendLabel = iv.backend?.displayName ?: (if (iv.hasUnknownBackend) (iv.backendRaw ?: "Agent") else "Claude")
            val mac = DeliveryPreview.macLabel(macName)

            var kind = AskKind.NOTE
            var ask = row.summary
            var detail: String? = null
            var blurb: String? = null
            var summary: String? = null
            var yesNo: String? = null
            when (iv.kind) {
                InterventionKind.APPROVAL -> {
                    if (iv.subtype == "plan") {
                        kind = AskKind.PLAN
                        ask = if (iv.context.isEmpty()) "Plan ready for review" else iv.context
                    } else if (Sw.hasPrefix(first, "[Bash]")) {
                        kind = AskKind.COMMAND
                        ask = Sw.trimWs(first.substring("[Bash]".length))
                        if (lines.size > 1) detail = lines[1]
                    } else if (Sw.hasPrefix(first, "[Edit]") || Sw.hasPrefix(first, "[Write]") || Sw.hasPrefix(first, "[MultiEdit]")) {
                        kind = AskKind.EDIT
                        ask = NowRowBuilder.stripTool(first)
                    } else if (Sw.hasPrefix(first, "One of these is waiting")) {
                        kind = AskKind.COMMAND
                        ask = lines.drop(1).joinToString("\n") { if (Sw.hasPrefix(it, "•")) Sw.trimWs(Sw.dropFirst(it)) else it }
                    } else {
                        kind = AskKind.NOTE
                        ask = if (iv.context.isEmpty()) "$backendLabel is waiting for your approval" else iv.context
                    }
                    if (row.chip == ChipKind.IRREVERSIBLE) blurb = "$backendLabel wants to do this. It can't be undone from your phone."
                }
                InterventionKind.USER_INPUT -> {
                    kind = AskKind.QUESTION
                    ask = if (iv.context.isEmpty()) "$backendLabel needs your input" else iv.context
                }
                InterventionKind.IDLE -> {
                    val parts = TurnSummaryLine.split(InterventionKind.IDLE, iv.context)
                    summary = parts.summary
                    if (row.section == NowRow.Section.REVIEW) yesNo = YesNoQuestion.detect(parts.message)
                    ask = if (row.section == NowRow.Section.REVIEW) {
                        if (parts.message.isEmpty()) (summary ?: "Finished a turn") else Sw.trimWsNl(parts.message)
                    } else {
                        if (iv.context.isEmpty()) row.summary else iv.context
                    }
                }
                InterventionKind.RATE_LIMIT -> ask = if (iv.context.isEmpty()) row.summary else iv.context
            }

            val isInfo: String? = when {
                iv.kind == InterventionKind.RATE_LIMIT && iv.subtype == "battery_forecast" -> "Nothing to answer. Plug your Mac in to keep the agents going."
                iv.kind == InterventionKind.RATE_LIMIT && iv.subtype == "usage_forecast" -> "Nothing to answer. Page keeps the Mac awake through the reset and can resume sessions when it resets."
                iv.kind == InterventionKind.RATE_LIMIT && iv.backend == InterventionBackend.CODEX -> "Nothing to answer. Codex picks up again once the limit resets."
                iv.kind == InterventionKind.IDLE && iv.subtype == "low_battery" -> "Page paused your agents at the battery cutoff. Plug the Mac in and they resume."
                else -> null
            }

            val cwd = if (iv.cwd.isEmpty()) null else PathDisplay.abbreviatingHome(iv.cwd)
            val footer: String
            if (iv.isBlockingHook) {
                footer = "Your answer goes straight to $backendLabel's permission hook in session ${Sw.prefix(iv.sessionId, 8)} on $mac."
            } else {
                var where_ = "session ${Sw.prefix(iv.sessionId, 8)}"
                val source = iv.source
                if (source != null && source != InterventionSource.UNKNOWN) where_ += " (${source.label})"
                footer = "Page types your reply into $where_ on $mac."
            }
            val level = row.reversibility
            val unknownAgent = iv.hasUnknownBackend || (session?.backend is AgentBackend.Other)
            return DecisionContent(
                id = iv.id, sessionId = iv.sessionId, chip = row.chip, section = row.section, project = iv.projectName, agent = backendLabel,
                route = DeliveryPreview.route(session?.host, session?.title ?: iv.projectName),
                headline = row.headline, blurb = blurb, askKind = kind, ask = ask, detail = detail, cwd = cwd, turnSummary = summary,
                tags = row.tags, reason = row.reason, undoNote = undoNote(level, row.tags),
                options = if (iv.kind == InterventionKind.APPROVAL) PromptOption.parse(iv.context) else emptyList(),
                screenNote = if (unknownAgent) DeliveryPreview.unreadableNote else null,
                decisionsOnly = iv.acceptsDecisionsOnly, isHook = iv.isBlockingHook, footer = footer, rawContext = iv.context,
                informational = isInfo, stoppable = PageSubtype.canStop(iv.subtype), canTell = !iv.acceptsDecisionsOnly, yesNo = yesNo,
            )
        }
    }
}
