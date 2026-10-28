package app.page.android.ui.nw.lanes

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.page.android.model.DaypartWeights
import app.page.android.model.DuskDawnLog
import app.page.android.model.LaneGroup
import app.page.android.model.LaneRow
import app.page.android.model.LanesModel
import app.page.android.model.NowModel
import app.page.android.model.NowBanner
import app.page.android.model.SessionAvailabilityCopy
import app.page.android.model.SkyModel
import app.page.android.model.StarState
import app.page.android.model.StripCell
import app.page.android.ui.nw.components.NWAnimated
import app.page.android.ui.nw.components.NWBannerCard
import app.page.android.ui.nw.components.NWDawnLight
import app.page.android.ui.nw.components.NWGlassCard
import app.page.android.ui.nw.components.NWHorizonBand
import app.page.android.ui.nw.components.NWLivingAurora
import app.page.android.ui.nw.components.NWStarGlyph
import app.page.android.ui.nw.components.color
import app.page.android.ui.nw.shell.NWCappedFontScale
import app.page.android.ui.nw.theme.AuroraPalette
import app.page.android.ui.nw.theme.LocalDaypart
import app.page.android.ui.nw.theme.LocalFixedNow
import app.page.android.ui.nw.theme.LocalFixedPhase
import app.page.android.ui.nw.theme.LocalMotionPin
import app.page.android.ui.nw.theme.LocalReduceMotion
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.NWMotionPin
import app.page.android.ui.nw.theme.Rgba
import java.time.Instant
import kotlinx.coroutines.delay

/** Everything Lanes draws, as values. */
data class LanesScreenData(
    /** The fleet, the Mac's battery (the moon) and whether agents are paused for power. */
    val fleet: SkyModel,
    val lanes: LanesModel,
    /** Why live sessions can't load, when they can't. */
    val availability: SessionAvailabilityCopy? = null,
    /** The last battery pause: the dusk and the dawn ([LanesPowerStory]). */
    val duskDawn: DuskDawnLog = DuskDawnLog(),
    /** The time of day the sky is drawn at ([LocalDaypart]); nighttime unless set. */
    val daypart: DaypartWeights = DaypartWeights.NIGHTTIME,
)

class LanesScreenActions(
    /** A lane was tapped: its decision when it has one, else its session. */
    val openRow: (LaneRow) -> Unit = {},
    /** The Mac's battery, top right: opens the Tower at Power. */
    val tapMoon: () -> Unit = {},
    val availabilityAction: (SessionAvailabilityCopy.Action) -> Unit = {},
)

/**
 * LANES: the fleet as a list, one group per project and one lane per live session, each with a 4-hour strip. The
 * Mac's battery sits top right. While agents are paused for power the screen plays the dusk (the aurora fades in,
 * every working glyph dims, a grey horizon holds above the bar) and, when power returns, the dawn (gold rising from
 * the horizon, each glyph relighting once its session is seen working). Nothing actionable lives only here: a lane
 * that needs you is also a card in Now. (iOS NWLanesScreen.)
 */
@Composable
fun NWLanesScreen(data: LanesScreenData, actions: LanesScreenActions, modifier: Modifier = Modifier) {
    val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val power = rememberPower(data)
    // How far above the bottom of the screen the horizon of a pause sits: clear of the bar.
    val lift = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding() + 84.dp + 8.dp
    BoxWithConstraints(modifier.fillMaxSize()) {
        val bandY = maxHeight - lift
        LanesAurora(data, power, top)
        PowerBackdrop(power)
        DawnLight(bandY, power)
        Column(Modifier.fillMaxSize()) {
            Header(data, actions, Modifier.padding(top = top + 8.dp))
            val a = data.availability
            if (a != null) {
                val banner = NowBanner(
                    "availability", if (a.tone == SessionAvailabilityCopy.Tone.INFO) NowBanner.Tone.INFO else if (a.tone == SessionAvailabilityCopy.Tone.ERROR) NowBanner.Tone.ERROR else NowBanner.Tone.WARNING,
                    a.systemImage, a.title, a.message, a.actionTitle, when (a.action) { SessionAvailabilityCopy.Action.REPAIR -> NowBanner.Action.REPAIR; SessionAvailabilityCopy.Action.RETRY -> NowBanner.Action.RETRY; null -> null },
                )
                NWBannerCard(banner, Modifier.padding(NW.Space.gutter)) { act -> actions.availabilityAction(if (act == NowBanner.Action.REPAIR) SessionAvailabilityCopy.Action.REPAIR else SessionAvailabilityCopy.Action.RETRY) }
            } else {
                LanesBody(data, actions, power)
            }
        }
        // The horizon holds in front of the lanes, a fine line above the bar, so a pause is seen even over a long list.
        HorizonBand(bandY, power)
    }
}

