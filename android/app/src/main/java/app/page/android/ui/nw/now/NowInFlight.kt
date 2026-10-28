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
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.structuralEqualityPolicy
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.page.android.model.FlightHealth
import app.page.android.model.FlightLineStatus
import app.page.android.model.FlightWorkflowLine
import app.page.android.model.InFlightRow
import app.page.android.model.InFlightSection
import app.page.android.model.MotionCurve
import app.page.android.model.NowMotion
import app.page.android.model.NowTipTarget
import app.page.android.model.NWTip
import app.page.android.model.RoomEntry
import app.page.android.ui.nw.components.NWButton
import app.page.android.ui.nw.components.NWButtonKind
import app.page.android.ui.nw.components.NWGlassCard
import app.page.android.ui.nw.components.NWRollingWords
import app.page.android.ui.nw.components.NWTipCallout
import app.page.android.ui.nw.components.color
import app.page.android.ui.nw.components.rememberNowChange
import app.page.android.ui.nw.components.rememberNowClock
import app.page.android.ui.nw.theme.LocalAnimationsPaused
import app.page.android.ui.nw.theme.LocalReduceMotion
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba
import kotlin.math.roundToInt

// The In flight section of Now. Every card hands its actions to closures; the container routes them (open the
// room, retire a tip). Nothing here types anything: Steer only opens the room with the composer focused.
// (iOS NWInFlight.swift.)

/**
 * "IN FLIGHT 3": a side-scroll strip that summarises every working session, then one full card per session, as
 * big as a Review card, so the whole picture of the work is on one screen. Tapping a card opens its room on
 * Story; "Open" shows its terminal and "Steer" opens the composer. Touching and holding offers the same, and Stop
 * (which opens the room where the 10 s hold lives). In motion ([NowMotion]) on one clock: cards and tiles rise in and
 * fold away, arcs and bars sweep, spring and close, and a finished workflow is said once, politely. [epoch] changes on
 * a reconnect, whose first snapshot is never news.
 */
@Composable
fun NWInFlightSection(
    section: InFlightSection,
    modifier: Modifier = Modifier,
    tip: NowTipTarget? = null,
    biometry: String = "fingerprint",
    epoch: Any? = null,
    onOpen: (String, RoomEntry) -> Unit = { _, _ -> },
    onToggle: () -> Unit = {},
    onHeader: () -> Unit = {},
    onDismissTip: (NWTip) -> Unit = {},
) {
    val reduce = LocalReduceMotion.current
    val track = rememberFlightTrack(section, epoch)
    val clock = rememberFlightClock(track, reduce)
    val motion = remember(track, clock, reduce) { FlightMotion(track, clock, reduce) }
    // Under the harness's script the section is drawn as it was at the pinned moment.
    val shown = track.section
    // Only the set of cards (a leaving one stays while it folds) and the announcement recompose; the motion is drawn.
    val cards by remember(track, reduce) { derivedStateOf(structuralEqualityPolicy()) { NowMotion.cards(track, clock.value, reduce) } }
    val said by remember(track) { derivedStateOf { NowMotion.said(track, clock.value) } }
    // Under the room (or a sheet) the room's Workflows lens says it itself; an ending heard there is not said again
    // here when the room closes.
    val covered = LocalAnimationsPaused.current
    val hushed = remember { object { var at: Double? = null } }
    if (covered) hushed.at = track.saidAt
    val spoken = said?.takeIf { !covered && track.saidAt != hushed.at }
    Box(modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                Modifier.fillMaxWidth().heightIn(min = 44.dp).clickable(role = Role.Button, onClickLabel = "Goes to Lanes", onClick = onHeader).semantics(mergeDescendants = true) {
                    heading(); contentDescription = "In flight, ${shown.total}"
                },
                horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("IN FLIGHT", style = NW.Typo.labelLarge, color = NW.Palette.teal.color)
                RollingText("${shown.total}", NW.Typo.labelLarge, NW.Palette.textTertiary.color, reduce)
                Box(Modifier.weight(1f).height(1.dp).background(Color.White.copy(alpha = 0.08f)))
                Icon(Icons.Outlined.ChevronRight, null, tint = NW.Palette.textTertiary.color, modifier = Modifier.size(16.dp))
            }
            if (shown.showsStrip) NWInFlightStrip(motion, Modifier.layoutFullBleed(), onOpen = { onOpen(it, RoomEntry.STORY) })
            for ((row, leaving) in cards) key(row.id) {
                val m = if (leaving != null) Modifier.flightLeave(motion, leaving).clearAndSetSemantics {} else Modifier.flightRise(motion, track.cardsIn[row.id])
                NWInFlightCardView(row, m, motion, onOpen = { onOpen(row.id, it) })
                if (leaving == null && tip != null && tip.anchorId == row.id && tip.tip == NWTip.IN_FLIGHT) NWTipCallout(tip.tip.text(biometry), symbol = tip.tip.symbol, onDismiss = { onDismissTip(tip.tip) })
            }
            if (shown.isCapped) {
                Box(
                    Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.06f))
                        .clickable(role = Role.Button, onClickLabel = if (shown.isExpanded) "Shows only the first few" else "Shows every working session", onClick = onToggle),
                    contentAlignment = Alignment.Center,
                ) { Text(if (shown.isExpanded) "Show fewer" else shown.showAllLabel, style = NW.Typo.captionStrong, color = NW.Palette.teal.color) }
            }
        }
        // A workflow that has just finished (or failed, or stopped), said once, politely: "page: Docs sweep finished". At
        // the section's top, where it is on screen whenever the section is.
        Box(Modifier.size(1.dp).semantics { liveRegion = LiveRegionMode.Polite; spoken?.let { contentDescription = it } })
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
fun NWInFlightStrip(motion: FlightMotion, modifier: Modifier = Modifier, onOpen: (String) -> Unit = {}) {
    val track = motion.track
    val tiles by remember(track, motion.reduce) { derivedStateOf(structuralEqualityPolicy()) { NowMotion.stripTiles(track, motion.now, motion.reduce) } }
    Row(modifier.horizontalScroll(rememberScrollState()).padding(horizontal = NW.Space.gutter), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        tiles.forEachIndexed { i, (r, leaving) ->
            key(r.id) {
                val m = if (leaving != null) Modifier.flightLeave(motion, leaving, across = true).clearAndSetSemantics {} else Modifier.flightRise(motion, track.tilesIn[r.id])
                StripTile(r, i, motion, m) { onOpen(r.id) }
            }
        }
    }
}

