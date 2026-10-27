package app.page.android.ui.nw.dispatch

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.AppRouter
import app.page.android.data.NowStore
import app.page.android.data.PairingStore
import app.page.android.data.SessionStore
import app.page.android.model.DispatchAvailability
import app.page.android.model.DispatchDraft
import app.page.android.model.DispatchStatus
import app.page.android.model.RunwayModel
import app.page.android.model.SessionDeliveryState
import app.page.android.model.TowerSection
import app.page.android.ui.nw.components.rememberNWNow
import kotlinx.coroutines.delay

/**
 * Dispatch, live: the Mac's known folders, a prompt, and Start, wired to the existing [SessionStore.startSession]
 * path. If no session appears within 90 s, or the Mac refuses, the sheet says plainly where to look. (iOS DispatchContainer.)
 */
@Composable
fun DispatchContainer(modifier: Modifier = Modifier) {
    val s by SessionStore.state.collectAsStateWithLifecycle()
    val screen by NowStore.screen.collectAsStateWithLifecycle()
    val mac by PairingStore.pairedMac.collectAsStateWithLifecycle()
    val clip = LocalClipboardManager.current
    var draft by remember { mutableStateOf(DispatchDraft()) }
    var problem by remember { mutableStateOf<String?>(null) }
    val now by rememberNWNow(slowMs = 30_000)
    val request = s.folders
    val availability = DispatchAvailability.from(request?.answer, request?.error)
    val folders = request?.answer?.folders ?: emptyList()
    val pinnedSending = app.page.android.ui.nw.shell.RenderHarness.spec.value?.dispatchSending == true
    val state: SessionDeliveryState? = if (pinnedSending) SessionDeliveryState.Sending else s.start?.state
    val sending = state == SessionDeliveryState.Sending
    LaunchedEffect(Unit) {
        // Cleared once per opening, so an earlier start and its wait never read as this one.
        SessionStore.clearStart()
        if (!pinnedSending) SessionStore.requestFolders()
    }
    LaunchedEffect(folders) { draft = draft.ensuringSelection(folders, now) }
    // The new session showed up on the Mac: open it.
    LaunchedEffect(s.startedSessionId) {
        val id = s.startedSessionId ?: return@LaunchedEffect
        SessionStore.clearStartedSession()
        AppRouter.closeSheet()
        delay(400)
        AppRouter.openSession(id)
    }
    val status = problem?.let { DispatchStatus(it, DispatchStatus.Tone.PROBLEM, false) }
        ?: DispatchStatus.from(state, state is SessionDeliveryState.Typed && !s.awaitingStartedSession)
    NWDispatchScreen(
        DispatchScreenData(mac?.name ?: "", availability, folders, now, status, sending, RunwayModel.build(screen.status, now)),
        DispatchScreenActions(
            start = {
                val path = draft.selectedPath
                if (path != null && draft.canStart(availability, sending)) problem = SessionStore.startSession(path, draft.trimmedPrompt)
            },
            close = AppRouter::closeSheet, paste = { clip.getText()?.let { draft = draft.copy(prompt = draft.prompt + it.text) } },
            openTower = { AppRouter.openTower(TowerSection.BUDGET) }, retry = SessionStore::requestFolders,
        ),
        draft, { draft = it }, modifier,
    )
}
