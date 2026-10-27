package app.page.android.ui.nw.lanes

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.ActivityStore
import app.page.android.data.AppRouter
import app.page.android.data.NowStore
import app.page.android.data.RelayClient
import app.page.android.data.SessionStore
import app.page.android.model.MacPresence
import app.page.android.model.SessionAvailability
import app.page.android.model.SessionAvailabilityCopy
import app.page.android.model.TowerSection
import app.page.android.ui.nw.components.rememberNWNow
import kotlinx.coroutines.launch

/** LANES, live: the fleet as a list of lanes, from the session list. (iOS LanesContainer.) */
@Composable
fun LanesScreen(modifier: Modifier = Modifier) {
    val screen by NowStore.screen.collectAsStateWithLifecycle()
    val sessionState by SessionStore.state.collectAsStateWithLifecycle()
    val connection by RelayClient.connection.collectAsStateWithLifecycle()
    val power by ActivityStore.power.collectAsStateWithLifecycle()
    val now by rememberNWNow(slowMs = 5_000)
    val shown = app.page.android.ui.nw.shell.RenderHarness.spec.value?.lanesAvailability
    val availability = shown ?: sessionState.availability(MacPresence.evaluate(screen.status, now), connection == RelayClient.ConnectionState.CONNECTED, now)
    val data = LanesScreenData(
        fleet = screen.sky, lanes = screen.lanes,
        availability = if (availability != SessionAvailability.Ready) SessionAvailabilityCopy.of(availability) else null,
        duskDawn = power,
    )
    val scope = rememberCoroutineScope()
    val actions = LanesScreenActions(
        openRow = { row ->
            val page = row.interventionId
            if (page != null) AppRouter.open(page, switchTab = false) else AppRouter.openSession(row.id)
        },
        tapMoon = { AppRouter.openTower(TowerSection.POWER) },
        availabilityAction = { a ->
            when (a) {
                SessionAvailabilityCopy.Action.REPAIR -> AppRouter.requestUnpair()
                SessionAvailabilityCopy.Action.RETRY -> { SessionStore.refresh(); scope.launch { RelayClient.refreshAll() } }
            }
        },
    )
    NWLanesScreen(data, actions, modifier.fillMaxSize())
}
