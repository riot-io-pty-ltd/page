package app.page.android.data

import app.page.android.model.PageDate
import app.page.android.model.PairedMac
import app.page.android.model.ValidatedPairing
import app.page.android.model.parseJsonObject
import app.page.android.model.str
import java.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * The single pairing this phone has with a Mac. Credentials live in
 * [SecretStore] (see [RelayCredentials]); this object only publishes whether
 * we're paired and drives the other services when that changes.
 */
object PairingStore {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val _pairedMac = MutableStateFlow<PairedMac?>(null)
    val pairedMac: StateFlow<PairedMac?> = _pairedMac.asStateFlow()

    /** Host of the paired relay, for display. */
    private val _relayHost = MutableStateFlow<String?>(null)
    val relayHost: StateFlow<String?> = _relayHost.asStateFlow()

    /**
     * Why the last pairing ended on its own: the Mac replaced it (relay
     * `token_retired`). Shown on the pairing screen until a new pairing is
     * adopted or the user dismisses it; kept across launches.
     */
    private val _retirementNotice = MutableStateFlow<String?>(null)
    val retirementNotice: StateFlow<String?> = _retirementNotice.asStateFlow()

    /** Pairing lifecycle hooks (the notification layer starts/stops its connection). */
    var onPairingChanged: (paired: Boolean) -> Unit = {}

    /** "Try the demo": in memory only, nothing written and no network. */
    var isDemoPairing = false
        private set

    val isPaired: Boolean get() = _pairedMac.value != null

    fun init() {
        load()
        _retirementNotice.value = AppGraph.prefs.retirementNotice
        // A retirement noticed while no UI existed (a notification action) is
        // handled here too, since this collects for the life of the process.
        scope.launch { RelayClient.retiredWhy.filterNotNull().collect { pairingRetired(it) } }
    }

    private fun load() {
        val creds = RelayCredentials.current(AppGraph.secrets)
        _relayHost.value = creds?.baseUrl?.let { runCatching { java.net.URI(it).host }.getOrNull() }
        val json = if (creds != null) AppGraph.secrets.get(SecretStore.PAIRED_MAC)?.let(::parseJsonObject) else null
        val name = json?.str("name")
        _pairedMac.value = if (name != null) PairedMac(name, PageDate.parseAny(json["pairedAt"])) else null
    }

    /**
     * Saves a pairing that already passed validation and the relay probe.
     * Returns false if the secure store refused the write.
     */
    fun adopt(pairing: ValidatedPairing): Boolean {
        val mac = PairedMac(pairing.macName, Instant.now())
        val macJson = JsonObject(mapOf("name" to JsonPrimitive(mac.name), "pairedAt" to JsonPrimitive(mac.pairedAt!!.toEpochMilli()))).toString()

        // Anything from a previous pairing must not bleed into this one.
        RelayClient.reset()
        AppRouter.reset()
        dismissRetirementNotice()
        AppGraph.prefs.clearNotified()

        val s = AppGraph.secrets
        if (!s.set(SecretStore.RELAY_URL, pairing.relayBaseUrl) ||
            !s.set(SecretStore.RELAY_TOKEN, pairing.token) ||
            !s.set(SecretStore.PAIRED_MAC, macJson)
        ) {
            return false
        }
        // After the reset above, which cleared the previous Mac's key. A failed
        // write leaves the pairing usable: the Sessions tab then asks for a
        // re-pair.
        val key = pairing.sessionKey
        if (key != null) SessionKeyStore.save(s, key) else SessionKeyStore.clear(s)
        SessionStore.reloadKey()
        isDemoPairing = false
        _relayHost.value = pairing.relayHost
        _pairedMac.value = mac
        onPairingChanged(true)
        return true
    }

    /**
     * Forgets the Mac. Local state is cleared immediately so the UI never
     * shows the old Mac's data. (Android registers no push token with the
     * relay yet, so there is nothing to unregister.)
     */
    fun unpair() {
        forget()
        RelayClient.reset()
        AppRouter.reset()
        RelayClient.notifier.clearAll()
        onPairingChanged(false)
    }

    /**
     * The relay retired this pairing (the Mac regenerated its token). Same
     * local cleanup as [unpair]; the pairing screen shows `why`.
     */
    private fun pairingRetired(why: String) {
        // Already handled, or a newer pairing replaced the retired one.
        if (RelayClient.retiredWhy.value != why) return
        _retirementNotice.value = why
        AppGraph.prefs.retirementNotice = why
        forget()
        RelayClient.reset()
        AppRouter.reset()
        onPairingChanged(false)
    }

    private fun forget() {
        val s = AppGraph.secrets
        s.delete(SecretStore.PAIRED_MAC)
        s.delete(SecretStore.RELAY_URL)
        s.delete(SecretStore.RELAY_TOKEN)
        SessionKeyStore.clear(s)
        AppGraph.prefs.clearNotified()
        StatusSnapshotStore.clear()
        isDemoPairing = false
        _pairedMac.value = null
        _relayHost.value = null
    }

    fun dismissRetirementNotice() {
        _retirementNotice.value = null
        AppGraph.prefs.retirementNotice = null
    }

    fun adoptDemo(mac: PairedMac) {
        isDemoPairing = true
        _relayHost.value = "demo.invalid"
        _pairedMac.value = mac
    }

    /** Leaving the demo: back to the pairing screen, nothing persisted. */
    fun endDemo() {
        if (!isDemoPairing) return
        isDemoPairing = false
        _pairedMac.value = null
        _relayHost.value = null
        StatusSnapshotStore.clear()
        RelayClient.reset()
        AppRouter.reset()
    }
}
