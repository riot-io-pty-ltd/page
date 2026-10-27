package app.page.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.page.android.ui.theme.MinTouch
import app.page.android.ui.theme.PageType
import app.page.android.ui.theme.Radius
import app.page.android.ui.theme.Space
import app.page.android.ui.theme.colors

enum class BannerTone { WARNING, ERROR, INFO }

/**
 * A problem the user should know about, with a way to fix it when there is
 * one. Shown at the top of the Inbox so "All quiet" is never a false promise.
 */
@Composable
fun StatusBanner(
    tone: BannerTone,
    icon: ImageVector,
    title: String,
    message: String,
    actionTitle: String? = null,
    modifier: Modifier = Modifier,
    action: (() -> Unit)? = null,
) {
    val tint = when (tone) {
        BannerTone.WARNING -> colors.warning
        BannerTone.ERROR -> colors.destructiveText
        BannerTone.INFO -> colors.textMuted
    }
    val shape = RoundedCornerShape(12.dp)
    Row(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(tint.copy(alpha = 0.08f))
            .border(1.dp, tint.copy(alpha = 0.35f), shape)
            .padding(Space.m),
        horizontalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(22.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Space.xs)) {
            Text(title, style = PageType.bodyEm, color = colors.text)
            if (message.isNotEmpty()) Text(message, style = PageType.caption12, color = colors.textMuted)
            if (actionTitle != null && action != null) {
                TextLink(actionTitle, onClick = action)
            }
        }
    }
}

/** A plain text button with a 48 dp touch target. */
@Composable
fun TextLink(text: String, color: Color = colors.text, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(
        modifier
            .defaultMinSize(minHeight = MinTouch)
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.CenterStart,
    ) {
        Text(text, style = PageType.bodyEm, color = color)
    }
}

enum class QuickButtonStyle { ACCENT, DESTRUCTIVE, OUTLINE }

/** Full-width action button (Approve, Deny, Carry on, Close). */
@Composable
fun QuickButton(label: String, style: QuickButtonStyle, enabled: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val shape = RoundedCornerShape(Radius.button)
    val base = modifier
        .fillMaxWidth()
        .heightIn(min = MinTouch)
        .clip(shape)
    val styled = when (style) {
        QuickButtonStyle.ACCENT -> base.background(colors.pulseGradient)
        QuickButtonStyle.DESTRUCTIVE -> base.background(colors.destructive)
        QuickButtonStyle.OUTLINE -> base.border(1.dp, colors.hairline, shape)
    }
    Box(
        styled
            .alpha(if (enabled) 1f else 0.45f)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = Space.l, vertical = Space.s),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = PageType.button17,
            color = if (style == QuickButtonStyle.OUTLINE) colors.text else colors.onAccent,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** The big pulse-gradient button on the pairing screen. */
@Composable
fun PrimaryButton(title: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    Box(
        modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clip(RoundedCornerShape(26.dp))
            .background(colors.pulseGradient)
            .alpha(if (enabled) 1f else 0.45f)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = Space.l, vertical = Space.s),
        contentAlignment = Alignment.Center,
    ) {
        Text(title, style = PageType.button17, color = colors.onAccent)
    }
}

/**
 * Growing text field with a round send button. [onSend] gets the trimmed
 * text; the button is enabled only when there is some.
 */
@Composable
fun ReplyField(
    text: String,
    onTextChange: (String) -> Unit,
    placeholder: String,
    enabled: Boolean,
    sendLabel: String = "Send reply",
    modifier: Modifier = Modifier,
    /** Lets a caller put the cursor here (the In flight row's "Type"). */
    focusRequester: FocusRequester? = null,
    onSend: (String) -> Unit,
) {
    val hasText = text.isNotBlank()
    val shape = RoundedCornerShape(Radius.input)
    Row(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.surfaceRaised)
            .border(1.dp, colors.hairline, shape),
        verticalAlignment = Alignment.Bottom,
    ) {
        Box(Modifier.weight(1f).padding(horizontal = Space.l, vertical = 14.dp)) {
            if (text.isEmpty()) Text(placeholder, style = PageType.body15, color = colors.textMuted)
            BasicTextField(
                value = text,
                onValueChange = onTextChange,
                enabled = enabled,
                textStyle = PageType.body15.copy(color = colors.text),
                cursorBrush = SolidColor(colors.text),
                maxLines = 5,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                modifier = Modifier
                    .fillMaxWidth()
                    .then(if (focusRequester != null) Modifier.focusRequester(focusRequester) else Modifier)
                    .semantics { contentDescription = placeholder },
            )
        }
        Box(
            Modifier
                .size(MinTouch)
                .clickable(enabled = enabled && hasText, role = Role.Button) { onSend(text.trim()) }
                .semantics { contentDescription = sendLabel },
            contentAlignment = Alignment.Center,
        ) {
            Box(
                Modifier
                    .size(36.dp)
                    .clip(CircleShape)
                    .then(
                        if (hasText && enabled) Modifier.background(colors.pulseGradient)
                        else Modifier.background(colors.textMuted.copy(alpha = 0.5f))
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.ArrowUpward, contentDescription = null, tint = colors.onAccent, modifier = Modifier.size(20.dp))
            }
        }
    }
}

/** The status strip's raised box, inset like the reply controls. */
@Composable
fun Modifier.strip(): Modifier {
    val shape = RoundedCornerShape(12.dp)
    return this
        .padding(horizontal = Space.xl)
        .padding(top = Space.s)
        .fillMaxWidth()
        .clip(shape)
        .background(colors.surfaceRaised)
        .border(1.dp, colors.hairline, shape)
        .padding(Space.m)
}

/**
 * One-line delivery or resolution state above the reply controls. No icon
 * means "in progress" and shows a spinner. Announced as it changes.
 */
@Composable
fun StatusStrip(icon: ImageVector?, text: String, color: Color, trailing: (@Composable () -> Unit)? = null) {
    Row(
        Modifier.strip().semantics { liveRegion = LiveRegionMode.Polite },
        horizontalArrangement = Arrangement.spacedBy(Space.s),
        verticalAlignment = Alignment.Top,
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(18.dp))
        } else {
            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = colors.textMuted)
        }
        Text(text, style = PageType.caption12, color = colors.text, modifier = Modifier.weight(1f))
        trailing?.invoke()
    }
}

/** A confirmation step (iOS confirmationDialog): a title, a message, and the choices. */
data class DialogChoice(val label: String, val destructive: Boolean = false, val onClick: () -> Unit)

@Composable
fun ConfirmDialog(title: String, message: String, choices: List<DialogChoice>, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title, style = PageType.title17) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Space.s)) {
                Text(message, style = PageType.body15, color = colors.textMuted)
                Spacer(Modifier.width(0.dp))
                for (c in choices) {
                    TextButton(
                        onClick = { onDismiss(); c.onClick() },
                        modifier = Modifier.fillMaxWidth().heightIn(min = MinTouch),
                    ) {
                        Text(
                            c.label,
                            style = PageType.bodyEm,
                            color = if (c.destructive) colors.destructiveText else colors.text,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss, modifier = Modifier.heightIn(min = MinTouch)) {
                Text("Cancel", style = PageType.bodyEm, color = colors.textMuted)
            }
        },
        containerColor = colors.surfaceRaised,
    )
}
