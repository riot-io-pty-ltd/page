package app.page.android.ui.nw.tower

import android.content.Intent
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.AppGraph
import app.page.android.data.AppRouter
import app.page.android.data.CardGlowStore
import app.page.android.data.NowStore
import app.page.android.data.PairingStore
import app.page.android.data.RelayClient
import app.page.android.data.SessionStore
import app.page.android.data.TipStore
import app.page.android.model.MacPresence
import app.page.android.model.summary
import app.page.android.model.NotificationsState
import app.page.android.model.RelayConnectionText
import app.page.android.model.SessionAvailability
import app.page.android.model.SessionAvailabilityCopy
import app.page.android.model.TowerBudget
import app.page.android.model.TowerMacRow
import app.page.android.model.TowerPower
import app.page.android.model.TowerSection
import app.page.android.notify.BackgroundConnection
import app.page.android.notify.NotificationAccess
import app.page.android.ui.nw.components.rememberNWNow

const val FEEDBACK_URL = "https://github.com/riot-io-pty-ltd/page/issues"

/** The Tower, live: power, budget, Macs, attention, pairing, appearance and about, from the stores. Every option the old Settings screen had is here. (iOS TowerContainer.) */
@Composable
fun TowerContainer(scrollTo: TowerSection?, onRequestNotifications: () -> Unit, modifier: Modifier = Modifier) {
    val screen by NowStore.screen.collectAsStateWithLifecycle()
    val mac by PairingStore.pairedMac.collectAsStateWithLifecycle()
    val sessionState by SessionStore.state.collectAsStateWithLifecycle()
    val connection by RelayClient.connection.collectAsStateWithLifecycle()
    val inboxLoad by RelayClient.inboxLoad.collectAsStateWithLifecycle()
    val notif by NotificationAccess.authorization.collectAsStateWithLifecycle()
    val stay by BackgroundConnection.stayConnected.collectAsStateWithLifecycle()
    val glow by CardGlowStore.glow.collectAsStateWithLifecycle()
    val relayHost by PairingStore.relayHost.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val now by rememberNWNow(slowMs = 15_000)
    LaunchedEffect(Unit) {
        if (!RelayClient.isDemoMode) RelayClient.refreshStatus()
        NotificationAccess.refresh(context)
    }
    val status = screen.status
    val name = mac?.name ?: screen.macName
    val presence = MacPresence.evaluate(status, now)
    val line = ArrayList<String>()
    line.add(presence.summary(now))
    if (presence.isReachable && status != null) {
        status.activeSessions?.let { line.add("$it active session${if (it == 1) "" else "s"}") }
        status.batteryPercent?.let { line.add("Battery $it%" + if (status.onAC == true) ", on power" else "") }
    }
    val availability = sessionState.availability(presence, connection == RelayClient.ConnectionState.CONNECTED, now)
    val live = when (availability) {
        SessionAvailability.Ready -> sessionState.sessions.size.let { "$it live session${if (it == 1) "" else "s"} · end-to-end encrypted" }
        is SessionAvailability.NeedsRepair -> "Re-pair with your Mac to turn on live sessions"
        else -> SessionAvailabilityCopy.of(availability).shortStatus
    }
    val data = TowerScreenData(
        macName = name, power = TowerPower.build(status), budget = TowerBudget.build(status?.usage, now),
        macs = TowerMacRow.build(name, mac?.pairedAt, status, now), macLine = line.joinToString(" · "), relayHost = relayHost,
        relayText = RelayConnectionText.text(connection == RelayClient.ConnectionState.CONNECTED, connection == RelayClient.ConnectionState.CONNECTING, inboxLoad.failureMessage),
        notifications = when (notif) {
            NotificationAccess.Authorization.AUTHORIZED -> NotificationsState.ALLOWED
            NotificationAccess.Authorization.DENIED -> NotificationsState.OFF
            NotificationAccess.Authorization.NOT_DETERMINED -> NotificationsState.NOT_SET
            NotificationAccess.Authorization.UNKNOWN -> NotificationsState.CHECKING
        },
        stayConnected = stay, liveSessionsText = live, glow = glow, version = AppGraph.appVersion, now = now, scrollTo = scrollTo,
        feedbackUrl = FEEDBACK_URL, isDemo = PairingStore.isDemoPairing,
    )
    val actions = TowerScreenActions(
        close = AppRouter::closeSheet,
        unpair = AppRouter::requestUnpair,
        openNotificationSettings = { NotificationAccess.openSettings(context) },
        turnOnNotifications = onRequestNotifications,
        setStayConnected = { BackgroundConnection.setStayConnected(context, it) },
        setGlow = CardGlowStore::set,
        openHistory = AppRouter::openHistory,
        resetTips = TipStore::reset,
        openFeedback = { runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(FEEDBACK_URL)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } },
    )
    NWTowerScreen(data, actions, modifier)
}
