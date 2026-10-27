package app.page.android.ui.nw.components

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.page.android.data.AnswerDraftStore
import app.page.android.model.AnswerSheet
import app.page.android.model.AskOption
import app.page.android.model.ChipKind
import app.page.android.model.DeliveryPreview
import app.page.android.model.SentSessionCommand
import app.page.android.model.SessionAsk
import app.page.android.model.SessionCommandKind
import app.page.android.model.SessionDeliveryState
import app.page.android.ui.nw.theme.LocalReduceMotion
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba

/**
 * Answering the terminal's questions ([AnswerSheet]): the card that sits in the Story and over the Screen lens,
 * and in the Decision sheet. One question at a time: tap to tick (a round mark for one answer, a square for
 * several), "Other" opens a text field, a single answer moves on by itself, Back and the progress strip go back,
 * and a last step lists every answer above the delivery preview and "Submit all". Nothing is typed until then.
 * The card owns no state of its own: [sheet] is the shared draft ([AnswerDraftStore]) and [edit] changes it, so
 * the Story, the Screen lens and the sheet show the same one. (iOS NWAnswerCard.)
 */
@Composable
fun NWAnswerCard(
    sheet: AnswerSheet,
    edit: (AnswerSheet.() -> Unit) -> Unit,
    modifier: Modifier = Modifier,
    /** Where the newest answers for this question stand (sending, answered, refused...). */
    delivery: SentSessionCommand? = null,
    route: String? = null,
    mac: String = "",
    agent: String = "Claude",
    compact: Boolean = false,
    /** False where the surrounding screen already says "Question" (the Decision sheet). */
    showsChip: Boolean = true,
    /** The answers go as text through Claude's question hook (nothing is pressed). */
    viaHook: Boolean = false,
    onSubmit: () -> Unit = {},
) {
    val amber = NW.Palette.amber
    val sending = delivery?.state?.isPending == true
    val answered = delivery?.state.let { it is SessionDeliveryState.Typed || it is SessionDeliveryState.Queued }
    val retrying = delivery?.state.let { it is SessionDeliveryState.Refused || it is SessionDeliveryState.Failed || it == SessionDeliveryState.NoAnswer }
    val radius = if (compact) 22.dp else NW.Radius.card
    val reduce = LocalReduceMotion.current
    val shape = RoundedCornerShape(radius)
    Column(
        modifier.fillMaxWidth().clip(shape)
            .then(if (compact) Modifier.background(NW.Palette.backgroundDeep.color) else Modifier)
            .background(NW.Palette.surface.mixed(amber.opacity(1.0), 0.07).color, shape)
            .border(1.dp, amber.opacity(0.28).color, shape)
            // Over the terminal it is only as tall as it needs, scrolling past that, so the screen above stays readable.
            .then(if (compact) Modifier.heightIn(max = 400.dp).verticalScroll(androidx.compose.foundation.rememberScrollState()) else Modifier)
            .padding(if (compact) 14.dp else NW.Space.lg),
        verticalArrangement = Arrangement.spacedBy(if (compact) 8.dp else 10.dp),
    ) {
        // Top line
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (showsChip) NWChip(ChipKind.QUESTION, pill = true)
            Text(positionText(sheet, answered), style = NW.Typo.caption, color = NW.Palette.textTertiary.color, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            if (!answered && !sending && (sheet.isReview || (sheet.currentIndex ?: 0) > 0)) {
                Row(
                    Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(12.dp)).clickable(role = Role.Button, onClickLabel = "Go back one step. Your answers are kept.") { edit { back() } }.padding(horizontal = 10.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Icon(Icons.AutoMirrored.Outlined.ArrowBack, null, tint = NW.Palette.textSecondary.color, modifier = Modifier.size(16.dp))
                    Text("Back", style = NW.Typo.captionStrong, color = NW.Palette.textSecondary.color)
                }
            }
        }
        // Progress
        if ((sheet.count > 1 || sheet.isReview) && !answered) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                for (q in 0 until sheet.count) {
                    val q0 = sheet.ask.questions[q]
                    Segment(
                        filled = sheet.isAnswered(q), on = sheet.currentIndex == q, reachable = sheet.isReachable(q) && !sending, modifier = Modifier.weight(1f),
                        label = "Question ${q + 1} of ${sheet.count}" + (if (q0.header.isEmpty()) "" else ", ${q0.header}"), value = if (sheet.isAnswered(q)) "answered" else "not answered",
                    ) { edit { go(q) } }
                }
                Segment(filled = sheet.canSubmit, on = sheet.isReview, reachable = sheet.canSubmit && !sending, modifier = Modifier.weight(1f), label = "Review", value = "") { edit { goToReview() } }
            }
        }
        if (answered) {
            AnsweredBlock(sheet, delivery, agent)
        } else {
            AnimatedContent(
                targetState = sheet.step,
                transitionSpec = {
                    if (reduce) fadeIn(tween(0)) togetherWith fadeOut(tween(0))
                    else (slideInHorizontally(tween(200)) { it / 4 } + fadeIn(tween(200))) togetherWith fadeOut(tween(120))
                },
                label = "answer-step",
            ) { _ ->
                if (sheet.isReview) ReviewStep(sheet, edit, route, mac, viaHook, compact, sending)
                else sheet.currentIndex?.let { QuestionStep(sheet, edit, it, compact, sending) }
            }
            // Footer: how the last send went, and the button that moves on.
            DeliveryNote(delivery, mac, agent)
            if (sheet.isReview) {
                NWButton(
                    if (retrying) "Try again" else "Submit all", onSubmit, Modifier.fillMaxWidth().semantics { stateDescription = sheet.previewLine(route, mac, viaHook) },
                    kind = NWButtonKind.BRIGHT, enabled = sheet.canSubmit && !sending,
                )
            } else {
                val q = sheet.currentIndex
                if (q != null && (sheet.ask.questions[q].multi || sheet.otherChosen(q))) NextButton(sheet, edit, q, sending)
            }
        }
    }
}

