package app.page.android.ui.inbox

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.AppGraph
import app.page.android.data.AppRouter
import app.page.android.data.RelayClient
import app.page.android.model.Intervention
import app.page.android.model.InterventionKind
import app.page.android.model.MacPresence
import app.page.android.model.RelativeTime
import app.page.android.model.ReplyCopy
import app.page.android.model.ReplyDelivery
import app.page.android.notify.NotificationAccess
import app.page.android.ui.components.BackendPill
import app.page.android.ui.components.KindChip
import app.page.android.ui.components.PulseMark
import app.page.android.ui.components.ScreenTitle
import app.page.android.ui.components.StatusDot
import app.page.android.ui.components.StatusLine
import app.page.android.ui.components.TabScaffold
import app.page.android.ui.components.rememberNow
import app.page.android.ui.theme.PageType
import app.page.android.ui.theme.Radius
import app.page.android.ui.theme.Space
import app.page.android.ui.theme.colors
import java.time.Instant

@Composable
fun InboxScreen() {
    val inbox by RelayClient.inbox.collectAsStateWithLifecycle()
    val inboxLoad by RelayClient.inboxLoad.collectAsStateWithLifecycle()
    val macStatus by RelayClient.macStatus.collectAsStateWithLifecycle()
    val deliveries by RelayClient.deliveries.collectAsStateWithLifecycle()
    val authorization by NotificationAccess.authorization.collectAsStateWithLifecycle()
    // Relative times, Mac presence and banners re-evaluate every 15 s even
    // when no data changes.
    val now = rememberNow(15_000)
    val reachable = MacPresence.evaluate(macStatus, now).isReachable

    TabScaffold(onRefresh = { RelayClient.refreshAll() }) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                ScreenTitle("Page", Modifier.weight(1f))
                PulseMark(size = 24.dp, pulsing = inbox.isNotEmpty())
            }
        }
        item { InboxBanners(now) }
        item {
            val n = inbox.size
            StatusLine(
                when {
                    n > 0 -> "$n page${if (n == 1) "" else "s"} waiting"
                    inboxLoad is RelayClient.LoadState.Failed -> "Inbox may be out of date"
                    inboxLoad == RelayClient.LoadState.Loaded -> if (reachable) "All quiet" else "Nothing waiting"
                    else -> "Checking…"
                }
            )
        }
        if (inbox.isEmpty()) {
            item {
                if (inboxLoad == RelayClient.LoadState.Loaded || inboxLoad is RelayClient.LoadState.Failed) {
                    EmptyInbox(
                        failed = inboxLoad is RelayClient.LoadState.Failed,
                        macOk = reachable,
                        pushOk = authorization == NotificationAccess.Authorization.AUTHORIZED,
                    )
                } else {
                    LoadingRow("Loading pages…")
                }
            }
        } else {
            // The top card gets the pulse edge only when it blocks an agent.
            val urgentId = inbox.first().takeIf { it.kind == InterventionKind.APPROVAL || it.kind == InterventionKind.USER_INPUT }?.id
            items(inbox, key = { it.id }) { item ->
                InterventionCard(
                    intervention = item,
                    isMostUrgent = item.id == urgentId,
                    delivery = deliveries[item.id],
                    now = now,
                    onOpen = { AppRouter.open(item.id) },
                )
            }
        }
    }
}

