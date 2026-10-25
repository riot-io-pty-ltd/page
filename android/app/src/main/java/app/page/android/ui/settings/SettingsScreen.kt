package app.page.android.ui.settings

import android.content.Intent
import android.net.Uri
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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.AppGraph
import app.page.android.data.PairingStore
import app.page.android.data.RelayClient
import app.page.android.data.SessionStore
import app.page.android.model.MacPresence
import app.page.android.model.MacStatusSnapshot
import app.page.android.model.SessionAvailability
import app.page.android.notify.BackgroundConnection
import app.page.android.notify.NotificationAccess
import app.page.android.notify.PushProviders
import app.page.android.ui.components.ConfirmDialog
import app.page.android.ui.components.DialogChoice
import app.page.android.ui.components.ScreenTitle
import app.page.android.ui.components.SectionTitle
import app.page.android.ui.components.StatusDot
import app.page.android.ui.components.TabScaffold
import app.page.android.ui.components.TextLink
import app.page.android.ui.components.card
import app.page.android.ui.components.dotColor
import app.page.android.ui.components.rememberNow
import app.page.android.ui.components.summary
import app.page.android.ui.sessions.SessionAvailabilityCopy
import app.page.android.ui.theme.MinTouch
import app.page.android.ui.theme.PageType
import app.page.android.ui.theme.Radius
import app.page.android.ui.theme.Space
import app.page.android.ui.theme.colors
import java.time.Instant

private const val FEEDBACK_URL = "https://github.com/riot-io-pty-ltd/page/issues"

@Composable
fun SettingsScreen(onRequestNotifications: () -> Unit) {
    val context = LocalContext.current
    val pairedMac by PairingStore.pairedMac.collectAsStateWithLifecycle()
    val relayHost by PairingStore.relayHost.collectAsStateWithLifecycle()
    val macStatus by RelayClient.macStatus.collectAsStateWithLifecycle()
    val now = rememberNow(15_000)
    var confirmingUnpair by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        RelayClient.refreshStatus()
        NotificationAccess.refresh(context)
    }

    TabScaffold(onRefresh = {
        RelayClient.refreshAll()
        NotificationAccess.refresh(context)
    }) {
        item { ScreenTitle("Settings") }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(Space.m)) {
                SectionTitle("YOUR MAC")
                pairedMac?.let { mac ->
                    MacCard(mac.name, MacPresence.evaluate(macStatus, now), macStatus, relayHost, now) { confirmingUnpair = true }
                }
            }
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(Space.m)) {
                SectionTitle("CONNECTION")
                ConnectionCard(onRequestNotifications)
            }
        }
        item {
            Column(verticalArrangement = Arrangement.spacedBy(Space.m)) {
                SectionTitle("ABOUT")
                Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(Space.m)) {
                    Row(Modifier.clearAndSetSemantics { contentDescription = "Version ${AppGraph.appVersion}" }, verticalAlignment = Alignment.CenterVertically) {
                        Text("Version", style = PageType.body15, color = colors.text, modifier = Modifier.weight(1f))
                        SelectionContainer { Text(versionString(), style = PageType.mono13, color = colors.textMuted) }
                    }
                    Divider()
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .heightIn(min = MinTouch)
                            .clickable(role = Role.Button, onClickLabel = "Open the Page issue tracker on GitHub") {
                                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(FEEDBACK_URL)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            },
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("Help & feedback", style = PageType.body15, color = colors.text, modifier = Modifier.weight(1f))
                        Icon(Icons.AutoMirrored.Filled.OpenInNew, contentDescription = null, tint = colors.textMuted, modifier = Modifier.size(16.dp))
                    }
                }
            }
        }
    }

    if (confirmingUnpair) {
        ConfirmDialog(
            title = "Unpair ${pairedMac?.name ?: "this Mac"}?",
            message = "This phone will stop receiving pages until you scan a pairing code again.",
            choices = listOf(DialogChoice("Unpair", destructive = true) {
                if (PairingStore.isDemoPairing) PairingStore.endDemo() else PairingStore.unpair()
            }),
            onDismiss = { confirmingUnpair = false },
        )
    }
}

@Composable
private fun MacCard(name: String, presence: MacPresence, status: MacStatusSnapshot?, relayHost: String?, now: Instant, onUnpair: () -> Unit) {
    Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(Space.m)) {
        Text(name, style = PageType.bodyEm, color = colors.text)
        Row(
            Modifier.clearAndSetSemantics { contentDescription = "Mac status: ${presence.summary(now)}" },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Space.s),
        ) {
            StatusDot(presence.dotColor)
            Text(presence.summary(now), style = PageType.caption12, color = colors.textMuted)
        }
        macDetails(presence, status)?.let { Text(it, style = PageType.body15, color = colors.textMuted) }
        relayHost?.let {
            SelectionContainer { Text("Relay: $it", style = PageType.mono13, color = colors.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        }
        val shape = RoundedCornerShape(Radius.button)
        Box(
            Modifier
                .fillMaxWidth()
                .heightIn(min = MinTouch)
                .clip(shape)
                .border(1.dp, colors.destructiveText.copy(alpha = 0.4f), shape)
                .clickable(role = Role.Button, onClick = onUnpair),
            contentAlignment = Alignment.Center,
        ) {
            Text(if (PairingStore.isDemoPairing) "Leave the demo" else "Unpair", style = PageType.bodyEm, color = colors.destructiveText)
        }
    }
}

