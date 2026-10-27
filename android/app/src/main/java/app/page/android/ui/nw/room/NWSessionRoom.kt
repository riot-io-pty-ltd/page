@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package app.page.android.ui.nw.room

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.StopCircle
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.page.android.model.AgentCharacter
import app.page.android.model.DraftSubmit
import app.page.android.model.HoldRingSpec
import app.page.android.model.LiveSessionState
import app.page.android.model.NowRow
import app.page.android.model.RoomBanner
import app.page.android.model.RoomChip
import app.page.android.model.RoomComposerMode
import app.page.android.model.RoomLens
import app.page.android.model.SendReceipt
import app.page.android.model.SessionComposer
import app.page.android.model.SessionStopPlan
import app.page.android.ui.nw.components.NWAnimated
import app.page.android.ui.nw.components.NWAuroraCanvas
import app.page.android.ui.nw.components.NWBackdrop
import app.page.android.ui.nw.components.NWButton
import app.page.android.ui.nw.components.NWButtonKind
import app.page.android.ui.nw.components.NWGlassCard
import app.page.android.ui.nw.components.NWHoldSurface
import app.page.android.ui.nw.components.nwIcon
import app.page.android.ui.nw.theme.AuroraPalette
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba

// The Session Room: one session, four lenses (Story, Screen, Changes, Workflows), a composer that follows the
// trust model, and Stop as a 0.6 s hold. These are plain views over values: the live container fills them from the
// stores and routes every closure through the existing services, the render harness fills them from fixtures.
// Nothing here types anything. (iOS NWRoom.swift.)

/** Claude copper, Codex slate, a local model's lime, anything else neutral. */
val AgentCharacter.tint: Rgba
    get() = when (kind) {
        AgentCharacter.Kind.CLAUDE -> Rgba.hex(0xE89E64)
        AgentCharacter.Kind.CODEX -> Rgba.hex(0xC9CEDB)
        AgentCharacter.Kind.LOCAL -> Rgba.hex(0xC6E86A)
        AgentCharacter.Kind.OTHER -> Rgba.hex(0xA3ADC2)
    }

val RoomChip.Tone.color: Rgba
    get() = when (this) {
        RoomChip.Tone.WORKING -> NW.Palette.teal
        RoomChip.Tone.NEEDS_YOU, RoomChip.Tone.WARM -> NW.Palette.amber
        RoomChip.Tone.QUIET -> NW.Palette.textSecondary
        RoomChip.Tone.LOCAL -> Rgba.hex(0xC6E86A)
    }

class SessionRoomActions(
    val close: () -> Unit = {},
    val send: (String) -> Unit = {},
    val stopCompleted: () -> Unit = {},
    val openRun: (String) -> Unit = {},
    val openAgent: (String, String) -> Unit = { _, _ -> },
    val openDecision: (String) -> Unit = {},
    val banner: (RoomBanner.Action) -> Unit = {},
    val approve: (NowRow) -> Unit = {},
    val holdComplete: (NowRow) -> Unit = {},
    val deny: (NowRow) -> Unit = {},
    val looksGood: (NowRow) -> Unit = {},
    val cancel: (String) -> Unit = {},
    val refreshChanges: () -> Unit = {},
    val copy: (String) -> Unit = {},
    val dismissReceipt: (String) -> Unit = {},
    /** "Submit all": the draft's answers, for the container to send. */
    val submitAnswers: (app.page.android.model.AnswerSheet) -> Unit = {},
)

