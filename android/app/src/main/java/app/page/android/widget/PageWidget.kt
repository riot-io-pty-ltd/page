package app.page.android.widget

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.Shader
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.semantics.contentDescription
import androidx.glance.semantics.semantics
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import app.page.android.MainActivity
import app.page.android.data.StatusSnapshot
import app.page.android.data.StatusSnapshotStore
import app.page.android.notify.LiveNotification
import app.page.android.model.RunwayMarker

/**
 * The home-screen widget (Glance): the status face of iOS NWWidgetStatusFace. "2 need you" in amber, "All quiet",
 * "Mac offline" in slate; what is working, the Mac and its power; and on the wider sizes the runway. It shows
 * counts and times only, never a project or a command, and tapping it opens Now. Dark whatever the system theme:
 * Night Watch has no light mode.
 */
class PageWidget : GlanceAppWidget() {
    override val sizeMode: SizeMode = SizeMode.Responsive(setOf(DpSize(110.dp, 110.dp), DpSize(250.dp, 110.dp)))

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snap = if (app.page.android.data.PairingStore.isPaired) StatusSnapshotStore.read() else null
        provideContent { Face(context, snap) }
    }

    @Composable
    private fun Face(context: Context, s: StatusSnapshot?) {
        val size = LocalSize.current
        val wide = size.width >= 220.dp
        val tone = when {
            s == null || s.isUnreachable -> Color(0xFF8A93A8)
            s.needsYou > 0 -> Color(0xFFF5B14C)
            else -> Color(0xF5FFFFFF)
        }
        val open = actionStartActivity(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW).setData(Uri.parse("page://now")))
        val said = if (s == null) "Page. Open Page to pair." else "Page. ${s.faceHeadline}. ${s.detail ?: ""}. ${s.macName}."
        Box(
            GlanceModifier.fillMaxSize().cornerRadius(28.dp).background(ImageProvider(sky(s))).clickable(open).semantics { contentDescription = said }.padding(16.dp),
        ) {
            Column(GlanceModifier.fillMaxSize(), verticalAlignment = Alignment.Top) {
                Text("Page", style = TextStyle(color = ColorProvider(Color(0x80FFFFFF)), fontSize = 12.sp, fontWeight = FontWeight.Medium))
                Spacer(GlanceModifier.defaultWeight())
                Text(
                    if (s == null) "Open Page to pair" else s.faceHeadline, maxLines = 2,
                    style = TextStyle(color = ColorProvider(tone), fontSize = if (wide) 28.sp else 22.sp, fontWeight = FontWeight.Bold),
                )
                s?.detail?.let { Text(it, maxLines = 1, style = TextStyle(color = ColorProvider(Color(0xB3FFFFFF)), fontSize = 12.sp, fontWeight = FontWeight.Medium)) }
                s?.let { st ->
                    Text(
                        macLine(st), maxLines = 1, style = TextStyle(color = ColorProvider(Color(0x99FFFFFF)), fontSize = 11.sp),
                    )
                    if (wide && st.markers.isNotEmpty() && !st.isUnreachable) {
                        Spacer(GlanceModifier.height(8.dp))
                        Image(
                            ImageProvider(LiveNotification.runwayBitmap(st.markers.map { m -> LiveNotification.Status.Marker(m.fraction, RunwayMarker.Tone.entries.firstOrNull { it.raw == m.tone } ?: RunwayMarker.Tone.GREEN) }, 720, 44)),
                            contentDescription = null, modifier = GlanceModifier.fillMaxWidth().height(18.dp), contentScale = ContentScale.FillBounds,
                        )
                    }
                }
            }
        }
    }

    private fun macLine(s: StatusSnapshot): String {
        val power = when (s.onAC) { true -> "on power"; false -> s.battery?.let { "on battery $it%" } ?: "on battery"; null -> null }
        return listOfNotNull(s.macName, power).joinToString(" · ")
    }

    /** The widget's sky: a sleeping aurora (amber when something needs you, slate when the Mac is gone) under a darkening so text stays readable. */
    private fun sky(s: StatusSnapshot?): Bitmap {
        val w = 480
        val h = 480
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        val base = Paint().apply { color = 0xFF04060A.toInt() }
        c.drawRect(0f, 0f, w.toFloat(), h.toFloat(), base)
        val glow = when {
            s == null || s.isUnreachable -> 0xFF4B5670.toInt()
            s.needsYou > 0 -> 0xFFF5B14C.toInt()
            (s.working ?: 0) > 0 -> 0xFF5EEAD4.toInt()
            else -> 0xFF38BDF8.toInt()
        }
        val strength = if (s == null || s.isUnreachable) 0.22f else if (s.needsYou > 0) 0.42f else 0.30f
        val p = Paint(Paint.ANTI_ALIAS_FLAG)
        p.shader = RadialGradient(w * 0.8f, 0f, w * 0.9f, intArrayOf((glow and 0x00FFFFFF) or ((strength * 255).toInt() shl 24), 0x00000000), null, Shader.TileMode.CLAMP)
        c.drawRect(0f, 0f, w.toFloat(), h.toFloat(), p)
        val shade = Paint().apply { shader = LinearGradient(0f, 0f, 0f, h.toFloat(), 0x1A04060A, 0xCC04060A.toInt(), Shader.TileMode.CLAMP) }
        c.drawRect(0f, 0f, w.toFloat(), h.toFloat(), shade)
        return bmp
    }
}

class PageWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = PageWidget()
}
