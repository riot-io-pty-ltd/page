package app.page.android.ui.nw.components

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.CheckBox
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.page.android.model.ChipKind
import app.page.android.model.MacChipModel
import app.page.android.model.NowBanner
import app.page.android.model.NowRow
import app.page.android.model.ProjectHue
import app.page.android.model.RingStat
import app.page.android.model.RingSummary
import app.page.android.model.RunwayMarker
import app.page.android.model.StarState
import app.page.android.model.TurnChip
import app.page.android.ui.nw.theme.LocalCardGlow
import app.page.android.ui.nw.theme.LocalReduceMotion
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba

// The Night Watch controls (iOS NWControls.swift, NWRowViews.swift, NWNowParts.swift pieces). Every action label
// is in words; every control is at least 44 dp (buttons 52) and speaks for TalkBack.

// MARK: - Colours the models point at

/** IRREVERSIBLE red, UNDOABLE green, CONSIDERED sky, everything that needs a look amber, a finished turn teal. */
val ChipKind.color: Rgba
    get() = when (this) {
        ChipKind.IRREVERSIBLE -> NW.Palette.red
        ChipKind.UNDOABLE -> NW.Palette.green
        ChipKind.CONSIDERED -> NW.Palette.sky
        ChipKind.LOOKS_STUCK, ChipKind.QUESTION, ChipKind.FORECAST, ChipKind.RATE_LIMITED -> NW.Palette.amber
        ChipKind.REVIEW -> NW.Palette.teal
    }

/** The icon drawn in front of the label on a card. */
val ChipKind.symbol: String
    get() = when (this) {
        ChipKind.IRREVERSIBLE -> "exclamationmark.shield"
        ChipKind.CONSIDERED -> "doc.text.magnifyingglass"
        ChipKind.UNDOABLE -> "arrow.uturn.backward.circle"
        ChipKind.LOOKS_STUCK -> "arrow.triangle.2.circlepath"
        ChipKind.QUESTION -> "questionmark.bubble"
        ChipKind.FORECAST -> "clock.badge.exclamationmark"
        ChipKind.RATE_LIMITED -> "gauge.with.needle"
        ChipKind.REVIEW -> "checkmark.circle"
    }

val RingStat.Kind.color: Rgba
    get() = when (this) {
        RingStat.Kind.UNBLOCKED -> NW.Palette.amber
        RingStat.Kind.SHIPPED -> NW.Palette.teal
        RingStat.Kind.CALM -> NW.Palette.violet
    }

val RunwayMarker.Tone.color: Rgba
    get() = when (this) {
        RunwayMarker.Tone.AMBER -> NW.Palette.amber
        RunwayMarker.Tone.GREEN -> NW.Palette.green
        RunwayMarker.Tone.BLUE -> NW.Palette.sky
    }

/** Teal working, amber needs you, dim white idle; the rest follow. */
val StarState.color: Rgba
    get() = when (this) {
        StarState.WORKING -> NW.Palette.teal
        StarState.NEEDS_YOU, StarState.STUCK -> NW.Palette.amber
        StarState.RATE_LIMITED -> NW.Palette.sky
        StarState.PAUSED -> Rgba.hex(0x8A8FA0)
        StarState.IDLE -> Rgba.hex(0xC9CEDB)
        StarState.OFFLINE -> Rgba.hex(0x6B7080)
    }

val ProjectHue.color: Rgba get() = Rgba.hex(hex)

val NowRow.Section.color: Rgba
    get() = when (this) {
        NowRow.Section.DECIDE, NowRow.Section.LOOK -> NW.Palette.amber
        NowRow.Section.REVIEW -> NW.Palette.teal
    }

/** The card's own colour for its state (red for Irreversible, amber for Look, teal for a finished turn). */
val NowRow.tint: Rgba
    get() = when (chip) {
        ChipKind.IRREVERSIBLE -> NW.Palette.red
        ChipKind.CONSIDERED -> NW.Palette.sky
        ChipKind.LOOKS_STUCK, ChipKind.FORECAST, ChipKind.RATE_LIMITED, ChipKind.QUESTION -> NW.Palette.amber
        ChipKind.UNDOABLE -> NW.Palette.green
        ChipKind.REVIEW -> NW.Palette.teal
    }

// MARK: - Chip