@Composable
private fun Header(data: LanesScreenData, actions: LanesScreenActions, modifier: Modifier) {
    Row(modifier.fillMaxWidth().padding(horizontal = NW.Space.gutter), verticalAlignment = Alignment.Top) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("Lanes", style = NW.Typo.hero.copy(fontSize = 40.sp, letterSpacing = (-1).sp), color = NW.Palette.textPrimary.color, modifier = Modifier.semantics { heading() })
            Text(data.fleet.headline, style = NW.Typo.caption, color = NW.Palette.textTertiary.color)
        }
        Moon(data, actions)
    }
}

/** The power story for [data], with the clock it is drawn at: the wall clock while live, null when drawn still. */
private class PowerContext(val story: LanesPowerStory, val live: Boolean, val fixedNow: Instant?, val pin: NWMotionPin?) {
    val now: Instant? get() = if (live) (fixedNow ?: Instant.now()) else null
    val moving: Boolean get() = story.isMoving(fixedNow ?: Instant.now(), pin)
    val shown: Boolean get() = story.isShown(fixedNow ?: Instant.now(), pin)
}

/**
 * The power story for the whole screen, once. The clocks that draw it read [PowerContext.moving] where they start, so
 * when the story stops moving the screen is recomposed once at that moment and every clock stops (a battery pause
 * must not keep the screen redrawing).
 */
@Composable
private fun rememberPower(data: LanesScreenData): PowerContext {
    val ids = data.lanes.groups.flatMap { g -> g.rows.map { it.id } }
    // The dusk falls from the hour's sky, and the dawn rises back into it.
    val base = AuroraPalette.of(NowModel.Mood.WORKING, data.daypart)
    val stars = data.daypart.stars
    val story = remember(data.fleet.paused, data.duskDawn, ids, base, stars) { LanesPowerStory(data.fleet.paused, data.duskDawn, ids, base, stars) }
    val live = !LocalReduceMotion.current && LocalFixedPhase.current == null
    var stopped by remember { mutableIntStateOf(0) }
    LaunchedEffect(story, live) {
        val until = story.movingUntil() ?: return@LaunchedEffect
        val wait = until.toEpochMilli() - System.currentTimeMillis()
        if (wait > 0) { delay(wait + 50); stopped++ }
    }
    @Suppress("UNUSED_EXPRESSION") stopped
    return PowerContext(story, live, LocalFixedNow.current, LocalMotionPin.current)
}

// MARK: The day band

/**
 * The fleet's mood for the day band: teal while anything works, else the quiet sky. A lane paused for battery still
 * counts as working, so the band keeps its palette while the dusk rises over it. Never amber: on Lanes amber stays in
 * the group heads. Pure.
 */
internal fun lanesFleetMood(lanes: LanesModel): NowModel.Mood =
    if (lanes.groups.any { g -> g.rows.any { it.state == StarState.WORKING || it.state == StarState.PAUSED } }) NowModel.Mood.WORKING else NowModel.Mood.QUIET

/** The day band's geometry, the same numbers as iOS's `lanesAurora`. */
internal object LanesDayBand {
    /** How far below the status bar the band reaches. */
    val depth = 280.dp
    const val opacity = 0.8

