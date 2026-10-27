package app.page.android

import android.app.Application
import androidx.lifecycle.ProcessLifecycleOwner
import app.page.android.data.ActivityStore
import app.page.android.data.AppGraph
import app.page.android.data.AppRouter
import app.page.android.data.CardGlowStore
import app.page.android.data.TipStore
import app.page.android.data.PairingStore
import app.page.android.data.RelayClient
import app.page.android.data.SessionStore
import app.page.android.notify.AppVisibility
import app.page.android.notify.BackgroundConnection
import app.page.android.notify.NotificationAccess
import app.page.android.notify.PageNotifications

class PageApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        AppGraph.init(this)
        PageNotifications.createChannels(this)
        AppRouter.restore()
        CardGlowStore.init()
        TipStore.init()
        ActivityStore.init()
        RelayClient.notifier = PageNotifications
        SessionStore.reloadKey()
        PairingStore.init()
        BackgroundConnection.init()
        NotificationAccess.refresh(this)
        PairingStore.onPairingChanged = { paired ->
            if (paired) RelayClient.activate()
            // Pairing happens on screen, so the service may start.
            BackgroundConnection.sync(this, fromForeground = paired)
        }
        // Socket open while a screen is visible (or Stay connected holds it).
        ProcessLifecycleOwner.get().lifecycle.addObserver(AppVisibility)
        AwayLifecycle.install()
        // A cold start from a notification action or the background check:
        // make sure the check stays scheduled; never start the service here.
        BackgroundConnection.sync(this, fromForeground = false)
    }
}
