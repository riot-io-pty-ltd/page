@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package app.page.android.ui.nw.decision

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.graphics.Brush
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.FindInPage
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import app.page.android.model.ActionGate
import app.page.android.model.AnswerSheet
import app.page.android.model.CardOutcome
import app.page.android.model.ChipKind
import app.page.android.model.DecisionContent
import app.page.android.model.DecisionPhase
import app.page.android.model.HoldRingSpec
import app.page.android.model.NWTip
import app.page.android.model.NowRow
import app.page.android.model.PendingAction
import app.page.android.model.ReceiptThreadInput
import app.page.android.model.RowAction
import app.page.android.model.SentSessionCommand
import app.page.android.model.SessionAsk
import app.page.android.model.TurnSummaryChips
import app.page.android.model.waitingText
import app.page.android.ui.nw.components.NWAnswerHost
import app.page.android.ui.nw.components.NWButton
import app.page.android.ui.nw.components.NWButtonKind
import app.page.android.ui.nw.components.NWChip
import app.page.android.ui.nw.components.NWDeliveryPreview
import app.page.android.ui.nw.components.NWHoldRing
import app.page.android.ui.nw.components.NWReceiptLine
import app.page.android.ui.nw.components.NWReceiptThreadView
import app.page.android.ui.nw.components.NWTextField
import app.page.android.ui.nw.components.NWTipCallout
import app.page.android.ui.nw.components.NWTurnChip
import app.page.android.ui.nw.components.color
import app.page.android.ui.nw.components.tint
import app.page.android.ui.nw.theme.NW
import java.time.Instant

/** What the Decision sheet shows and can do, as values. (iOS DecisionScreenState.) */
data class DecisionScreenState(
    val content: DecisionContent,
    val row: NowRow,
    val phase: DecisionPhase,
    val legacyRelay: Boolean = false,
    val now: Instant,
    /** Seen by the person: "fingerprint", "face" or "screen lock". */
    val biometry: String = "fingerprint",
    val pending: PendingAction? = null,
    val outcome: CardOutcome = CardOutcome.None,
    /** Whether this sheet has a live session behind it to open. */
    val hasSession: Boolean = true,
    /** The question behind a question page, when it can be answered from the phone (picker). */
    val ask: SessionAsk? = null,
    val askDelivery: SentSessionCommand? = null,
    val macName: String = "",
    /** The page is one Claude's question hook holds: the answers go as text through it. */
    val askViaHook: Boolean = false,
    val fixedSheet: AnswerSheet? = null,
    /** Draws the hold ring part-way (the render harness). */
    val fixedHold: Double? = null,
    /** The delivery state of this sheet's action, drawn as its Receipt thread. */
    val receipt: ReceiptThreadInput? = null,
    /** When an Irreversible approve passed biometrics here (it outlives the pending action, so the burst is not cut short). */
    /** When biometrics passed for this sheet's Irreversible approve (the burst's start). */
    val holdCommittedAt: java.time.Instant? = null,
    /** The first-time tip for the delivery preview, while it is unseen. */
    val tip: NWTip? = null,
)

class DecisionScreenActions(
    val approve: () -> Unit = {},
    val holdComplete: () -> Unit = {},
    val deny: () -> Unit = {},
    val carryOn: () -> Unit = {},
    val stop: () -> Unit = {},
    val send: (String) -> Unit = {},
    val submitAnswers: (AnswerSheet) -> Unit = {},
    val cancel: () -> Unit = {},
    val openSession: () -> Unit = {},
    val viewChanges: () -> Unit = {},
    val copy: () -> Unit = {},
    val close: () -> Unit = {},
    val dismissTip: (NWTip) -> Unit = {},
    val tipShown: (NWTip) -> Unit = {},
)

/** The sheet's own surface tint: near-black, tinted by the card's class. (iOS NWDecisionBackground.) */
fun decisionBackground(row: NowRow?): Color =
    (row?.tint?.let { NW.Palette.surface.mixed(it.opacity(1.0), 0.10) } ?: NW.Palette.surface).color