private fun positionText(sheet: AnswerSheet, answered: Boolean): String {
    if (answered) return "Answered"
    if (sheet.isReview) return "Review · ${sheet.count} answer${if (sheet.count == 1) "" else "s"}"
    val q = sheet.currentIndex ?: 0
    return "Question ${q + 1} of ${sheet.count} · choose ${if (sheet.ask.questions[q].multi) "any" else "one"}"
}

@Composable
private fun Segment(filled: Boolean, on: Boolean, reachable: Boolean, modifier: Modifier, label: String, value: String, onClick: () -> Unit) {
    Box(
        modifier.heightIn(min = 32.dp).clickable(enabled = reachable, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label; if (value.isNotEmpty()) stateDescription = value },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier.fillMaxWidth().height(5.dp).clip(CircleShape)
                .background(if (on) NW.Palette.amber.color else if (filled) NW.Palette.teal.opacity(0.7).color else Color.White.copy(alpha = 0.14f)),
        )
    }
}

@Composable
private fun QuestionStep(sheet: AnswerSheet, edit: (AnswerSheet.() -> Unit) -> Unit, q: Int, compact: Boolean, sending: Boolean) {
    val question = sheet.ask.questions[q]
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(if (compact) 8.dp else 12.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            if (question.header.isNotEmpty()) Text(question.header.uppercase(), style = NW.Typo.label, color = NW.Palette.amber.color)
            Text(question.text, style = if (compact) NW.Typo.bodyStrong else NW.Typo.title, color = NW.Palette.textPrimary.color, modifier = Modifier.semantics { heading() })
        }
        Column(Modifier.alpha(if (sending) 0.6f else 1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            question.options.forEachIndexed { i, option -> OptionRow(sheet, edit, q, i, option, question.multi, compact, sending) }
            if (sheet.allowsOther) OtherRow(sheet, edit, q, question.multi, sending)
            else Text("To answer in your own words, write a reply instead.", style = NW.Typo.caption, color = NW.Palette.textTertiary.color, modifier = Modifier.padding(horizontal = 4.dp))
        }
    }
}

@Composable
private fun Mark(on: Boolean, multi: Boolean) {
    val c = if (on) NW.Palette.teal else NW.Palette.textQuiet
    Box(Modifier.size(24.dp).clearAndSetSemantics {}, contentAlignment = Alignment.Center) {
        if (multi) {
            Box(Modifier.size(22.dp).clip(RoundedCornerShape(6.dp)).background(if (on) NW.Palette.teal.opacity(0.2).color else Color.Transparent).border(2.dp, c.color, RoundedCornerShape(6.dp)))
            if (on) Icon(Icons.Outlined.Check, null, tint = NW.Palette.teal.color, modifier = Modifier.size(14.dp))
        } else {
            Box(Modifier.size(22.dp).clip(CircleShape).border(2.dp, c.color, CircleShape))
            if (on) Box(Modifier.size(12.dp).clip(CircleShape).background(NW.Palette.teal.color))
        }
    }
}

private fun rowBg(on: Boolean): Pair<Color, Color> =
    if (on) NW.Palette.teal.opacity(0.10).color to NW.Palette.teal.opacity(0.55).color else Color.White.copy(alpha = 0.05f) to Color.White.copy(alpha = 0.07f)

