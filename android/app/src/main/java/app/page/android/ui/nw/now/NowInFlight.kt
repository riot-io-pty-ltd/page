@file:OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)

package app.page.android.ui.nw.now

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.layout
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.page.android.model.FlightHealth
import app.page.android.model.InFlightRow
import app.page.android.model.InFlightSection
import app.page.android.model.NowTipTarget
import app.page.android.model.NWTip
import app.page.android.model.RoomEntry
import app.page.android.ui.nw.components.NWButton
import app.page.android.ui.nw.components.NWButtonKind
import app.page.android.ui.nw.components.NWGlassCard
import app.page.android.ui.nw.components.NWRing
import app.page.android.ui.nw.components.NWStarGlyph
import app.page.android.ui.nw.components.NWTipCallout
import app.page.android.ui.nw.components.color
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba

// The In flight section of Now. Every card hands its actions to closures; the container routes them (open the
// room, retire a tip). Nothing here types anything: Steer only opens the room with the composer focused.
// (iOS NWInFlight.swift.)

/**
 * "IN FLIGHT 3": a side-scroll strip that summarises every working session, then one full card per session, as
 * big as a Review card, so the whole picture of the work is on one screen. Tapping a card opens its room on
 * Story; "Open" shows its terminal and "Steer" opens the composer. Touching and holding offers the same, and Stop
 * (which opens the room where the 0.6 s hold lives).
 */
@Composable
fun NWInFlightSection(
    section: InFlightSection,
    modifier: Modifier = Modifier,
    tip: NowTipTarget? = null,
    biometry: String = "fingerprint",
    onOpen: (String, RoomEntry) -> Unit = { _, _ -> },
    onToggle: () -> Unit = {},
    onHeader: () -> Unit = {},
    onDismissTip: (NWTip) -> Unit = {},
) {
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 44.dp).clickable(role = Role.Button, onClickLabel = "Goes to Lanes", onClick = onHeader).semantics(mergeDescendants = true) {
                heading(); contentDescription = "In flight, ${section.total}"
            },
            horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("IN FLIGHT", style = NW.Typo.labelLarge, color = NW.Palette.teal.color)
            Text("${section.total}", style = NW.Typo.labelLarge, color = NW.Palette.textTertiary.color)
            Box(Modifier.weight(1f).height(1.dp).background(Color.White.copy(alpha = 0.08f)))
            Icon(Icons.Outlined.ChevronRight, null, tint = NW.Palette.textTertiary.color, modifier = Modifier.size(16.dp))
        }
        if (section.showsStrip) NWInFlightStrip(section.strip, Modifier.layoutFullBleed(), onOpen = { onOpen(it, RoomEntry.STORY) })
        for (row in section.rows) {
            NWInFlightCardView(row, onOpen = { onOpen(row.id, it) })
            if (tip != null && tip.anchorId == row.id && tip.tip == NWTip.IN_FLIGHT) NWTipCallout(tip.tip.text(biometry), symbol = tip.tip.symbol, onDismiss = { onDismissTip(tip.tip) })
        }
        if (section.isCapped) {
            Box(
                Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.06f))
                    .clickable(role = Role.Button, onClickLabel = if (section.isExpanded) "Shows only the first few" else "Shows every working session", onClick = onToggle),
                contentAlignment = Alignment.Center,
            ) { Text(if (section.isExpanded) "Show fewer" else section.showAllLabel, style = NW.Typo.captionStrong, color = NW.Palette.teal.color) }
        }
    }
}

/** The strip runs under the stream's gutters, edge to edge. */
private fun Modifier.layoutFullBleed(): Modifier = this.then(
    Modifier.layout { measurable, constraints ->
        val extra = 32.dp.roundToPx()
        val p = measurable.measure(constraints.copy(maxWidth = constraints.maxWidth + extra, minWidth = constraints.maxWidth + extra))
        layout(constraints.maxWidth, p.height) { p.place(-extra / 2, 0) }
    },
)

