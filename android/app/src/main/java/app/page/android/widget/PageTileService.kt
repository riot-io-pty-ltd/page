package app.page.android.widget

import android.app.PendingIntent
import android.content.Intent
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import app.page.android.MainActivity
import app.page.android.R
import app.page.android.data.AppGraph
import app.page.android.data.PairingStore
import app.page.android.data.StatusSnapshotStore

/**
 * The Quick Settings tile: "Page · 2 need you". Amber-lit while something needs you, dim otherwise, and it shows
 * the same count as the pulse. Tapping it opens Now (never a tab, never an action: the tile cannot approve
 * anything). It reads the status snapshot the app keeps, which holds counts and a sentence and nothing else, so it
 * is as quiet on a locked phone as the home-screen widget. (Spec: "Action Button / Control Center: 'Open Now', with
 * the count. It never acts on its own.")
 */
class PageTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        render()
    }

    override fun onClick() {
        super.onClick()
        val intent = Intent(this, MainActivity::class.java).setAction(Intent.ACTION_VIEW).setData(Uri.parse("page://now")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        // Opening an activity from a tile asks for the phone to be unlocked first.
        unlockAndRun {
            if (Build.VERSION.SDK_INT >= 34) {
                startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            } else {
                @Suppress("DEPRECATION") startActivityAndCollapse(intent)
            }
        }
    }

    private fun render() {
        val tile = qsTile ?: return
        val snap = if (runCatching { AppGraph.app }.isSuccess && PairingStore.isPaired) StatusSnapshotStore.read() else null
        tile.label = "Page"
        tile.icon = Icon.createWithResource(this, R.drawable.ic_stat_page)
        if (snap == null) {
            tile.state = Tile.STATE_INACTIVE
            if (Build.VERSION.SDK_INT >= 29) tile.subtitle = if (PairingStore.isPaired) "Opens Now" else "Open Page to pair"
        } else {
            tile.state = if (snap.needsYou > 0 && !snap.isUnreachable) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            if (Build.VERSION.SDK_INT >= 29) tile.subtitle = if (snap.isUnreachable) snap.faceHeadline else snap.headline
        }
        tile.updateTile()
    }
}