@Composable
fun LoadingRow(text: String) {
    Column(Modifier.fillMaxWidth().padding(top = 80.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        CircularProgressIndicator(color = colors.textMuted)
        Spacer(Modifier.height(Space.m))
        Text(text, style = PageType.body15, color = colors.textMuted)
    }
}

@Composable
private fun EmptyInbox(failed: Boolean, macOk: Boolean, pushOk: Boolean) {
    val detail = when {
        failed -> "Page couldn't load your inbox. Pull down to try again."
        !macOk -> "Nothing is waiting right now, but your Mac isn't connected, so new pages can't reach you yet."
        !pushOk -> "Your agents are working. Turn on notifications so Page can buzz you when one needs you."
        !AppGraph.prefs.stayConnected -> "Your agents are working away. While Page is closed it checks for new pages every 15 minutes; turn on Stay connected in Settings to be paged the moment one needs you."
        else -> "Your agents are working away. We'll buzz you the moment one needs you."
    }
    Column(
        Modifier.fillMaxWidth().padding(top = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Space.l),
    ) {
        PulseMark(size = 96.dp, pulsing = false)
        Text("Nothing to handle.", style = PageType.title17, color = colors.text)
        Text(detail, style = PageType.body15, color = colors.textMuted, textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = Space.l))
    }
}

private data class DeliveryBadge(val text: String, val color: Color)

@Composable
private fun deliveryBadge(delivery: ReplyDelivery?): DeliveryBadge? = when (delivery) {
    ReplyDelivery.Sending -> DeliveryBadge("SENDING", colors.textMuted)
    is ReplyDelivery.Sent -> DeliveryBadge(if (delivery.queued) "QUEUED" else "SENT", colors.textMuted)
    is ReplyDelivery.Delivered -> DeliveryBadge("DELIVERED", colors.success)
    is ReplyDelivery.Failed -> DeliveryBadge("DELIVERY FAILED", colors.destructiveText)
    ReplyDelivery.AlreadyReplied -> DeliveryBadge("ANSWERED", colors.textMuted)
    ReplyDelivery.Gone, null -> null
}

@Composable
fun InterventionCard(intervention: Intervention, isMostUrgent: Boolean, delivery: ReplyDelivery?, now: Instant, onOpen: () -> Unit) {
    val badge = deliveryBadge(delivery)
    val paged = RelativeTime.string("Paged", intervention.openedAt, now)
    val spoken = buildList {
        add(intervention.kind.accessibilityName)
        add("from ${intervention.projectName}")
        intervention.backend?.let { add(it.displayName) }
        if (intervention.context.isNotEmpty()) add(intervention.context)
        add(paged)
        badge?.let { add(it.text.lowercase().replaceFirstChar { c -> c.uppercase() }) }
    }.joinToString(". ")
    val shape = RoundedCornerShape(Radius.card)
    Box(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.surfaceRaised)
            .border(1.dp, colors.hairline, shape)
            .clickable(role = Role.Button, onClickLabel = "Open the reply screen", onClick = onOpen)
            .clearAndSetSemantics {
                contentDescription = spoken
                onClick(label = "Open the reply screen") { onOpen(); true }
            }
    ) {
        Column(Modifier.padding(Space.l), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(intervention.projectName, style = PageType.mono13, color = colors.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                KindChip(intervention.kind, intervention.subtype)
                intervention.backend?.let { BackendPill(it, intervention.source) }
            }
            // An idle page's v4 turn summary reads as its own small line.
            val split = app.page.android.model.TurnSummaryLine.split(intervention.kind, intervention.context)
            split.summary?.let { Text(it, style = PageType.caption12, color = colors.kindIdle, maxLines = 1, overflow = TextOverflow.Ellipsis) }
            Text(
                split.message.ifEmpty { ReplyCopy.headline(intervention) },
                style = PageType.body15, color = colors.text, maxLines = 3, overflow = TextOverflow.Ellipsis,
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                Text(paged.uppercase(), style = PageType.caption12, color = colors.textMuted, modifier = Modifier.weight(1f))
                badge?.let { Text(it.text, style = PageType.chip11, color = it.color) }
                StatusDot(colors.kind(intervention.kind))
            }
        }
        if (isMostUrgent) UrgencyEdge()
    }
}

/** The pulse-gradient edge on a card's leading side, sized to the card. */
@Composable
fun androidx.compose.foundation.layout.BoxScope.UrgencyEdge() {
    Box(Modifier.matchParentSize()) {
        Box(Modifier.width(4.dp).fillMaxHeight().background(colors.pulseGradient))
    }
}
