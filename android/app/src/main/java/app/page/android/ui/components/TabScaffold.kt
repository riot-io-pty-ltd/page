package app.page.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.calculateEndPadding
import androidx.compose.foundation.layout.calculateStartPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.dp
import app.page.android.ui.theme.Space
import app.page.android.ui.theme.colors
import kotlinx.coroutines.launch

/**
 * A tab's scrolling body: Page's surface, pull to refresh, the screen's
 * gutters and system-bar insets, and room at the bottom for the floating
 * tab bar.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TabScaffold(onRefresh: suspend () -> Unit, content: LazyListScope.() -> Unit) {
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }
    val insets = WindowInsets.safeDrawing.asPaddingValues()
    val dir = LocalLayoutDirection.current
    PullToRefreshBox(
        isRefreshing = refreshing,
        onRefresh = {
            scope.launch {
                refreshing = true
                try { onRefresh() } finally { refreshing = false }
            }
        },
        modifier = Modifier.fillMaxSize().background(colors.surface),
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                start = Space.xl + insets.calculateStartPadding(dir),
                end = Space.xl + insets.calculateEndPadding(dir),
                top = Space.xxl + insets.calculateTopPadding(),
                // Tab-bar padding.
                bottom = 120.dp + insets.calculateBottomPadding(),
            ),
            verticalArrangement = Arrangement.spacedBy(Space.xl),
            content = content,
        )
    }
}
