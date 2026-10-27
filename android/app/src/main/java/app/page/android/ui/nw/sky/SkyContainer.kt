package app.page.android.ui.nw.sky

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.AppRouter
import app.page.android.data.NowStore
import app.page.android.data.RelayClient
import app.page.android.data.SessionStore
import app.page.android.model.MacPresence
import app.page.android.model.NWDestination
import app.page.android.model.SessionAvailability
import app.page.android.model.SessionAvailabilityCopy
import app.page.android.model.TowerSection
import app.page.android.ui.nw.components.rememberNWNow
import kotlinx.coroutines.launch

/** SKY, live: the fleet as constellations or Lanes, from the session list. (iOS SkyContainer.) */
@Composable
fun SkyScreen(modifier: Modifier = Modifier) {
    val screen by NowStore.screen.collectAsStateWithLifecycle()
    val router by AppRouter.state.collectAsStateWithLifecycle()
    val sessionState by SessionStore.state.collectAsStateWithLifecycle()
    val connection by RelayClient.connection.collectAsStateWithLifecycle()
    val power by app.page.android.data.ActivityStore.power.collectAsStateWithLifecycle()
    var selected by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<String?>(app.page.android.ui.nw.shell.RenderHarness.spec.value?.selectedStar) }
    val now by rememberNWNow(slowMs = 5_000)
    val availability = sessionState.availability(MacPresence.evaluate(screen.status, now), connection == RelayClient.ConnectionState.CONNECTED, now)
    val data = SkyScreenData(
        sky = screen.sky, lanes = screen.lanes, mode = router.skyMode,
        availability = if (availability != SessionAvailability.Ready) SessionAvailabilityCopy.of(availability) else null, selectedStar = selected,
        duskDawn = power,
    )
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val actions = SkyScreenActions(
        setMode = AppRouter::selectSkyMode, select = { selected = it },
        openStar = { star ->
            selected = null
            if (star.interventionId != null) AppRouter.open(star.interventionId!!, switchTab = false) else AppRouter.openSession(star.id)
        },
        tapMoon = { AppRouter.openTower(TowerSection.POWER) },
        availabilityAction = { a ->
            when (a) {
                SessionAvailabilityCopy.Action.REPAIR -> AppRouter.requestUnpair()
                SessionAvailabilityCopy.Action.RETRY -> { SessionStore.refresh(); scope.launch { RelayClient.refreshAll() } }
            }
        },
        toNow = { AppRouter.selectDestination(NWDestination.NOW) },
    )
    NWSkyScreen(data, actions, modifier.fillMaxSize())
}