    /** The scrim at the very top of the screen, behind the status bar. */
    const val scrimTop = 0.06

    /**
     * The scrim's stops between the top and the band's bottom (where it is gone): dp below the status bar, and how
     * deep the page colour lies there. The title's row is light; the caption and the axis are deep.
     */
    val scrim: List<Pair<Float, Double>> = listOf(
        0f to 0.12, 20f to 0.24, 40f to 0.44, 56f to 0.64, 66f to 0.72, 104f to 0.72, 140f to 0.6, 190f to 0.36,
    )
}

/**
 * The living sky behind the header, at the time of day: the Horizon's aurora as a crown over the top of Lanes, its
 * curtains glowing above and behind the title and gone into the page by the first lane. The scrim is weighted onto
 * the caption and the axis, the small dim text, so the glow can stay bright where only the bold title sits. It gives
 * way to the power story's cover as the dusk rises and comes back as the dawn settles, never a cut; a settled pause
 * draws none of it (and runs no clock). Each layer takes the band's opacity on its own, as iOS's does. (iOS
 * NWLanesScreen.lanesAurora.)
 */
@Composable
private fun LanesAurora(data: LanesScreenData, power: PowerContext, inset: Dp) {
    if (data.fleet.paused && !power.moving) return
    val palette = AuroraPalette.of(lanesFleetMood(data.lanes), data.daypart)
    val stars = data.daypart.stars
    NWAnimated(fps = 15.0) { t ->
        val cover = power.story.skyLight(power.now, power.pin).cover
        val alpha = (LanesDayBand.opacity * (1 - cover)).toFloat()
        Box(Modifier.fillMaxWidth().height(inset + LanesDayBand.depth).clearAndSetSemantics {}) {
            NWLivingAurora(palette, t, Modifier.fillMaxSize().graphicsLayer { this.alpha = alpha }, stars = stars)
            Canvas(Modifier.fillMaxSize()) {
                val deep = NW.Palette.backgroundDeep
                // The Horizon's own fade into the page.
                drawRect(
                    Brush.verticalGradient(0f to Color.Transparent, 0.35f to deep.opacity(0.0).color, 0.88f to deep.opacity(0.85).color, 1f to deep.color),
                    alpha = alpha,
                )
                // The header scrim, deepest behind the caption and the axis.
                val h = size.height
                val top = inset.toPx()
                val stops = listOf(0f to deep.opacity(LanesDayBand.scrimTop).color) +
                    LanesDayBand.scrim.map { (y, a) -> (top + y.dp.toPx()) / h to deep.opacity(a).color } +
                    listOf(1f to deep.opacity(0.0).color)
                drawRect(Brush.verticalGradient(*stops.toTypedArray()), alpha = alpha)
            }
        }
    }
}

// MARK: The power story

/**
 * The aurora behind the list, only while the power story is on screen: fading to dusk, settled in the night of a
 * pause, or fading back into the day as the dawn ends. Otherwise the day band ([LanesAurora]) crowns the header over
 * the shell's own sky.
 */
@Composable
private fun PowerBackdrop(power: PowerContext) {
    if (!power.shown) return
    // A battery pause that has settled is a still night: no clock while agents are paused for power.
    NWAnimated(active = power.moving) { t ->
        val light = power.story.skyLight(power.now, power.pin)
        NWLivingAurora(
            light.palette, t,
            Modifier.fillMaxSize().graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen; alpha = light.cover.toFloat() }.drawWithContent {
                drawContent()
                drawRect(Brush.verticalGradient(listOf(Color.White, Color.White.copy(alpha = 0.7f), Color.Transparent)), blendMode = BlendMode.DstIn)
            }.clearAndSetSemantics {},
            stars = light.stars,
        )
    }
}

/** The dawn's gold rising from the horizon to the very top of the screen (over the header too), behind the lanes. No clock otherwise. */
@Composable
private fun DawnLight(bandY: androidx.compose.ui.unit.Dp, power: PowerContext) {
    NWAnimated(active = power.moving) { _ ->
        val d = power.story.skyLight(power.now, power.pin).dawn
        if (d != null) NWDawnLight(d.sweep, d.warmth, Modifier.fillMaxWidth().height(bandY + 160.dp).offset(y = (-160).dp))
    }
}

