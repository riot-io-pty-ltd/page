package app.page.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.page.android.ui.theme.MinTouch
import app.page.android.ui.theme.PageType
import app.page.android.ui.theme.Space
import app.page.android.ui.theme.colors

/** A two-or-three option switch, like iOS's segmented picker. */
@Composable
fun <T> SegmentedControl(options: List<T>, selected: T, label: (T) -> String, modifier: Modifier = Modifier, onSelect: (T) -> Unit) {
    val shape = RoundedCornerShape(10.dp)
    Row(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.surfaceInset)
            .border(1.dp, colors.hairline, shape)
            .padding(2.dp),
    ) {
        for (option in options) {
            val isSelected = option == selected
            Box(
                Modifier
                    .weight(1f)
                    .heightIn(min = MinTouch)
                    .clip(RoundedCornerShape(8.dp))
                    .then(if (isSelected) Modifier.background(colors.surfaceRaised) else Modifier)
                    .selectable(selected = isSelected, role = Role.Tab) { onSelect(option) },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label(option),
                    style = if (isSelected) PageType.bodyEm else PageType.body15,
                    color = if (isSelected) colors.text else colors.textMuted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(horizontal = Space.s),
                )
            }
        }
    }
}

