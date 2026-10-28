package app.page.android.ui.nw.room

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.HelpOutline
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.VerifiedUser
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.page.android.model.AgentCharacter
import app.page.android.model.ChipKind
import app.page.android.model.HeldDelete
import app.page.android.model.HeldMessages
import app.page.android.model.QueuedDelete
import app.page.android.model.NowRow
import app.page.android.model.PhotoText
import app.page.android.model.SentSessionCommand
import app.page.android.model.SessionCommandKind
import app.page.android.model.SessionDeliveryState
import app.page.android.model.StoryBlock
import app.page.android.model.StoryStep
import app.page.android.ui.nw.components.NWAnimated
import app.page.android.ui.nw.components.NWSpinner
import app.page.android.ui.nw.components.NWAnswerHost
import app.page.android.ui.nw.components.NWReceiptAction
import app.page.android.ui.nw.components.nwIcon
import app.page.android.ui.nw.now.NWDecideCard
import app.page.android.ui.nw.now.NWLookCard
import app.page.android.ui.nw.now.NWQuestionCard
import app.page.android.ui.nw.now.NWUndoableRow
import app.page.android.ui.nw.now.RowActions
import app.page.android.ui.nw.now.RowStatus
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba
import kotlin.math.max
import kotlin.math.sin
import kotlinx.coroutines.launch

/**
 * The Story lens: the transcript as a readable thread. Your messages are right-aligned bubbles (stamped "from
 * phone" when they came from here), the agent's words sit on the left beside its mark, consecutive tool calls fold
 * into one "N STEPS" card, and an open decision is pinned inline as the same card Now uses. The wire has no tool
 * results, so a step shows only what was done, never an invented count or exit code. (iOS NWRoomStory.)
 */
@Composable
fun NWRoomStory(data: SessionRoomData, actions: SessionRoomActions, modifier: Modifier = Modifier) {
    val state = rememberLazyListState()
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var opened by remember { mutableStateOf(setOf<String>()) }
    val signature = data.story.joinToString("|") { it.id } + data.story.size + (data.liveLine ?: "") + (data.pageRow?.id ?: "")
    val atBottom by remember { derivedStateOf { !state.canScrollForward } }
    // Items: truncated note, privacy card, empty state, blocks, live line, pinned page, timing note.
    val total = data.story.size + 6
    LaunchedEffect(Unit) { state.scrollToItem(Int.MAX_VALUE.coerceAtMost(maxOf(0, total))) }
    LaunchedEffect(signature) { if (atBottom || state.firstVisibleItemIndex == 0) state.animateScrollToItem(Int.MAX_VALUE) }
    Box(modifier.fillMaxSize()) {
        LazyColumn(state = state, contentPadding = PaddingValues(start = NW.Space.lg, end = NW.Space.lg, top = 10.dp, bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            if (data.truncated) item { Text("Earlier messages aren't shown", style = NW.Typo.caption, color = NW.Palette.textQuiet.color, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth()) }
            if (data.character.kind == AgentCharacter.Kind.LOCAL) data.character.privacyTitle?.let { t -> item { PrivacyCard(t, data.character) } }
            if (data.story.isEmpty()) item {
                Column(Modifier.fillMaxWidth().padding(top = 60.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (data.storyLoading) CircularProgressIndicator(Modifier.size(24.dp), color = NW.Palette.textSecondary.color, strokeWidth = 2.dp)
                    Text(data.emptyStory ?: "Nothing in this session yet.", style = NW.Typo.body, color = NW.Palette.textTertiary.color, textAlign = TextAlign.Center)
                }
            }
            itemsIndexed(data.story, key = { _, b -> b.id }) { i, block -> BlockView(block, i == data.story.lastIndex, data, actions, opened) { id -> opened = if (id in opened) opened - id else opened + id } }
            data.liveLine?.let { line -> item { LiveLine(line) } }
            data.pageRow?.let { row -> item { Pinned(row, data, actions) } }
            data.timingNote?.let { n -> item { NWInfoNote(n) } }
        }
        if (!atBottom && data.story.isNotEmpty()) {
            Box(
                Modifier.align(Alignment.BottomEnd).padding(14.dp).size(48.dp).clip(CircleShape).background(NW.Palette.surfaceRaised.color)
                    .clickable(role = Role.Button, onClickLabel = "Jump to latest") { scope.launch { state.animateScrollToItem(Int.MAX_VALUE) } },
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Outlined.ArrowDownward, "Jump to latest", tint = NW.Palette.textPrimary.color, modifier = Modifier.size(22.dp)) }
        }
    }
}

@Composable
private fun BlockView(block: StoryBlock, isLast: Boolean, data: SessionRoomData, actions: SessionRoomActions, opened: Set<String>, toggle: (String) -> Unit) {
    when (block) {
        is StoryBlock.Divider -> Divider(block.label)
        is StoryBlock.User -> {
            // A message with photos reads as its words (Claude Code's "[Image #1]" chips are replaced by a chip of ours).
            val photos = PhotoText.count(block.entry.text, block.entry.images)
            UserBubble(if (photos > 0) PhotoText.caption(block.entry.text) else block.entry.text, photos, block.delivery, false, data, actions)
        }
        is StoryBlock.Pending -> UserBubble(block.command.text, block.command.photos, block.command, true, data, actions)
        is StoryBlock.Assistant -> {
            val clip = androidx.compose.ui.platform.LocalClipboardManager.current
            var menu by remember { mutableStateOf(false) }
            @OptIn(ExperimentalFoundationApi::class)
            Row(
                Modifier.fillMaxWidth().combinedClickable(onLongClickLabel = "Copy", onLongClick = { menu = true }, onClick = {}).semantics(mergeDescendants = true) { contentDescription = "${data.character.name}: ${block.entry.text}" },
                horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top,
            ) {
                NWAgentGlyph(data.character, 34.dp)
                SelectionContainer(Modifier.weight(1f)) { Text(block.entry.text, style = NW.Typo.subline.copy(fontSize = androidx.compose.ui.unit.TextUnit(16f, androidx.compose.ui.unit.TextUnitType.Sp)), color = NW.Palette.textPrimary.color) }
                DropdownMenu(menu, { menu = false }) { DropdownMenuItem({ Text("Copy") }, { menu = false; clip.setText(androidx.compose.ui.text.AnnotatedString(block.entry.text)); actions.copy(block.entry.text) }) }
            }
        }
        is StoryBlock.Steps -> StepsCard(block.steps, block.live, block.live || isLast || block.blockId in opened) { toggle(block.blockId) }
        is StoryBlock.Marker -> Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Text(block.text, style = NW.Typo.caption, color = NW.Palette.textTertiary.color, modifier = Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.06f)).padding(horizontal = 14.dp, vertical = 6.dp))
        }
    }
}

