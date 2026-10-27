package app.page.android.ui.nw.sky

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
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
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.page.android.model.Constellation
import app.page.android.model.DuskDawnLog
import app.page.android.ui.nw.components.NWDawnLight
import app.page.android.ui.nw.components.NWHorizonBand
import app.page.android.ui.nw.theme.LocalFixedNow
import app.page.android.ui.nw.theme.LocalFixedPhase
import app.page.android.ui.nw.theme.LocalMotionPin
import app.page.android.ui.nw.theme.LocalReduceMotion
import app.page.android.ui.nw.theme.NWMotionPin
import androidx.compose.ui.unit.Dp
import java.time.Instant
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableIntStateOf
import kotlinx.coroutines.delay
import app.page.android.model.LaneGroup
import app.page.android.model.LaneRow
import app.page.android.model.LanesModel
import app.page.android.model.NWDestination
import app.page.android.model.NowBanner
import app.page.android.model.PulseModel
import app.page.android.model.SessionAvailabilityCopy
import app.page.android.model.SkyLabelKind
import app.page.android.model.SkyMode
import app.page.android.model.SkyModel
import app.page.android.model.SkySize
import app.page.android.model.SkyStar
import app.page.android.model.StarState
import app.page.android.model.StripCell
import app.page.android.ui.nw.components.NWAnimated
import app.page.android.ui.nw.components.NWBannerCard
import app.page.android.ui.nw.components.NWGlassCard
import app.page.android.ui.nw.components.NWLivingAurora
import app.page.android.ui.nw.components.NWPulseOrb
import app.page.android.ui.nw.components.NWPulseStyle
import app.page.android.ui.nw.components.NWSegmented
import app.page.android.ui.nw.components.NWStarGlyph
import app.page.android.ui.nw.components.NWTonightCard
import app.page.android.ui.nw.components.color
import app.page.android.ui.nw.components.nwStarPath
import app.page.android.ui.nw.shell.NWCappedFontScale
import app.page.android.ui.nw.theme.AuroraPalette
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba

/** Everything Sky and Lanes draw, as values. */
data class SkyScreenData(
    val sky: SkyModel,
    val lanes: LanesModel,
    val mode: SkyMode,
    /** Why live sessions can't load, when they can't. */
    val availability: SessionAvailabilityCopy? = null,
    /** The star whose tooltip is open. */
    val selectedStar: String? = null,
    /** The last battery pause: the dusk and the dawn ([SkyPowerStory]). */
    val duskDawn: DuskDawnLog = DuskDawnLog(),
)

class SkyScreenActions(
    val setMode: (SkyMode) -> Unit = {},
    val select: (String?) -> Unit = {},
    val openStar: (SkyStar) -> Unit = {},
    val tapMoon: () -> Unit = {},
    val availabilityAction: (SessionAvailabilityCopy.Action) -> Unit = {},
    val toNow: () -> Unit = {},
)

/**
 * SKY: the fleet. Every live session is a star, every project a constellation (named, joined by faint lines); the
 * Mac is the moon. Or LANES: the same fleet as an accessible list with a 4-hour strip per session. The last mode is
 * remembered. Nothing actionable lives only here: amber stars are also cards in Now. (iOS NWSkyScreen.)
 */
@Composable
fun NWSkyScreen(data: SkyScreenData, actions: SkyScreenActions, modifier: Modifier = Modifier) {
    val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val power = rememberPower(data)
    Box(modifier.fillMaxSize()) {
        if (data.mode == SkyMode.SKY) SkyBackdrop(data, power)
        Column(Modifier.fillMaxSize()) {
            Header(data, actions, Modifier.padding(top = top + 8.dp))
            val a = data.availability
            if (a != null) {
                val banner = NowBanner(
                    "availability", if (a.tone == SessionAvailabilityCopy.Tone.INFO) NowBanner.Tone.INFO else if (a.tone == SessionAvailabilityCopy.Tone.ERROR) NowBanner.Tone.ERROR else NowBanner.Tone.WARNING,
                    a.systemImage, a.title, a.message, a.actionTitle, when (a.action) { SessionAvailabilityCopy.Action.REPAIR -> NowBanner.Action.REPAIR; SessionAvailabilityCopy.Action.RETRY -> NowBanner.Action.RETRY; null -> null },
                )
                NWBannerCard(banner, Modifier.padding(NW.Space.gutter)) { act -> actions.availabilityAction(if (act == NowBanner.Action.REPAIR) SessionAvailabilityCopy.Action.REPAIR else SessionAvailabilityCopy.Action.RETRY) }
            } else when (data.mode) {
                SkyMode.SKY -> SkyBody(data, actions, power)
                SkyMode.LANES -> LanesBody(data, actions)
            }
        }
    }
}