/**
 * "3 active sessions · Battery 54%, on power" — only real values, and only
 * while the Mac is reporting (a stale count would mislead).
 */
private fun macDetails(presence: MacPresence, status: MacStatusSnapshot?): String? {
    if (!presence.isReachable || status == null) return null
    val parts = mutableListOf<String>()
    status.activeSessions?.let { parts.add("$it active session${if (it == 1) "" else "s"}") }
    status.batteryPercent?.let { pct -> parts.add("Battery $pct%" + if (status.onAC == true) ", on power" else "") }
    return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
}

@Composable
private fun ConnectionCard(onRequestNotifications: () -> Unit) {
    val context = LocalContext.current
    val connection by RelayClient.connection.collectAsStateWithLifecycle()
    val inboxLoad by RelayClient.inboxLoad.collectAsStateWithLifecycle()
    val authorization by NotificationAccess.authorization.collectAsStateWithLifecycle()
    val stayConnected by BackgroundConnection.stayConnected.collectAsStateWithLifecycle()

    Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(Space.m)) {
        SettingRow(
            "Relay",
            when (connection) {
                RelayClient.ConnectionState.CONNECTED -> "Connected"
                RelayClient.ConnectionState.CONNECTING -> "Connecting…"
                RelayClient.ConnectionState.DISCONNECTED -> inboxLoad.failureMessage?.let { "Offline — $it" } ?: "Reconnecting…"
            },
        )
        Divider()
        Row(verticalAlignment = Alignment.CenterVertically) {
            SettingRow(
                "Notifications",
                when (authorization) {
                    NotificationAccess.Authorization.AUTHORIZED -> "Allowed"
                    NotificationAccess.Authorization.DENIED -> "Off — you won't be paged"
                    NotificationAccess.Authorization.NOT_DETERMINED -> "Not set up yet"
                    NotificationAccess.Authorization.UNKNOWN -> "Checking…"
                },
                Modifier.weight(1f),
            )
            when (authorization) {
                NotificationAccess.Authorization.DENIED -> TextLink("Open settings") { NotificationAccess.openSettings(context) }
                NotificationAccess.Authorization.NOT_DETERMINED -> TextLink("Turn on", onClick = onRequestNotifications)
                else -> Unit
            }
        }
        Divider()
        Row(
            Modifier
                .fillMaxWidth()
                .toggleable(value = stayConnected, role = Role.Switch) { BackgroundConnection.setStayConnected(context, it) },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Space.m),
        ) {
            SettingRow(
                "Stay connected",
                if (stayConnected) "Page keeps its connection open in the background and pages you instantly. Shows an ongoing notification; uses a little battery."
                else "Off: while Page is closed it checks for new pages every 15 minutes. Turn on to be paged instantly.",
                Modifier.weight(1f),
            )
            Switch(
                checked = stayConnected,
                onCheckedChange = null,
                colors = SwitchDefaults.colors(checkedTrackColor = colors.kindApproval, checkedThumbColor = colors.surfaceRaised),
            )
        }
        Divider()
        SettingRow("Push", PushProviders.active.let { if (it.isAvailable) it.displayName else "Not available on Android yet — Stay connected stands in for it" })
        Divider()
        LiveSessionsRow()
    }
}

/**
 * Settings' "Live sessions" row: whether the Sessions tab works, and if not
 * the step that fixes it. Watches [SessionStore] on its own so session
 * updates recompose this row, not the whole screen.
 */
@Composable
private fun LiveSessionsRow() {
    val state by SessionStore.state.collectAsStateWithLifecycle()
    val macStatus by RelayClient.macStatus.collectAsStateWithLifecycle()
    val connection by RelayClient.connection.collectAsStateWithLifecycle()
    val availability = state.availability(
        MacPresence.evaluate(macStatus, Instant.now()), connection == RelayClient.ConnectionState.CONNECTED, Instant.now(),
    )
    val text = when (availability) {
        SessionAvailability.Ready -> {
            val n = state.sessions.size
            "$n live session${if (n == 1) "" else "s"} · end-to-end encrypted"
        }
        is SessionAvailability.NeedsRepair -> "Re-pair with your Mac to turn on live sessions"
        else -> SessionAvailabilityCopy.of(availability).shortStatus
    }
    SettingRow("Live sessions", text)
}

@Composable
private fun SettingRow(label: String, value: String, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = "$label: $value" }, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(label, style = PageType.body15, color = colors.text)
        Text(value, style = PageType.caption12, color = colors.textMuted)
    }
}

@Composable
private fun Divider() {
    Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline.copy(alpha = 0.6f)))
}

private fun versionString(): String {
    val app = AppGraph.app
    return try {
        val info = app.packageManager.getPackageInfo(app.packageName, 0)
        @Suppress("DEPRECATION")
        val code = if (android.os.Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
        "${info.versionName} ($code)"
    } catch (_: Exception) {
        "?"
    }
}
