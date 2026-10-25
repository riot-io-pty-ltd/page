package app.page.android.ui.sessions

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import app.page.android.data.AppRouter
import app.page.android.data.SessionStore
import app.page.android.ui.components.strip
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import app.page.android.model.PathDisplay
import app.page.android.model.RelativeTime
import app.page.android.model.SessionCommandKind
import app.page.android.model.SessionDeliveryState
import app.page.android.model.StartFolder
import app.page.android.model.StartPrompt
import app.page.android.ui.components.BannerTone
import app.page.android.ui.components.PrimaryButton
import app.page.android.ui.components.SectionTitle
import app.page.android.ui.components.StatusBanner
import app.page.android.ui.components.StatusStrip
import app.page.android.ui.components.rememberNow
import app.page.android.ui.theme.MinTouch
import app.page.android.ui.theme.PageType
import app.page.android.ui.theme.Space
import app.page.android.ui.theme.colors

/**
 * "New session" (v4 `folders` + `start`): pick a folder the Mac offers
 * (newest first), optionally type the first prompt, and Start. The Mac only
 * allows this when "Let my phone start new Claude sessions" is on, and checks
 * the folder again itself.
 */
@Composable
fun NewSessionScreen(onClose: () -> Unit) {
    val state by SessionStore.state.collectAsStateWithLifecycle()
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    var prompt by rememberSaveable { mutableStateOf("") }
    var problem by remember { mutableStateOf<String?>(null) }
    val now = rememberNow(60_000)

    // Cleared once per opening, not again when the activity is recreated
    // (a rotation would otherwise drop the start and its wait).
    var cleared by rememberSaveable { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        if (!cleared) {
            SessionStore.clearStart()
            cleared = true
        }
        SessionStore.requestFolders()
        // The session this sheet started showed up on the Mac: close the
        // sheet and open it. (clearStart above dropped any earlier one.)
        val id = SessionStore.state.map { it.startedSessionId }.filterNotNull().first()
        SessionStore.clearStartedSession()
        AppRouter.openSession(id)
    }
    BackHandler(onBack = onClose)

    Column(Modifier.fillMaxSize().background(colors.surface).statusBarsPadding().navigationBarsPadding().imePadding()) {
        OverlayTopBar("New session", Icons.Filled.KeyboardArrowDown, "Close", onClose)
        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = Space.xl, vertical = Space.l),
            verticalArrangement = Arrangement.spacedBy(Space.l),
        ) {
            val request = state.folders
            val answer = request?.answer
            when {
                answer != null && !answer.enabled -> StatusBanner(
                    BannerTone.INFO, Icons.Filled.Warning, "Starting sessions is off on your Mac",
                    "Turn on 'Let my phone start new Claude sessions' in Page on your Mac (Settings → Phone).",
                    actionTitle = "Check again",
                ) { SessionStore.requestFolders() }
                answer != null -> {
                    Text("Start Claude in a folder on your Mac.", style = PageType.body15, color = colors.textMuted)
                    SectionTitle("FOLDER")
                    if (answer.folders.isEmpty()) {
                        Text("Your Mac has no recent folders to offer yet. Start Claude there once, then try again.", style = PageType.body15, color = colors.textMuted)
                    } else {
                        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(colors.surfaceRaised).border(1.dp, colors.hairline, RoundedCornerShape(14.dp))) {
                            answer.folders.forEachIndexed { i, f ->
                                FolderRow(f, f.path == selected, now) { selected = f.path; problem = null }
                                if (i < answer.folders.size - 1) Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline))
                            }
                        }
                    }
                    SectionTitle("FIRST PROMPT (OPTIONAL)")
                    PromptField(prompt) { prompt = it; problem = null }
                    problem?.let { Text(it, style = PageType.caption12, color = colors.destructiveText) }
                }
                request?.error != null -> StatusBanner(
                    BannerTone.ERROR, Icons.Filled.Warning, "Couldn't ask your Mac", request.error, actionTitle = "Try again",
                ) { SessionStore.requestFolders() }
                else -> Row(horizontalArrangement = Arrangement.spacedBy(Space.s), verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = colors.textMuted)
                    Text("Asking your Mac for folders…", style = PageType.body15, color = colors.textMuted)
                }
            }
        }
        state.start?.let { start ->
            val s = start.state
            when (s) {
                SessionDeliveryState.Sending -> StatusStrip(null, "Starting…", colors.textMuted)
                is SessionDeliveryState.Typed, is SessionDeliveryState.Queued -> {
                    val detail = (s as? SessionDeliveryState.Typed)?.detail
                    if (state.awaitingStartedSession) {
                        StartedOpeningStrip(detail ?: "Started")
                    } else {
                        // Gave up waiting (90 s). The Mac always sends a detail
                        // ("Started Claude in X"), so keep the pointer to where it is.
                        StatusStrip(Icons.Filled.CheckCircle, "${detail ?: "Started"}, but it hasn't shown up here yet. Look for it in Sessions, or in cmux on your Mac.", colors.success)
                    }
                }
                else -> StatusStrip(Icons.Filled.Warning, "Couldn't start: ${s.explanation(SessionCommandKind.INPUT, "Claude") ?: s.label(SessionCommandKind.INPUT)}", colors.destructiveText)
            }
        }
        val folder = selected
        val ready = state.folders?.answer?.enabled == true && folder != null && state.start?.state?.isPending != true
        Box(Modifier.padding(horizontal = Space.xl, vertical = Space.m)) {
            PrimaryButton("Start", enabled = ready) {
                if (folder != null) problem = SessionStore.startSession(folder, prompt)
            }
        }
        Text(
            "Page on your Mac opens a new cmux workspace in that folder and runs Claude there.",
            style = PageType.caption12, color = colors.textMuted, textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(start = Space.xl, end = Space.xl, bottom = Space.l),
        )
    }
}

