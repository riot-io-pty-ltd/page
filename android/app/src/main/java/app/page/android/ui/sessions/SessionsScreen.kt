package app.page.android.ui.sessions

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.BatteryAlert
import androidx.compose.material.icons.filled.DataUsage
import androidx.compose.material.icons.filled.KeyboardHide
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.AppRouter
import app.page.android.data.PairingStore
import app.page.android.data.RelayClient
import app.page.android.data.SessionStore
import app.page.android.model.LiveSession
import app.page.android.model.LiveSessionState
import app.page.android.model.MacPresence
import app.page.android.model.MacStatusStrip
import app.page.android.ui.components.dotColor
import app.page.android.model.RelativeTime
import app.page.android.model.SessionAvailability
import app.page.android.model.SessionGroup
import app.page.android.model.SessionGrouping
import app.page.android.model.secondsSince
import app.page.android.ui.components.AgentPill
import app.page.android.ui.components.ConfirmDialog
import app.page.android.ui.components.DialogChoice
import app.page.android.ui.components.PulseMark
import app.page.android.ui.components.ScreenTitle
import app.page.android.ui.components.SessionStateChip
import app.page.android.ui.components.StatusBanner
import app.page.android.ui.components.StatusDot
import app.page.android.ui.components.StatusLine
import app.page.android.ui.components.TabScaffold
import app.page.android.ui.components.rememberNow
import app.page.android.ui.inbox.LoadingRow
import app.page.android.ui.inbox.UrgencyEdge
import app.page.android.ui.theme.MinTouch
import app.page.android.ui.theme.PageType
import app.page.android.ui.theme.Radius
import app.page.android.ui.theme.Space
import app.page.android.ui.theme.colors
import java.time.Instant
import kotlinx.coroutines.launch

/**
 * Every live agent session on the Mac, grouped "Needs you", "Working" and
 * "Idle" (iOS SessionsView.swift). Tapping a card opens its transcript and
 * composer; a session with an open page also offers that page directly.
 */
@Composable
fun SessionsScreen() {
    val state by SessionStore.state.collectAsStateWithLifecycle()
    val macStatus by RelayClient.macStatus.collectAsStateWithLifecycle()
    val connection by RelayClient.connection.collectAsStateWithLifecycle()
    val pairedMac by PairingStore.pairedMac.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    var confirmingRepair by remember { mutableStateOf(false) }
    // Ages and presence re-evaluate every 5 s; the store bumps waitTick when
    // the first-list wait runs out, which recomposes through `state`.
    val now = rememberNow(5_000)
    @Suppress("UNUSED_VARIABLE") val tick = state.waitTick
    // Evaluated against the wall clock, so the 5-second wait ends on time.
    val availability = state.availability(
        MacPresence.evaluate(macStatus, Instant.now()), connection == RelayClient.ConnectionState.CONNECTED, Instant.now(),
    )

    fun perform(action: SessionAvailabilityCopy.Action?) {
        when (action) {
            SessionAvailabilityCopy.Action.REPAIR -> confirmingRepair = true
            SessionAvailabilityCopy.Action.RETRY -> {
                SessionStore.refresh()
                scope.launch { RelayClient.refreshAll() }
            }
            null -> Unit
        }
    }

    TabScaffold(onRefresh = {
        SessionStore.refresh()
        RelayClient.refreshAll()
    }) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                ScreenTitle("Sessions", Modifier.weight(1f))
                if (availability == SessionAvailability.Ready) NewSessionButton()
                PulseMark(size = 24.dp, pulsing = state.sessions.any { it.state == LiveSessionState.ACTIVE })
            }
        }
        item {
            val text = if (availability != SessionAvailability.Ready) {
                SessionAvailabilityCopy.of(availability).shortStatus
            } else {
                val mac = state.macName ?: pairedMac?.name ?: "Your Mac"
                var t = "$mac · ${state.sessions.size} live"
                // The Mac refreshes the list at least every 20 s; say so when it's late.
                state.lastListAt?.let { if (now.secondsSince(it) > 45) t += " · updated ${RelativeTime.ago(it, now)}" }
                t
            }
            StatusLine(text)
        }
        // v4: presence, battery forecast and Claude usage at a glance.
        item { MacStatusStripCard(macStatus, now) }
        when (availability) {
            SessionAvailability.Ready -> if (state.sessions.isEmpty()) {
                item { EmptySessions() }
            } else {
                for (section in SessionGrouping.sections(state.sessions)) {
                    item(key = "h-${section.group}") { SessionGroupHeader(section.group, section.sessions.size) }
                    items(section.sessions, key = { it.id }) { session ->
                        SessionCard(
                            session, now,
                            onOpen = { AppRouter.openSession(session.id) },
                            // Any open page, idle ones included.
                            onOpenPage = session.interventionId?.let { id -> { AppRouter.open(id, switchTab = false) } },
                        )
                    }
                }
            }
            SessionAvailability.Waiting -> item { LoadingRow("Connecting to your Mac…") }
            else -> item {
                val copy = SessionAvailabilityCopy.of(availability)
                StatusBanner(copy.tone, copy.icon, copy.title, copy.message, copy.actionTitle, action = copy.action?.let { a -> { perform(a) } })
            }
        }
    }

    if (confirmingRepair) {
        ConfirmDialog(
            title = "Unpair this Mac?",
            message = "You'll go back to the pairing screen. On your Mac, open Page → Pair phone… and scan the new code.",
            choices = listOf(DialogChoice("Unpair", destructive = true) { PairingStore.unpair() }),
            onDismiss = { confirmingRepair = false },
        )
    }
}

