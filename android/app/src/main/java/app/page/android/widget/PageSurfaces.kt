package app.page.android.widget

import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.service.quicksettings.TileService
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.updateAll
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** Tells the home-screen widget and the Quick Settings tile that the status snapshot changed. */
object PageSurfaces {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    fun refresh(context: Context) {
        scope.launch {
            runCatching {
                // Only if a widget has been placed: nothing to do (and nothing to wake) otherwise.
                if (GlanceAppWidgetManager(context).getGlanceIds(PageWidget::class.java).isNotEmpty()) PageWidget().updateAll(context)
            }
            runCatching { TileService.requestListeningState(context, ComponentName(context, PageTileService::class.java)) }
        }
    }
}