/** The side-scroll summary: one small tile per working session (the ribbon), with what it is doing and for how long. A tap opens that session. */
@Composable
fun NWInFlightStrip(rows: List<InFlightRow>, modifier: Modifier = Modifier, onOpen: (String) -> Unit = {}) {
    Row(modifier.horizontalScroll(rememberScrollState()).padding(horizontal = NW.Space.gutter), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        for (r in rows) StripTile(r) { onOpen(r.id) }
    }
}

@Composable
private fun StripTile(r: InFlightRow, onClick: () -> Unit) {
    val time = r.card.turn?.removePrefix("working ") ?: r.age?.let { "$it ago" }
    val flow = r.card.workflows.firstOrNull()
    val attention = r.card.health.needsAttention
    NWGlassCard(
        Modifier.width(212.dp).clickable(role = Role.Button, onClickLabel = "Opens the session", onClick = onClick).semantics(mergeDescendants = true) { contentDescription = r.spoken },
        radius = NW.Radius.row, padding = androidx.compose.foundation.layout.PaddingValues(horizontal = 12.dp, vertical = 10.dp), tint = if (attention) NW.Palette.amber else null,
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(contentAlignment = Alignment.Center) {
                NWStarGlyph(r.seed, r.hue.color, size = 30.dp)
                flow?.fraction?.let { NWRing(it, NW.Palette.teal, lineWidth = 2.dp, size = 34.dp) }
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(r.project, style = NW.Typo.monoSmall, color = NW.Palette.textPrimary.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(r.card.now, style = NW.Typo.monoMicro, color = NW.Palette.textTertiary.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    val label = r.card.health.label
                    if (attention && label != null) Text(label, style = NW.Typo.monoMicro, color = NW.Palette.amber.color, maxLines = 1)
                    else flow?.progress?.let { Text(it.replace(" agents", ""), style = NW.Typo.monoMicro, color = NW.Palette.teal.color, maxLines = 1) }
                    if (time != null) Text(time, style = NW.Typo.monoMicro, color = NW.Palette.textQuiet.color, maxLines = 1)
                }
            }
        }
    }
}

/**
 * One working session, as big as a Review card: who and where, what it is doing now and just did, how long, its
 * workflows, how it is doing, and two buttons in words. The body is a button that opens the room on Story; the
 * buttons sit under it, each at least 48 dp.
 */
