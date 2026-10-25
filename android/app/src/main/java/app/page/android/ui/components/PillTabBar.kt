package app.page.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import app.page.android.data.AppTab
import app.page.android.ui.theme.PageType
import app.page.android.ui.theme.colors

val AppTab.label: String
    get() = when (this) {
        AppTab.INBOX -> "INBOX"
        AppTab.SESSIONS -> "SESSIONS"
        AppTab.HISTORY -> "HISTORY"
        AppTab.SETTINGS -> "SETTINGS"
    }

val AppTab.accessibilityName: String get() = label.lowercase().replaceFirstChar { it.uppercase() }

val AppTab.icon: ImageVector
    get() = when (this) {
        AppTab.INBOX -> Icons.Filled.Inbox
        AppTab.SESSIONS -> Icons.Filled.Terminal
        AppTab.HISTORY -> Icons.Filled.History
        AppTab.SETTINGS -> Icons.Filled.Settings
    }

/**
 * The floating pill tab bar (iOS Design/PillTabBar.swift). Four tabs can't
 * grow forever on a phone, so the bar caps its own font scale; TalkBack still
 * reads each tab's full name and count.
 */
@Composable
fun PillTabBar(selection: AppTab, inboxCount: Int, sessionsNeedingYou: Int, modifier: Modifier = Modifier, onSelect: (AppTab) -> Unit) {
    val density = LocalDensity.current
    CompositionLocalProvider(LocalDensity provides Density(density.density, minOf(density.fontScale, 1.3f))) {
        val shape = RoundedCornerShape(36.dp)
        Row(
            modifier
                .padding(horizontal = 21.dp)
                .padding(bottom = 12.dp)
                .fillMaxWidth()
                .clip(shape)
                .background(colors.surfaceRaised)
                .border(1.dp, colors.hairline, shape)
                .padding(4.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            for (tab in AppTab.entries) {
                val selected = tab == selection
                val value = when {
                    tab == AppTab.INBOX && inboxCount > 0 -> "$inboxCount waiting"
                    tab == AppTab.SESSIONS && sessionsNeedingYou > 0 -> "$sessionsNeedingYou need${if (sessionsNeedingYou == 1) "s" else ""} you"
                    else -> ""
                }
                val tabShape = RoundedCornerShape(26.dp)
                Column(
                    Modifier
                        .weight(1f)
                        .heightIn(min = 54.dp)
                        .clip(tabShape)
                        .then(if (selected) Modifier.background(colors.pulseGradient) else Modifier)
                        .selectable(selected = selected, role = Role.Tab) { onSelect(tab) }
                        .clearAndSetSemantics {
                            contentDescription = tab.accessibilityName
                            if (value.isNotEmpty()) stateDescription = value
                            this.selected = selected
                            role = Role.Tab
                        }
                        .padding(vertical = 6.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterVertically),
                ) {
                    val tint = if (selected) colors.onAccent else colors.textMuted
                    Icon(tab.icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
                    Text(tab.label, style = PageType.chip11, color = tint, maxLines = 1, overflow = TextOverflow.Clip)
                }
            }
        }
    }
}