@Composable
private fun StripTile(r: InFlightRow, index: Int, motion: FlightMotion, modifier: Modifier, onClick: () -> Unit) {
    val time = r.card.turn?.removePrefix("working ") ?: r.age?.let { "$it ago" }
    val track = motion.track
    // The one line the tile shows: the first running, or a ghost while it closes.
    val flow by remember(track, r.id, motion.reduce) { derivedStateOf { NowMotion.tileLine(track, r.id, motion.now, motion.reduce) } }
    val attention = r.card.health.needsAttention
    val amber by remember(track, r.id, motion.reduce) { derivedStateOf { stepped(NowMotion.rowAmber(track, r, motion.now, motion.reduce)) } }
    NWGlassCard(
        modifier.width(212.dp).clickable(role = Role.Button, onClickLabel = "Opens the session", onClick = onClick).semantics(mergeDescendants = true) { contentDescription = r.spoken },
        radius = NW.Radius.row, padding = androidx.compose.foundation.layout.PaddingValues(horizontal = 12.dp, vertical = 10.dp),
        tint = if (amber <= 0.0) null else NW.Palette.amber.mixed(NW.Palette.surface, 1 - amber),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(contentAlignment = Alignment.Center) {
                FlightStar(r.seed, r.hue.color, NowMotion.live(r, motion.reduce), motion.clock, size = 30.dp, index = index)
                flow?.let { l -> if (l.fraction != null) key(l.key) { FlightRing(motion, r, l, index) } }
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(r.project, style = NW.Typo.monoSmall, color = NW.Palette.textPrimary.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(r.card.now, style = NW.Typo.monoMicro, color = NW.Palette.textTertiary.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    val label = r.card.health.label
                    val l = flow
                    val word = l?.let { if (motion.reduce) null else NowMotion.endedWord(it.status) }
                    if (attention && label != null) Text(label, style = NW.Typo.monoMicro, color = NW.Palette.amber.color, maxLines = 1)
                    else if (l != null && (word != null || l.progress != null)) {
                        RollingText(word ?: l.progress!!.replace(" agents", ""), NW.Typo.monoMicro, (if (l.status == FlightLineStatus.FAILED || l.status == FlightLineStatus.STOPPED) NW.Palette.amber else NW.Palette.teal).color, motion.reduce)
                    }
                    if (time != null) Text(time, style = NW.Typo.monoMicro, color = NW.Palette.textQuiet.color, maxLines = 1)
                }
            }
        }
    }
}