/**
 * The Decision sheet's content: who is asking, the ask in full, why it is the class it is, the delivery preview
 * (what will be typed, where, on which Mac) and the controls its class allows. Undoable and Considered approve
 * with a tap and the 1.2 s cancel ring; Irreversible only through the hold ring, then the fingerprint / face /
 * screen lock. "Tell it instead" opens a composer that sends Esc, then your message, then Return; while the sheet
 * is waiting on an approval, free text can never reach a live prompt any other way. Every action is a closure for
 * the container to route through the existing services. (iOS NWDecisionScreen.)
 */
@Composable
fun NWDecisionScreen(
    state: DecisionScreenState,
    actions: DecisionScreenActions,
    draft: String,
    onDraft: (String) -> Unit,
    composerOpen: Boolean,
    onComposerOpen: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val c = state.content
    val row = state.row
    val fontScale = LocalDensity.current.fontScale
    BoxWithConstraints(modifier.fillMaxSize()) {
        // The answer picker is as tall as a screenful: it flows with the rest instead of being pinned.
        val pinned = maxHeight >= 580.dp && fontScale <= 1.6f && !(state.ask != null && c.chip == ChipKind.QUESTION)
        val v = DecisionView(state, actions, draft, onDraft, composerOpen, onComposerOpen)
        if (pinned) v.Pinned() else v.Flowing()
    }
}