/**
 * The small all-caps label on a row. [pill] adds a tinted capsule with the class icon (as on the Decide cards);
 * without it, plain tracked text.
 */
@Composable
fun NWChip(kind: ChipKind, modifier: Modifier = Modifier, pill: Boolean = false) {
    val c = kind.color
    Row(
        modifier
            .then(if (pill) Modifier.clip(CircleShape).background(c.opacity(0.16).color).padding(horizontal = 9.dp, vertical = 5.dp) else Modifier)
            .clearAndSetSemantics { contentDescription = kind.title.lowercase().replaceFirstChar { it.uppercase() } },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        if (pill) Icon(nwIcon(kind.symbol), null, tint = c.color, modifier = Modifier.size(14.dp))
        Text(kind.title, style = NW.Typo.label, color = c.color, maxLines = 1, softWrap = false)
    }
}

// MARK: - Buttons

enum class NWButtonKind { QUIET, BRIGHT, AMBER, DANGER }

/**
 * A Night Watch button, always a word: quiet slate (Deny, Steer), bright teal-to-sky (Looks good), amber (Steer
 * on a stuck card) or red-tinted (the Irreversible approve). A 52 dp minimum height, so the touch target is
 * generous.
 */
@Composable
fun NWButton(
    text: String, onClick: () -> Unit, modifier: Modifier = Modifier, kind: NWButtonKind = NWButtonKind.QUIET,
    enabled: Boolean = true, leading: ImageVector? = null, alpha: Float = 1f,
) {
    val shape = RoundedCornerShape(NW.Radius.button)
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val p = NW.Palette
    val fg = when (kind) { NWButtonKind.QUIET, NWButtonKind.DANGER -> p.textPrimary; NWButtonKind.BRIGHT, NWButtonKind.AMBER -> p.onBright }
    val border = when (kind) {
        NWButtonKind.QUIET -> p.hairline
        NWButtonKind.BRIGHT -> p.teal.opacity(0.4)
        NWButtonKind.AMBER -> p.yellow.opacity(0.5)
        NWButtonKind.DANGER -> p.red.opacity(0.45)
    }
    val bg: Brush = when (kind) {
        NWButtonKind.QUIET -> Brush.linearGradient(listOf(Color.White.copy(alpha = 0.07f), Color.White.copy(alpha = 0.07f)))
        NWButtonKind.BRIGHT -> Brush.horizontalGradient(listOf(p.teal.color, p.sky.color))
        NWButtonKind.AMBER -> Brush.horizontalGradient(listOf(p.yellow.color, p.amber.color))
        NWButtonKind.DANGER -> Brush.linearGradient(listOf(p.red.opacity(0.14).color, p.red.opacity(0.14).color))
    }
    Row(
        modifier
            .heightIn(min = NW.buttonHeight)
            .alpha((if (!enabled) 0.45f else if (pressed) 0.8f else 1f) * alpha)
            .clip(shape)
            .background(bg)
            .border(BorderStroke(1.dp, border.color), shape)
            .clickable(interactionSource = source, indication = null, enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        if (leading != null) {
            Icon(leading, null, tint = fg.color, modifier = Modifier.size(20.dp))
            Box(Modifier.width(8.dp))
        }
        Text(text, style = NW.Typo.button, color = fg.color, maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
    }
}

// MARK: - Delivery preview and receipt

/** The delivery preview: what will be typed, where, on which Mac, in a dark inset with a keyboard glyph ("Will type 1 · cmux › page · Studio MBP"). */
@Composable
fun NWDeliveryPreview(text: String, modifier: Modifier = Modifier) {
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(NW.Radius.inset))
            .background(Color.White.copy(alpha = 0.05f))
            .padding(horizontal = 12.dp, vertical = 10.dp)
            .clearAndSetSemantics { contentDescription = text },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(nwIcon("keyboard"), null, tint = NW.Palette.textTertiary.color, modifier = Modifier.size(18.dp))
        Text(text, style = NW.Typo.monoSmall, color = NW.Palette.textSecondary.color, maxLines = 2, modifier = Modifier.weight(1f))
    }
}