/** A cross-fade's share in twentieths, so a tint fading recomposes a few times and never while it holds. */
private fun stepped(x: Double): Double = kotlin.math.round(x.coerceIn(0.0, 1.0) * 20) / 20

/**
 * One working session, as big as a Review card: who and where, what it is doing now and just did, how long, its
 * workflows, how it is doing, and two buttons in words. The body is a button that opens the room on Story; the
 * buttons sit under it, each at least 48 dp. Its star breathes while it works normally, its NOW step rolls on, its
 * workflow bars move, and its health dot breathes or, when it is stuck, ripples amber.
 */
@Composable
fun NWInFlightCardView(row: InFlightRow, modifier: Modifier = Modifier, motion: FlightMotion, onOpen: (RoomEntry) -> Unit = {}) {
    val card = row.card
    val track = motion.track
    val reduce = motion.reduce
    // The health tint cross-fades (0.5 s) when it turns.
    val amber by remember(track, row.id, reduce) { derivedStateOf { stepped(NowMotion.rowAmber(track, row, motion.now, reduce)) } }
    val tint = if (amber >= 1.0) NW.Palette.amber else if (amber <= 0.0) NW.Palette.teal else NW.Palette.teal.mixed(NW.Palette.amber, amber)
    val lines by remember(track, row.id, reduce) { derivedStateOf(structuralEqualityPolicy()) { NowMotion.drawn(track, row.id, motion.now, reduce) } }
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
                        Box(Modifier.size(36.dp), contentAlignment = Alignment.Center) { FlightStar(row.seed, row.hue.color, NowMotion.live(row, reduce), motion.clock, size = 30.dp) }
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
                    Fact("NOW") { NowSteps(row, motion) }
                    card.timeText?.let { t -> Fact("TIME") { TimeText(t) } }
                    if (lines.isNotEmpty()) {
                        // With only a ghost left, the whole fact folds away with it.
                        val last = lines.singleOrNull()?.takeIf { it.status != FlightLineStatus.RUNNING }
                        Box(if (last != null) Modifier.flightFold(motion, row, last) else Modifier) {
                            Fact("WORKFLOWS") {
                                Column {
                                    WorkflowHeading(card.workflowHeading, reduce)
                                    // Each line's gap above it folds away with it (as on iOS), so nothing jumps when a ghost goes.
                                    lines.forEachIndexed { i, w ->
                                        key(w.key) { WorkflowLine(row, w, i, motion, (if (last == null) Modifier.flightFold(motion, row, w) else Modifier).padding(top = 8.dp)) }
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
                            FlightHealthDot(card.health, hc, motion)
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

/**
 * TIME ("working 12m · session 2h 10m"): only the numbers that moved roll, as iOS's numericText does, so a minute
 * ticking over moves one or two digits instead of sliding the whole line; new wording cross-fades ([NWRollingWords]).
 * Its own clock, only while a change plays.
 */
@Composable
private fun TimeText(text: String) {
    val change = rememberNowChange(text)
    val clock = rememberNowClock(change.at?.plus(NowMotion.wordsLast(LocalReduceMotion.current)))
    NWRollingWords(AnnotatedString(text), change, clock, NW.Typo.monoSmall, NW.Palette.textPrimary.color, textAlign = TextAlign.Start, maxLines = 2)
}

/** "2 workflows running", rolling to each new count; the last count while the last line closes. */
@Composable
private fun WorkflowHeading(heading: String?, reduce: Boolean) {
    var last by remember { mutableStateOf(heading) }
    if (heading != null) last = heading
    last?.let { RollingText(it, NW.Typo.captionStrong, NW.Palette.teal.color, reduce) }
}

/** One workflow line: its words (the progress rolls on its own, and a finish reads "✓ done") and its bar in motion. */
@Composable
private fun WorkflowLine(row: InFlightRow, w: FlightWorkflowLine, index: Int, motion: FlightMotion, modifier: Modifier) {
    val ended = if (motion.reduce) null else NowMotion.endedWord(w.status)
    val amber = w.status == FlightLineStatus.FAILED || w.status == FlightLineStatus.STOPPED
    Column(modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.Top) {
            Text(if (ended != null) listOfNotNull(w.name, w.phase).joinToString(" · ") + " · " else w.lead, style = NW.Typo.monoMicro, color = NW.Palette.textSecondary.color, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
            (ended ?: w.progress)?.let { RollingText(it, NW.Typo.monoMicro, (if (amber && ended != null) NW.Palette.amber else NW.Palette.textSecondary).color, motion.reduce) }
        }
        if (w.fraction != null) FlightBar(motion, row, w, index)
    }
}

/**
 * The NOW step and the two before it. A new step rises in (0.35 s, spring) as the old slides up 6 dp and fades
 * (0.25 s); the earlier steps shift down on the stream's spring, the newest of them fading in and the oldest falling
 * off with a fade. Under Reduce Motion the steps cross-fade in place over 0.2 s and the oldest simply goes.
 */
@Composable
private fun NowSteps(row: InFlightRow, motion: FlightMotion) {
    val card = row.card
    val track = motion.track
    val reduce = motion.reduce
    val change by remember(track, row.id, reduce) { derivedStateOf { NowMotion.step(track, row.id, motion.now, reduce)?.first } }
    val pitch = remember { mutableFloatStateOf(0f) }
    val gap = with(LocalDensity.current) { 6.dp.toPx() }
    val style = NW.Typo.monoSmall.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold)
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box {
            val s = change
            if (s != null) Text(s.now, style = style, color = NW.Palette.textPrimary.color, maxLines = 3, overflow = TextOverflow.Ellipsis, modifier = Modifier.clearAndSetSemantics {}.graphicsLayer {
                val k = NowMotion.stepOld(motion.now - s.at, reduce)
                translationY = k.offset.dp.toPx()
                alpha = k.opacity.toFloat()
            })
            Text(card.now, style = style, color = NW.Palette.textPrimary.color, maxLines = 3, overflow = TextOverflow.Ellipsis, modifier = if (s == null) Modifier else Modifier.graphicsLayer {
                val k = NowMotion.stepNew(motion.now - s.at, reduce)
                translationY = k.offset.dp.toPx()
                alpha = k.opacity.toFloat()
            })
        }
        val s = change
        val falling = s?.previous?.withIndex()?.filter { (_, old) -> old !in card.previous && old != card.now } ?: emptyList()
        // Clipped, so the oldest slides out under the list's edge instead of over the TIME fact below.
        if (card.previous.isNotEmpty() || falling.isNotEmpty()) Box(Modifier.clipToBounds()) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                card.previous.forEachIndexed { i, step ->
                    val was = s?.previous?.indexOf(step) ?: -1
                    val m = when {
                        s == null -> Modifier
                        was >= 0 -> Modifier.graphicsLayer { translationY = (was - i) * pitch.floatValue * (1 - NowMotion.stepShift(motion.now - s.at, reduce)).toFloat() }
                        // The newest fades in as the row it replaces moves out of its place, never stacked on it.
                        else -> Modifier.graphicsLayer {
                            val e = motion.now - s.at
                            val k = MotionCurve.clamp01(NowMotion.stepShift(e, reduce))
                            alpha = (if (reduce) NowMotion.stepNew(e, true).opacity else k * k).toFloat()
                        }
                    }
                    PreviousStep(step, i, m.then(if (i == 0) Modifier.onSizeChanged { pitch.floatValue = it.height + gap } else Modifier))
                }
            }
            // The oldest falls off below the others as they shift down, fading, taking no room.
            if (s != null) for ((j, old) in falling) {
                val slot = card.previous.size
                PreviousStep(old, slot, Modifier.clearAndSetSemantics {}.layout { m, c ->
                    val p = m.measure(c)
                    layout(0, 0) {
                        p.placeWithLayer(0, (slot * pitch.floatValue).roundToInt()) {
                            val e = motion.now - s.at
                            translationY = (j - slot) * pitch.floatValue * (1 - NowMotion.stepShift(e, reduce)).toFloat()
                            alpha = NowMotion.stepOld(e, reduce).opacity.toFloat()
                        }
                    }
                })
            }
        }
    }
}

@Composable
private fun PreviousStep(step: String, i: Int, modifier: Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(5.dp).clip(CircleShape).background(NW.Palette.textQuiet.opacity((1 - 0.22 * i).coerceAtLeast(0.2)).color))
        Text(step, style = NW.Typo.monoMicro, color = NW.Palette.textTertiary.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
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