@Composable
fun NWSessionRoom(
    data: SessionRoomData,
    actions: SessionRoomActions,
    lens: RoomLens,
    onLens: (RoomLens) -> Unit,
    draft: String,
    onDraft: (String) -> Unit,
    runId: String?,
    onRunId: (String?) -> Unit,
    modifier: Modifier = Modifier,
    /** The room was opened with Steer: the composer takes the keyboard once it is on screen. */
    focusComposer: Boolean = false,
    /** The room was opened with Stop: say what holding the stop button does. */
    stopHint: Boolean = false,
) {
    val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    var stopHeld by remember { mutableStateOf<Double?>(null) }
    val stopShown = stopHeld != null || data.fixedStop != null || stopHint
    val palette = when (data.session.state) {
        LiveSessionState.WAITING_ON_APPROVAL, LiveSessionState.WAITING_ON_USER -> AuroraPalette.needsYou
        LiveSessionState.ACTIVE -> AuroraPalette.working
        else -> AuroraPalette.quiet
    }
    Box(modifier.fillMaxSize().background(NW.Palette.backgroundDeep.color)) {
        NWBackdrop()
        // The aurora behind the header, fading into the page.
        Box(Modifier.fillMaxWidth().height(230.dp + top)) {
            NWAnimated { t -> NWAuroraCanvas(palette, t, Modifier.fillMaxSize()) }
            Box(
                Modifier.fillMaxSize().background(
                    Brush.verticalGradient(0f to Color.Transparent, 0.7f to NW.Palette.backgroundDeep.opacity(0.7).color, 1f to NW.Palette.backgroundDeep.color),
                ),
            )
        }
        Column(Modifier.fillMaxSize().padding(top = top)) {
            TopBar(data, actions, onHeld = { stopHeld = it })
            if (stopShown) StopPreview(data.stop)
            // Chips
            Row(Modifier.padding(top = 12.dp).horizontalScroll(rememberScrollState()).padding(horizontal = NW.Space.lg), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (c in data.chips) RoomChipView(c)
            }
            LensBar(data, lens, onLens)
            Column(Modifier.weight(1f).fillMaxWidth()) {
                for (b in data.banners) RoomBannerView(b, actions.banner, Modifier.padding(horizontal = NW.Space.lg).padding(top = 8.dp))
                when (lens) {
                    RoomLens.STORY -> NWRoomStory(data, actions)
                    RoomLens.SCREEN -> NWRoomScreenLens(data, actions)
                    RoomLens.CHANGES -> NWRoomChangesLens(data, actions)
                    RoomLens.WORKFLOWS -> NWRoomWorkflowsLens(data, actions, runId, onRunId)
                }
            }
            NWRoomComposer(data, draft, onDraft, actions, focusOnAppear = focusComposer)
        }
    }
}

// MARK: - Header

@Composable
private fun TopBar(data: SessionRoomData, actions: SessionRoomActions, onHeld: (Double?) -> Unit) {
    // Back and Stop on one line; the session's name gets a line of its own (board 32), so it is never squeezed by Stop.
    Column(Modifier.fillMaxWidth().padding(horizontal = NW.Space.lg).padding(top = 14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(48.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.09f)).clickable(role = Role.Button, onClickLabel = "Close", onClick = actions.close),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Close", tint = NW.Palette.textPrimary.color, modifier = Modifier.size(22.dp)) }
            Spacer(Modifier.weight(1f))
            NWRoomStopButton(data.stop, data.stopping, data.character.name, data.fixedStop, onHeld, actions.stopCompleted)
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            NWAgentGlyph(data.character, 42.dp)
            Text(
                data.session.title, style = NW.Typo.title.copy(fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace), color = NW.Palette.textPrimary.color,
                maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f).semantics { heading() },
            )
        }
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(data.subtitle, style = NW.Typo.subline, color = NW.Palette.textTertiary.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
            // Where this session lives, so two rooms can never read alike: the folder, and the id's first four.
            data.whereLine?.let { Text(it, style = NW.Typo.monoMicro, color = NW.Palette.textQuiet.color, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        }
    }
}

/** What the hold will do, in words, while the ring fills: nothing is a surprise. */
@Composable
private fun StopPreview(stop: SessionStopPlan) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = NW.Space.lg).padding(top = 10.dp).clip(RoundedCornerShape(14.dp)).background(Color.Black.copy(alpha = 0.35f)).padding(horizontal = 14.dp, vertical = 10.dp)
            .semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(nwIcon("keyboard"), null, tint = NW.Palette.textTertiary.color, modifier = Modifier.size(18.dp))
        Text(stop.preview, style = NW.Typo.monoSmall, color = NW.Palette.textSecondary.color, modifier = Modifier.weight(1f))
    }
}