/** One line of proof that a keystroke landed (or why it did not). */
@Composable
fun NWReceiptLine(text: String, modifier: Modifier = Modifier, failed: Boolean = false) {
    val tone = if (failed) NW.Palette.amber else NW.Palette.teal
    Row(
        modifier
            .fillMaxWidth()
            .heightIn(min = 40.dp)
            .clip(RoundedCornerShape(NW.Radius.inset))
            .background(tone.opacity(0.08).color)
            .padding(horizontal = 14.dp, vertical = 8.dp)
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(if (failed) Icons.Outlined.ErrorOutline else Icons.Outlined.CheckBox, null, tint = tone.opacity(0.95).color, modifier = Modifier.size(18.dp))
        Text(text, style = NW.Typo.monoMicro, color = tone.opacity(0.95).color, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

// MARK: - Switch and segmented control

/** The Night Watch switch: a teal capsule with a white knob; off is a dim slate. */
@Composable
fun NWSwitch(isOn: Boolean, modifier: Modifier = Modifier, onChange: ((Boolean) -> Unit)? = null, width: Dp = 52.dp, height: Dp = 32.dp) {
    val reduce = LocalReduceMotion.current
    val knob = height - 6.dp
    val x by animateDpAsState(if (isOn) width - knob - 3.dp else 3.dp, tween(if (reduce) 0 else 140), label = "knob")
    Box(
        modifier
            .size(width, height)
            .clip(CircleShape)
            .background(if (isOn) Brush.horizontalGradient(listOf(NW.Palette.teal.opacity(0.95).color, NW.Palette.green.opacity(0.9).color)) else Brush.linearGradient(listOf(Color.White.copy(alpha = 0.12f), Color.White.copy(alpha = 0.12f))))
            .then(if (onChange != null) Modifier.clickable(role = Role.Switch) { onChange(!isOn) } else Modifier)
            .semantics { stateDescription = if (isOn) "on" else "off" },
    ) {
        Box(
            Modifier.offset(x = x, y = 3.dp).size(knob).shadow(2.dp, CircleShape).clip(CircleShape).background(Color.White),
        )
    }
}

/** A segmented control in the Night Watch style: slate track, a raised pill under the selected option. Every segment is a 44 dp button. */
@Composable
fun <T> NWSegmented(options: List<Pair<T, String>>, selection: T, onSelect: (T) -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.07f)).padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        for ((value, label) in options) {
            val on = value == selection
            Box(
                Modifier
                    .weight(1f)
                    .heightIn(min = 44.dp)
                    .clip(RoundedCornerShape(9.dp))
                    .background(if (on) Color.White.copy(alpha = 0.14f) else Color.Transparent)
                    .clickable(role = Role.Tab) { onSelect(value) }
                    .semantics { selected = on },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label, style = NW.Typo.body.copy(fontWeight = if (on) FontWeight.SemiBold else FontWeight.Medium),
                    color = if (on) NW.Palette.textPrimary.color else NW.Palette.textTertiary.color, maxLines = 1,
                )
            }
        }
    }
}

// MARK: - Rings

/** A progress ring. */
@Composable
fun NWRing(progress: Double, color: Rgba, modifier: Modifier = Modifier, lineWidth: Dp = 4.dp, size: Dp = 24.dp) {
    Canvas(modifier.size(size)) {
        val lw = lineWidth.toPx()
        val inset = lw / 2
        val d = this.size.width - lw
        drawArc(color.opacity(0.2).color, 0f, 360f, false, topLeft = Offset(inset, inset), size = androidx.compose.ui.geometry.Size(d, d), style = Stroke(lw))
        drawArc(
            color.color, -90f, (360 * progress.coerceIn(0.0, 1.0)).toFloat(), false, topLeft = Offset(inset, inset),
            size = androidx.compose.ui.geometry.Size(d, d), style = Stroke(lw, cap = StrokeCap.Round),
        )
    }
}

/** Unblocked, Shipped and Calm as three concentric rings (the glyph in the corner of the Horizon and in the "Tonight" card). */
@Composable
fun NWConcentricRings(rings: List<RingStat>, modifier: Modifier = Modifier, size: Dp = 44.dp) {
    val lw = maxOf(3.dp, size / 9)
    Box(
        modifier.size(size).clearAndSetSemantics { contentDescription = rings.joinToString(", ") { "${it.kind.raw} ${it.detail}" } },
        contentAlignment = Alignment.Center,
    ) {
        rings.forEachIndexed { i, r -> NWRing(r.progress, r.kind.color, lineWidth = lw, size = size - (lw * 2 + 2.dp) * i) }
    }
}

