package app.page.android.ui.nw.history

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.CircularProgressIndicator
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
import app.page.android.model.HistoryDay
import app.page.android.model.HistoryEmpty
import app.page.android.model.HistoryRow
import app.page.android.model.HistoryScreenModel
import app.page.android.model.RelativeTime
import app.page.android.model.SettledLine
import app.page.android.ui.nw.components.NWBackdrop
import app.page.android.ui.nw.components.NWButton
import app.page.android.ui.nw.components.NWGlassCard
import app.page.android.ui.nw.components.NWSegmented
import app.page.android.ui.nw.components.NWTonightCard
import app.page.android.ui.nw.components.nwIcon
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba

class HistoryScreenData(val model: HistoryScreenModel, /** What to say while there are no rows (null when there are some). */ val empty: HistoryEmpty?)

class HistoryScreenActions(val close: () -> Unit = {}, val retry: () -> Unit = {})

enum class HistorySegment { HISTORY, STATS }

/**
 * History, the Night Watch way: Settled's lines for every page you have resolved, one glass card per day, and the
 * day's numbers (the three rings, four tiles, the busiest projects) under a second segment. Reached from
 * Settled's "See all" and from the Tower. (iOS NWHistoryScreen.)
 */
@Composable
fun NWHistoryScreen(data: HistoryScreenData, actions: HistoryScreenActions, modifier: Modifier = Modifier, initial: HistorySegment = HistorySegment.HISTORY) {
    var segment by remember { mutableStateOf(initial) }
    val large = LocalDensity.current.fontScale >= 1.5f
    Box(modifier.fillMaxSize().background(NW.Palette.backgroundDeep.color)) {
        NWBackdrop()
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().verticalScroll(rememberScrollState()).padding(horizontal = NW.Space.gutter).padding(top = 18.dp, bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("SETTLED", style = NW.Typo.labelLarge.copy(letterSpacing = 2.sp), color = NW.Palette.teal.color)
                    Text("History", style = NW.Typo.hero.copy(fontSize = 34.sp, letterSpacing = (-0.8).sp), color = NW.Palette.textPrimary.color, modifier = Modifier.semantics { heading() })
                    if (segment == HistorySegment.HISTORY && data.model.total > 0) Text("${data.model.total} resolved page${if (data.model.total == 1) "" else "s"}", style = NW.Typo.caption, color = NW.Palette.textTertiary.color)
                }
                Box(Modifier.size(48.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.08f)).clickable(role = Role.Button, onClickLabel = "Close", onClick = actions.close), contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.Close, "Close", tint = NW.Palette.textPrimary.color, modifier = Modifier.size(20.dp))
                }
            }
            NWSegmented(listOf(HistorySegment.HISTORY to "History", HistorySegment.STATS to "Stats"), segment, { segment = it })
            when (segment) {
                HistorySegment.HISTORY -> HistoryTab(data, actions, large)
                HistorySegment.STATS -> StatsTab(data, actions, large)
            }
        }
    }
}

private fun toneColor(t: SettledLine.Tone): Rgba = when (t) { SettledLine.Tone.APPROVED -> NW.Palette.green; SettledLine.Tone.SENT -> NW.Palette.sky; SettledLine.Tone.NEUTRAL -> NW.Palette.textQuiet }

@Composable
private fun HistoryTab(data: HistoryScreenData, actions: HistoryScreenActions, large: Boolean) {
    val empty = data.empty
    if (empty != null) { EmptyCard(empty, actions); return }
    for (day in data.model.days) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            DayHeader(day, large)
            NWGlassCard(padding = PaddingValues(0.dp)) {
                day.rows.forEachIndexed { i, row ->
                    if (i > 0) Box(Modifier.fillMaxWidth().padding(start = 33.dp).height(1.dp).background(Color.White.copy(alpha = 0.07f)))
                    RowView(row, large)
                }
            }
        }
    }
}

@Composable
private fun DayHeader(day: HistoryDay, large: Boolean) {
    Column(Modifier.fillMaxWidth().semantics(mergeDescendants = true) { heading() }) {
        if (large) {
            Text(day.title.uppercase(), style = NW.Typo.labelLarge.copy(letterSpacing = 1.2.sp), color = NW.Palette.textTertiary.color)
            Text(day.summary, style = NW.Typo.caption, color = NW.Palette.textQuiet.color)
        } else Row(verticalAlignment = Alignment.Bottom) {
            Text(day.title.uppercase(), style = NW.Typo.labelLarge.copy(letterSpacing = 1.2.sp), color = NW.Palette.textTertiary.color)
            Box(Modifier.weight(1f))
            Text(day.summary, style = NW.Typo.caption, color = NW.Palette.textQuiet.color, textAlign = TextAlign.End, modifier = Modifier.padding(start = 8.dp))
        }
    }
}