@Composable
private fun OptionRow(sheet: AnswerSheet, edit: (AnswerSheet.() -> Unit) -> Unit, q: Int, i: Int, option: AskOption, multi: Boolean, compact: Boolean, sending: Boolean) {
    val on = sheet.isPicked(q, i)
    val (bg, rim) = rowBg(on)
    val shape = RoundedCornerShape(NW.Radius.inset)
    Row(
        Modifier.fillMaxWidth().heightIn(min = if (compact) 44.dp else 48.dp).clip(shape).background(bg).border(1.dp, rim, shape)
            .clickable(enabled = !sending, role = Role.Button, onClickLabel = if (multi) "Ticks or unticks it" else "Picks it and moves to the next step") { edit { tap(i) } }
            .padding(horizontal = 14.dp, vertical = 8.dp)
            .semantics(mergeDescendants = true) { selected = on; stateDescription = if (on) "selected" else "not selected" },
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top,
    ) {
        Mark(on, multi)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(option.label, style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color)
            if (option.detail.isNotEmpty()) Text(option.detail, style = NW.Typo.caption, color = NW.Palette.textTertiary.color, maxLines = if (compact) 1 else 3, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun OtherRow(sheet: AnswerSheet, edit: (AnswerSheet.() -> Unit) -> Unit, q: Int, multi: Boolean, sending: Boolean) {
    val on = sheet.otherChosen(q)
    val (bg, rim) = rowBg(on)
    val shape = RoundedCornerShape(NW.Radius.inset)
    val focus = remember { FocusRequester() }
    LaunchedEffect(on) { if (on) runCatching { focus.requestFocus() } }
    Column(Modifier.fillMaxWidth().clip(shape).background(bg).border(1.dp, rim, shape).padding(horizontal = 14.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 36.dp).clickable(enabled = !sending, role = Role.Button, onClickLabel = "Opens a box to type your own answer") { edit { toggleOther() } }
                .semantics(mergeDescendants = true) { selected = on; contentDescription = "Other" },
            horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically,
        ) {
            Mark(on, multi)
            Text("Other…", style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color, modifier = Modifier.weight(1f))
            Icon(Icons.Outlined.Edit, null, tint = NW.Palette.textTertiary.color, modifier = Modifier.size(16.dp))
        }
        if (on) {
            Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Color.Black.copy(alpha = 0.35f)).border(1.dp, Color.White.copy(alpha = 0.10f), RoundedCornerShape(12.dp)).padding(horizontal = 12.dp, vertical = 11.dp)) {
                val text = sheet.otherText(q)
                if (text.isEmpty()) Text("Type your answer", style = NW.Typo.body, color = NW.Palette.textQuiet.color)
                BasicTextField(
                    text, { v -> edit { setOther(v) } }, Modifier.fillMaxWidth().focusRequester(focus).semantics { contentDescription = "Your own answer" },
                    textStyle = NW.Typo.body.copy(color = NW.Palette.textPrimary.color), cursorBrush = SolidColor(NW.Palette.teal.color),
                    keyboardOptions = KeyboardOptions(imeAction = if (multi) ImeAction.Done else ImeAction.Next),
                    keyboardActions = KeyboardActions(onNext = { edit { commitOther() } }, onDone = {}),
                )
            }
        }
    }
}

@Composable
private fun NextButton(sheet: AnswerSheet, edit: (AnswerSheet.() -> Unit) -> Unit, q: Int, sending: Boolean) {
    val ready = sheet.isAnswered(q) && !sheet.otherNeedsText(q)
    val last = q == sheet.count - 1 || (0 until sheet.count).all { it == q || sheet.isAnswered(it) }
    NWButton(if (last) "Review answers" else "Next", { edit { next() } }, Modifier.fillMaxWidth().semantics { stateDescription = if (ready) "Moves on. Nothing is sent yet." else "Choose an answer first" }, kind = NWButtonKind.BRIGHT, enabled = ready && !sending)
}