/**
 * The start worked; the sheet stays up until the new session appears in the
 * list (it's a background cmux workspace on the Mac), then opens it.
 */
@Composable
private fun StartedOpeningStrip(text: String) {
    Column(
        Modifier.strip().semantics { liveRegion = LiveRegionMode.Polite },
        verticalArrangement = Arrangement.spacedBy(Space.xs),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(Space.s), verticalAlignment = Alignment.Top) {
            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = colors.success, modifier = Modifier.size(18.dp))
            Text(text, style = PageType.caption12, color = colors.text, modifier = Modifier.weight(1f))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Space.s), verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = colors.textMuted)
            Text(
                "Opening it here as soon as it appears… On your Mac it's a new cmux workspace.",
                style = PageType.caption12, color = colors.textMuted, modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun FolderRow(f: StartFolder, selected: Boolean, now: java.time.Instant, onSelect: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = MinTouch)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onSelect)
            .clearAndSetSemantics {
                contentDescription = "${f.name}, ${PathDisplay.abbreviatingHome(f.path)}${if (selected) ", selected" else ""}"
            }
            .padding(horizontal = Space.l, vertical = Space.m),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Icon(
            if (selected) Icons.Filled.CheckCircle else Icons.Outlined.Circle, contentDescription = null,
            tint = if (selected) colors.kindApproval else colors.textMuted, modifier = Modifier.size(20.dp),
        )
        Icon(Icons.Filled.Folder, contentDescription = null, tint = colors.textMuted, modifier = Modifier.size(18.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(f.name, style = PageType.bodyEm, color = colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(PathDisplay.abbreviatingHome(f.path), style = PageType.mono12, color = colors.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        f.lastUsedAt?.let { Text(RelativeTime.ago(it, now), style = PageType.caption12, color = colors.textMuted) }
    }
}

@Composable
private fun PromptField(text: String, onChange: (String) -> Unit) {
    val shape = RoundedCornerShape(12.dp)
    Column(horizontalAlignment = Alignment.End) {
        Box(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 96.dp)
                .clip(shape)
                .background(colors.surfaceRaised)
                .border(1.dp, colors.hairline, shape)
                .padding(Space.m)
        ) {
            if (text.isEmpty()) Text("What should Claude do first?", style = PageType.body15, color = colors.textMuted)
            BasicTextField(
                value = text,
                onValueChange = onChange,
                textStyle = PageType.body15.copy(color = colors.text),
                cursorBrush = SolidColor(colors.text),
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = "First prompt" },
            )
        }
        if (text.length >= StartPrompt.MAX_CHARACTERS - 500) {
            Text("${text.length} / ${StartPrompt.MAX_CHARACTERS}", style = PageType.caption12, color = colors.textMuted, modifier = Modifier.padding(top = 4.dp))
        }
    }
}