/** The grey band of a battery pause: it falls with the dusk, holds while paused, and fades as the dawn leaves it. */
@Composable
private fun HorizonBand(bandY: androidx.compose.ui.unit.Dp, power: PowerContext) {
    NWAnimated(active = power.moving) { _ ->
        NWHorizonBand(power.story.skyLight(power.now, power.pin).band, Modifier.offset(y = bandY - 6.dp))
    }
}

/** The Mac: its battery as a small moon with a ring. A tap opens the Tower at Power. */
@Composable
private fun Moon(data: LanesScreenData, actions: LanesScreenActions) {
    val m = data.fleet.moon
    NWCappedFontScale(1.3f) {
        Row(
            Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp)).clickable(role = Role.Button, onClickLabel = "Opens the Tower at Power", onClick = actions.tapMoon).padding(start = 10.dp, end = 6.dp)
                .semantics { contentDescription = "${data.fleet.macName}, battery ${m.percent}, ${m.detail}" },
            horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(m.percent, style = NW.Typo.captionStrong, color = NW.Palette.textPrimary.color)
                Text(if (m.onAC) "on power" else "on battery", style = NW.Typo.monoMicro, color = NW.Palette.textTertiary.color)
            }
            Canvas(Modifier.size(36.dp)) {
                drawCircle(Brush.radialGradient(listOf(Color.White.copy(alpha = 0.95f), Rgba.hex(0xB8C0D8).color), center = Offset(size.width * 0.35f, size.height * 0.35f), radius = 22.dp.toPx()), radius = 13.dp.toPx())
                m.fraction?.let { f -> drawArc(NW.Palette.teal.color, -90f, (360 * f).toFloat(), false, Offset(1.dp.toPx(), 1.dp.toPx()), androidx.compose.ui.geometry.Size(size.width - 2.dp.toPx(), size.height - 2.dp.toPx()), style = Stroke(2.dp.toPx(), cap = androidx.compose.ui.graphics.StrokeCap.Round)) }
            }
        }
    }
}

// MARK: Lanes

@Composable
private fun LanesBody(data: LanesScreenData, actions: LanesScreenActions, power: PowerContext) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = NW.Space.gutter, end = NW.Space.gutter, top = 14.dp, bottom = 132.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        if (data.lanes.groups.isNotEmpty()) item {
            Row(Modifier.fillMaxWidth().padding(start = 150.dp).clearAndSetSemantics {}) {
                data.lanes.axis.forEachIndexed { i, t ->
                    Text(t, style = NW.Typo.monoMicro, color = NW.Palette.textQuiet.color, modifier = Modifier.weight(1f), textAlign = if (i == data.lanes.axis.lastIndex) TextAlign.End else TextAlign.Start)
                }
            }
        }
        if (data.lanes.groups.isEmpty()) item {
            Text(
                "No live sessions. Start Claude Code or Codex on your Mac, or start one from the + button, and it shows up here with what it's doing right now.",
                style = NW.Typo.caption, color = NW.Palette.textSecondary.color, modifier = Modifier.padding(top = 20.dp),
            )
        }
        items(data.lanes.groups, key = { it.key }) { g -> Group(g, actions, power) }
        data.lanes.coverageNote?.let { n -> item { Text(n, style = NW.Typo.caption, color = NW.Palette.textQuiet.color) } }
    }
}

@Composable
private fun Group(g: LaneGroup, actions: LanesScreenActions, power: PowerContext) {
    val head: Rgba = if (g.urgentState == StarState.NEEDS_YOU || g.urgentState == StarState.STUCK) NW.Palette.amber else g.hue.color
    NWGlassCard(padding = PaddingValues(0.dp)) {
        Row(Modifier.fillMaxWidth().height(40.dp).clip(RoundedCornerShape(topStart = NW.Radius.card, topEnd = NW.Radius.card)).background(head.opacity(0.10).color).padding(horizontal = 16.dp).semantics { heading() }, horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(head.color))
            Text(g.name.uppercase(), style = NW.Typo.labelLarge, color = head.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        for (r in g.rows) {
            Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.06f)))
            LaneRowView(r, actions, power)
        }
    }
}