/** The agent's mark: a rounded square in its colour with its glyph. */
@Composable
fun NWAgentGlyph(character: AgentCharacter, size: androidx.compose.ui.unit.Dp = 38.dp, modifier: Modifier = Modifier) {
    Box(modifier.size(size).clip(RoundedCornerShape(size * 0.3f)).background(character.tint.opacity(0.16).color).clearAndSetSemantics {}, contentAlignment = Alignment.Center) {
        Icon(nwIcon(character.symbol), null, tint = character.tint.color, modifier = Modifier.size(size * 0.5f))
    }
}

@Composable
fun RoomChipView(chip: RoomChip) {
    val c = chip.tone.color
    Row(
        Modifier.heightIn(min = 40.dp).clip(CircleShape).background(c.opacity(if (chip.tone == RoomChip.Tone.QUIET) 0.07 else 0.12).color)
            .border(1.dp, c.opacity(if (chip.tone == RoomChip.Tone.QUIET) 0.22 else 0.45).color, CircleShape).padding(horizontal = 14.dp)
            .clearAndSetSemantics { contentDescription = chip.text.lowercase().replaceFirstChar { it.uppercase() } },
        horizontalArrangement = Arrangement.spacedBy(7.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        if (chip.symbol != null) Icon(nwIcon(chip.symbol!!), null, tint = c.color, modifier = Modifier.size(14.dp))
        else Box(Modifier.size(9.dp).clip(CircleShape).background(c.color))
        Text(chip.text, style = NW.Typo.captionStrong, color = c.color, maxLines = 1, softWrap = false)
    }
}

@Composable
private fun LensBar(data: SessionRoomData, lens: RoomLens, onLens: (RoomLens) -> Unit) = app.page.android.ui.nw.shell.NWCappedFontScale(1.15f) {
    NWGlassCard(Modifier.padding(horizontal = NW.Space.lg).padding(top = 18.dp, bottom = 6.dp), radius = 22.dp, padding = androidx.compose.foundation.layout.PaddingValues(4.dp)) {
        // At big system font sizes four tabs and their badges cannot share the width: the bar scrolls instead of clipping.
        val scrolling = androidx.compose.ui.platform.LocalConfiguration.current.fontScale > 1.3f
        Row(if (scrolling) Modifier.horizontalScroll(rememberScrollState()) else Modifier, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            for (l in data.lenses) {
                val on = l == lens
                val badge = data.badges[l]
                Row(
                    (if (scrolling) Modifier else Modifier.weight(1f)).heightIn(min = 48.dp).clip(RoundedCornerShape(16.dp)).background(if (on) Color.White.copy(alpha = 0.13f) else Color.Transparent)
                        .clickable(role = Role.Tab) { onLens(l) }
                        .semantics { selected = on; contentDescription = l.title + (badge?.let { ", $it" } ?: "") }
                        .padding(horizontal = if (scrolling) 14.dp else 0.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(l.title, style = NW.Typo.bodyStrong.copy(fontSize = 14.sp, fontWeight = if (on) androidx.compose.ui.text.font.FontWeight.SemiBold else androidx.compose.ui.text.font.FontWeight.Medium), color = (if (on) NW.Palette.textPrimary else NW.Palette.textTertiary).color, maxLines = 1)
                    if (badge != null) Text("$badge", style = NW.Typo.captionStrong.copy(fontSize = 11.sp), color = NW.Palette.teal.color, modifier = Modifier.clip(CircleShape).background(NW.Palette.teal.opacity(0.18).color).padding(horizontal = 5.dp, vertical = 1.dp))
                }
            }
        }
    }
}

@Composable
fun RoomBannerView(banner: RoomBanner, onAction: (RoomBanner.Action) -> Unit, modifier: Modifier = Modifier) {
    val tone = if (banner.tone == RoomBanner.Tone.INFO) NW.Palette.textSecondary else NW.Palette.amber
    NWGlassCard(modifier, radius = 18.dp, padding = androidx.compose.foundation.layout.PaddingValues(14.dp), tint = if (banner.tone == RoomBanner.Tone.INFO) null else NW.Palette.amber) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
                Icon(nwIcon(banner.symbol), null, tint = tone.color, modifier = Modifier.size(22.dp))
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(banner.title, style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color)
                    Text(banner.message, style = NW.Typo.caption, color = NW.Palette.textSecondary.color)
                }
            }
            val title = banner.actionTitle
            val action = banner.action
            if (title != null && action != null) NWButton(title, { onAction(action) }, Modifier.fillMaxWidth(), kind = if (banner.tone == RoomBanner.Tone.INFO) NWButtonKind.QUIET else NWButtonKind.AMBER)
        }
    }
}