@Composable
private fun Header(data: SkyScreenData, actions: SkyScreenActions, modifier: Modifier) {
    Row(modifier.fillMaxWidth().padding(horizontal = NW.Space.gutter), verticalAlignment = Alignment.Top) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("Sky", style = NW.Typo.hero.copy(fontSize = 40.sp, letterSpacing = (-1).sp), color = NW.Palette.textPrimary.color, modifier = Modifier.semantics { heading() })
            Text(data.sky.headline, style = NW.Typo.caption, color = NW.Palette.textTertiary.color)
        }
        Box(Modifier.width(176.dp)) { NWSegmented(SkyMode.entries.map { it to it.label }, data.mode, actions.setMode) }
    }
}

/** The power story for [data], with the clock it is drawn at: the wall clock while live, null when drawn still. */
private class PowerContext(val story: SkyPowerStory, val live: Boolean, val fixedNow: Instant?, val pin: NWMotionPin?) {
    val now: Instant? get() = if (live) (fixedNow ?: Instant.now()) else null
    val moving: Boolean get() = story.isMoving(fixedNow ?: Instant.now(), pin)
}

/**
 * The power story for the whole screen, once. The clocks that draw it read [PowerContext.moving] where they start, so
 * when the story stops moving the screen is recomposed once at that moment and every clock stops (a battery pause
 * must not keep the sky redrawing).
 */
@Composable
private fun rememberPower(data: SkyScreenData): PowerContext {
    val stars = data.sky.constellations.flatMap { it.stars }
    val story = remember(data.sky.paused, data.duskDawn, stars) { SkyPowerStory(data.sky.paused, data.duskDawn, stars) }
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

@Composable
private fun SkyBackdrop(data: SkyScreenData, power: PowerContext) {
    // A battery pause that has settled is a still night: no clock while agents are paused for power.
    NWAnimated(active = !data.sky.paused || power.moving) { t ->
        val light = power.story.skyLight(power.now, power.pin)
        NWLivingAurora(
            light.palette, t,
            Modifier.fillMaxSize().graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }.drawWithContent {
                drawContent()
                drawRect(Brush.verticalGradient(listOf(Color.White, Color.White.copy(alpha = 0.7f), Color.Transparent)), blendMode = BlendMode.DstIn)
            }.clearAndSetSemantics {},
            stars = light.stars,
        )
    }
}

/** The power story over the sky: the grey horizon band under the stars while paused, and the dawn's gold rising from it. No clock otherwise. */
@Composable
private fun PowerStory(height: Dp, power: PowerContext) {
    val bandY = maxOf(120.dp, height - SkyModel.labelBottomReserve.dp - 4.dp)
    NWAnimated(active = power.moving) { _ ->
        val light = power.story.skyLight(power.now, power.pin)
        Box(Modifier.fillMaxSize().clearAndSetSemantics {}) {
            // The dawn rises from the band to the very top of the screen (over the header too).
            light.dawn?.let { d -> NWDawnLight(d.sweep, d.warmth, Modifier.fillMaxWidth().height(bandY + 160.dp).offset(y = (-160).dp)) }
            NWHorizonBand(light.band, Modifier.offset(y = bandY - 6.dp))
        }
    }
}