@Composable
private fun ReviewStep(sheet: AnswerSheet, edit: (AnswerSheet.() -> Unit) -> Unit, route: String?, mac: String, viaHook: Boolean, compact: Boolean, sending: Boolean) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(if (compact) 8.dp else 12.dp)) {
        Text("Check your answers", style = if (compact) NW.Typo.bodyStrong else NW.Typo.title, color = NW.Palette.textPrimary.color, modifier = Modifier.semantics { heading() })
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            for (row in sheet.reviewRows()) {
                val shape = RoundedCornerShape(NW.Radius.inset)
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 52.dp).clip(shape).background(Color.White.copy(alpha = 0.05f))
                        .clickable(enabled = !sending, role = Role.Button, onClickLabel = "Opens this question to change it") { edit { go(row.index) } }
                        .padding(horizontal = 14.dp, vertical = 10.dp)
                        .semantics(mergeDescendants = true) { contentDescription = "${row.header}. ${row.question} Your answer: ${row.answer}" },
                    horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top,
                ) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(row.header.uppercase(), style = NW.Typo.label, color = NW.Palette.textQuiet.color)
                        if (!compact) Text(row.question, style = NW.Typo.caption, color = NW.Palette.textTertiary.color, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Text(row.answer, style = NW.Typo.bodyStrong, color = (if (sheet.isAnswered(row.index)) NW.Palette.textPrimary else NW.Palette.amber).color)
                    }
                    Icon(Icons.Outlined.Edit, null, tint = NW.Palette.textQuiet.color, modifier = Modifier.size(16.dp))
                }
            }
        }
        // The delivery preview in full: what will be chosen, where, on which Mac.
        val text = sheet.previewLine(route, mac, viaHook)
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(NW.Radius.inset)).background(Color.White.copy(alpha = 0.05f)).padding(horizontal = 12.dp, vertical = 10.dp).clearAndSetSemantics { contentDescription = text },
            horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top,
        ) {
            Icon(nwIcon("keyboard"), null, tint = NW.Palette.textTertiary.color, modifier = Modifier.size(18.dp))
            Text(text, style = NW.Typo.monoSmall, color = NW.Palette.textSecondary.color, modifier = Modifier.weight(1f))
        }
    }
}

@Composable
private fun DeliveryNote(delivery: SentSessionCommand?, mac: String, agent: String) {
    val d = delivery ?: return
    when (val s = d.state) {
        SessionDeliveryState.Sending -> Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(Modifier.size(16.dp), color = NW.Palette.textSecondary.color, strokeWidth = 2.dp)
            Text("Sending your answers to ${DeliveryPreview.macLabel(mac)}…", style = NW.Typo.caption, color = NW.Palette.textSecondary.color)
        }
        is SessionDeliveryState.Refused, is SessionDeliveryState.Failed, SessionDeliveryState.NoAnswer ->
            Row(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(NW.Palette.amber.opacity(0.10).color).padding(horizontal = 12.dp, vertical = 10.dp).semantics(mergeDescendants = true) {},
                horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top,
            ) {
                Icon(Icons.Outlined.WarningAmber, null, tint = NW.Palette.amber.color, modifier = Modifier.size(18.dp))
                Text(s.explanation(SessionCommandKind.ANSWER, agent) ?: "", style = NW.Typo.caption, color = NW.Palette.textSecondary.color)
            }
        else -> Unit
    }
}

@Composable
private fun AnsweredBlock(sheet: AnswerSheet, delivery: SentSessionCommand?, agent: String) {
    Column(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.CheckCircle, null, tint = NW.Palette.teal.color, modifier = Modifier.size(22.dp))
            Text("Answered", style = NW.Typo.title, color = NW.Palette.textPrimary.color)
        }
        Text(sheet.summaryLine, style = NW.Typo.body, color = NW.Palette.textSecondary.color)
        delivery?.state?.explanation(SessionCommandKind.ANSWER, agent)?.let { Text(it, style = NW.Typo.monoMicro, color = NW.Palette.textTertiary.color) }
    }
}

/** The card over the shared draft store, so the Story, the Screen lens and the Decision sheet show one draft. [fixedSheet] draws a given draft instead (the render harness). */
@Composable
fun NWAnswerHost(
    ask: SessionAsk,
    modifier: Modifier = Modifier,
    delivery: SentSessionCommand? = null,
    route: String? = null,
    mac: String = "",
    agent: String = "Claude",
    compact: Boolean = false,
    fixedSheet: AnswerSheet? = null,
    showsChip: Boolean = true,
    viaHook: Boolean = false,
    onSubmit: (AnswerSheet) -> Unit = {},
) {
    val drafts by AnswerDraftStore.sheets.collectAsStateWithLifecycleCompat()
    val sheet = fixedSheet ?: (drafts[ask.id]?.takeIf { it.ask == ask && it.allowsOther == !viaHook } ?: AnswerSheet(ask, !viaHook))
    NWAnswerCard(
        sheet, { change -> AnswerDraftStore.edit(ask, !viaHook, change) }, modifier, delivery, route, mac, agent, compact, showsChip, viaHook, onSubmit = { onSubmit(sheet) },
    )
}
