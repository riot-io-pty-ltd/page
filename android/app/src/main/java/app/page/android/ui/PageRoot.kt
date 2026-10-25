package app.page.android.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.AppRouter
import app.page.android.data.AppTab
import app.page.android.data.PairingStore
import app.page.android.data.RelayClient
import app.page.android.data.SessionStore
import app.page.android.model.SessionGrouping
import app.page.android.ui.components.PillTabBar
import app.page.android.ui.history.HistoryScreen
import app.page.android.ui.inbox.InboxScreen
import app.page.android.ui.inbox.ReplyScreen
import app.page.android.ui.pairing.PairScreen
import app.page.android.ui.sessions.NewSessionScreen
import app.page.android.ui.sessions.SessionDetailScreen
import app.page.android.ui.sessions.SessionsScreen
import app.page.android.ui.settings.SettingsScreen
import app.page.android.ui.theme.colors

/** Paired: the tabs. Not paired: the pairing screen. */
@Composable
fun PageRoot(onRequestNotifications: () -> Unit) {
    val pairedMac by PairingStore.pairedMac.collectAsStateWithLifecycle()
    Box(Modifier.fillMaxSize().background(colors.surface)) {
        if (pairedMac != null) MainScreen(onRequestNotifications) else PairScreen()
    }
}

/**
 * The four tabs under the floating pill bar, plus the two full-screen
 * overlays (a page's reply screen, a session's detail), only one of which is
 * up at a time (see [AppRouter]).
 */
@Composable
private fun MainScreen(onRequestNotifications: () -> Unit) {
    val route by AppRouter.route.collectAsStateWithLifecycle()
    val inbox by RelayClient.inbox.collectAsStateWithLifecycle()

    LaunchedEffect(Unit) {
        // First appearance after launch or after pairing (iOS MainTabView.task).
        if (!RelayClient.isDemoMode) RelayClient.activate()
        onRequestNotifications()
    }

    Box(Modifier.fillMaxSize()) {
        when (route.tab) {
            AppTab.SESSIONS -> SessionsScreen()
            AppTab.INBOX -> InboxScreen()
            AppTab.HISTORY -> HistoryScreen()
            AppTab.SETTINGS -> SettingsScreen(onRequestNotifications)
        }
        TabBarHost(route.tab, inbox.size, Modifier.align(Alignment.BottomCenter))

        Overlay(visible = route.newSession) { NewSessionScreen(onClose = AppRouter::closeNewSession) }
        Overlay(visible = route.sessionId != null) {
            val id = remember(route.sessionId) { route.sessionId } ?: return@Overlay
            SessionDetailScreen(id, onDismiss = AppRouter::closeSession)
        }
        Overlay(visible = route.interventionId != null) {
            val id = remember(route.interventionId) { route.interventionId } ?: return@Overlay
            ReplyScreen(id, onDismiss = AppRouter::closeReply, onOpenSession = AppRouter::openSession)
        }
    }
}

/**
 * The tab bar plus the one thing it needs from live sessions (how many need
 * you), so session updates recompose the bar, not every tab.
 */
@Composable
private fun TabBarHost(selection: AppTab, inboxCount: Int, modifier: Modifier) {
    val state by SessionStore.state.collectAsStateWithLifecycle()
    PillTabBar(
        selection = selection,
        inboxCount = inboxCount,
        sessionsNeedingYou = SessionGrouping.needsYouCount(state.sessions),
        modifier = modifier.navigationBarsPadding(),
        onSelect = AppRouter::selectTab,
    )
}

/** A full-screen sheet that slides up over the tabs, like an iOS sheet. */
@Composable
private fun Overlay(visible: Boolean, content: @Composable () -> Unit) {
    AnimatedVisibility(
        visible = visible,
        enter = slideInVertically(tween(260)) { it },
        exit = slideOutVertically(tween(220)) { it },
    ) {
        Box(Modifier.fillMaxSize().background(colors.surface)) { content() }
    }
}
