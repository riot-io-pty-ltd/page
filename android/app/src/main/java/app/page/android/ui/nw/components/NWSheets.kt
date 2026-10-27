package app.page.android.ui.nw.components

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import app.page.android.ui.nw.theme.LocalReduceMotion
import app.page.android.ui.nw.theme.NW
import kotlin.math.roundToInt

/**
 * The host of a bottom sheet (Decision, Tower, Dispatch): a scrim, a panel of about 88% of the height that
 * slides up, a drag handle that pulls it down, back to close. One at a time (the router's `SheetQueue`). It owns
 * the scrim and back handling; [originBounds] is the hook the motion stage uses for a container transform from the
 * thing that opened it. Reduce Motion: the sheet just appears.
 */
@Composable
fun NWSheetHost(
    visible: Boolean,
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
    heightFraction: Float = 0.88f,
    /** The panel's fill (the Decision sheet tints it by the card's class). */
    containerColor: Color = NW.Palette.background.color,
    @Suppress("UNUSED_PARAMETER") originBounds: Rect? = null,
    content: @Composable () -> Unit,
) {
    val reduce = LocalReduceMotion.current
    val ms = if (reduce) 0 else 260
    BackHandler(enabled = visible, onBack = onDismissRequest)
    Box(modifier.fillMaxSize()) {
        AnimatedVisibility(visible, enter = fadeIn(tween(ms)), exit = fadeOut(tween(ms))) {
            Box(
                Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.58f))
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClickLabel = "Close", onClick = onDismissRequest),
            )
        }
        AnimatedVisibility(
            visible, modifier = Modifier.align(Alignment.BottomCenter),
            enter = slideInVertically(tween(ms)) { it }, exit = slideOutVertically(tween(ms)) { it },
        ) {
            var dragY by remember { mutableFloatStateOf(0f) }
            LaunchedEffect(visible) { dragY = 0f }
            val dismiss by rememberUpdatedState(onDismissRequest)
            val shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)
            Box(
                Modifier
                    .fillMaxWidth()
                    .fillMaxHeight(heightFraction)
                    .offset { IntOffset(0, dragY.roundToInt()) }
                    .clip(shape)
                    .background(containerColor, shape)
                    .border(1.dp, Color.White.copy(alpha = 0.07f), shape)
                    // Swallow taps so they don't reach the scrim.
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, enabled = false) {},
            ) {
                content()
                // The drag handle: pull it down to close.
                Box(
                    Modifier
                        .align(Alignment.TopCenter)
                        .width(120.dp)
                        .height(28.dp)
                        .pointerInput(Unit) {
                            detectVerticalDragGestures(
                                onDragEnd = { if (dragY > 160f) dismiss() else dragY = 0f },
                                onDragCancel = { dragY = 0f },
                                onVerticalDrag = { _, dy -> dragY = (dragY + dy).coerceAtLeast(0f) },
                            )
                        }
                        .clearAndSetSemantics {},
                    contentAlignment = Alignment.Center,
                ) { Box(Modifier.width(44.dp).height(5.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.28f))) }
            }
        }
    }
}

/**
 * The host of a room (a session's, full screen): it zooms in over what is under it, and back closes it. A room
 * is a place you go into, never a tab. [originBounds] is the same motion-stage hook as the sheet's.
 */
@Composable
fun NWOverlay(
    visible: Boolean,
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
    @Suppress("UNUSED_PARAMETER") originBounds: Rect? = null,
    content: @Composable () -> Unit,
) {
    val reduce = LocalReduceMotion.current
    val ms = if (reduce) 0 else 280
    BackHandler(enabled = visible, onBack = onDismissRequest)
    AnimatedVisibility(
        visible, modifier = modifier,
        enter = fadeIn(tween(ms)) + scaleIn(tween(ms), initialScale = 0.94f, transformOrigin = TransformOrigin(0.5f, 0.7f)),
        exit = fadeOut(tween(ms)) + scaleOut(tween(ms), targetScale = 0.94f, transformOrigin = TransformOrigin(0.5f, 0.7f)),
    ) {
        Box(Modifier.fillMaxSize().background(NW.Palette.background.color)) { content() }
    }
}
