package app.page.android.ui.nw.room

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.SessionStore
import app.page.android.model.ChangesModel
import app.page.android.ui.nw.components.NWBackdrop
import app.page.android.ui.nw.components.rememberNWNow
import app.page.android.ui.nw.theme.NW
import java.time.Instant

/** A session's changes as a sheet: this turn's files (or the repository's uncommitted changes) with the redacted diff, asked from the Mac when the screen opens (`diff` op). Read-only. The Room's Changes lens draws the same panel. (iOS DiffView.) */
@Composable
fun NWDiffSheet(sessionId: String, title: String, onClose: () -> Unit, modifier: Modifier = Modifier) {
    val state by SessionStore.state.collectAsStateWithLifecycle()
    var requestedAt by remember { mutableStateOf(Instant.now()) }
    val now by rememberNWNow(slowMs = 1_000)
    val clip = LocalClipboardManager.current
    fun request() { requestedAt = Instant.now(); SessionStore.requestDiff(sessionId) }
    LaunchedEffect(sessionId) { request() }
    val req = state.diffs[sessionId]
    val load = ChangesModel.load(req?.answer != null, req?.error, requestedAt, now)
    Box(modifier.fillMaxSize().background(NW.Palette.backgroundDeep.color)) {
        NWBackdrop()
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = NW.Space.lg).padding(top = 14.dp, bottom = 6.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(48.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.09f)).clickable(role = Role.Button, onClickLabel = "Close", onClick = onClose), contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.ExpandMore, "Close", tint = NW.Palette.textPrimary.color, modifier = Modifier.size(24.dp))
                }
                Text(title, style = NW.Typo.title.copy(fontFamily = FontFamily.Monospace), color = NW.Palette.textPrimary.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            NWChangesPanel(req?.answer?.let { ChangesModel.build(it) }, load, onRefresh = ::request, onCopy = { clip.setText(AnnotatedString(it)) })
        }
    }
}
