package app.page.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.page.android.model.AgentBackend
import app.page.android.model.InterventionBackend
import app.page.android.model.InterventionKind
import app.page.android.model.LiveSessionState

/**
 * The Page design system, ported from iOS Design/Theme.swift: colours,
 * typography, spacing and radii, in light and dark.
 */
@Immutable
data class PageColors(
    val surface: Color,
    val surfaceRaised: Color,
    val surfaceInset: Color,
    val text: Color,
    val textMuted: Color,
    val hairline: Color,
    /** Fill for the destructive Deny button (dark text on top). */
    val destructive: Color,
    /** Destructive *text* on light surfaces needs a darker red for contrast. */
    val destructiveText: Color,
    val warning: Color,
    val success: Color,
    // Intervention kind hues: each kind chip ring and footer dot use the same
    // colour. The light variants are darker so 11sp chip text stays above
    // 4.5:1 on white.
    val kindApproval: Color,
    val kindUserInput: Color,
    val kindIdle: Color,
    val kindRateLimit: Color,
    // Backend brand tints: pill text, background and stroke.
    val backendClaude: Color,
    val backendCodex: Color,
    /** Any other backend (local models, future agents): neutral slate. */
    val backendOther: Color,
    /** The signature gradient. Cyan→teal in dark, amber→chartreuse in light. */
    val pulseStart: Color,
    val pulseEnd: Color,
    val isDark: Boolean,
) {
    /** Text drawn on top of the pulse gradient or the destructive fill. */
    val onAccent: Color get() = Color(0xFF15171A)

    /** Top-leading to bottom-trailing, like the iOS LinearGradient. */
    val pulseGradient: Brush
        get() = Brush.linearGradient(listOf(pulseStart, pulseEnd), start = Offset.Zero, end = Offset.Infinite)

    fun kind(kind: InterventionKind): Color = when (kind) {
        InterventionKind.APPROVAL -> kindApproval
        InterventionKind.USER_INPUT -> kindUserInput
        InterventionKind.IDLE -> kindIdle
        InterventionKind.RATE_LIMIT -> kindRateLimit
    }

    fun backend(backend: InterventionBackend): Color = when (backend) {
        InterventionBackend.CLAUDE -> backendClaude
        InterventionBackend.CODEX -> backendCodex
    }

    /** Brand tint for Claude and Codex, neutral for anything else. */
    fun agent(agent: AgentBackend): Color = when (agent) {
        is AgentBackend.Known -> backend(agent.backend)
        is AgentBackend.Other -> backendOther
    }

    /**
     * State dot and chip colour. Waiting states reuse the matching page
     * kind's hue, so a session and its page read as the same thing.
     */
    fun state(state: LiveSessionState): Color = when (state) {
        LiveSessionState.WAITING_ON_APPROVAL -> kindApproval
        LiveSessionState.WAITING_ON_USER -> kindUserInput
        LiveSessionState.ACTIVE -> success
        LiveSessionState.RATE_LIMITED -> kindRateLimit
        LiveSessionState.INTERRUPTED -> warning
        LiveSessionState.FAILED -> destructiveText
        LiveSessionState.IDLE, LiveSessionState.OFFLINE, LiveSessionState.UNKNOWN -> textMuted
    }

    companion object {
        val Light = PageColors(
            surface = Color(0xFFFAF8F4), surfaceRaised = Color(0xFFFFFFFF), surfaceInset = Color(0xFFF2EFE9),
            text = Color(0xFF15171A), textMuted = Color(0xFF5F6672), hairline = Color(0xFFE5E2DC),
            destructive = Color(0xFFE06464), destructiveText = Color(0xFFB42318),
            warning = Color(0xFFB45309), success = Color(0xFF047857),
            kindApproval = Color(0xFF0F766E), kindUserInput = Color(0xFF0369A1),
            kindIdle = Color(0xFFB45309), kindRateLimit = Color(0xFFB42318),
            backendClaude = Color(0xFF9A3412), backendCodex = Color(0xFF047857), backendOther = Color(0xFF475467),
            pulseStart = Color(0xFFF2C94C), pulseEnd = Color(0xFFC9E265),
            isDark = false,
        )
        val Dark = PageColors(
            surface = Color(0xFF0E1014), surfaceRaised = Color(0xFF181B22), surfaceInset = Color(0xFF12151B),
            text = Color(0xFFE8EAED), textMuted = Color(0xFF8B92A1), hairline = Color(0xFF262A31),
            destructive = Color(0xFFE06464), destructiveText = Color(0xFFF07878),
            warning = Color(0xFFFBBF24), success = Color(0xFF34D399),
            kindApproval = Color(0xFF5EEAD4), kindUserInput = Color(0xFF38BDF8),
            kindIdle = Color(0xFFFBBF24), kindRateLimit = Color(0xFFE06464),
            backendClaude = Color(0xFFE89E64), backendCodex = Color(0xFF10A37F), backendOther = Color(0xFFA3ADC2),
            pulseStart = Color(0xFF5EEAD4), pulseEnd = Color(0xFF38BDF8),
            isDark = true,
        )
    }
}