@Composable
private fun RowView(row: HistoryRow, large: Boolean) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp).semantics(mergeDescendants = false) { contentDescription = row.spoken }.clearAndSetSemantics { contentDescription = row.spoken }, horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top) {
        Box(Modifier.padding(top = 6.dp).size(7.dp).clip(CircleShape).background(toneColor(row.tone).color))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            if (large) {
                Text(row.text, style = NW.Typo.monoSmall, color = NW.Palette.textSecondary.color)
                Text(row.trailing, style = NW.Typo.monoSmall, color = NW.Palette.textTertiary.color)
            } else Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(row.text, style = NW.Typo.monoSmall, color = NW.Palette.textSecondary.color, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                Text(row.trailing, style = NW.Typo.monoSmall, color = NW.Palette.textTertiary.color, maxLines = 1, softWrap = false)
            }
            Text(row.detail, style = NW.Typo.monoMicro, color = NW.Palette.textQuiet.color, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun EmptyCard(e: HistoryEmpty, actions: HistoryScreenActions) {
    when (e) {
        HistoryEmpty.Loading -> NWGlassCard {
            Row(Modifier.semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(20.dp), color = NW.Palette.textSecondary.color, strokeWidth = 2.dp)
                Text("Loading history…", style = NW.Typo.body, color = NW.Palette.textSecondary.color)
            }
        }
        is HistoryEmpty.Failed -> NWGlassCard(padding = PaddingValues(18.dp), tint = NW.Palette.amber) {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.Top) {
                    Icon(nwIcon("wifi.exclamationmark"), null, tint = NW.Palette.amber.color, modifier = Modifier.size(24.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text("Couldn't load history", style = NW.Typo.title, color = NW.Palette.textPrimary.color)
                        Text(e.why, style = NW.Typo.body, color = NW.Palette.textSecondary.color)
                    }
                }
                NWButton("Try again", actions.retry, Modifier.fillMaxWidth())
            }
        }
        HistoryEmpty.None -> NWGlassCard {
            Column(Modifier.fillMaxWidth().padding(vertical = 12.dp).semantics(mergeDescendants = true) {}, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("No history yet", style = NW.Typo.title, color = NW.Palette.textPrimary.color)
                Text("Pages you've resolved will appear here.", style = NW.Typo.body, color = NW.Palette.textSecondary.color, textAlign = TextAlign.Center)
            }
        }
    }
}

@Composable
private fun StatsTab(data: HistoryScreenData, actions: HistoryScreenActions, large: Boolean) {
    (data.empty as? HistoryEmpty.Failed)?.let { f ->
        // The history failed to load: say so here too, and that the numbers are partial.
        NWGlassCard(tint = NW.Palette.amber) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Couldn't load history", style = NW.Typo.title, color = NW.Palette.textPrimary.color)
                Text("${f.why} Stats only include pages on this screen.", style = NW.Typo.body, color = NW.Palette.textSecondary.color)
                NWButton("Try again", actions.retry, Modifier.fillMaxWidth())
            }
        }
    }
    NWTonightCard(data.model.rings)
    val s = data.model.stats
    val items = listOf(
        Triple("TODAY", "${s.today}", if (s.today == 1) "page" else "pages"),
        Triple("THIS WEEK", "${s.thisWeek}", if (s.thisWeek == 1) "page" else "pages"),
        Triple("AVG RESPONSE", s.avgResponseSeconds?.let { RelativeTime.compact(it) } ?: "—", if (s.repliedCount == 0) "no replies yet" else "across ${s.repliedCount} repl${if (s.repliedCount == 1) "y" else "ies"}"),
        Triple("PENDING NOW", "${data.model.pending}", ""),
    )
    if (large) Column(verticalArrangement = Arrangement.spacedBy(12.dp)) { items.forEach { Tile(it, Modifier.fillMaxWidth()) } }
    else Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) { Tile(items[0], Modifier.weight(1f)); Tile(items[1], Modifier.weight(1f)) }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) { Tile(items[2], Modifier.weight(1f)); Tile(items[3], Modifier.weight(1f)) }
    }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("TOP PROJECTS", style = NW.Typo.labelLarge.copy(letterSpacing = 1.2.sp), color = NW.Palette.textTertiary.color, modifier = Modifier.semantics { heading() })
        val top = s.topProjects
        if (top.isEmpty()) NWGlassCard { Text("Nothing yet", style = NW.Typo.body, color = NW.Palette.textTertiary.color) }
        else NWGlassCard(padding = PaddingValues(0.dp)) {
            top.forEachIndexed { i, p ->
                if (i > 0) Box(Modifier.fillMaxWidth().padding(start = 33.dp).height(1.dp).background(Color.White.copy(alpha = 0.07f)))
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp).semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(p.name, style = NW.Typo.monoSmall, color = NW.Palette.textSecondary.color, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    Text("${p.count}", style = NW.Typo.monoSmall, color = NW.Palette.textPrimary.color)
                }
            }
        }
    }
}

@Composable
private fun Tile(t: Triple<String, String, String>, modifier: Modifier) {
    NWGlassCard(modifier, radius = NW.Radius.row) {
        Column(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(t.first, style = NW.Typo.label, color = NW.Palette.textTertiary.color)
            Text(t.second, style = NW.Typo.hero.copy(fontSize = 28.sp, fontWeight = FontWeight.Bold), color = NW.Palette.textPrimary.color, maxLines = 1)
            if (t.third.isNotEmpty()) Text(t.third, style = NW.Typo.caption, color = NW.Palette.textSecondary.color)
        }
    }
}