/** The three daily rings with labels, one per line. */
@Composable
fun NWRingsList(rings: List<RingStat>, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        for (r in rings) {
            Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.size(8.dp).clip(CircleShape).background(r.kind.color.color))
                Text(r.kind.raw, style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color, modifier = Modifier.weight(1f))
                Text(r.detail, style = NW.Typo.monoSmall, color = r.kind.color.color)
            }
        }
    }
}

// MARK: - Section header, tip, chips on Now

/** "Decide 2" and a hairline. The words are the section's own; colour says whether it needs you (amber) or is done (teal). */
@Composable
fun NWSectionHeader(title: String, color: Rgba, modifier: Modifier = Modifier, count: Int? = null) {
    Row(
        modifier.fillMaxWidth().semantics(mergeDescendants = true) { heading() },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(title, style = NW.Typo.title.copy(fontSize = 20.sp), color = color.color)
        if (count != null) Text("$count", style = NW.Typo.labelLarge, color = NW.Palette.textTertiary.color)
        Box(Modifier.weight(1f).height(1.dp).background(Color.White.copy(alpha = 0.08f)))
    }
}

/** A one-line tip with a pointer to the element it explains. Drawn inline in the stream (never over a control), dismissible, and quiet: no motion of its own beyond a fade. */
@Composable
fun NWTipCallout(text: String, modifier: Modifier = Modifier, symbol: String = "lightbulb", pointerUp: Boolean = true, pointerInset: Dp = 36.dp, onDismiss: () -> Unit = {}) {
    val base = NW.Palette.surface.mixed(NW.Palette.teal.opacity(1.0), 0.13)
    val rim = NW.Palette.teal.opacity(0.32)
    Column(modifier.fillMaxWidth().semantics(mergeDescendants = false) { contentDescription = "Tip. $text" }) {
        if (pointerUp) TipArrow(true, base, rim, Modifier.padding(start = pointerInset))
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(base.color)
                .border(1.dp, rim.color, RoundedCornerShape(16.dp))
                .padding(start = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(nwIcon(symbol), null, tint = NW.Palette.teal.color, modifier = Modifier.size(18.dp))
            Text(text, style = NW.Typo.captionStrong, color = NW.Palette.textPrimary.color, modifier = Modifier.weight(1f).padding(vertical = 8.dp))
            Box(
                Modifier.size(48.dp).clickable(role = Role.Button, onClickLabel = "Dismiss tip", onClick = onDismiss),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Outlined.Close, "Dismiss tip", tint = NW.Palette.textTertiary.color, modifier = Modifier.size(16.dp)) }
        }
        if (!pointerUp) TipArrow(false, base, rim, Modifier.padding(start = pointerInset))
    }
}

@Composable
private fun TipArrow(up: Boolean, fill: Rgba, rim: Rgba, modifier: Modifier) {
    Canvas(modifier.size(18.dp, 9.dp)) {
        val w = size.width
        val h = size.height
        val path = androidx.compose.ui.graphics.Path().apply {
            if (up) { moveTo(0f, h); lineTo(w / 2, 0f); lineTo(w, h) } else { moveTo(0f, 0f); lineTo(w / 2, h); lineTo(w, 0f) }
            close()
        }
        drawPath(path, fill.color)
        drawPath(path, rim.color, style = Stroke(1.dp.toPx()))
    }
}

/** "Studio MBP · on battery · 41%". Amber when the cutoff is close, dim when the Mac is not answering. Tapping it opens the Tower. */
@Composable
fun NWMacChip(model: MacChipModel, modifier: Modifier = Modifier, onTap: () -> Unit = {}) {
    val dot = when (model.tone) {
        MacChipModel.Tone.OK -> NW.Palette.green
        MacChipModel.Tone.WARN -> NW.Palette.amber
        MacChipModel.Tone.OFFLINE -> Rgba.hex(0x8A8FA0)
    }
    val warn = model.tone == MacChipModel.Tone.WARN
    val shape = CircleShape
    Box(modifier.heightIn(min = 48.dp), contentAlignment = Alignment.CenterStart) {
        Row(
            Modifier
                .height(38.dp)
                .clip(shape)
                .background(Color.Black.copy(alpha = 0.35f))
                .border(1.dp, if (warn) NW.Palette.amber.opacity(0.5).color else Color.White.copy(alpha = 0.14f), shape)
                .clickable(role = Role.Button, onClickLabel = "Open the Tower: power, budget, Macs and settings", onClick = onTap)
                .padding(horizontal = 14.dp)
                .semantics { contentDescription = model.text },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Box(Modifier.size(9.dp).clip(CircleShape).background(dot.color))
            Text(model.text, style = NW.Typo.bodyStrong, color = if (warn) NW.Palette.amber.color else NW.Palette.textPrimary.color, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 260.dp))
            Icon(Icons.Filled.ExpandMore, null, tint = NW.Palette.textTertiary.color, modifier = Modifier.size(16.dp))
        }
    }
}