@Composable
private fun SkyBody(data: SkyScreenData, actions: SkyScreenActions, power: PowerContext) {
    Box(Modifier.fillMaxSize()) {
        BoxWithConstraints(Modifier.fillMaxSize().clickable(interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }, indication = null) { actions.select(null) }) {
            val w = maxWidth
            val h = maxHeight
            val size = SkySize(w.value.toDouble(), h.value.toDouble())
            val points = SkyModel.starPoints(data.sky.constellations, size)
            val labels = SkyModel.labelLayout(data.sky.constellations, size)
            val hit = SkyModel.hitRadii(data.sky.constellations, size)
            PowerStory(h, power)
            if (data.sky.isEmpty) Column(Modifier.align(Alignment.Center).padding(horizontal = 36.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                NWPulseOrb(NWPulseStyle.Style.QUIET, Modifier.size(120.dp))
                Text("No live sessions", style = NW.Typo.title, color = NW.Palette.textPrimary.color)
                Text("Start Claude Code or Codex on your Mac, or dispatch one from here, and it appears as a star.", style = NW.Typo.caption, color = NW.Palette.textSecondary.color, textAlign = TextAlign.Center)
            }
            for (c in data.sky.constellations) ConstellationView(c, points, labels, hit, data, actions, power)
            Box(Modifier.align(Alignment.TopEnd).padding(top = 6.dp, end = 4.dp)) { Moon(data, actions) }
            val sel = data.selectedStar?.let { id -> data.sky.constellations.flatMap { it.stars }.firstOrNull { it.id == id } }
            if (sel != null) Box(Modifier.align(Alignment.BottomCenter).padding(bottom = 130.dp)) { Tooltip(sel, actions) }
        }
        // The label layout reserves a fixed height for the card (SkyModel.labelBottomReserve).
        Column(Modifier.align(Alignment.BottomCenter).padding(horizontal = NW.Space.gutter).padding(bottom = 108.dp).graphicsLayer { alpha = if (data.selectedStar == null) 1f else 0f }) {
            NWCappedFontScale(1.15f) { NWTonightCard(data.sky.rings) }
        }
    }
}

@Composable
private fun ConstellationView(c: Constellation, points: Map<String, app.page.android.model.SkyPoint>, labels: List<app.page.android.model.SkyLabelPlacement>, hit: Map<String, Double>, data: SkyScreenData, actions: SkyScreenActions, power: PowerContext) {
    fun pt(s: SkyStar) = points[s.id]!!
    // The lines.
    Canvas(Modifier.fillMaxSize().clearAndSetSemantics {}) {
        for (l in c.links) {
            if (l.size != 2 || l[0] !in c.stars.indices || l[1] !in c.stars.indices) continue
            val a = pt(c.stars[l[0]])
            val b = pt(c.stars[l[1]])
            drawLine(c.hue.color.opacity(0.32).color, Offset(a.x.toFloat().dp.toPx(), a.y.toFloat().dp.toPx()), Offset(b.x.toFloat().dp.toPx(), b.y.toFloat().dp.toPx()), 1.dp.toPx())
        }
    }
    // Where each label sits is decided once, for the whole sky, so none lands on another or on a star.
    // The label boxes are laid out for the default text size: these two stay at it (Lanes is the list that scales with the system font).
    labels.firstOrNull { it.kind == SkyLabelKind.PROJECT && it.id == c.key }?.let { l ->
        NWCappedFontScale(1.0f) {
            Box(
                Modifier.offset(l.rect.x.toFloat().dp, l.rect.y.toFloat().dp).size(l.rect.width.toFloat().dp, l.rect.height.toFloat().dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.28f))
                    .semantics { heading() },
                contentAlignment = Alignment.Center,
            ) {
                Text(l.text, style = NW.Typo.label, color = (if (c.urgentState == StarState.NEEDS_YOU) NW.Palette.amber else c.hue.color).color, maxLines = 1, softWrap = false, overflow = TextOverflow.Clip)
            }
        }
    }
    for (s in c.stars) {
        val p = pt(s)
        // The tap target is a circle that never reaches another star's (SkyModel.hitRadii): what is drawn under the finger is exactly the star that opens.
        val r = (hit[s.id] ?: SkyModel.maxHitRadius).toFloat()
        Box(
            Modifier.offset((p.x.toFloat() - r).dp, (p.y.toFloat() - r).dp).size((r * 2).dp).clip(CircleShape)
                .clickable(role = Role.Button, onClickLabel = "Shows details") { actions.select(if (data.selectedStar == s.id) null else s.id) }
                .semantics { contentDescription = "${s.title}, ${c.name}, ${s.state.label.lowercase()}" },
            contentAlignment = Alignment.Center,
        ) { StarView(s, data, power) }
        labels.firstOrNull { it.kind == SkyLabelKind.CAPTION && it.id == s.id }?.let { l ->
            NWCappedFontScale(1.0f) {
                Box(
                    Modifier.offset(l.rect.x.toFloat().dp, l.rect.y.toFloat().dp).size(l.rect.width.toFloat().dp, l.rect.height.toFloat().dp).clearAndSetSemantics {},
                    contentAlignment = if (l.rect.midX < p.x) Alignment.CenterEnd else Alignment.CenterStart,
                ) { Text(l.text, style = NW.Typo.monoMicro, color = NW.Palette.textSecondary.opacity(0.8).color, maxLines = 1, softWrap = false, overflow = TextOverflow.Clip) }
            }
        }
    }
}