/** An open page, pinned inline: the same card as in Now. */
@Composable
private fun Pinned(row: NowRow, data: SessionRoomData, actions: SessionRoomActions) {
    val status = RowStatus(data.pageOutcome, data.pagePending, null)
    val ra = RowActions(
        open = { actions.openDecision(row.id) }, approve = { actions.approve(row) }, holdComplete = { actions.holdComplete(row) }, deny = { actions.deny(row) },
        looksGood = { actions.looksGood(row) }, steer = { actions.steer(row.id) }, cancel = { actions.cancel(row.id) },
    )
    when {
        row.section == NowRow.Section.DECIDE && row.chip == ChipKind.QUESTION -> {
            val ask = data.ask
            if (ask != null) NWAnswerHost(ask, delivery = data.askDelivery, route = data.answerRoute, mac = data.macName, agent = data.character.name, viaHook = data.askViaHook, onSubmit = actions.submitAnswers)
            else NWQuestionCard(row, data.now, false, { actions.openDecision(row.id) })
        }
        row.section == NowRow.Section.DECIDE && row.canSwipeApprove -> NWUndoableRow(row, data.now, status, ra)
        row.section == NowRow.Section.DECIDE -> NWDecideCard(row, data.now, status, ra, fixedHold = data.fixedHold)
        row.section == NowRow.Section.LOOK -> NWLookCard(row, data.now, status, ra)
        else -> Unit
    }
}

@Composable
private fun PrivacyCard(title: String, c: AgentCharacter) {
    val lime = c.tint
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(NW.Palette.surface.mixed(lime.opacity(1.0), 0.06).opacity(0.95).color).padding(14.dp).semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Outlined.VerifiedUser, null, tint = lime.color, modifier = Modifier.size(22.dp))
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color)
            c.privacyNote?.let { Text(it, style = NW.Typo.caption, color = NW.Palette.textSecondary.color) }
        }
    }
}

@Composable
private fun Divider(label: String) {
    Row(Modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = label }, horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.weight(1f).size(1.dp).background(Color.White.copy(alpha = 0.07f)))
        Text(label.uppercase(), style = NW.Typo.monoMicro, color = NW.Palette.textTertiary.color, maxLines = 1)
        Box(Modifier.weight(1f).size(1.dp).background(Color.White.copy(alpha = 0.07f)))
    }
}

