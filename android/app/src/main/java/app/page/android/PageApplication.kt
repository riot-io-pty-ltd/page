package app.page.android

import android.app.Application
import app.page.android.data.AppGraph
import app.page.android.data.PairingStore
import app.page.android.data.SessionStore

class PageApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        AppGraph.init(this)
        SessionStore.reloadKey()
        PairingStore.init()
    }
}
