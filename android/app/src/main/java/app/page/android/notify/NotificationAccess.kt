package app.page.android.notify

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import app.page.android.data.AppGraph
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Whether Page may post notifications (Android 13+ asks at runtime via
 * POST_NOTIFICATIONS; older versions only have the per-app switch). The
 * Android side of iOS NotificationService.authorization.
 */
object NotificationAccess {
    enum class Authorization { UNKNOWN, NOT_DETERMINED, DENIED, AUTHORIZED }

    private val _authorization = MutableStateFlow(Authorization.UNKNOWN)
    val authorization: StateFlow<Authorization> = _authorization.asStateFlow()

    /** The runtime permission exists on this Android version. */
    val needsRuntimePermission: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU

    fun canPost(context: Context): Boolean {
        if (needsRuntimePermission &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        return NotificationManagerCompat.from(context).areNotificationsEnabled()
    }

    fun refresh(context: Context) {
        _authorization.value = when {
            canPost(context) -> Authorization.AUTHORIZED
            needsRuntimePermission && !AppGraph.prefs.askedNotificationPermission -> Authorization.NOT_DETERMINED
            else -> Authorization.DENIED
        }
    }

    /** The system screen with Page's notification switches. */
    fun openSettings(context: Context) {
        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }
}