/** Your message: right-aligned, with its delivery state underneath. A refusal says why and, for a waiting prompt, offers the decision. */
@Composable
private fun UserBubble(text: String, photos: Int, delivery: SentSessionCommand?, pending: Boolean, data: SessionRoomData, actions: SessionRoomActions) {
    val agent = data.character.name
    val pageId = data.session.interventionId
    val clip = androidx.compose.ui.platform.LocalClipboardManager.current
    var menu by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            Box(Modifier.width(48.dp))
            @OptIn(ExperimentalFoundationApi::class)
            Column(
                Modifier.weight(1f, fill = false)
                    .clip(RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp, bottomStart = 24.dp, bottomEnd = 8.dp))
                    .background(NW.Palette.sky.mixed(NW.Palette.backgroundDeep, if (pending) 0.88 else 0.74).color)
                    .combinedClickable(onLongClickLabel = if (text.isEmpty()) null else "Copy", onLongClick = { if (text.isNotEmpty()) menu = true }, onClick = {})
                    .padding(horizontal = 18.dp, vertical = 14.dp)
                    .semantics(mergeDescendants = true) {
                        contentDescription = "You: " + listOf(text, if (photos > 0) PhotoText.chip(photos) else "").filter { it.isNotEmpty() }.joinToString(", ")
                        delivery?.let { stateDescription = it.state.spokenBubbleStatus(SessionCommandKind.INPUT, agent) }
                    },
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                // "2 photos": the pictures themselves never come back from the Mac, only how many there were.
                if (photos > 0) PhotosChip(photos)
                if (text.isNotEmpty()) Text(text, style = NW.Typo.subline, color = NW.Palette.textPrimary.color)
            }
            DropdownMenu(menu, { menu = false }) { DropdownMenuItem({ Text("Copy") }, { menu = false; clip.setText(androidx.compose.ui.text.AnnotatedString(text)); actions.copy(text) }) }
        }
        if (delivery != null) {
            val state = delivery.state
            val color: Rgba = when (state) {
                SessionDeliveryState.Sending -> NW.Palette.textTertiary
                is SessionDeliveryState.Typed -> NW.Palette.teal
                is SessionDeliveryState.Queued -> NW.Palette.textSecondary
                is SessionDeliveryState.Deleted -> NW.Palette.textTertiary
                else -> NW.Palette.amber
            }
            // Photos going up say how far; a sent message says what the Mac did with them.
            val uploading = data.uploads[delivery.clientId]
            val explanation = when {
                state == SessionDeliveryState.Sending && uploading != null && photos > 0 -> uploading.line(photos, delivery.target?.host)
                state is SessionDeliveryState.Typed && photos > 0 -> state.detail
                // Held: the headline here; why the last try didn't type it is its own quieter line below.
                state is SessionDeliveryState.Held && !state.typing -> HeldMessages.heldHeadline(state.detail, agent)
                else -> state.bubbleExplanation(SessionCommandKind.INPUT, agent)
            }
            // A held message: its delete's answer, and Delete while the Mac holds it and can take it back.
            val delete = data.deletes[delivery.clientId]
            val canDelete = QueuedDelete.heldMessage(state, data.caps, delete)
            Column(Modifier.padding(start = 56.dp).clearAndSetSemantics {}, horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
                    when (state) {
                        SessionDeliveryState.Sending -> CircularProgressIndicator(Modifier.size(10.dp), color = color.color, strokeWidth = 1.5.dp)
                        is SessionDeliveryState.Typed -> Icon(Icons.Outlined.Check, null, tint = color.color, modifier = Modifier.size(12.dp))
                        is SessionDeliveryState.Queued, is SessionDeliveryState.Held -> Icon(Icons.Outlined.Schedule, null, tint = color.color, modifier = Modifier.size(12.dp))
                        is SessionDeliveryState.Deleted -> Icon(Icons.Outlined.Close, null, tint = color.color, modifier = Modifier.size(12.dp))
                        SessionDeliveryState.NoAnswer -> Icon(Icons.Outlined.HelpOutline, null, tint = color.color, modifier = Modifier.size(12.dp))
                        else -> Icon(Icons.Outlined.ErrorOutline, null, tint = color.color, modifier = Modifier.size(12.dp))
                    }
                    Text(state.label(SessionCommandKind.INPUT, photos), style = NW.Typo.captionStrong, color = color.color)
                }
                explanation?.let { Text(it, style = NW.Typo.caption, color = NW.Palette.textTertiary.color, textAlign = TextAlign.End) }
                if (state is SessionDeliveryState.Held && !state.typing) state.note?.let { Text(it, style = NW.Typo.caption, color = NW.Palette.textQuiet.color, textAlign = TextAlign.End) }
                if (state is SessionDeliveryState.Held && delivery.fromOtherDevice) {
                    Text("Sent from another device", style = NW.Typo.caption, color = NW.Palette.textQuiet.color, textAlign = TextAlign.End)
                }
                when {
                    delete is HeldDelete.Deleting -> Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(10.dp), color = NW.Palette.textTertiary.color, strokeWidth = 1.5.dp)
                        Text("Deleting…", style = NW.Typo.caption, color = NW.Palette.textTertiary.color)
                    }
                    // A delete that could not happen says why, in the Mac's own words.
                    delete?.text != null && state is SessionDeliveryState.Held -> Text(delete.text!!, style = NW.Typo.caption, color = NW.Palette.amber.color, textAlign = TextAlign.End)
                }
            }
            // The things to do are outside the silenced status column, so TalkBack reaches them.
            if (canDelete) NWReceiptAction(
                "Delete", { actions.deleteHeld(delivery.clientId) }, Modifier.padding(start = 56.dp), tone = NW.Palette.red.mixed(NW.Palette.white, 0.2),
                hint = "Takes this held message back. Nothing is typed.",
            )
            if (state is SessionDeliveryState.Refused && state.reason == "waiting" && pageId != null) {
                Text("Open decision", style = NW.Typo.bodyStrong, color = NW.Palette.amber.color, modifier = Modifier.heightIn(min = 48.dp).clickable(role = Role.Button) { actions.openDecision(pageId) }.padding(horizontal = 8.dp).padding(top = 12.dp))
            }
        }
    }
}