/**
 * Text styles in `sp`, so everything follows the user's font size. At the
 * default size each matches the iOS mockups' point sizes.
 */
object PageType {
    val display28 = TextStyle(fontSize = 28.sp, fontWeight = FontWeight.Bold, lineHeight = 32.sp)
    val display22 = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.SemiBold, lineHeight = 26.sp)
    val title17 = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold, lineHeight = 22.sp)
    val button17 = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold, lineHeight = 22.sp)
    val body15 = TextStyle(fontSize = 15.sp, lineHeight = 20.sp)
    val bodyEm = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold, lineHeight = 20.sp)
    val caption12 = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium, lineHeight = 16.sp)
    val chip11 = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, lineHeight = 14.sp, letterSpacing = 0.5.sp)
    val mono13 = TextStyle(fontSize = 13.sp, fontFamily = FontFamily.Monospace, lineHeight = 18.sp)
    val mono12 = TextStyle(fontSize = 12.sp, fontFamily = FontFamily.Monospace, lineHeight = 16.sp)
    val mono11 = TextStyle(fontSize = 11.sp, fontFamily = FontFamily.Monospace, lineHeight = 15.sp)
}

object Space {
    val xs = 4.dp
    val s = 8.dp
    val m = 12.dp
    val l = 16.dp
    val xl = 20.dp
    val xxl = 24.dp
}

object Radius {
    val card = 14.dp
    val button = 22.dp
    val input = 24.dp
}

/** Android's minimum touch target (iOS uses 44 pt). */
val MinTouch = 48.dp

val LocalPageColors = staticCompositionLocalOf { PageColors.Light }

/** Shorthand for the current palette. */
val colors: PageColors
    @Composable get() = LocalPageColors.current

@Composable
fun PageTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val c = if (dark) PageColors.Dark else PageColors.Light
    // Material components (dialogs, switches, menus) take Page's palette.
    val scheme = if (dark) {
        darkColorScheme(
            primary = c.kindApproval, onPrimary = c.onAccent, background = c.surface, onBackground = c.text,
            surface = c.surfaceRaised, onSurface = c.text, surfaceVariant = c.surfaceInset, onSurfaceVariant = c.textMuted,
            outline = c.hairline, outlineVariant = c.hairline, error = c.destructiveText, surfaceContainerHigh = c.surfaceRaised,
            surfaceContainer = c.surfaceRaised, surfaceContainerHighest = c.surfaceInset,
        )
    } else {
        lightColorScheme(
            primary = c.kindApproval, onPrimary = Color.White, background = c.surface, onBackground = c.text,
            surface = c.surfaceRaised, onSurface = c.text, surfaceVariant = c.surfaceInset, onSurfaceVariant = c.textMuted,
            outline = c.hairline, outlineVariant = c.hairline, error = c.destructiveText, surfaceContainerHigh = c.surfaceRaised,
            surfaceContainer = c.surfaceRaised, surfaceContainerHighest = c.surfaceInset,
        )
    }
    CompositionLocalProvider(LocalPageColors provides c) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}
