package app.page.android.ui.nw.components

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowForward
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material.icons.automirrored.outlined.Undo
import androidx.compose.material.icons.filled.StopCircle
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.AddCircleOutline
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Laptop
import androidx.compose.material.icons.outlined.SettingsInputAntenna
import androidx.compose.material.icons.outlined.Verified
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material.icons.outlined.WbTwilight
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.BatteryAlert
import androidx.compose.material.icons.outlined.BatteryStd
import androidx.compose.material.icons.outlined.Bedtime
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.Category
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.DesktopAccessDisabled
import androidx.compose.material.icons.outlined.DesktopWindows
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.FindInPage
import androidx.compose.material.icons.outlined.GppMaybe
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Group
import androidx.compose.material.icons.outlined.Groups
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.HourglassEmpty
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.Keyboard
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Memory
import androidx.compose.material.icons.outlined.NotificationsActive
import androidx.compose.material.icons.outlined.NotificationsOff
import androidx.compose.material.icons.outlined.PanTool
import androidx.compose.material.icons.outlined.Pets
import androidx.compose.material.icons.outlined.QrCode2
import androidx.compose.material.icons.outlined.QuestionAnswer
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Speed
import androidx.compose.material.icons.outlined.StopCircle
import androidx.compose.material.icons.outlined.SwapHoriz
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material.icons.outlined.SystemUpdate
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material.icons.outlined.TouchApp
import androidx.compose.material.icons.outlined.VerifiedUser
import androidx.compose.material.icons.outlined.ViewColumn
import androidx.compose.material.icons.outlined.ViewModule
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material.icons.outlined.VpnKey
import androidx.compose.material.icons.outlined.VpnKeyOff
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * The icons the models name. The models carry semantic names (the iOS app's SF Symbol names, so one table of
 * copy and icons serves both phones); this maps each to a Material icon.
 */
fun nwIcon(symbol: String): ImageVector = when (symbol) {
    "exclamationmark.shield" -> Icons.Outlined.GppMaybe
    "doc.text.magnifyingglass" -> Icons.Outlined.FindInPage
    "arrow.uturn.backward.circle" -> Icons.AutoMirrored.Outlined.Undo
    "arrow.triangle.2.circlepath" -> Icons.Outlined.Sync
    "questionmark.bubble" -> Icons.Outlined.QuestionAnswer
    "clock.badge.exclamationmark" -> Icons.Outlined.Schedule
    "gauge.with.needle" -> Icons.Outlined.Speed
    "checkmark.circle" -> Icons.Outlined.CheckCircle
    "keyboard" -> Icons.Outlined.Keyboard
    "key.slash" -> Icons.Outlined.VpnKeyOff
    "wifi.exclamationmark", "wifi.slash" -> Icons.Outlined.WifiOff
    "desktopcomputer.trianglebadge.exclamationmark", "desktopcomputer" -> Icons.Outlined.DesktopAccessDisabled
    "bell.slash" -> Icons.Outlined.NotificationsOff
    "key" -> Icons.Outlined.VpnKey
    "arrow.down.app" -> Icons.Outlined.SystemUpdate
    "eye.slash" -> Icons.Outlined.VisibilityOff
    "hourglass" -> Icons.Outlined.HourglassEmpty
    "lock" -> Icons.Outlined.Lock
    "checkmark.shield" -> Icons.Outlined.VerifiedUser
    "qrcode" -> Icons.Outlined.QrCode2
    "exclamationmark.bubble" -> Icons.Outlined.ErrorOutline
    "tray" -> Icons.Outlined.Inbox
    "moon.zzz" -> Icons.Outlined.Bedtime
    "battery.25" -> Icons.Outlined.BatteryAlert
    "battery.50" -> Icons.Outlined.BatteryStd
    "clock.arrow.circlepath" -> Icons.Outlined.History
    "hand.tap", "rectangle.and.hand.point.up.left" -> Icons.Outlined.TouchApp
    "sparkle" -> Icons.Outlined.AutoAwesome
    "hexagon" -> Icons.Outlined.Category
    "cpu" -> Icons.Outlined.Memory
    "questionmark.circle" -> Icons.AutoMirrored.Outlined.HelpOutline
    "bell.badge" -> Icons.Outlined.NotificationsActive
    "doc.text" -> Icons.Outlined.Description
    "magnifyingglass" -> Icons.Outlined.Search
    "square.and.pencil", "pencil.circle" -> Icons.Outlined.Edit
    "terminal" -> Icons.Outlined.Terminal
    "terminal.fill" -> Icons.Filled.Terminal
    "globe" -> Icons.Outlined.Language
    "checklist" -> Icons.Outlined.Checklist
    "person.2" -> Icons.Outlined.Group
    "person.3" -> Icons.Outlined.Groups
    "plus.circle" -> Icons.Outlined.AddCircleOutline
    "circle.dashed" -> Icons.Outlined.RadioButtonUnchecked
    "macwindow" -> Icons.Outlined.DesktopWindows
    "rectangle.split.3x1" -> Icons.Outlined.ViewColumn
    "square.grid.2x2" -> Icons.Outlined.GridView
    "pawprint" -> Icons.Outlined.Pets
    "rectangle.3.group" -> Icons.Outlined.ViewModule
    "arrow.right" -> Icons.AutoMirrored.Outlined.ArrowForward
    "waveform" -> Icons.Outlined.GraphicEq
    "hand.point.up.left" -> Icons.Outlined.PanTool
    "xmark.circle" -> Icons.Outlined.Cancel
    "stop.circle" -> Icons.Outlined.StopCircle
    "stop.circle.fill" -> Icons.Filled.StopCircle
    "arrow.left.arrow.right" -> Icons.Outlined.SwapHoriz
    "arrow.down" -> Icons.Outlined.ArrowDownward
    "arrow.up" -> Icons.Outlined.ArrowUpward
    "bolt.horizontal" -> Icons.Outlined.Bolt
    "lightbulb" -> Icons.Outlined.Lightbulb
    "moon" -> Icons.Outlined.Bedtime
    "antenna.radiowaves.left.and.right" -> Icons.Outlined.SettingsInputAntenna
    "info.circle" -> Icons.Outlined.Info
    "bubble.left.and.bubble.right" -> Icons.Outlined.Forum
    "plus" -> Icons.Outlined.Add
    "sunrise" -> Icons.Outlined.WbTwilight
    "laptopcomputer" -> Icons.Outlined.Laptop
    "display" -> Icons.Outlined.DesktopWindows
    "arrow.turn.down.right" -> Icons.AutoMirrored.Outlined.ArrowForward
    "checkmark.seal" -> Icons.Outlined.Verified
    "exclamationmark.triangle" -> Icons.Outlined.WarningAmber
    "chevron.right" -> Icons.Outlined.ChevronRight
    else -> Icons.Outlined.Circle
}