/** "2 photos" with a picture glyph, at the top of a bubble whose message carried photos. */
@Composable
private fun PhotosChip(count: Int) {
    Row(
        Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.10f)).padding(horizontal = 10.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Outlined.Image, null, tint = NW.Palette.textSecondary.color, modifier = Modifier.size(14.dp))
        Text(PhotoText.chip(count), style = NW.Typo.captionStrong, color = NW.Palette.textSecondary.color)
    }
}

/** "5 STEPS": consecutive tool calls in one card. The newest one of a busy session spins. */
@Composable
private fun StepsCard(steps: List<StoryStep>, live: Boolean, expanded: Boolean, onToggle: () -> Unit) {
    val shape = RoundedCornerShape(20.dp)
    Column(Modifier.fillMaxWidth().clip(shape).background(NW.Palette.inset.opacity(0.9).color).border(1.dp, Color.White.copy(alpha = 0.07f), shape)) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(role = Role.Button, onClickLabel = if (expanded) "Collapses the steps" else "Shows the steps", onClick = onToggle).padding(horizontal = 18.dp)
                .semantics { contentDescription = "${steps.size} steps" },
            horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("${steps.size} STEP${if (steps.size == 1) "" else "S"}", style = NW.Typo.label, color = NW.Palette.textTertiary.color)
            Icon(if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null, tint = NW.Palette.textTertiary.color, modifier = Modifier.size(20.dp))
        }
        if (expanded) {
            Column(Modifier.padding(bottom = 6.dp)) {
                steps.forEachIndexed { i, s ->
                    val isLive = live && i == steps.lastIndex
                    Row(
                        Modifier.fillMaxWidth().heightIn(min = 44.dp).padding(horizontal = 18.dp).semantics(mergeDescendants = true) { contentDescription = s.title },
                        horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(Modifier.width(24.dp), contentAlignment = Alignment.Center) {
                            if (isLive) NWSpinner(NW.Palette.teal.color, size = 18.dp)
                            else Icon(nwIcon(s.symbol), null, tint = NW.Palette.textTertiary.color, modifier = Modifier.size(18.dp))
                        }
                        Text(
                            s.title, style = if (s.mono) NW.Typo.monoBody else NW.Typo.body, color = (if (isLive) NW.Palette.teal else NW.Palette.textPrimary).color,
                            maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
        }
    }
}

/** The live line at the foot of a busy story: three dots and what the agent is doing now. */
@Composable
private fun LiveLine(text: String) {
    Row(Modifier.fillMaxWidth().padding(start = 4.dp).semantics(mergeDescendants = true) { contentDescription = "Working: $text" }, horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        NWAnimated { t ->
            Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                for (i in 0..2) Box(Modifier.size(8.dp).clip(CircleShape).background(NW.Palette.teal.opacity(0.35 + 0.65 * max(0.0, sin(t * 3 - i * 0.9))).color))
            }
        }
        Text(text, style = NW.Typo.subline, color = NW.Palette.teal.color, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}
