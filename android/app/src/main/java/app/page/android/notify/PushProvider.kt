package app.page.android.notify

/**
 * Where a future push provider plugs in. Android has none today: the relay's
 * `device.register` only accepts APNs tokens (`apnsToken`), so Page
 * registers nothing and relies on [StayConnectedService] and
 * [PageCheckWorker] instead.
 *
 * A provider (FCM, UnifiedPush, …) implements this, is set as
 * [PushProviders.active], and feeds incoming payloads to
 * [app.page.android.model.PushPayload] (closed ids, project name) and
 * [PageNotifications] (pageOpened / pagesClosed). The relay will need a
 * matching device-registration route first.
 */
interface PushProvider {
    /** Shown in Settings → Push. */
    val displayName: String

    /** Whether this provider can deliver pages on this device right now. */
    val isAvailable: Boolean

    /** Called after every (re-)pairing: register this device with the relay. */
    suspend fun register(): PushRegistration

    /** Called on unpair, with the old pairing still readable. */
    suspend fun unregister()
}

sealed interface PushRegistration {
    data object Registered : PushRegistration
    data class Failed(val why: String) : PushRegistration
    data class Unavailable(val why: String) : PushRegistration
}

/** No push provider: the honest default. */
object NoPushProvider : PushProvider {
    override val displayName: String = "None"
    override val isAvailable: Boolean = false
    override suspend fun register(): PushRegistration =
        PushRegistration.Unavailable("Push isn't available on Android yet. Turn on Stay connected to be paged instantly.")

    override suspend fun unregister() = Unit
}

object PushProviders {
    var active: PushProvider = NoPushProvider
}
