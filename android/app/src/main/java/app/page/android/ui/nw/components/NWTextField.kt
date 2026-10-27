package app.page.android.ui.nw.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import app.page.android.ui.nw.theme.NW

/** The Night Watch text field: a soft slate box, a placeholder that says what the text is for, 1 to [maxLines] lines. */
@Composable
fun NWTextField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    maxLines: Int = 5,
    focus: FocusRequester? = null,
    imeAction: ImeAction = ImeAction.Default,
    onImeAction: () -> Unit = {},
    enabled: Boolean = true,
    label: String = placeholder,
) {
    Box(
        modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(16.dp)).background(Color.White.copy(alpha = 0.07f)).padding(horizontal = 14.dp, vertical = 12.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        if (value.isEmpty()) Text(placeholder, style = NW.Typo.body, color = NW.Palette.textQuiet.color, maxLines = 2)
        BasicTextField(
            value, onValueChange,
            Modifier.fillMaxWidth().let { if (focus != null) it.focusRequester(focus) else it }.semantics { contentDescription = label },
            enabled = enabled, maxLines = maxLines,
            textStyle = NW.Typo.body.copy(color = NW.Palette.textPrimary.color), cursorBrush = SolidColor(NW.Palette.teal.color),
            keyboardOptions = KeyboardOptions(imeAction = imeAction), keyboardActions = KeyboardActions(onSend = { onImeAction() }, onDone = { onImeAction() }, onNext = { onImeAction() }),
        )
    }
}