@Composable
private fun NewSessionButton() {
    Row(
        Modifier
            .padding(end = Space.s)
            .heightIn(min = MinTouch)
            .clip(RoundedCornerShape(50))
            .clickable(role = Role.Button, onClickLabel = "Start a new Claude session on your Mac", onClick = AppRouter::openNewSession)
            .border(1.dp, colors.hairline, RoundedCornerShape(50))
            .padding(horizontal = Space.m),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(Icons.Filled.Add, contentDescription = null, tint = colors.text, modifier = Modifier.size(18.dp))
        Text("New session", style = PageType.bodyEm, color = colors.text)
    }
}

/** The compact Mac status strip: online/offline, battery cutoff forecast, Claude usage. */
@Composable
private fun MacStatusStripCard(snapshot: app.page.android.model.MacStatusSnapshot?, now: Instant) {
    val presence = MacPresence.evaluate(snapshot, now)
    val clock = remember { java.time.format.DateTimeFormatter.ofLocalizedTime(java.time.format.FormatStyle.SHORT).withZone(java.time.ZoneId.systemDefault()) }
    val lines = MacStatusStrip.lines(snapshot, presence, now) { clock.format(it) }
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(colors.surfaceInset)
            .padding(horizontal = Space.m, vertical = Space.s)
            .clearAndSetSemantics { contentDescription = lines.joinToString(". ") { it.text } },
        verticalArrangement = Arrangement.spacedBy(Space.xs),
    ) {
        for (line in lines) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                when (line.kind) {
                    MacStatusStrip.Kind.PRESENCE -> StatusDot(presence.dotColor)
                    MacStatusStrip.Kind.BATTERY -> Icon(Icons.Filled.BatteryAlert, contentDescription = null, tint = colors.warning, modifier = Modifier.size(14.dp))
                    MacStatusStrip.Kind.USAGE -> Icon(Icons.Filled.DataUsage, contentDescription = null, tint = colors.backendClaude, modifier = Modifier.size(14.dp))
                }
                Text(line.text, style = PageType.caption12, color = colors.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun EmptySessions() {
    Column(
        Modifier.fillMaxWidth().padding(top = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Space.l),
    ) {
        PulseMark(size = 96.dp, pulsing = false)
        Text("No live sessions", style = PageType.title17, color = colors.text)
        Text(
            "Start Claude Code or Codex on your Mac and it shows up here, with what it's doing right now.",
            style = PageType.body15, color = colors.textMuted, textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = Space.l),
        )
    }
}

/**
 * Separator above each group: the group's colour dot, its name and count, and
 * a hairline across the rest of the row, so Needs you / Working / Idle read as
 * distinct blocks at a glance.
 */
@Composable
fun SessionGroupHeader(group: SessionGroup, count: Int) {
    val color = when (group) {
        SessionGroup.NEEDS_YOU -> colors.state(LiveSessionState.WAITING_ON_APPROVAL)
        SessionGroup.WORKING -> colors.state(LiveSessionState.ACTIVE)
        SessionGroup.IDLE -> colors.textMuted
    }
    Row(
        Modifier
            .fillMaxWidth()
            .padding(top = Space.xs)
            .clearAndSetSemantics {
                contentDescription = "${group.title.lowercase().replaceFirstChar { it.uppercase() }}, $count"
                heading()
            },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        StatusDot(color)
        Text(group.title, style = PageType.chip11.copy(letterSpacing = PageType.chip11.letterSpacing * 1.6f), color = if (group == SessionGroup.IDLE) colors.textMuted else color)
        Text(
            "$count", style = PageType.chip11, color = colors.textMuted,
            modifier = Modifier.clip(RoundedCornerShape(50)).background(colors.surfaceInset).padding(horizontal = 6.dp, vertical = 1.dp),
        )
        Box(Modifier.weight(1f).height(1.dp).background(colors.hairline))
    }
}

/**
 * One session, modelled on the inbox's card: project, backend and host,
 * state, what it's doing, and how long ago.
 */
@Composable
fun SessionCard(session: LiveSession, now: Instant, onOpen: () -> Unit, onOpenPage: (() -> Unit)?) {
    val preview = session.preview.ifEmpty { session.cwd.ifEmpty { "No recent activity" } }
    val age = session.lastActivityAt?.let { RelativeTime.string("Active", it, now) } ?: session.state.label
    val spoken = buildList {
        add(session.title); add(session.backend.displayName); add(session.hostLabel); add(session.state.label)
        if (session.preview.isNotEmpty()) add(session.preview)
        session.lastActivityAt?.let { add(RelativeTime.string("Active", it, now)) }
        if (!session.canType) add("Page can't type here")
    }.joinToString(". ")
    val shape = RoundedCornerShape(Radius.card)
    Box(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.surfaceRaised)
            .border(1.dp, colors.hairline, shape)
    ) {
        Column {
            Column(
                Modifier
                    .fillMaxWidth()
                    .clickable(role = Role.Button, onClick = onOpen)
                    .clearAndSetSemantics {
                        contentDescription = spoken
                        onClick(label = "Open the session's transcript") { onOpen(); true }
                    }
                    .padding(Space.l),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(session.title, style = PageType.mono13, color = colors.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    AgentPill(session.backend, session.hostLabel)
                    SessionStateChip(session.state)
                }
                Text(
                    preview, style = PageType.body15,
                    color = if (session.preview.isEmpty()) colors.textMuted else colors.text,
                    maxLines = 2, overflow = TextOverflow.Ellipsis,
                )
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    Text(age.uppercase(), style = PageType.caption12, color = colors.textMuted, modifier = Modifier.weight(1f))
                    if (!session.canType) Icon(Icons.Filled.KeyboardHide, contentDescription = null, tint = colors.textMuted, modifier = Modifier.size(14.dp))
                    StatusDot(colors.state(session.state))
                }
            }
            if (onOpenPage != null) {
                Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline))
                Row(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(min = MinTouch)
                        .clickable(role = Role.Button, onClickLabel = "Open the reply screen for this session's prompt", onClick = onOpenPage)
                        .padding(horizontal = Space.l),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Space.s),
                ) {
                    Icon(Icons.Filled.NotificationsActive, contentDescription = null, tint = colors.state(session.state), modifier = Modifier.size(18.dp))
                    Text("Open page", style = PageType.bodyEm, color = colors.state(session.state), modifier = Modifier.weight(1f))
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = colors.textMuted, modifier = Modifier.size(16.dp))
                }
            }
        }
        if (session.state.isWaiting) UrgencyEdge()
    }
}