/**
 * Stop in the room: hold for 0.6 s (a ring fills round the button, amber warming to red), then Esc goes to the
 * session. Letting go early unwinds the ring and sends nothing. While it is held, [onHeld] reports the seconds so
 * the room can say what will be pressed, where, on which Mac. TalkBack gets a "Stop" action (it confirms first).
 */
@Composable
fun NWRoomStopButton(plan: SessionStopPlan, stopping: Boolean, agent: String, fixedProgress: Double? = null, onHeld: (Double?) -> Unit = {}, onComplete: () -> Unit) {
    when {
        stopping -> Box(Modifier.size(width = 104.dp, height = 52.dp).semantics { contentDescription = "Stopping" }, contentAlignment = Alignment.Center) {
            CircularProgressIndicator(Modifier.size(24.dp), color = NW.Palette.textSecondary.color, strokeWidth = 2.dp)
        }
        plan.canStop -> {
            var confirm by remember { mutableStateOf(false) }
            NWHoldSurface(
                SessionStopPlan.spec, Modifier.size(width = 104.dp, height = 52.dp).semantics {
                    role = Role.Button
                    contentDescription = "Stop $agent"
                    stateDescription = "Hold for a moment. ${plan.preview}"
                    customActions = listOf(CustomAccessibilityAction("Stop") { confirm = true; true })
                },
                fixedProgress = fixedProgress, onHeld = onHeld, onComplete = onComplete,
            ) { p ->
                val tone = NW.Palette.amber.mixed(NW.Palette.red, HoldRingSpec.warmth(p))
                val shape = CircleShape
                Box(
                    Modifier.size(width = 104.dp, height = 52.dp).clip(shape).background(NW.Palette.red.opacity(0.14 + 0.06 * p).color)
                        .border(1.5.dp, (if (p > 0) tone else NW.Palette.red.opacity(0.45)).color, shape),
                ) {
                    // The hold fills left to right behind the word.
                    Box(Modifier.fillMaxHeight().fillMaxWidth(p.toFloat().coerceIn(0f, 1f)).background(tone.opacity(0.35).color))
                    Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.StopCircle, null, tint = NW.Palette.red.mixed(NW.Palette.white, 0.25).color, modifier = Modifier.size(20.dp))
                        Text("Stop", style = NW.Typo.button, color = NW.Palette.red.mixed(NW.Palette.white, 0.25).color, maxLines = 1)
                    }
                }
            }
            if (confirm) androidx.compose.material3.AlertDialog(
                onDismissRequest = { confirm = false },
                title = { Text("Stop $agent?") },
                text = { Text("${plan.preview}. It interrupts the current turn.") },
                confirmButton = { androidx.compose.material3.TextButton({ confirm = false; onComplete() }) { Text("Stop") } },
                dismissButton = { androidx.compose.material3.TextButton({ confirm = false }) { Text("Cancel") } },
            )
        }
        else -> Box(Modifier.size(1.dp))
    }
}

// MARK: - Composer

/**
 * The composer, pinned. Its mode follows the session: it types only where the trust model allows, and the delivery
 * preview always says what will be typed, where and on which Mac. While the agent waits on a prompt it is "Tell it
 * instead...", which the page sends as Esc, then your words.
 */
