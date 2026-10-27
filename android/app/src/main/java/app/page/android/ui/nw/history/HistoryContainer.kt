package app.page.android.ui.nw.history

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.AppRouter
import app.page.android.data.RelayClient
import app.page.android.model.HistoryEmpty
import app.page.android.model.HistoryScreenModel
import app.page.android.ui.nw.components.rememberNWNow
import kotlinx.coroutines.launch

/** History, live: every settled page and the day's numbers, from the relay client. It refreshes on open and ticks the ages over. (iOS HistoryContainer.) */
@Composable
fun HistoryContainer(modifier: Modifier = Modifier) {
    val history by RelayClient.history.collectAsStateWithLifecycle()
    val inbox by RelayClient.inbox.collectAsStateWithLifecycle()
    val load by RelayClient.historyLoad.collectAsStateWithLifecycle()
    val now by rememberNWNow(slowMs = 30_000)
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { if (!RelayClient.isDemoMode) RelayClient.refreshHistory() }
    val model = HistoryScreenModel.build(history, inbox, now)
    val empty = HistoryEmpty.state(history.isEmpty(), load is RelayClient.LoadState.Loaded, load.failureMessage)
    val stats = app.page.android.ui.nw.shell.RenderHarness.spec.value?.screen?.contains("stats") == true
    NWHistoryScreen(
        HistoryScreenData(model, empty), HistoryScreenActions(close = AppRouter::closeSheet, retry = { scope.launch { RelayClient.refreshHistory() } }), modifier,
        initial = if (stats) HistorySegment.STATS else HistorySegment.HISTORY,
    )
}
