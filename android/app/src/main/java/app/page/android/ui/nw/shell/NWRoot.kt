package app.page.android.ui.nw.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.AppRouter
import app.page.android.data.BiometricGate
import app.page.android.data.NowStore
import app.page.android.data.PairingStore
import app.page.android.data.RelayClient
import app.page.android.data.StopCoordinator
import app.page.android.model.NWSheet
import app.page.android.model.RoomEntry
import app.page.android.model.NowRowBuilder
import app.page.android.ui.nw.decision.DecisionContainer
import app.page.android.ui.nw.room.RoomContainer
import app.page.android.ui.nw.decision.decisionBackground
import app.page.android.ui.nw.components.NWOverlay
import app.page.android.ui.nw.components.NWSheetHost
import app.page.android.ui.nw.theme.LocalAnimationsPaused
import app.page.android.ui.nw.theme.LocalFixedNow
import app.page.android.ui.nw.theme.LocalFixedPhase
import app.page.android.ui.nw.theme.LocalMotionPin
import app.page.android.ui.nw.theme.NW
import kotlinx.coroutines.delay

/** Paired: the Night Watch shell. Not paired: the pairing screen. */
@Composable
fun NWRoot(onRequestNotifications: () -> Unit) {
    val pairedMac by PairingStore.pairedMac.collectAsStateWithLifecycle()
    val spec by RenderHarness.spec.collectAsStateWithLifecycle()
    val standalone = spec?.let { RenderHarness.standalone(it.screen) }
    CompositionLocalProvider(
        LocalFixedPhase provides spec?.phase, LocalFixedNow provides spec?.now, LocalMotionPin provides spec?.pin,
    ) {
        Box(Modifier.fillMaxSize().background(NW.Palette.background.color)) {
            when {
                standalone != null -> standalone()
                pairedMac != null -> {
                    val welcome by AppRouter.state.collectAsStateWithLifecycle()
                    if (welcome.pairedWelcome) app.page.android.ui.nw.onboarding.PairedContainer(onRequestNotifications) else NWMain(onRequestNotifications)
                }
                else -> app.page.android.ui.nw.onboarding.PairFlow()
            }
        }
    }
}

/**
 * The shell with its destinations and the one sheet that can be up: the Decision sheet, the Tower, Dispatch,
 * History and the Session Room (a room, never a tab).
 */
@Composable
private fun NWMain(onRequestNotifications: () -> Unit) {
    val router by AppRouter.state.collectAsStateWithLifecycle()
    val screen by NowStore.screen.collectAsStateWithLifecycle()
    val stop by StopCoordinator.phase.collectAsStateWithLifecycle()
    val pinnedHeld by RenderHarness.heldProgress.collectAsStateWithLifecycle()
    var held by remember { mutableStateOf<Double?>(null) }
    val context = LocalContext.current
    val biometry = remember { BiometricGate.methodName(context) }

    LaunchedEffect(Unit) {
        // First appearance after launch or after pairing (iOS MainTabView.task).
        if (!RelayClient.isDemoMode) RelayClient.activate()
        // Notifications are asked for once, on the Paired screen (or from the Tower), never here.
        NowStore.observeActivity()
    }
    val sheets = router.sheets
    // Whatever is waiting comes up once the first sheet has finished leaving.
    LaunchedEffect(sheets.current, sheets.pending) {
        if (sheets.current == null && sheets.pending != null) {
            delay(300)
            AppRouter.sheetDismissed()
        }
    }
    LaunchedEffect(sheets.current != null) { NowStore.setFrozen(sheets.current != null) }

    if (router.confirmingUnpair) {
        val mac by PairingStore.pairedMac.collectAsStateWithLifecycle()
        val demo = PairingStore.isDemoPairing
        app.page.android.ui.nw.components.NWConfirmDialog(
            title = if (demo) "Leave the demo?" else "Unpair ${mac?.name ?: "this Mac"}?",
            message = if (demo) "This goes back to the pairing screen." else "This phone will stop receiving pages until you scan a pairing code again. On your Mac, open Page → Pair phone… and scan the new code.",
            confirmLabel = if (demo) "Leave the demo" else "Unpair", destructive = true,
            onConfirm = { AppRouter.clearUnpairRequest(); AppRouter.closeSheet(); if (demo) PairingStore.endDemo() else PairingStore.unpair() },
            onDismiss = AppRouter::clearUnpairRequest,
        )
    }
    CompositionLocalProvider(LocalAnimationsPaused provides (sheets.current != null)) {
        NWShell(
            destination = router.destination, onDestinationChange = AppRouter::selectDestination,
            decideCount = screen.decideCount, workingCount = screen.workingCount,
            pulseWaiting = screen.model.pulseWaiting, pulseLongestWait = screen.pulse.longestWait,
            stop = stop, stopPlan = screen.stopPlan, biometry = biometry, held = pinnedHeld ?: held, onHeld = { held = it },
            onPulseTap = AppRouter::openDispatch, onPulseHold = { StopCoordinator.holdCompleted(screen.stopPlan) },
            now = { app.page.android.ui.nw.now.NowScreen() }, sky = { app.page.android.ui.nw.sky.SkyScreen() },
            overlays = { Sheets(sheets.current, onRequestNotifications) },
        )
    }
}

/** The one sheet that can be up, with its content kept while it leaves. */
@Composable
private fun Sheets(current: NWSheet?, onRequestNotifications: () -> Unit) {
    var decisionId by remember { mutableStateOf<String?>(null) }
    var sessionId by remember { mutableStateOf<String?>(null) }
    var entry by remember { mutableStateOf(RoomEntry.STORY) }
    if (current is NWSheet.Decision) decisionId = current.pageId
    if (current is NWSheet.Session && current.sessionId != sessionId) {
        sessionId = current.sessionId
        entry = AppRouter.takeRoomEntry(current.sessionId)
    }
    val inbox by RelayClient.inbox.collectAsStateWithLifecycle()
    var diffFor by remember { mutableStateOf<Pair<String, String>?>(null) }
    val decisionColor = decisionBackground(inbox.firstOrNull { it.id == decisionId }?.let { NowRowBuilder.row(it, null, "") })
    NWSheetHost(current is NWSheet.Decision, AppRouter::closeSheet, containerColor = decisionColor) {
        decisionId?.let { id -> DecisionContainer(id, onViewChanges = { sid, title -> diffFor = sid to title }) }
    }
    NWOverlay(diffFor != null && current is NWSheet.Decision, { diffFor = null }) {
        diffFor?.let { (sid, title) -> app.page.android.ui.nw.room.NWDiffSheet(sid, title, onClose = { diffFor = null }) }
    }
    var towerSection by remember { mutableStateOf<app.page.android.model.TowerSection?>(null) }
    if (current is NWSheet.Tower) towerSection = current.section
    NWSheetHost(current is NWSheet.Tower, AppRouter::closeSheet) { app.page.android.ui.nw.tower.TowerContainer(towerSection, onRequestNotifications) }
    NWSheetHost(current is NWSheet.Dispatch, AppRouter::closeSheet) { app.page.android.ui.nw.dispatch.DispatchContainer() }
    NWSheetHost(current is NWSheet.History, AppRouter::closeSheet) { app.page.android.ui.nw.history.HistoryContainer() }
    NWOverlay(current is NWSheet.Session, AppRouter::closeSheet) {
        sessionId?.let { id -> RoomContainer(id, entry) }
    }
}