@Composable
fun NWRoomComposer(data: SessionRoomData, draft: String, onDraft: (String) -> Unit, actions: SessionRoomActions, focusOnAppear: Boolean = false, modifier: Modifier = Modifier) {
    val focus = remember { FocusRequester() }
    var didFocus by remember { mutableStateOf(false) }
    val hasText = draft.trim().isNotEmpty()
    fun submit(raw: String) {
        val text = raw.trim()
        if (text.isNotEmpty()) actions.send(text)
    }
    LaunchedEffect(data.composer.acceptsText, focusOnAppear) {
        if (!focusOnAppear || didFocus || !data.composer.acceptsText) return@LaunchedEffect
        kotlinx.coroutines.delay(500)
        runCatching { focus.requestFocus() }
        didFocus = true
    }
    Column(
        modifier.fillMaxWidth().background(NW.Palette.backgroundDeep.color).imePadding().navigationBarsPadding().padding(horizontal = NW.Space.lg).padding(vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        data.stopNote?.let { n -> NoteStrip(n.text, when (n.tone) { SessionRoomData.StopNoteTone.GOOD -> NW.Palette.teal; SessionRoomData.StopNoteTone.PROBLEM -> NW.Palette.amber; else -> NW.Palette.textSecondary }, n.tone == SessionRoomData.StopNoteTone.WORKING, if (n.tone == SessionRoomData.StopNoteTone.GOOD) "stop" else "warn") }
        data.receipt?.let { ReceiptView(it, actions) }
        data.composerProblem?.let { Text(it, style = NW.Typo.caption, color = NW.Palette.amber.color, modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp).semantics { liveRegion = LiveRegionMode.Polite }) }
        if (data.composer.offersQuickReplies && data.character.kind != AgentCharacter.Kind.LOCAL && draft.isEmpty()) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (q in RoomComposerMode.quickReplies) Text(
                    q, style = NW.Typo.captionStrong, color = NW.Palette.textSecondary.color,
                    modifier = Modifier.heightIn(min = 48.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.07f)).border(1.dp, Color.White.copy(alpha = 0.10f), CircleShape)
                        .clickable(role = Role.Button, onClickLabel = "Puts this in the message box. Nothing is sent until you send it.") { onDraft(q); runCatching { focus.requestFocus() } }
                        .padding(horizontal = 14.dp).wrapCenter(),
                )
            }
        }
        when (val mode = data.composer) {
            is RoomComposerMode.Locked -> LockedBlock(if (mode.routesThroughPage) "keyboard" else "lock", data.composerCopy.placeholder, mode.why)
            is RoomComposerMode.Disabled -> LockedBlock("lock", data.composerCopy.placeholder, mode.why)
            is RoomComposerMode.Blocked -> LockedBlock("keyboard", mode.why, "You can still follow along here, and answer pages from Now.")
            else -> Field(data, draft, onDraft, focus, hasText, ::submit)
        }
    }
}

private fun Modifier.wrapCenter(): Modifier = this.padding(vertical = 12.dp)

@Composable
private fun Field(data: SessionRoomData, draft: String, onDraft: (String) -> Unit, focus: FocusRequester, hasText: Boolean, submit: (String) -> Unit) {
    val shape = RoundedCornerShape(30.dp)
    Row(
        Modifier.fillMaxWidth().clip(shape).background(NW.Palette.surface.opacity(0.95).color, shape).border(1.dp, Color.White.copy(alpha = 0.08f), shape).padding(horizontal = 14.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Bottom,
    ) {
        Column(Modifier.weight(1f).padding(start = 6.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Box(Modifier.heightIn(min = 28.dp), contentAlignment = Alignment.CenterStart) {
                if (draft.isEmpty()) Text(data.composerCopy.placeholder, style = NW.Typo.subline, color = NW.Palette.textQuiet.color, maxLines = 1)
                BasicTextField(
                    draft, { v ->
                        // The keyboard's Send key is the same Send as the button; one Return typed at the end counts too.
                        if (DraftSubmit.isReturnKey(draft, v)) submit(draft) else onDraft(v)
                    },
                    Modifier.fillMaxWidth().focusRequester(focus).semantics { contentDescription = data.composerCopy.placeholder },
                    textStyle = NW.Typo.subline.copy(color = NW.Palette.textPrimary.color), cursorBrush = SolidColor(NW.Palette.teal.color), maxLines = 5,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send), keyboardActions = KeyboardActions(onSend = { submit(draft) }),
                )
            }
            Text(data.preview ?: data.composerCopy.hint, style = NW.Typo.monoMicro, color = NW.Palette.textQuiet.color, maxLines = 3)
            if (draft.length >= SessionComposer.COUNTER_FROM) Text(
                "${draft.length} / ${SessionComposer.MAX_CHARACTERS}", style = NW.Typo.monoMicro,
                color = (if (draft.length > SessionComposer.MAX_CHARACTERS) NW.Palette.amber else NW.Palette.textTertiary).color,
            )
        }
        Box(
            Modifier.size(48.dp).clip(CircleShape)
                .background(if (hasText) Brush.linearGradient(listOf(NW.Palette.teal.color, NW.Palette.sky.color)) else Brush.linearGradient(listOf(Color.White.copy(alpha = 0.14f), Color.White.copy(alpha = 0.14f))))
                .clickable(enabled = hasText, role = Role.Button, onClickLabel = data.preview ?: data.composerCopy.hint) { submit(draft) }
                .semantics { contentDescription = data.composerCopy.sendLabel },
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Outlined.ArrowUpward, null, tint = NW.Palette.onBright.color, modifier = Modifier.size(22.dp)) }
    }
}