@Composable
private fun LaneRowView(r: LaneRow, actions: LanesScreenActions, power: PowerContext) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 60.dp)
            .clickable(role = Role.Button, onClickLabel = if (r.interventionId != null) "Opens the decision" else "Opens the session") { actions.openRow(r) }
            .padding(horizontal = 12.dp)
            .semantics(mergeDescendants = true) {
                contentDescription = "${r.title}, ${r.state.label.lowercase()}, ${r.agent}" + (if (r.lastAction.isEmpty()) "" else ", ${r.lastAction}")
            },
        horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        // In the power story the glyph exhales and dims with the pause, and relights at its own resume.
        NWAnimated(fps = 20.0, active = power.moving) { _ ->
            val (light, scale) = power.story.starLight(r.id, r.state, power.now, power.pin)
            Box(Modifier.graphicsLayer { scaleX = scale.toFloat(); scaleY = scale.toFloat() }) {
                NWStarGlyph(r.seed, r.state.color, size = 30.dp, brightness = light)
            }
        }
        Column(Modifier.width(100.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(r.title, style = NW.Typo.mono, color = NW.Palette.textPrimary.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(r.state.label, style = NW.Typo.label, color = r.state.color.color, maxLines = 1)
        }
        ActivityStrip(r.strip, Modifier.weight(1f).height(30.dp))
    }
}

/**
 * The 4-hour strip on a lane: one thin bar per five minutes, ending at now. A bright teal bar is working, a short
 * dim one idle, an amber bar waiting, a jagged amber one stuck, a gap with a sky tick rate-limited, a grey band a
 * battery pause. A faint dot is time this phone did not see: it is never filled in.
 */
@Composable
fun ActivityStrip(cells: List<StripCell>, modifier: Modifier = Modifier) {
    Canvas(modifier.clearAndSetSemantics {}) {
        val n = maxOf(1, cells.size)
        val gap = 1.dp.toPx()
        val w = maxOf(1f, (size.width - gap * (n - 1)) / n)
        val h = size.height
        cells.forEachIndexed { i, cell ->
            val x = i * (w + gap)
            val last = i == cells.lastIndex
            fun bar(color: Color, height: Float) = drawRoundRect(color, Offset(x, h - height), androidx.compose.ui.geometry.Size(w, height), androidx.compose.ui.geometry.CornerRadius(1.dp.toPx()))
            when (cell.level) {
                null, StarState.OFFLINE -> drawCircle(Color.White.copy(alpha = if (cell.level == null) 0.12f else 0.2f), 1.dp.toPx(), Offset(x + w / 2, h - 1.dp.toPx()))
                StarState.WORKING -> bar(NW.Palette.teal.opacity(if (last) 1.0 else 0.55).color, h)
                StarState.NEEDS_YOU -> bar(NW.Palette.amber.opacity(if (last) 1.0 else 0.6).color, h * 0.8f)
                StarState.STUCK -> bar(NW.Palette.amber.opacity(if (last) 1.0 else 0.6).color, h * (if (i % 2 == 0) 1f else 0.55f))
                StarState.RATE_LIMITED -> drawRect(NW.Palette.sky.opacity(0.6).color, Offset(x, h - 2.dp.toPx()), androidx.compose.ui.geometry.Size(w, 2.dp.toPx()))
                StarState.PAUSED -> drawRect(Rgba.hex(0x8A8FA0).opacity(0.5).color, Offset(x, h - h * 0.4f), androidx.compose.ui.geometry.Size(w, h * 0.4f))
                StarState.IDLE -> bar(Color.White.copy(alpha = if (last) 0.5f else 0.22f), h * 0.2f)
            }
        }
    }
}
