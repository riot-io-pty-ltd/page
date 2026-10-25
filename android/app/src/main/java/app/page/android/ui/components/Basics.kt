package app.page.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.page.android.ui.theme.PageType
import app.page.android.ui.theme.Radius
import app.page.android.ui.theme.Space
import app.page.android.ui.theme.colors
import java.time.Instant
import kotlinx.coroutines.delay

/**
 * The wall clock, re-read every [periodMs], so relative times ("Paged 12s
 * ago"), Mac presence and banners re-evaluate even when no data changes (the
 * iOS TimelineView.periodic).
 */
@Composable
fun rememberNow(periodMs: Long): Instant {
    var now by remember { mutableStateOf(Instant.now()) }
    LaunchedEffect(periodMs) {
        while (true) {
            now = Instant.now()
            delay(periodMs)
        }
    }
    return now
}

/** Raised card: surface, hairline border, rounded corners. */
@Composable
fun Modifier.card(padding: Dp = Space.l): Modifier {
    val shape = RoundedCornerShape(Radius.card)
    return this
        .fillMaxWidth()
        .clip(shape)
        .background(colors.surfaceRaised)
        .border(1.dp, colors.hairline, shape)
        .padding(padding)
}

@Composable
fun StatusDot(color: Color, modifier: Modifier = Modifier) {
    Box(modifier.size(8.dp).clip(CircleShape).background(color).clearAndSetSemantics { })
}

/** Section title used across tabs ("YOUR MAC", "TOP PROJECTS" …). */
@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = PageType.caption12.copy(letterSpacing = PageType.chip11.letterSpacing),
        color = colors.textMuted,
        modifier = modifier.semantics { heading() },
    )
}

/** Big screen title ("Page", "Sessions", "History", "Settings"). */
@Composable
fun ScreenTitle(text: String, modifier: Modifier = Modifier) {
    Text(text, style = PageType.display28, color = colors.text, modifier = modifier.semantics { heading() })
}

/** The uppercase status line under a screen title. */
@Composable
fun StatusLine(text: String, modifier: Modifier = Modifier) {
    Text(
        text.uppercase(),
        style = PageType.caption12.copy(letterSpacing = PageType.chip11.letterSpacing),
        color = colors.textMuted,
        maxLines = 1,
        modifier = modifier.fillMaxWidth(),
    )
}