private class DecisionView(
    val state: DecisionScreenState,
    val actions: DecisionScreenActions,
    val draft: String,
    val onDraft: (String) -> Unit,
    val composerOpen: Boolean,
    val onComposerOpen: (Boolean) -> Unit,
) {
    val c get() = state.content
    val row get() = state.row
    val accepts get() = state.phase.acceptsInput
    val irreversible get() = c.chip == ChipKind.IRREVERSIBLE

    private val pinsAsk: Boolean
        get() = (c.askKind == DecisionContent.AskKind.COMMAND || c.askKind == DecisionContent.AskKind.EDIT) && c.section == NowRow.Section.DECIDE &&
            c.informational == null && row.action(RowAction.Kind.OPEN_ON_MAC) == null

    /** Roomy sheets: what will be done stays in view with the controls that do it. */
    @Composable
    fun Pinned() {
        Column(Modifier.fillMaxSize().imePadding()) {
            val scroll = rememberScrollState()
            Box(Modifier.weight(1f)) {
                Column(Modifier.fillMaxSize().verticalScroll(scroll).padding(horizontal = NW.Space.xl).padding(top = 10.dp, bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    Header()
                    if (!pinsAsk) AskBlock()
                    c.screenNote?.let { ScreenNote(it) }
                    ReasonBlock()
                    OptionsBlock()
                    SecondaryLinks(linksToo = false)
                }
                // The scroll area ends in a fade where it meets the pinned command, so nothing reads as half-cut and
                // the fade says there is more above it.
                if (scroll.canScrollForward) {
                    val bg = decisionBackground(row)
                    Box(
                        Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(28.dp)
                            .background(Brush.verticalGradient(listOf(Color.Transparent, bg))),
                    )
                }
            }
            Column(Modifier.padding(horizontal = NW.Space.xl), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (pinsAsk) PinnedAsk()
                // The links sit with the command they are about, never half-hidden at the foot of the scroll area.
                SecondaryLinks(footerToo = false)
                previewText?.let { PreviewTip(); NWDeliveryPreview(it) }
                StatusBlock()
            }
            Column(Modifier.padding(horizontal = NW.Space.xl).padding(top = 8.dp, bottom = NW.Space.lg).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(10.dp)) { Controls() }
        }
    }

    /** Short sheets: one scroll, in reading order. The controls come last, directly under the command and the preview. */
    @Composable
    fun Flowing() {
        Column(Modifier.fillMaxSize().imePadding().verticalScroll(rememberScrollState()).padding(horizontal = NW.Space.xl).padding(top = 10.dp, bottom = NW.Space.lg).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Header()
            AskBlock()
            c.screenNote?.let { ScreenNote(it) }
            previewText?.let { PreviewTip(); NWDeliveryPreview(it) }
            StatusBlock()
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) { Controls() }
            ReasonBlock()
            OptionsBlock()
            SecondaryLinks()
        }
    }

    @Composable
    private fun PinnedAsk() {
        Column(Modifier.heightIn(max = 132.dp * LocalDensity.current.fontScale.coerceAtMost(1.4f)).verticalScroll(rememberScrollState())) { AskBlock() }
    }

    // region Header and ask

    @Composable
    private fun Header() {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                NWChip(c.chip, pill = true)
                Spacer(Modifier.weight(1f))
                Row(
                    Modifier.size(48.dp).clip(RoundedCornerShape(24.dp)).clickable(role = Role.Button, onClickLabel = "Close", onClick = actions.close),
                    horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
                ) { Icon(Icons.Outlined.Close, "Close", tint = NW.Palette.textSecondary.color, modifier = Modifier.size(18.dp)) }
            }
            Text(
                "${c.project} · ${c.agent} · ${row.waitingText(state.now)}", style = NW.Typo.caption, color = NW.Palette.textTertiary.color, maxLines = 2,
                modifier = Modifier.offset(y = (-6).dp),
            )
            Text(c.headline, style = NW.Typo.hero, color = NW.Palette.textPrimary.color, modifier = Modifier.semantics { heading() })
            c.blurb?.let { Text(it, style = NW.Typo.subline, color = NW.Palette.textSecondary.color) }
        }
    }

    @Composable
    private fun AskBlock() {
        val shape = RoundedCornerShape(NW.Radius.inset)
        when (c.askKind) {
            DecisionContent.AskKind.COMMAND, DecisionContent.AskKind.EDIT -> Column(
                Modifier.fillMaxWidth().clip(shape).background(NW.Palette.inset.color).border(1.dp, Color.White.copy(alpha = 0.07f), shape).padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                val askColor = if (irreversible) NW.Palette.red.mixed(NW.Palette.white, 0.2) else NW.Palette.textPrimary
                SelectionContainer {
                    Text(
                        buildAnnotatedString {
                            withStyle(SpanStyle(color = (if (irreversible) NW.Palette.red else NW.Palette.textTertiary).color)) { append(if (c.askKind == DecisionContent.AskKind.COMMAND) "$ " else "✎ ") }
                            withStyle(SpanStyle(color = askColor.color)) { append(c.ask) }
                        },
                        style = NW.Typo.mono,
                    )
                }
                c.detail?.let { Text(it, style = NW.Typo.monoMicro, color = NW.Palette.textTertiary.color) }
                c.cwd?.let { Text(it, style = NW.Typo.monoMicro, color = NW.Palette.textQuiet.color) }
            }
            else -> Column(Modifier.fillMaxWidth().clip(shape).background(NW.Palette.inset.color).padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                c.turnSummary?.let { s ->
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) { TurnSummaryChips.parse(s).forEach { NWTurnChip(it) } }
                }
                SelectionContainer { Text(c.ask.ifEmpty { "No details were sent with this page." }, style = NW.Typo.body, color = NW.Palette.textPrimary.color) }
                c.cwd?.let { Text(it, style = NW.Typo.monoMicro, color = NW.Palette.textQuiet.color) }
            }
        }
    }

    @Composable
    private fun ScreenNote(text: String) {
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(NW.Radius.inset)).background(NW.Palette.amber.opacity(0.10).color).padding(12.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Outlined.VisibilityOff, null, tint = NW.Palette.amber.color, modifier = Modifier.size(18.dp))
            Text(text, style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color)
        }
    }

    /** Why it is this class, and what undoing would look like. A hint, never a "safe" badge. */
    @Composable
    private fun ReasonBlock() {
        if (row.reversibility == null || (c.reason.isEmpty() && c.undoNote == null)) return
        Column(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (c.tags.isNotEmpty()) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    for (t in c.tags) Text(
                        t.raw, style = NW.Typo.monoMicro, color = NW.Palette.textSecondary.color,
                        modifier = Modifier.clip(RoundedCornerShape(7.dp)).background(Color.White.copy(alpha = 0.07f)).padding(horizontal = 8.dp, vertical = 4.dp),
                    )
                }
            }
            if (c.reason.isNotEmpty()) {
                Text(
                    buildAnnotatedString {
                        withStyle(SpanStyle(color = NW.Palette.textQuiet.color, fontWeight = androidx.compose.ui.text.font.FontWeight.ExtraBold, letterSpacing = androidx.compose.ui.unit.TextUnit(1f, androidx.compose.ui.unit.TextUnitType.Sp))) { append("WHY  ") }
                        append(c.reason)
                    },
                    style = NW.Typo.caption, color = NW.Palette.textSecondary.color,
                )
            }
            c.undoNote?.let { Text(it, style = NW.Typo.caption, color = NW.Palette.textTertiary.color) }
        }
    }

    /**
     * The prompt's own options, as read from the page. Shown, not offered: Approve types 1 and nothing else does.
     * An option that would stand for the future ("don't ask again") reads "Open in terminal to choose this".
     */
    @Composable
    private fun OptionsBlock() {
        if (c.options.size < 2) return
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("THE PROMPT OFFERS", style = NW.Typo.label, color = NW.Palette.textQuiet.color)
            for (o in c.options) {
                Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top) {
                    Text("${o.number}", style = NW.Typo.monoSmall, color = NW.Palette.textQuiet.color, modifier = Modifier.width(14.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(o.text, style = NW.Typo.body, color = (if (o.isStanding) NW.Palette.textTertiary else NW.Palette.textSecondary).color)
                        o.instead?.let { Text(it, style = NW.Typo.monoMicro, color = NW.Palette.amber.color) }
                    }
                }
            }
        }
    }

    @Composable
    private fun PreviewTip() {
        val tip = state.tip ?: return
        LaunchedEffect(tip) { actions.tipShown(tip) }
        NWTipCallout(tip.text(state.biometry), symbol = tip.symbol, pointerUp = false, onDismiss = { actions.dismissTip(tip) })
    }

    /** The delivery preview of the action in focus: Tell it instead while the composer is open, else the approve line, else the first action that sends. */
    private val previewText: String?
        get() {
            if (composerOpen) row.action(RowAction.Kind.TELL_INSTEAD)?.preview?.let { return it }
            // The answer picker carries its own preview (the review step names exactly what will be chosen).
            if (state.ask != null && c.chip == ChipKind.QUESTION) return null
            // Nothing will be typed: the controls below already say why, so a second line adds nothing.
            if (row.action(RowAction.Kind.OPEN_ON_MAC) != null) return null
            return row.focusPreview
        }

    @Composable
    private fun StatusBlock() {
        val receipt = state.receipt
        if (receipt != null && !receipt.isEmpty) {
            // The Receipt thread: arm, sent, then typed and verified only on the Mac's word.
            NWReceiptThreadView(receipt, onTap = actions.cancel)
        } else if (state.outcome != CardOutcome.None && (accepts || state.pending != null)) {
            OutcomeStrip()
        }
        // The line adds the detail ("typed into tmux pane %3"); a failure the thread already says is not said twice.
        val s = state.phase.statusLine(state.legacyRelay)
        if (s != null && !(receipt?.frame(state.now)?.word == s.text)) {
            NWReceiptLine(s.text, failed = s.tone == DecisionPhase.Tone.PROBLEM || s.tone == DecisionPhase.Tone.WARN)
        }
    }

    @Composable
    private fun OutcomeStrip() {
        when (val o = state.outcome) {
            is CardOutcome.Problem -> NWReceiptLine(o.why, failed = true)
            is CardOutcome.Arming -> NWReceiptLine("Sending in a moment · tap to cancel", failed = false, modifier = Modifier.clickable(onClick = actions.cancel))
            CardOutcome.Sending -> NWReceiptLine("Sending…")
            is CardOutcome.Delivered -> NWReceiptLine("Delivered · ${o.detail}")
            CardOutcome.None -> Unit
        }
    }

    /** The hold ring's burst belongs to one Irreversible approve that passed biometrics (the pending action starts at that moment). */
    private val committedAt: java.time.Instant?
        get() {
            if (!irreversible) return null
            state.pending?.let { if (ActionGate.requiresBiometrics(it.kind, it.commit)) return it.startedAt }
            return if (accepts) null else state.holdCommittedAt
        }

    @Composable
    private fun SecondaryLinks(linksToo: Boolean = true, footerToo: Boolean = true) {
        val clip = androidx.compose.ui.platform.LocalClipboardManager.current
        if (linksToo) FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(0.dp)) {
            if (state.hasSession) LinkButton("Open session", Icons.Outlined.Terminal, actions.openSession)
            if (c.turnSummary != null) LinkButton("View changes", Icons.Outlined.FindInPage, actions.viewChanges)
            LinkButton("Copy", Icons.Outlined.ContentCopy) { clip.setText(AnnotatedString(c.rawContext)); actions.copy() }
        }
        if (footerToo) Text(c.footer, style = NW.Typo.caption, color = NW.Palette.textQuiet.color)
    }

    @Composable
    private fun LinkButton(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector, onClick: () -> Unit) {
        Row(
            Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(12.dp)).clickable(role = Role.Button, onClick = onClick).padding(horizontal = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(icon, null, tint = NW.Palette.textSecondary.color, modifier = Modifier.size(16.dp))
            Text(label, style = NW.Typo.captionStrong, color = NW.Palette.textSecondary.color)
        }
    }

    // endregion

    // region Controls

    @Composable
    fun Controls() {
        val busy = state.pending != null || !accepts
        val info = c.informational
        val committed = committedAt
        when {
            info != null -> {
                Text(info, style = NW.Typo.caption, color = NW.Palette.textSecondary.color, modifier = Modifier.fillMaxWidth())
                NWButton("Close", actions.close, Modifier.fillMaxWidth())
            }
            row.action(RowAction.Kind.OPEN_ON_MAC) != null -> {
                Text(
                    if (c.screenNote != null) "Answer this one on your Mac." else (row.action(RowAction.Kind.OPEN_ON_MAC)?.preview ?: "Page can't type here. Answer this one on your Mac."),
                    style = NW.Typo.caption, color = NW.Palette.textSecondary.color, modifier = Modifier.fillMaxWidth(),
                )
                if (state.hasSession) NWButton("Open session", actions.openSession, Modifier.fillMaxWidth())
            }
            committed != null -> Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                NWHoldRing(HoldRingSpec.irreversible, onComplete = {}, burstAt = committed)
                Text("Approved with ${state.biometry}", style = NW.Typo.bodyStrong, color = NW.Palette.textSecondary.color)
            }
            !busy || state.phase == DecisionPhase.Unconfirmed -> when {
                c.section == NowRow.Section.DECIDE && c.chip == ChipKind.QUESTION -> QuestionControls()
                c.section == NowRow.Section.DECIDE -> ApprovalControls()
                c.section == NowRow.Section.LOOK -> LookControls()
                else -> ReviewControls()
            }
        }
    }

    @Composable
    private fun QuestionControls() {
        val ask = state.ask
        if (ask != null && !composerOpen) {
            NWAnswerHost(
                ask, delivery = state.askDelivery, route = c.route, mac = state.macName, agent = c.agent, fixedSheet = state.fixedSheet,
                showsChip = false, viaHook = state.askViaHook, onSubmit = actions.submitAnswers,
            )
            NWButton("Write a reply instead…", { onComposerOpen(true) }, Modifier.fillMaxWidth())
        } else {
            Composer("Answer", "Type your answer…", alwaysOpen = ask == null)
        }
    }

    @Composable
    private fun ApprovalControls() {
        if (composerOpen) {
            Composer("Send", "Deny with instructions…", alwaysOpen = false)
            return
        }
        val approve = row.action(RowAction.Kind.APPROVE)
        if (irreversible && approve != null) {
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                NWHoldRing(HoldRingSpec.irreversible, onComplete = actions.holdComplete, fixedProgress = state.fixedHold)
                Text(
                    HoldRingSpec.prompt(state.fixedHold ?: 0.0, state.biometry).replaceFirstChar { it.uppercase() }, style = NW.Typo.bodyStrong,
                    color = NW.Palette.red.mixed(NW.Palette.white, 0.35).color, modifier = Modifier.semantics { contentDescription = "Hold the ring, then confirm with your ${state.biometry}." },
                )
            }
        } else if (approve != null) {
            NWButton(approve.label, actions.approve, Modifier.fillMaxWidth(), kind = NWButtonKind.BRIGHT)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
            row.action(RowAction.Kind.DENY)?.let { NWButton(it.label, actions.deny, Modifier.weight(1f)) }
            if (row.action(RowAction.Kind.TELL_INSTEAD) != null && c.canTell) NWButton("Tell it instead…", { onComposerOpen(true) }, Modifier.weight(1f))
        }
    }

    @Composable
    private fun LookControls() {
        if (composerOpen) {
            Composer("Send", if (c.stoppable) "Tell it what to do instead…" else "Tell it what to do next…", alwaysOpen = false)
            return
        }
        if (c.stoppable && row.action(RowAction.Kind.STOP) != null) NWButton("Stop it", actions.stop, Modifier.fillMaxWidth())
        if (row.action(RowAction.Kind.TELL_INSTEAD) != null) NWButton("Steer…", { onComposerOpen(true) }, Modifier.fillMaxWidth(), kind = NWButtonKind.AMBER)
        Text(
            if (c.stoppable) "Stop presses Esc in the session. A message is queued until its current step ends." else "Your message is typed into the session that started it.",
            style = NW.Typo.caption, color = NW.Palette.textTertiary.color, modifier = Modifier.fillMaxWidth(),
        )
    }

    @Composable
    private fun ReviewControls() {
        if (composerOpen) {
            Composer("Send", "Tell it what to do next…", alwaysOpen = false)
            return
        }
        if (row.action(RowAction.Kind.CARRY_ON) != null) NWButton("Looks good ✦", actions.carryOn, Modifier.fillMaxWidth(), kind = NWButtonKind.BRIGHT)
        if (row.action(RowAction.Kind.TELL_INSTEAD) != null) NWButton("Steer…", { onComposerOpen(true) }, Modifier.fillMaxWidth())
    }

    /** The composer. Locked until asked for: a written reply to a waiting prompt is Esc, then the text, then Return, and the label says so. */
    @Composable
    private fun Composer(label: String, placeholder: String, alwaysOpen: Boolean) {
        val focus = remember { FocusRequester() }
        LaunchedEffect(Unit) { if (!alwaysOpen) runCatching { focus.requestFocus() } }
        val blank = draft.trim().isEmpty()
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text((row.action(RowAction.Kind.TELL_INSTEAD)?.preview?.split(" · ")?.firstOrNull() ?: "Your message").uppercase(), style = NW.Typo.label, color = NW.Palette.textQuiet.color, modifier = Modifier.weight(1f))
                if (!alwaysOpen) Text(
                    "Cancel", style = NW.Typo.captionStrong, color = NW.Palette.textSecondary.color,
                    modifier = Modifier.heightIn(min = 48.dp).clickable(role = Role.Button) { onComposerOpen(false); onDraft("") }.padding(horizontal = 8.dp).wrapCenter(),
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Bottom) {
                NWTextField(draft, onDraft, placeholder, Modifier.weight(1f), focus = focus)
                NWButton(label, { actions.send(draft) }, Modifier.width(96.dp), kind = NWButtonKind.BRIGHT, enabled = !blank)
            }
        }
    }

    private fun Modifier.wrapCenter(): Modifier = this

    // endregion
}
