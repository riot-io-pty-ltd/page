package app.page.android

import android.Manifest
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import app.page.android.data.ActivityStore
import app.page.android.data.AwayStore
import app.page.android.data.BiometricGate
import app.page.android.data.AppGraph
import app.page.android.data.AppRouter
import app.page.android.demo.Demo
import app.page.android.notify.NotificationAccess
import app.page.android.ui.nw.shell.NWRoot
import app.page.android.ui.theme.PageTheme

class MainActivity : FragmentActivity() {
    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        NotificationAccess.refresh(this)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Night Watch is dark: light status and navigation bar icons over the night sky.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        BiometricGate.attach(this)
        if (savedInstanceState == null) handle(intent)
        setContent {
            PageTheme {
                NWRoot(onRequestNotifications = ::requestNotificationsIfNeeded)
            }
        }
    }

    override fun onDestroy() {
        BiometricGate.attach(null)
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    override fun onResume() {
        super.onResume()
        NotificationAccess.refresh(this)
    }

    /**
     * `page://intervention/<id>` (a notification tap) opens that page's Decision sheet over Now; `page://now`,
     * `page://sky` and `page://tower` (a widget, the Quick Settings tile) open those.
     */
    private fun handle(intent: Intent?) {
        intent?.data?.toString()?.let { AppRouter.handle(it) }
        Demo.handleLaunchExtras(intent?.extras)
    }

    /**
     * Asks once (after pairing, when the user knows why), like iOS. Android
     * 12 and older grant notifications at install, so there is nothing to ask.
     */
    private fun requestNotificationsIfNeeded() {
        NotificationAccess.refresh(this)
        if (!NotificationAccess.needsRuntimePermission || NotificationAccess.canPost(this)) return
        if (AppGraph.prefs.askedNotificationPermission) return
        AppGraph.prefs.askedNotificationPermission = true
        notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
    }
}

/** Remembers when Page went to the background, so the Return Brief and the handover sentence can say how long you were away. */
object AwayLifecycle : DefaultLifecycleObserver {
    override fun onStart(owner: LifecycleOwner) = AwayStore.onForeground()

    override fun onStop(owner: LifecycleOwner) {
        AwayStore.onBackground()
        ActivityStore.flush()
    }

    fun install() = ProcessLifecycleOwner.get().lifecycle.addObserver(this)
}
