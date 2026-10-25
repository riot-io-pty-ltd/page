package app.page.android

import android.Manifest
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import app.page.android.data.AppGraph
import app.page.android.data.AppRouter
import app.page.android.demo.Demo
import app.page.android.notify.NotificationAccess
import app.page.android.ui.PageRoot
import app.page.android.ui.theme.PageTheme

class MainActivity : ComponentActivity() {
    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        NotificationAccess.refresh(this)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (savedInstanceState == null) handle(intent)
        setContent {
            PageTheme {
                PageRoot(onRequestNotifications = ::requestNotificationsIfNeeded)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    override fun onResume() {
        super.onResume()
        NotificationAccess.refresh(this)
    }

    /** `page://intervention/<id>` (a notification tap) opens that page's reply screen. */
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
