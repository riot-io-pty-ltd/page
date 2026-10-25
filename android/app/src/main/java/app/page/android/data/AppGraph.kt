package app.page.android.data

import android.app.Application
import app.page.android.model.Intervention

/**
 * The process-wide objects, created once in [app.page.android.PageApplication].
 * A notification action or the background check can start the process cold;
 * Application.onCreate still runs first, so everything here is ready for them.
 */
object AppGraph {
    lateinit var app: Application
        private set
    lateinit var secrets: SecretStore
        private set
    lateinit var prefs: AppPrefs
        private set

    fun init(application: Application) {
        app = application
        secrets = SecretStore(application)
        prefs = AppPrefs(application)
    }

    val appVersion: String
        get() = try {
            app.packageManager.getPackageInfo(app.packageName, 0).versionName ?: "0"
        } catch (_: Exception) {
            "0"
        }
}

/**
 * What the relay client tells the notification layer. Kept as an interface
 * so data/ doesn't depend on Android notification APIs, and so a push
 * provider can drive the same calls later.
 */
interface PageNotifier {
    /** A page opened (an `intervention.opened` frame or a background check found it). */
    fun pageOpened(iv: Intervention) {}

    /** These pages closed: pull their notifications. */
    fun pagesClosed(ids: Collection<String>) {}

    /** After a fresh inbox load: pull notifications for pages no longer pending. */
    fun removeNotIn(pending: Set<String>) {}

    /** Unpair / retirement: pull every notification. */
    fun clearAll() {}

    /** A reply sent from a notification needs a follow-up notice. */
    fun notice(title: String, body: String, interventionId: String) {}
}