@Composable
private fun NoteStrip(text: String, tone: Rgba, working: Boolean, icon: String) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(tone.opacity(0.09).color).padding(horizontal = 14.dp, vertical = 10.dp).semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        if (working) CircularProgressIndicator(Modifier.size(16.dp), color = tone.color, strokeWidth = 2.dp)
        else Icon(if (icon == "stop") Icons.Outlined.StopCircle else Icons.Outlined.ErrorOutline, null, tint = tone.color, modifier = Modifier.size(18.dp))
        Text(text, style = NW.Typo.caption, color = tone.color, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun ReceiptView(r: SendReceipt, actions: SessionRoomActions) {
    val tone = when (r.tone) { SendReceipt.Tone.GOOD -> NW.Palette.teal; SendReceipt.Tone.PROBLEM -> NW.Palette.amber; else -> NW.Palette.textSecondary }
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(tone.opacity(0.09).color).padding(horizontal = 14.dp, vertical = 10.dp).semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top,
    ) {
        if (r.tone == SendReceipt.Tone.WORKING) CircularProgressIndicator(Modifier.size(16.dp), color = tone.color, strokeWidth = 2.dp)
        else Icon(if (r.tone == SendReceipt.Tone.GOOD) nwIcon("checkmark.circle") else Icons.Outlined.ErrorOutline, null, tint = tone.color, modifier = Modifier.size(18.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(r.headline, style = NW.Typo.captionStrong, color = tone.color)
            r.detail?.let { Text(it, style = NW.Typo.monoMicro, color = NW.Palette.textTertiary.color) }
        }
        if (r.tone == SendReceipt.Tone.PROBLEM) Box(Modifier.size(32.dp).clickable(role = Role.Button, onClickLabel = "Dismiss") { actions.dismissReceipt(r.id) }, contentAlignment = Alignment.Center) {
            Icon(Icons.Outlined.Close, "Dismiss", tint = NW.Palette.textTertiary.color, modifier = Modifier.size(16.dp))
        }
    }
}

@Composable
private fun LockedBlock(symbol: String, title: String, text: String) {
    val shape = RoundedCornerShape(22.dp)
    Row(
        Modifier.fillMaxWidth().clip(shape).background(NW.Palette.surface.opacity(0.95).color, shape).border(1.dp, Color.White.copy(alpha = 0.08f), shape).padding(14.dp).semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top,
    ) {
        Icon(nwIcon(symbol), null, tint = NW.Palette.textTertiary.color, modifier = Modifier.size(20.dp))
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color)
            Text(text, style = NW.Typo.caption, color = NW.Palette.textTertiary.color)
        }
    }
}

/** A quiet note with an info glyph (when a message lands, who can be typed to). */
@Composable
fun NWInfoNote(text: String, modifier: Modifier = Modifier, icon: androidx.compose.ui.graphics.vector.ImageVector = Icons.Outlined.Info) {
    Row(
        modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Color.White.copy(alpha = 0.045f)).padding(14.dp).semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top,
    ) {
        Icon(icon, null, tint = NW.Palette.textTertiary.color, modifier = Modifier.size(20.dp))
        Text(text, style = NW.Typo.caption, color = NW.Palette.textSecondary.color, modifier = Modifier.weight(1f))
    }
}
