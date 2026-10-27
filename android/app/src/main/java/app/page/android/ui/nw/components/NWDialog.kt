package app.page.android.ui.nw.components

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import app.page.android.ui.nw.theme.NW

/** A confirmation in the Night Watch colours: a question, what it will do, and one plain word to say yes. */
@Composable
fun NWConfirmDialog(
    title: String, message: String, confirmLabel: String, onConfirm: () -> Unit, onDismiss: () -> Unit,
    destructive: Boolean = false, cancelLabel: String = "Cancel",
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = NW.Palette.surfaceRaised.color,
        title = { Text(title, style = NW.Typo.title, color = NW.Palette.textPrimary.color) },
        text = { Text(message, style = NW.Typo.body, color = NW.Palette.textSecondary.color) },
        confirmButton = { TextButton({ onDismiss(); onConfirm() }) { Text(confirmLabel, style = NW.Typo.bodyStrong, color = (if (destructive) NW.Palette.amber else NW.Palette.teal).color) } },
        dismissButton = { TextButton(onDismiss) { Text(cancelLabel, style = NW.Typo.bodyStrong, color = NW.Palette.textSecondary.color) } },
    )
}
