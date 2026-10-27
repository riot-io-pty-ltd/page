package app.page.android.ui.nw.now

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.WbTwilight
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.remember
import app.page.android.model.DawnModel
import app.page.android.model.MotionCurve
import app.page.android.ui.nw.components.NWAuroraCanvas
import app.page.android.ui.nw.components.NWDawnLight
import app.page.android.ui.nw.components.NWOneShot
import app.page.android.ui.nw.components.nwClockSeconds
import app.page.android.ui.nw.theme.AuroraPalette
import app.page.android.ui.nw.theme.LocalMotionPin
import app.page.android.ui.nw.theme.NWMotionPin
import app.page.android.ui.nw.theme.pinned
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import app.page.android.model.ProblemState
import app.page.android.model.ReturnBrief
import app.page.android.model.SettledLine
import app.page.android.model.SettledLog
import app.page.android.ui.nw.components.NWButton
import app.page.android.ui.nw.components.NWButtonKind
import app.page.android.ui.nw.components.NWGlassCard
import app.page.android.ui.nw.components.nwIcon
import app.page.android.ui.nw.components.color
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba

/**
 * The Return Brief. Collapsed it is one line ("While you were away · 1h 52m"); expanded, a glass card with a
 * low sunrise behind the title (as bright as the absence was productive), three counts, a line per thing that
 * happened, and the two actions. Everything on it is counted from Page's own log. (iOS NWBriefCard.)
 */
@Composable
fun NWBriefCard(brief: ReturnBrief, expanded: Boolean, onToggle: () -> Unit, onDismiss: () -> Unit, onReview: () -> Unit, modifier: Modifier = Modifier) {
    if (!expanded) {
        NWGlassCard(modifier.clickable(role = Role.Button, onClickLabel = "Opens the summary of what happened while you were away", onClick = onToggle), radius = NW.Radius.row, padding = PaddingValues(horizontal = 16.dp)) {
            Row(Modifier.heightIn(min = 52.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.WbTwilight, null, tint = NW.Palette.teal.color, modifier = Modifier.size(20.dp))
                Text(brief.title, style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color, modifier = Modifier.weight(1f))
                Icon(Icons.Outlined.ChevronRight, null, tint = NW.Palette.textTertiary.color, modifier = Modifier.size(18.dp))
            }
        }
        return
    }
    NWGlassCard(modifier, padding = PaddingValues(0.dp)) {
        Box {
            // The sunrise: it rises once as the Brief opens, brighter the more finished.
            BriefSunrise(brief.sunrise, key = brief.window + " " + brief.awayText)
            Column(Modifier.padding(NW.Space.lg), verticalArrangement = Arrangement.spacedBy(18.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("WHILE YOU WERE AWAY", style = NW.Typo.label, color = NW.Palette.textTertiary.color)
                    Text(brief.awayText, style = NW.Typo.hero.copy(fontSize = androidx.compose.ui.unit.TextUnit(34f, androidx.compose.ui.unit.TextUnitType.Sp)), color = NW.Palette.textPrimary.color, modifier = Modifier.semantics { heading() })
                    Text(brief.window, style = NW.Typo.monoSmall, color = NW.Palette.textTertiary.color)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                    for (c in brief.counts) {
                        val col: Rgba = when (c.kind) {
                            ReturnBrief.Count.Kind.FINISHED -> NW.Palette.teal
                            ReturnBrief.Count.Kind.IN_FLIGHT -> NW.Palette.sky
                            ReturnBrief.Count.Kind.NEED_YOU -> NW.Palette.amber
                        }
                        Column(
                            Modifier.weight(1f).clip(RoundedCornerShape(14.dp)).background(Color.White.copy(alpha = 0.05f)).padding(12.dp).semantics(mergeDescendants = true) {},
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Text("${c.value}", style = NW.Typo.hero, color = col.color)
                            Text(c.kind.raw.uppercase(), style = NW.Typo.label, color = NW.Palette.textTertiary.color, maxLines = 1)
                        }
                    }
                }
                if (brief.lines.isEmpty()) Text("Nothing happened that needed you.", style = NW.Typo.body, color = NW.Palette.textSecondary.color)
                Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    for (line in brief.lines) {
                        val t: Rgba = when (line.tone) {
                            ReturnBrief.Tone.GOOD -> NW.Palette.green
                            ReturnBrief.Tone.NEUTRAL -> NW.Palette.sky
                            ReturnBrief.Tone.WARN -> NW.Palette.amber
                        }
                        Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
                            Box(Modifier.size(36.dp).clip(RoundedCornerShape(10.dp)).background(t.opacity(0.14).color), contentAlignment = Alignment.Center) {
                                Icon(nwIcon(line.symbol), null, tint = t.color, modifier = Modifier.size(20.dp))
                            }
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(line.title, style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color)
                                line.detail?.let { Text(it, style = NW.Typo.caption, color = NW.Palette.textSecondary.color) }
                            }
                        }
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                    NWButton("Dismiss", onDismiss, Modifier.weight(1f))
                    if (brief.finished > 0) NWButton("Review the ${brief.finished} finished", onReview, Modifier.weight(1.4f), kind = NWButtonKind.BRIGHT)
                }
            }
        }
    }
}

/**
 * When each absence's sunrise first played (on the [nwClockSeconds] base), so it plays once per absence however often
 * the Brief is scrolled away, collapsed and reopened, or Now is left and come back to.
 */
