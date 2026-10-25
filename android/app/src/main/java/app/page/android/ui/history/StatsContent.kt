package app.page.android.ui.history

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.RelayClient
import app.page.android.model.PageStats
import app.page.android.model.RelativeTime
import app.page.android.ui.components.BannerTone
import app.page.android.ui.components.SectionTitle
import app.page.android.ui.components.StatusBanner
import app.page.android.ui.components.card
import app.page.android.ui.theme.PageType
import app.page.android.ui.theme.Space
import app.page.android.ui.theme.colors
import java.time.Instant
import kotlinx.coroutines.launch

/** Stats, shown as the second segment of the History tab. */
@Composable
fun StatsContent(now: Instant) {
    val history by RelayClient.history.collectAsStateWithLifecycle()
    val inbox by RelayClient.inbox.collectAsStateWithLifecycle()
    val historyLoad by RelayClient.historyLoad.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val stats = PageStats.compute(history, inbox, now)

    Column(verticalArrangement = Arrangement.spacedBy(Space.xxl)) {
        val failure = historyLoad.failureMessage
        if (failure != null && history.isEmpty()) {
            StatusBanner(
                BannerTone.ERROR, Icons.Filled.WifiOff,
                title = "Couldn't load history",
                message = "$failure Stats only include pages on this screen.",
                actionTitle = "Try again",
            ) { scope.launch { RelayClient.refreshHistory() } }
        }
        Column(verticalArrangement = Arrangement.spacedBy(Space.m)) {
            Row(Modifier.height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(Space.m)) {
                StatCard("TODAY", "${stats.today}", if (stats.today == 1) "page" else "pages", Modifier.weight(1f))
                StatCard("THIS WEEK", "${stats.thisWeek}", if (stats.thisWeek == 1) "page" else "pages", Modifier.weight(1f))
            }
            Row(Modifier.height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(Space.m)) {
                StatCard(
                    "AVG RESPONSE",
                    stats.avgResponseSeconds?.let { RelativeTime.compact(it) } ?: "—",
                    if (stats.repliedCount == 0) "no replies yet" else "across ${stats.repliedCount} repl${if (stats.repliedCount == 1) "y" else "ies"}",
                    Modifier.weight(1f),
                )
                StatCard("PENDING NOW", "${inbox.size}", "", Modifier.weight(1f))
            }
        }
        TopProjects(stats)
    }
}

@Composable
private fun StatCard(label: String, value: String, sub: String, modifier: Modifier) {
    Box(modifier.fillMaxHeight()) {
        Column(
            Modifier
                .card()
                .fillMaxHeight()
                .clearAndSetSemantics { contentDescription = "$label: $value $sub".lowercase() },
            verticalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            Text(label, style = PageType.caption12, color = colors.textMuted)
            Text(value, style = PageType.display28, color = colors.text, maxLines = 1)
            if (sub.isNotEmpty()) Text(sub, style = PageType.caption12, color = colors.textMuted)
        }
    }
}

@Composable
private fun TopProjects(stats: PageStats) {
    Column(verticalArrangement = Arrangement.spacedBy(Space.m)) {
        SectionTitle("TOP PROJECTS")
        if (stats.topProjects.isEmpty()) {
            Text("Nothing yet", style = PageType.body15, color = colors.textMuted)
        } else {
            Column(Modifier.card(Space.m)) {
                stats.topProjects.forEachIndexed { index, row ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .padding(vertical = Space.s)
                            .clearAndSetSemantics { contentDescription = "${row.name}, ${row.count}" },
                    ) {
                        Text(row.name, style = PageType.body15, color = colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                        Text("${row.count}", style = PageType.bodyEm, color = colors.textMuted)
                    }
                    if (index < stats.topProjects.size - 1) {
                        Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline.copy(alpha = 0.6f)))
                    }
                }
            }
        }
    }
}