@Composable
private fun StarView(s: SkyStar, data: SkyScreenData, power: PowerContext) {
    val color = s.state.color
    val size = if (s.state == StarState.NEEDS_YOU) 38.dp else 28.dp
    Box(Modifier.size(56.dp).clearAndSetSemantics {}, contentAlignment = Alignment.Center) {
        when (s.state) {
            StarState.NEEDS_YOU -> {
                // The pulse's amber ripple: one waiting item, one ring.
                NWAnimated { t ->
                    Canvas(Modifier.size(56.dp)) {
                        for (r in PulseModel(0, 1).ripples(t + (s.seed % 13UL).toDouble() * 0.21)) {
                            val d = size.toPx() * 0 + 38.dp.toPx() * (1.2f + 1.4f * r.progress.toFloat())
                            drawCircle(color.opacity(0.5 * r.opacity).color, d / 2, center, style = Stroke(1.dp.toPx()))
                        }
                    }
                }
                NWStarGlyph(s.seed, color, size = size, brightness = s.brightness)
            }
            StarState.STUCK -> {
                Canvas(Modifier.size(56.dp)) { drawCircle(color.opacity(0.7).color, 28.dp.toPx() * 1.6f / 2, center, style = Stroke(1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx())))) }
                NWStarGlyph(s.seed, color, size = size, brightness = s.brightness)
            }
            StarState.RATE_LIMITED -> Canvas(Modifier.size(56.dp)) { drawPath(nwStarPath(s.seed, center, 28.dp.toPx() * 0.35f), color.opacity(0.9).color, style = Stroke(1.4.dp.toPx())) }
            else -> {
                // Working stars breathe with the pulse's teal breath, each a little out of step; in the power story
                // they exhale and dim together at dusk and relight one by one at dawn.
                val working = s.state == StarState.WORKING
                NWAnimated(fps = 20.0, active = (working && !data.sky.paused) || power.moving) { t ->
                    val (light, scale) = power.story.starLight(s, power.now, power.pin)
                    val breath = if (working) 0.85 + 0.15 * PulseModel(1, 0).breath(t + (s.seed % 7UL).toDouble() * 0.57) else 1.0
                    Box(Modifier.graphicsLayer { scaleX = scale.toFloat(); scaleY = scale.toFloat() }) {
                        NWStarGlyph(s.seed, color, size = size, brightness = s.brightness * breath * light)
                    }
                }
            }
        }
    }
}