private object BriefSunriseBook {
    private val starts = HashMap<String, Double>()

    @Synchronized
    fun start(key: String): Double = starts.getOrPut(key) { nwClockSeconds() }
}

/**
 * The Brief's sunrise behind its title: the same sweep as Dusk and dawn, as bright as the absence was productive
 * ([share] finished). It rises once as the Brief opens, then holds a low warmth, still. The render harness pins it
 * ([NWMotionPin.Kind.BRIEF]); Remove animations draws it risen. (iOS NWBriefCard.sunrise.)
 */
@Composable
private fun BriefSunrise(share: Double, key: String) {
    val pinned = LocalMotionPin.current.pinned(NWMotionPin.Kind.BRIEF)
    val openedAt = remember(key) { BriefSunriseBook.start(key) }
    NWOneShot(openedAt, DawnModel.sweepDuration + 0.6, pinned = pinned) { e ->
        val s = DawnModel.briefSunrise(e ?: DawnModel.sweepDuration, share)
        // Gold while it rises, settling to a low warmth that stays.
        val warmth = s.strength * (e?.let { 1 - 0.55 * MotionCurve.smooth((it - DawnModel.sweepDuration) / 0.6) } ?: 0.45)
        Box(
            Modifier.fillMaxWidth().height(150.dp)
                .clip(RoundedCornerShape(topStart = NW.Radius.card, topEnd = NW.Radius.card))
                .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                .drawWithContent {
                    drawContent()
                    drawRect(Brush.verticalGradient(listOf(Color.White, Color.Transparent)), blendMode = BlendMode.DstIn)
                }
                .clearAndSetSemantics {},
        ) {
            NWAuroraCanvas(AuroraPalette.brief(share * s.sweep), 2.0, Modifier.fillMaxSize().graphicsLayer { alpha = 0.55f })
            NWDawnLight(s.sweep, warmth, Modifier.fillMaxSize())
        }
    }
}

/**
 * Settled: today's receipt lines, then a headline card per earlier day. This is where History went. "See all"
 * opens every settled page and the day stats. (iOS NWSettledList.)
 */
@Composable
fun NWSettledList(log: SettledLog, modifier: Modifier = Modifier, onSeeAll: (() -> Unit)? = null) {
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("SETTLED", style = NW.Typo.labelLarge, color = NW.Palette.textTertiary.color, modifier = Modifier.weight(1f).semantics { heading() })
            if (onSeeAll != null) Row(
                Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(12.dp)).clickable(role = Role.Button, onClick = onSeeAll).padding(horizontal = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("See all", style = NW.Typo.captionStrong, color = NW.Palette.textSecondary.color)
                Icon(Icons.Outlined.ChevronRight, null, tint = NW.Palette.textSecondary.color, modifier = Modifier.size(14.dp))
            }
        }
        if (log.today.isEmpty() && log.days.isEmpty()) {
            Text("Nothing settled yet. Every decision you make, and every turn that finishes, lands here.", style = NW.Typo.caption, color = NW.Palette.textQuiet.color)
        }
        for (line in log.today) {
            val c: Rgba = when (line.tone) {
                SettledLine.Tone.APPROVED -> NW.Palette.green
                SettledLine.Tone.SENT -> NW.Palette.sky
                SettledLine.Tone.NEUTRAL -> NW.Palette.textQuiet
            }
            Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(7.dp).clip(CircleShape).background(c.color))
                Text(line.text, style = NW.Typo.monoSmall, color = NW.Palette.textSecondary.color, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                Text(listOfNotNull(line.age, line.status).joinToString(" · "), style = NW.Typo.monoSmall, color = NW.Palette.textTertiary.color, maxLines = 1)
            }
        }
        for (day in log.days) {
            Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(7.dp).clip(CircleShape).background(NW.Palette.textQuiet.color))
                Text(day.headline, style = NW.Typo.monoSmall, color = NW.Palette.textSecondary.color, maxLines = 2)
            }
        }
    }
}

/** What is wrong, what it means, and the one obvious fix. It sits first in the Now stream under a Horizon that has gone hollow. (iOS NWProblemCard.) */
@Composable
fun NWProblemCard(problem: ProblemState, onAction: (ProblemState.Action) -> Unit, modifier: Modifier = Modifier) {
    val tone = if (problem.tone == ProblemState.Tone.SLATE) Rgba.hex(0x8A93A8) else NW.Palette.amber
    NWGlassCard(modifier, radius = 24.dp, padding = PaddingValues(18.dp), tint = if (problem.tone == ProblemState.Tone.AMBER) NW.Palette.amber else null) {
        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                for (d in problem.details) Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.Top) {
                    Icon(nwIcon(d.symbol), null, tint = tone.color, modifier = Modifier.size(24.dp))
                    Text(d.text, style = NW.Typo.body, color = NW.Palette.textSecondary.color, modifier = Modifier.weight(1f))
                }
            }
            NWButton(problem.actionTitle, { onAction(problem.action) }, Modifier.fillMaxWidth(), kind = if (problem.tone == ProblemState.Tone.SLATE) NWButtonKind.QUIET else NWButtonKind.AMBER)
            val t = problem.secondaryTitle
            val a = problem.secondaryAction
            if (t != null && a != null) NWButton(t, { onAction(a) }, Modifier.fillMaxWidth())
        }
    }
}
