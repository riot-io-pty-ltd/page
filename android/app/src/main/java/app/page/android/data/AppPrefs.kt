package app.page.android.data

import android.content.Context
import android.content.SharedPreferences
import java.util.UUID

/**
 * Non-secret settings and bookkeeping. Secrets never go here: they live in
 * [SecretStore]. This file is excluded from backups too, like everything the
 * app writes.
 */
class AppPrefs(context: Context) {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences("page_prefs", Context.MODE_PRIVATE)

    /**
     * Random per install: the Mac keeps one watched session per viewer. Not a
     * secret.
     */
    val viewer: String by lazy {
        prefs.getString(KEY_VIEWER, null)?.takeIf { it.isNotEmpty() } ?: UUID.randomUUID().toString().lowercase().also {
            prefs.edit().putString(KEY_VIEWER, it).apply()
        }
    }

    /**
     * Why the last pairing ended on its own (relay `token_retired`), shown on
     * the pairing screen until dismissed or a new pairing is adopted.
     */
    var retirementNotice: String?
        get() = prefs.getString(KEY_RETIREMENT, null)
        set(value) = prefs.edit().apply { if (value == null) remove(KEY_RETIREMENT) else putString(KEY_RETIREMENT, value) }.apply()

    /** The Terminal mirror folds long lines (the default). */
    var terminalWrap: Boolean
        get() = prefs.getBoolean(KEY_WRAP, true)
        set(value) = prefs.edit().putBoolean(KEY_WRAP, value).apply()

    /** The user turned on the "Stay connected" foreground service. */
    var stayConnected: Boolean
        get() = prefs.getBoolean(KEY_STAY_CONNECTED, false)
        set(value) = prefs.edit().putBoolean(KEY_STAY_CONNECTED, value).apply()

    /** The app asked for the notification permission once already. */
    var askedNotificationPermission: Boolean
        get() = prefs.getBoolean(KEY_ASKED_NOTIFICATIONS, false)
        set(value) = prefs.edit().putBoolean(KEY_ASKED_NOTIFICATIONS, value).apply()

    /** Which one-time tips were dismissed (model/Tips.kt), newline-joined wire names. */
    var dismissedTips: String?
        get() = prefs.getString(KEY_TIPS, null)
        set(value) = prefs.edit().apply { if (value == null) remove(KEY_TIPS) else putString(KEY_TIPS, value) }.apply()

    /**
     * Page ids a notification was already posted for, newest last. Shared by
     * the in-app socket, the foreground service and the background check so
     * one page never buzzes twice. Bounded.
     */
    @Synchronized
    fun notifiedIds(): List<String> =
        prefs.getString(KEY_NOTIFIED, null)?.split('\n')?.filter { it.isNotEmpty() } ?: emptyList()

    /** Records [id]; returns false if it was already recorded. */
    @Synchronized
    fun markNotified(id: String): Boolean {
        val current = notifiedIds()
        if (id in current) return false
        val next = (current + id).takeLast(MAX_NOTIFIED)
        prefs.edit().putString(KEY_NOTIFIED, next.joinToString("\n")).apply()
        return true
    }

    /** Forgets [id], so a page that is re-opened later (a restored hook page) can alert again. */
    @Synchronized
    fun forgetNotified(ids: Collection<String>) {
        if (ids.isEmpty()) return
        val next = notifiedIds().filter { it !in ids }
        prefs.edit().putString(KEY_NOTIFIED, next.joinToString("\n")).apply()
    }

    /**
     * What the phone itself posted for each page notification, so an action
     * can be checked against our own record instead of the intent's extras
     * (see notify/PostedPages). JSON; bounded by its owner.
     */
    var postedPagesJson: String?
        get() = prefs.getString(KEY_POSTED, null)
        set(value) = prefs.edit().apply { if (value == null) remove(KEY_POSTED) else putString(KEY_POSTED, value) }.apply()

    // Night Watch preferences: the phone's own, never synced. Generic readers so each store owns its key.

    fun string(key: String): String? = prefs.getString(key, null)

    fun putString(key: String, value: String?) {
        prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
    }

    fun boolean(key: String, default: Boolean = false): Boolean = prefs.getBoolean(key, default)

    fun putBoolean(key: String, value: Boolean) {
        prefs.edit().putBoolean(key, value).apply()
    }

    fun long(key: String): Long? = if (prefs.contains(key)) prefs.getLong(key, 0L) else null

    fun putLong(key: String, value: Long?) {
        prefs.edit().apply { if (value == null) remove(key) else putLong(key, value) }.apply()
    }

    @Synchronized
    fun clearNotified() {
        prefs.edit().remove(KEY_NOTIFIED).apply()
    }

    companion object {
        private const val KEY_VIEWER = "page.sessions.viewer"
        private const val KEY_RETIREMENT = "page.retirementNotice"
        private const val KEY_WRAP = "page.terminal.wrap"
        private const val KEY_STAY_CONNECTED = "page.stayConnected"
        private const val KEY_ASKED_NOTIFICATIONS = "page.askedNotifications"
        private const val KEY_NOTIFIED = "page.notifiedIds"
        private const val KEY_POSTED = "page.postedPages"
        private const val KEY_TIPS = "page.dismissedTips"
        private const val MAX_NOTIFIED = 300
    }
}