/** A problem above the stream: a rejected pairing, an unreachable relay, a silent Mac, notifications off. One glass card, one action. */
@Composable
fun NWBannerCard(banner: NowBanner, modifier: Modifier = Modifier, onAction: (NowBanner.Action) -> Unit = {}) {
    val tone = if (banner.tone == NowBanner.Tone.INFO) NW.Palette.sky else NW.Palette.amber
    Row(
        modifier.fillMaxWidth().nwGlass(NW.Radius.row, tint = tone, glow = LocalCardGlow.current).padding(NW.Space.md),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.size(36.dp).clip(RoundedCornerShape(10.dp)).background(tone.opacity(0.14).color), contentAlignment = Alignment.Center) {
            Icon(nwIcon(banner.symbol), null, tint = tone.color, modifier = Modifier.size(20.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(banner.title, style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color)
            Text(banner.message, style = NW.Typo.caption, color = NW.Palette.textSecondary.color)
            val t = banner.actionTitle
            val a = banner.action
            if (t != null && a != null) {
                Text(
                    t, style = NW.Typo.captionStrong, color = tone.color,
                    modifier = Modifier.heightIn(min = 44.dp).clickable(role = Role.Button) { onAction(a) }.padding(top = 10.dp),
                )
            }
        }
    }
}

/** "New ↑ 1": arrivals held back while you are touching or scrolling the stream. */
@Composable
fun NWNewPill(count: Int, modifier: Modifier = Modifier, onTap: () -> Unit) {
    Row(
        modifier
            .height(40.dp)
            .shadow(6.dp, CircleShape)
            .clip(CircleShape)
            .background(NW.Palette.amber.color)
            .clickable(role = Role.Button, onClickLabel = "Show $count new", onClick = onTap)
            .padding(horizontal = 16.dp)
            .semantics { contentDescription = "$count new, show" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(nwIcon("arrow.up"), null, tint = NW.Palette.onBright.color, modifier = Modifier.size(14.dp))
        Text("New $count", style = NW.Typo.captionStrong, color = NW.Palette.onBright.color)
    }
}

/** A chip on a Review card, read from the Mac's turn-summary line. */
@Composable
fun NWTurnChip(chip: TurnChip, modifier: Modifier = Modifier) {
    val c = when (chip.tone) {
        TurnChip.Tone.NEUTRAL -> NW.Palette.textPrimary
        TurnChip.Tone.ADDED, TurnChip.Tone.PASS -> NW.Palette.green
        // A failed test is amber, never red: red is for two press-and-hold commits only.
        TurnChip.Tone.REMOVED -> NW.Palette.red
        TurnChip.Tone.FAIL -> NW.Palette.amber
    }
    Text(
        chip.text, style = NW.Typo.monoSmall, color = c.opacity(0.95).color,
        modifier = modifier.clip(RoundedCornerShape(9.dp)).background(c.opacity(if (chip.tone == TurnChip.Tone.NEUTRAL) 0.09 else 0.14).color).padding(horizontal = 10.dp, vertical = 6.dp),
    )
}

/** "Tonight": the day's three rings and a line about them. */
@Composable
fun NWTonightCard(rings: List<RingStat>, modifier: Modifier = Modifier) {
    NWGlassCard(modifier) {
        Row(horizontalArrangement = Arrangement.spacedBy(18.dp), verticalAlignment = Alignment.CenterVertically) {
            NWConcentricRings(rings, size = 64.dp)
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(RingSummary.title(rings), style = NW.Typo.title, color = NW.Palette.textPrimary.color)
                Text(RingSummary.detail(rings), style = NW.Typo.caption, color = NW.Palette.textSecondary.color)
            }
        }
    }
}