@Composable
private fun Moon(data: SkyScreenData, actions: SkyScreenActions) {
    val m = data.sky.moon
    NWCappedFontScale(1.3f) {
        Row(
            Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp)).clickable(role = Role.Button, onClickLabel = "Opens the Tower at Power", onClick = actions.tapMoon).padding(start = 10.dp, end = 6.dp)
                .semantics { contentDescription = "${data.sky.macName}, battery ${m.percent}, ${m.detail}" },
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

@Composable
private fun Tooltip(s: SkyStar, actions: SkyScreenActions) {
    NWGlassCard(Modifier.padding(horizontal = NW.Space.gutter).widthIn(max = 360.dp), radius = NW.Radius.row, padding = PaddingValues(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            NWStarGlyph(s.seed, s.state.color, size = 30.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(s.title, style = NW.Typo.monoSmall, color = NW.Palette.textPrimary.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    "${s.state.label.lowercase().replaceFirstChar { it.uppercase() }} · ${s.agent} · #${s.id.take(4)}" + (if (s.lastAction.isEmpty()) "" else " · ${s.lastAction}"),
                    style = NW.Typo.monoMicro, color = NW.Palette.textTertiary.color, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                if (s.interventionId != null) "Decide" else "Open", style = NW.Typo.captionStrong, color = NW.Palette.onBright.color,
                modifier = Modifier.heightIn(min = 48.dp).clip(CircleShape).background(NW.Palette.teal.color).clickable(role = Role.Button) { actions.openStar(s) }.padding(horizontal = 16.dp).padding(vertical = 14.dp),
            )
        }
    }
}

// MARK: Lanes

@Composable
private fun LanesBody(data: SkyScreenData, actions: SkyScreenActions) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = NW.Space.gutter, end = NW.Space.gutter, top = 14.dp, bottom = 132.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        item {
            Row(Modifier.fillMaxWidth().padding(start = 150.dp).clearAndSetSemantics {}) {
                data.lanes.axis.forEachIndexed { i, t ->
                    Text(t, style = NW.Typo.monoMicro, color = NW.Palette.textQuiet.color, modifier = Modifier.weight(1f), textAlign = if (i == data.lanes.axis.lastIndex) TextAlign.End else TextAlign.Start)
                }
            }
        }
        if (data.lanes.groups.isEmpty()) item {
            Text("No live sessions. Start Claude Code or Codex on your Mac and it shows up here, with what it's doing right now.", style = NW.Typo.caption, color = NW.Palette.textSecondary.color, modifier = Modifier.padding(top = 20.dp))
        }
        items(data.lanes.groups, key = { it.key }) { g -> Group(g, actions) }
        data.lanes.coverageNote?.let { n -> item { Text(n, style = NW.Typo.caption, color = NW.Palette.textQuiet.color) } }
    }
}

@Composable
private fun Group(g: LaneGroup, actions: SkyScreenActions) {
    val head: Rgba = if (g.urgentState == StarState.NEEDS_YOU || g.urgentState == StarState.STUCK) NW.Palette.amber else g.hue.color
    NWGlassCard(padding = PaddingValues(0.dp)) {
        Row(Modifier.fillMaxWidth().height(40.dp).clip(RoundedCornerShape(topStart = NW.Radius.card, topEnd = NW.Radius.card)).background(head.opacity(0.10).color).padding(horizontal = 16.dp).semantics { heading() }, horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(head.color))
            Text(g.name.uppercase(), style = NW.Typo.labelLarge, color = head.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        for (r in g.rows) {
            Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.06f)))
            LaneRowView(r, actions)
        }
    }
}

@Composable
private fun LaneRowView(r: LaneRow, actions: SkyScreenActions) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 60.dp)
            .clickable(role = Role.Button, onClickLabel = if (r.interventionId != null) "Opens the decision" else "Opens the session") {
                actions.openStar(SkyStar(r.id, r.title, r.state, 0.0, 0.0, 1.0, r.lastAction, r.interventionId, r.agent, true, r.seed))
            }
            .padding(horizontal = 12.dp).semantics(mergeDescendants = true) { contentDescription = "${r.title}, ${r.state.label.lowercase()}, ${r.agent}" },
        horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        NWStarGlyph(r.seed, r.state.color, size = 30.dp)
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