@Composable
fun NWInFlightCardView(row: InFlightRow, modifier: Modifier = Modifier, onOpen: (RoomEntry) -> Unit = {}) {
    val card = row.card
    val tint = if (card.health.needsAttention) NW.Palette.amber else NW.Palette.teal
    var menu by remember { mutableStateOf(false) }
    NWGlassCard(
        modifier.semantics {
            customActions = buildList {
                add(CustomAccessibilityAction("Open") { onOpen(RoomEntry.SCREEN); true })
                add(CustomAccessibilityAction("Steer") { onOpen(RoomEntry.TYPE); true })
                if (row.canStop) add(CustomAccessibilityAction("Stop") { onOpen(RoomEntry.STOP); true })
            }
        },
        tint = tint,
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Box {
                Column(
                    Modifier.fillMaxWidth().combinedClickable(role = Role.Button, onClickLabel = "Opens the session", onLongClickLabel = "Open, Steer or Stop", onLongClick = { menu = true }, onClick = { onOpen(RoomEntry.STORY) })
                        .semantics(mergeDescendants = true) { contentDescription = row.spoken },
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    // Who and where.
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(36.dp), contentAlignment = Alignment.Center) { NWStarGlyph(row.seed, row.hue.color, size = 30.dp) }
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(row.project, style = NW.Typo.mono, color = NW.Palette.textPrimary.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(listOfNotNull(row.character, row.route ?: row.host, card.model).joinToString(" · "), style = NW.Typo.caption, color = NW.Palette.textTertiary.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        val h = card.health.label
                        if (card.health.needsAttention && h != null) Text(
                            h.uppercase(), style = NW.Typo.label, color = NW.Palette.amber.color, maxLines = 1,
                            modifier = Modifier.clip(CircleShape).background(NW.Palette.amber.opacity(0.14).color).padding(horizontal = 8.dp, vertical = 4.dp),
                        )
                    }
                    Fact("NOW") {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(card.now, style = NW.Typo.monoSmall.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold), color = NW.Palette.textPrimary.color, maxLines = 3, overflow = TextOverflow.Ellipsis)
                            card.previous.forEachIndexed { i, step ->
                                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                                    Box(Modifier.size(5.dp).clip(CircleShape).background(NW.Palette.textQuiet.opacity(1 - 0.22 * i).color))
                                    Text(step, style = NW.Typo.monoMicro, color = NW.Palette.textTertiary.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                            }
                        }
                    }
                    card.timeText?.let { t -> Fact("TIME") { Text(t, style = NW.Typo.monoSmall, color = NW.Palette.textPrimary.color, maxLines = 2) } }
                    card.workflowHeading?.let { heading ->
                        Fact("WORKFLOWS") {
                            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text(heading, style = NW.Typo.captionStrong, color = NW.Palette.teal.color)
                                for (w in card.workflows) Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Text(w.text, style = NW.Typo.monoMicro, color = NW.Palette.textSecondary.color, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                    w.fraction?.let { f ->
                                        Box(Modifier.fillMaxWidth().height(3.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.08f))) {
                                            Box(Modifier.fillMaxWidth(f.toFloat().coerceIn(0.02f, 1f)).height(3.dp).clip(CircleShape).background(NW.Palette.teal.color))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Fact("HEALTH") {
                        val hc: Rgba = when (card.health) {
                            FlightHealth.NORMAL -> NW.Palette.green
                            FlightHealth.LONG_RUNNING -> NW.Palette.sky
                            FlightHealth.STUCK, FlightHealth.RATE_LIMITED -> NW.Palette.amber
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(7.dp).clip(CircleShape).background(hc.color))
                            Text(
                                card.healthLine ?: "Normal", style = NW.Typo.monoMicro, maxLines = 3, overflow = TextOverflow.Ellipsis,
                                color = (if (card.health.needsAttention) NW.Palette.amber else NW.Palette.textSecondary).color,
                            )
                        }
                    }
                }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem({ Text("Open") }, { menu = false; onOpen(RoomEntry.SCREEN) })
                    DropdownMenuItem({ Text("Steer") }, { menu = false; onOpen(RoomEntry.TYPE) })
                    if (row.canStop) DropdownMenuItem({ Text("Stop…") }, { menu = false; onOpen(RoomEntry.STOP) })
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                // A terminal Page cannot mirror or type into is dimmed, not hidden: it still opens the room, which says why.
                EntryButton(RoomEntry.SCREEN, row.canMirror, NWButtonKind.QUIET, Modifier.weight(1f)) { onOpen(RoomEntry.SCREEN) }
                EntryButton(RoomEntry.TYPE, row.canType, NWButtonKind.BRIGHT, Modifier.weight(1f)) { onOpen(RoomEntry.TYPE) }
            }
        }
    }
}

@Composable
private fun EntryButton(entry: RoomEntry, enabled: Boolean, kind: NWButtonKind, modifier: Modifier, onClick: () -> Unit) {
    val hint = if (enabled) (if (entry == RoomEntry.TYPE) "Opens the session with the keyboard up" else "Shows its terminal")
    else (if (entry == RoomEntry.TYPE) "Page can't type into this terminal; opens the session to say why" else "Page can't mirror this terminal; opens the session")
    Box(modifier.semantics { stateDescription = hint }) {
        NWButton(entry.buttonTitle, onClick, Modifier.fillMaxWidth().then(if (enabled) Modifier else Modifier.padding(0.dp)), kind = if (enabled) kind else NWButtonKind.QUIET, alpha = if (enabled) 1f else 0.55f)
    }
}

/** A small caps label, and its content under it (stacked like the Mac's card, so a long step or a health line gets the card's whole width). */
@Composable
private fun Fact(title: String, content: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title, style = NW.Typo.label, color = NW.Palette.textTertiary.color, maxLines = 1)
        content()
    }
}
