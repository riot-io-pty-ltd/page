package app.page.android.ui.history

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Reply
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.RelayClient
import app.page.android.model.CloseReason
import app.page.android.model.Intervention
import app.page.android.model.RelativeTime
import app.page.android.model.ReplyCopy
import app.page.android.ui.components.KindChip
import app.page.android.ui.components.PulseMark
import app.page.android.ui.components.ScreenTitle
import app.page.android.ui.components.SegmentedControl
import app.page.android.ui.components.TabScaffold
import app.page.android.ui.components.TextLink
import app.page.android.ui.components.card
import app.page.android.ui.components.rememberNow
import app.page.android.ui.theme.PageType
import app.page.android.ui.theme.Space
import app.page.android.ui.theme.colors
import java.time.Instant
import kotlinx.coroutines.launch

private enum class Segment(val label: String) { HISTORY("History"), STATS("Stats") }

/** Resolved pages, with Stats as a second segment. */
@Composable
fun HistoryScreen() {
    val history by RelayClient.history.collectAsStateWithLifecycle()
    val historyLoad by RelayClient.historyLoad.collectAsStateWithLifecycle()
    var segment by rememberSaveable { mutableStateOf(Segment.HISTORY) }
    val now = rememberNow(30_000)
    val scope = rememberCoroutineScope()

    LaunchedEffect(Unit) { RelayClient.refreshHistory() }

    TabScaffold(onRefresh = { RelayClient.refreshHistory() }) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(Space.l)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    ScreenTitle("History", Modifier.weight(1f))
                    if (segment == Segment.HISTORY && history.isNotEmpty()) {
                        Text(
                            "${history.size}", style = PageType.caption12, color = colors.textMuted,
                            modifier = Modifier.semantics { contentDescription = "${history.size} resolved pages" },
                        )
                    }
                }
                SegmentedControl(Segment.entries, segment, { it.label }) { segment = it }
            }
        }
        when (segment) {
            Segment.HISTORY -> if (history.isEmpty()) {
                item { EmptyHistory(historyLoad) { scope.launch { RelayClient.refreshHistory() } } }
            } else {
                items(history, key = { it.id }) { HistoryCard(it, now) }
            }
            Segment.STATS -> item { StatsContent(now) }
        }
    }
}

@Composable
private fun EmptyHistory(load: RelayClient.LoadState, onRetry: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(top = 80.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Space.l),
    ) {
        when (load) {
            RelayClient.LoadState.Idle, RelayClient.LoadState.Loading -> {
                CircularProgressIndicator(color = colors.textMuted)
                Text("Loading history…", style = PageType.body15, color = colors.textMuted)
            }
            is RelayClient.LoadState.Failed -> {
                Icon(Icons.Filled.WifiOff, contentDescription = null, tint = colors.textMuted, modifier = Modifier.size(40.dp))
                Text("Couldn't load history", style = PageType.title17, color = colors.text)
                Text(load.message, style = PageType.body15, color = colors.textMuted, textAlign = TextAlign.Center)
                TextLink("Try again", onClick = onRetry)
            }
            RelayClient.LoadState.Loaded -> {
                PulseMark(size = 64.dp, pulsing = false)
                Text("No history yet", style = PageType.title17, color = colors.text)
                Text("Pages you've resolved will appear here.", style = PageType.body15, color = colors.textMuted, textAlign = TextAlign.Center)
            }
        }
    }
}

@Composable
private fun HistoryCard(iv: Intervention, now: Instant) {
    val time = iv.closedAt?.let { RelativeTime.string("Closed", it, now) } ?: RelativeTime.string("Paged", iv.openedAt, now)
    val reply = iv.repliedText?.takeIf { it.isNotEmpty() }
    val actionLabel = ReplyCopy.actionLabel(iv.repliedAction)
    val outcome = when {
        reply != null -> "You replied: $reply"
        actionLabel != null -> actionLabel
        else -> CloseReason.description(iv.closeReason)
    }
    val headline = iv.context.ifEmpty { ReplyCopy.headline(iv) }
    val answered = iv.responseTimeSeconds?.let { "Answered in ${RelativeTime.compact(it)}" }
    Column(
        Modifier
            .card()
            .clearAndSetSemantics {
                contentDescription = listOfNotNull(iv.projectName, iv.kind.accessibilityName, headline, outcome, time, answered).joinToString(". ")
            },
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            Text(iv.projectName, style = PageType.mono13, color = colors.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            KindChip(iv.kind, iv.subtype)
        }
        Text(headline, style = PageType.body15, color = colors.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
        when {
            reply != null -> Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.AutoMirrored.Filled.Reply, contentDescription = null, tint = colors.textMuted, modifier = Modifier.size(14.dp).padding(top = 2.dp))
                Text(reply, style = PageType.body15.copy(fontStyle = FontStyle.Italic), color = colors.textMuted, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            actionLabel != null -> Text(actionLabel.uppercase(), style = PageType.caption12, color = colors.textMuted)
            else -> Text(CloseReason.description(iv.closeReason), style = PageType.caption12, color = colors.textMuted)
        }
        Row {
            Text(time.uppercase(), style = PageType.caption12, color = colors.textMuted, modifier = Modifier.weight(1f))
            answered?.let { Text(it, style = PageType.caption12, color = colors.textMuted) }
        }
    }
}
