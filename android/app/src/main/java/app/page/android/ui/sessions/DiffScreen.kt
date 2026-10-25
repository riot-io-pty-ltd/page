package app.page.android.ui.sessions

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.SessionStore
import app.page.android.model.DiffFile
import app.page.android.model.PatchParser
import app.page.android.model.SessionDiff
import app.page.android.ui.components.SectionTitle
import app.page.android.ui.components.TextLink
import app.page.android.ui.components.card
import app.page.android.ui.theme.PageType
import app.page.android.ui.theme.Space
import app.page.android.ui.theme.colors

/**
 * What a session changed (v4 `diff`): the repository and scope ("This turn" /
 * "Uncommitted changes") with totals, the file list with +/− counts, and the
 * patch, one section per file, monospaced and scrolling sideways, with added
 * and removed lines coloured. Asks the Mac when it opens; read-only.
 */
@Composable
fun DiffScreen(sessionId: String, title: String?, onClose: () -> Unit) {
    val state by SessionStore.state.collectAsStateWithLifecycle()
    val request = state.diffs[sessionId]
    LaunchedEffect(sessionId) { SessionStore.requestDiff(sessionId) }
    BackHandler(onBack = onClose)

    Column(Modifier.fillMaxSize().background(colors.surface).statusBarsPadding().navigationBarsPadding()) {
        OverlayTopBar(title?.let { "Changes · $it" } ?: "Changes", Icons.Filled.KeyboardArrowDown, "Close", onClose)
        val answer = request?.answer
        when {
            answer != null -> DiffContent(answer)
            request?.error != null -> Column(
                Modifier.fillMaxSize().padding(Space.xxl),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(Space.m, Alignment.CenterVertically),
            ) {
                Icon(Icons.Filled.WifiOff, contentDescription = null, tint = colors.textMuted, modifier = Modifier.size(40.dp))
                Text("Couldn't load the changes", style = PageType.title17, color = colors.text)
                Text(request.error, style = PageType.body15, color = colors.textMuted, textAlign = TextAlign.Center)
                TextLink("Try again") { SessionStore.requestDiff(sessionId) }
            }
            else -> Row(
                Modifier.fillMaxWidth().padding(top = 60.dp),
                horizontalArrangement = Arrangement.spacedBy(Space.s, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = colors.textMuted)
                Text("Asking your Mac…", style = PageType.body15, color = colors.textMuted)
            }
        }
    }
}

@Composable
private fun DiffContent(diff: SessionDiff) {
    val sections = remember(diff.patch) { PatchParser.sections(diff.patch) }
    LazyColumn(
        contentPadding = PaddingValues(horizontal = Space.l, vertical = Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        item {
            Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
                Text(diff.repo ?: "Changes", style = PageType.title17, color = colors.text, modifier = Modifier.semantics { heading() })
                val totals = listOfNotNull(
                    "${diff.files.size} file${if (diff.files.size == 1) "" else "s"}",
                    diff.added?.let { "+$it" }, diff.removed?.let { "−$it" },
                ).joinToString("  ")
                Text("${diff.scopeLabel} · $totals", style = PageType.caption12, color = colors.textMuted)
                diff.note?.let { Text(it, style = PageType.caption12, color = colors.textMuted) }
                if (diff.truncated) Text("The diff was cut to fit; the rest is on your Mac.", style = PageType.caption12, color = colors.warning)
            }
        }
        if (diff.files.isNotEmpty()) {
            item { SectionTitle("FILES") }
            item {
                Column(Modifier.card(padding = 0.dp)) {
                    diff.files.forEachIndexed { i, f ->
                        FileRow(f)
                        if (i < diff.files.size - 1) Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline))
                    }
                }
            }
        }
        if (sections.isNotEmpty()) {
            item { SectionTitle("PATCH") }
            sections.forEachIndexed { i, s -> item(key = "s$i") { PatchSection(s) } }
        } else if (diff.files.isEmpty() && diff.note == null) {
            item { Text("No changes.", style = PageType.body15, color = colors.textMuted) }
        }
    }
}

@Composable
private fun FileRow(f: DiffFile) {
    val counts = listOfNotNull(f.added?.let { "+$it" }, f.removed?.let { "−$it" })
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Space.l, vertical = Space.m)
            .clearAndSetSemantics {
                contentDescription = "${f.path}, ${f.status}" +
                    (f.added?.let { ", $it lines added" } ?: "") + (f.removed?.let { ", $it removed" } ?: "")
            },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Text(f.path, style = PageType.mono12, color = colors.text, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        if (f.status == "added") Text("NEW", style = PageType.chip11, color = colors.success)
        if (counts.isEmpty()) {
            Text(f.status, style = PageType.caption12, color = colors.textMuted)
        } else {
            f.added?.let { Text("+$it", style = PageType.mono12, color = colors.success) }
            f.removed?.let { Text("−$it", style = PageType.mono12, color = colors.destructiveText) }
        }
    }
}

@Composable
private fun PatchSection(section: PatchParser.Section) {
    val shape = RoundedCornerShape(12.dp)
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.surfaceInset)
            .border(1.dp, colors.hairline, shape)
    ) {
        Text(
            section.path.ifEmpty { "Patch" }, style = PageType.mono12, color = colors.text,
            modifier = Modifier.fillMaxWidth().background(colors.surfaceRaised).padding(horizontal = Space.m, vertical = Space.s).semantics { heading() },
        )
        // Line backgrounds span at least the section's width, wider lines scroll.
        BoxWithConstraints(Modifier.fillMaxWidth()) {
        val minWidth = maxWidth
        SelectionContainer {
            Column(Modifier.horizontalScroll(rememberScrollState()).width(IntrinsicSize.Max).widthIn(min = minWidth).padding(vertical = Space.xs)) {
                for (line in section.lines) {
                    if (line.kind == PatchParser.LineKind.FILE_HEADER) continue
                    val (fg, bg) = colorsFor(line.kind)
                    Text(
                        line.text.ifEmpty { " " }, style = PageType.mono11, color = fg, softWrap = false, maxLines = 1,
                        modifier = Modifier.fillMaxWidth().background(bg).padding(horizontal = Space.m),
                    )
                }
            }
        }
        }
    }
}

@Composable
private fun colorsFor(kind: PatchParser.LineKind): Pair<Color, Color> = when (kind) {
    PatchParser.LineKind.ADDED -> colors.success to colors.success.copy(alpha = 0.10f)
    PatchParser.LineKind.REMOVED -> colors.destructiveText to colors.destructiveText.copy(alpha = 0.10f)
    PatchParser.LineKind.HUNK -> colors.kindUserInput to Color.Transparent
    PatchParser.LineKind.META, PatchParser.LineKind.FILE_HEADER -> colors.textMuted to Color.Transparent
    PatchParser.LineKind.CONTEXT -> colors.text to Color.Transparent
}
