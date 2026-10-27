package app.page.android.notify

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import app.page.android.MainActivity
import app.page.android.R
import app.page.android.model.RunwayMarker
import app.page.android.model.RunwayModel

/**
 * The ongoing "live" notification (board 34): "2 need you · 5 working", "Page · live · runway clear till 3:40",
 * and the runway drawn under it with its markers. It is the Stay connected service's notification, so it exists
 * only while the user has asked Page to stay connected, and shows nothing but counts and times: no project names
 * and no commands. Android's own progress-style live update (API 36) is not used: it is not available to this
 * build, so the runway is drawn to a bitmap in a decorated custom view.
 */
object LiveNotification {
    /** What it shows; kept as plain values so an unchanged status never re-posts. */
    data class Status(
        val headline: String,
        val subline: String,
        val markers: List<Marker>,
        val connected: Boolean,
    ) {
        data class Marker(val fraction: Double, val tone: RunwayMarker.Tone)
    }

    fun status(headline: String, subline: String, runway: RunwayModel, connected: Boolean) =
        Status(headline, subline, runway.markers.map { Status.Marker(it.fraction, it.tone) }, connected)

    fun build(context: Context, channel: String, s: Status, turnOff: PendingIntent): Notification {
        val open = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP).setData(android.net.Uri.parse("page://now")),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val sub = (if (s.connected) "Page · live" else "Page · reconnecting") + s.subline.takeIf { it.isNotEmpty() }?.let { " · $it" }.orEmpty()
        val views = RemoteViews(context.packageName, R.layout.notification_live).apply {
            setTextViewText(R.id.live_title, s.headline)
            setTextViewText(R.id.live_text, sub)
            setImageViewBitmap(R.id.live_runway, runwayBitmap(s.markers))
        }
        return NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_stat_page)
            .setContentTitle(s.headline)
            .setContentText(sub)
            .setStyle(NotificationCompat.DecoratedCustomViewStyle())
            .setCustomContentView(views)
            .setCustomBigContentView(views)
            .setContentIntent(open)
            .addAction(0, "Turn off", turnOff)
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(
                NotificationCompat.Builder(context, channel).setSmallIcon(R.drawable.ic_stat_page).setContentTitle("Page is live").build(),
            )
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    /** The runway as a picture: a track, teal up to the first marker, and a dot per marker in its tone. */
    fun runwayBitmap(markers: List<Status.Marker>, width: Int = 720, height: Int = 44): Bitmap {
        val bmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        val mid = height / 2f
        val pad = height / 2f
        val track = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0x66808A99; strokeWidth = 6f; strokeCap = Paint.Cap.ROUND }
        c.drawLine(pad, mid, width - pad, mid, track)
        fun x(f: Double) = pad + ((width - 2 * pad) * f.coerceIn(0.0, 1.0)).toFloat()
        val sorted = markers.sortedBy { it.fraction }
        val teal = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFF5EEAD4.toInt(); strokeWidth = 6f; strokeCap = Paint.Cap.ROUND }
        c.drawLine(pad, mid, if (sorted.isEmpty()) width - pad else x(sorted.first().fraction), mid, teal)
        for (m in sorted) {
            val col = when (m.tone) { RunwayMarker.Tone.AMBER -> 0xFFF5B14C; RunwayMarker.Tone.GREEN -> 0xFF34D399; RunwayMarker.Tone.BLUE -> 0xFF38BDF8 }.toInt()
            c.drawCircle(x(m.fraction), mid, 11f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = col })
        }
        return bmp
    }
}
