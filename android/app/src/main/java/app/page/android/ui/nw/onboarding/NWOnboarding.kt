package app.page.android.ui.nw.onboarding

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.page.android.model.OnboardingCopy
import app.page.android.model.PairedWelcome
import app.page.android.ui.nw.components.NWAnimated
import app.page.android.ui.nw.components.NWAuroraCanvas
import app.page.android.ui.nw.components.NWBackdrop
import app.page.android.ui.nw.components.NWButton
import app.page.android.ui.nw.components.NWButtonKind
import app.page.android.ui.nw.components.NWGlassCard
import app.page.android.ui.nw.components.NWPulseOrb
import app.page.android.ui.nw.components.NWPulseStyle
import app.page.android.ui.nw.components.nwIcon
import app.page.android.ui.nw.components.pulseGlyphPath
import app.page.android.ui.nw.theme.AuroraPalette
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba
import kotlin.math.sin

// First run: Welcome, Scan, the pairing steps and Paired. Plain views over values; PairFlow (the live flow, with the
// camera, the Keystore and the relay probe) fills them in, the render harness draws them from fixtures.
// (iOS NWOnboarding.swift.)

/** A far ridge and a nearer one against the aurora, like the board's lake at night, drawn with paths so there is no bitmap to ship. */
@Composable
fun NWRidges(modifier: Modifier = Modifier) {
    Canvas(modifier.fillMaxSize().clearAndSetSemantics {}) {
        fun ridge(base: Double, amp: Double, seed: Double, alpha: Double) {
            val p = Path()
            p.moveTo(0f, size.height)
            var x = 0f
            while (x <= size.width + 4) {
                val u = (x / size.width).toDouble()
                val y = size.height * (base - amp * (0.55 * sin(u * 6.0 + seed) + 0.30 * sin(u * 13.0 + seed * 2) + 0.15 * sin(u * 29.0 + seed * 3)))
                p.lineTo(x, y.toFloat())
                x += 4
            }
            p.lineTo(size.width, size.height)
            p.close()
            drawPath(p, Brush.verticalGradient(listOf(Color(0.05f, 0.12f, 0.16f, alpha.toFloat()), NW.Palette.backgroundDeep.color), startY = (size.height * (base - amp)).toFloat(), endY = size.height))
        }
        ridge(0.62, 0.10, 1.2, 0.85)
        ridge(0.80, 0.07, 4.1, 1.0)
    }
}

/** The pulse with rings that open out, centred on the water. */
@Composable
fun NWWelcomePulse(modifier: Modifier = Modifier) {
    NWAnimated { t ->
        Canvas(modifier.size(300.dp).clearAndSetSemantics {}) {
            val c = Offset(size.width / 2, size.height / 2)
            for (i in 0..2) {
                val p = (((t / 5) + i / 3.0) % 1.0).toFloat()
                drawCircle(NW.Palette.teal.opacity(0.34 * (1 - p)).color, (70.dp.toPx() + 220.dp.toPx() * p) / 2, c, style = Stroke(1.4.dp.toPx()))
            }
            drawCircle(Brush.radialGradient(listOf(NW.Palette.teal.opacity(0.45).color, Color.Transparent), center = c, radius = 80.dp.toPx()), 80.dp.toPx(), c)
            val s = 44.dp.toPx()
            val glyph = pulseGlyphPath(Offset(c.x - s / 2, c.y - s / 2), s, s)
            drawPath(glyph, Brush.radialGradient(listOf(Color.White, NW.Palette.teal.opacity(0.9).color), center = c, radius = 24.dp.toPx()))
            drawPath(glyph, NW.Palette.teal.color, style = Stroke(2.dp.toPx(), join = StrokeJoin.Round))
        }
    }
}

/** Teal curtains over a deep night sky, as the welcome board has them. */
val welcomePalette = AuroraPalette(Rgba.hex(0x3FBFB6), Rgba.hex(0x38BDF8), Rgba.hex(0x4B7BD0), Rgba.hex(0x0B2A33), NW.Palette.backgroundDeep, 0.85, 0.5)

/** Bright cyan curtains, once, to say it worked. */
val pairedPalette = AuroraPalette(Rgba.hex(0x4FF3E6), Rgba.hex(0x38BDF8), Rgba.hex(0x6D8BF0), Rgba.hex(0x0C3A44), NW.Palette.backgroundDeep, 1.3, 0.6)

/** Fades what is drawn to nothing from [stop1] to [stop2] of the height (so the curtains never reach the words). */
private fun Modifier.fadeDown(stop1: Float, stop2: Float): Modifier = this
    .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
    .drawWithContent {
        drawContent()
        drawRect(Brush.verticalGradient(0f to Color.White, stop1 to Color.White, stop2 to Color.Transparent), blendMode = BlendMode.DstIn)
    }

// MARK: - Welcome

@Composable
fun NWWelcomeScreen(
    modifier: Modifier = Modifier,
    /** A notice that comes first ("Pair again": the old token was retired). */
    notice: Pair<String, String>? = null,
    onPair: () -> Unit = {},
    onDismissNotice: () -> Unit = {},
    /** Debug builds only: skip pairing with mock data. */
    onTryDemo: (() -> Unit)? = null,
) {
    Box(modifier.fillMaxSize().background(NW.Palette.backgroundDeep.color)) {
        NWBackdrop()
        // The curtains fade out before the words begin, so the headline always sits on dark sky.
        NWAnimated { t -> NWAuroraCanvas(welcomePalette, t, Modifier.fillMaxSize().fadeDown(0.38f, 0.62f)) }
        NWRidges(Modifier.fillMaxSize().graphicsLayer { alpha = 0.95f })
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().verticalScroll(rememberScrollState())) {
            Spacer(Modifier.weight(1f))
            Box(Modifier.fillMaxWidth().offset(y = (-30).dp), contentAlignment = Alignment.Center) { NWWelcomePulse() }
            Spacer(Modifier.weight(1f))
            Column(Modifier.padding(horizontal = 28.dp).padding(bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(OnboardingCopy.eyebrow, style = NW.Typo.bodyStrong.copy(letterSpacing = 4.sp), color = NW.Palette.teal.color)
                Text(OnboardingCopy.welcomeTitle, style = NW.Typo.hero.copy(fontSize = 40.sp, lineHeight = 42.sp, letterSpacing = (-1.2).sp), color = NW.Palette.textPrimary.color, modifier = Modifier.semantics { heading() })
                Text(OnboardingCopy.welcomeBody, style = NW.Typo.subline, color = NW.Palette.textSecondary.color)
                notice?.let { n ->
                    NWGlassCard(radius = 18.dp, padding = PaddingValues(14.dp), tint = NW.Palette.amber) {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                                Icon(nwIcon("key.slash"), null, tint = NW.Palette.amber.color, modifier = Modifier.size(18.dp))
                                Text(n.first, style = NW.Typo.bodyStrong, color = NW.Palette.amber.color)
                            }
                            Text(n.second, style = NW.Typo.caption, color = NW.Palette.textSecondary.color)
                            Text("Dismiss", style = NW.Typo.captionStrong, color = NW.Palette.textPrimary.color, modifier = Modifier.heightIn(min = 48.dp).clickable(onClick = onDismissNotice).padding(vertical = 14.dp))
                        }
                    }
                }
                NWButton(OnboardingCopy.pairButton, onPair, Modifier.fillMaxWidth().heightIn(min = 60.dp).padding(top = 8.dp), kind = NWButtonKind.BRIGHT, leading = Icons.Outlined.QrCodeScanner)
                if (onTryDemo != null) Text("Try the demo (debug build)", style = NW.Typo.caption, color = NW.Palette.textQuiet.color, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(onClick = onTryDemo).padding(vertical = 14.dp))
            }
        }
    }
}

// MARK: - Scan

@Composable
private fun ScanCorners(modifier: Modifier, color: Color) {
    Canvas(modifier) {
        val l = 34.dp.toPx()
        val c = 12.dp.toPx()
        val w = size.width
        val h = size.height
        val sw = Stroke(5.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round)
        fun corner(x: Float, y: Float, dx: Float, dy: Float) {
            val p = Path()
            p.moveTo(x + dx * l, y)
            p.lineTo(x + dx * c, y)
            p.quadraticTo(x, y, x, y + dy * c)
            p.lineTo(x, y + dy * l)
            drawPath(p, color, style = sw)
        }
        corner(0f, 0f, 1f, 1f); corner(w, 0f, -1f, 1f); corner(0f, h, 1f, -1f); corner(w, h, -1f, -1f)
    }
}

/** The scanner: a viewfinder window (the camera sits in it on a device), the four teal corners and a scan line, then what the code holds. */
@Composable
fun NWScanScreen(modifier: Modifier = Modifier, hint: String? = null, onPaste: () -> Unit = {}, onCancel: () -> Unit = {}, camera: @Composable BoxScope.() -> Unit) {
    Box(modifier.fillMaxSize().background(NW.Palette.backgroundDeep.color)) {
        NWBackdrop()
        Box(Modifier.fillMaxSize().background(Brush.radialGradient(listOf(NW.Palette.teal.opacity(0.06).color, Color.Transparent), radius = 900f)))
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(top = 14.dp), horizontalArrangement = Arrangement.End) {
                Text(
                    "Cancel", style = NW.Typo.bodyStrong, color = NW.Palette.textSecondary.color,
                    modifier = Modifier.heightIn(min = 48.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.08f)).clickable(onClick = onCancel).padding(horizontal = 18.dp).padding(vertical = 12.dp),
                )
            }
            Text(OnboardingCopy.scanTitle, style = NW.Typo.hero.copy(fontSize = 28.sp, letterSpacing = (-0.8).sp), color = NW.Palette.textPrimary.color, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 30.dp).padding(horizontal = 24.dp).semantics { heading() })
            Text(OnboardingCopy.scanHint, style = NW.Typo.subline, color = NW.Palette.textTertiary.color, modifier = Modifier.padding(top = 6.dp))
            Spacer(Modifier.height(20.dp))
            val side = 270.dp
            Box(Modifier.size(side).semantics(mergeDescendants = true) { contentDescription = "Camera view. Point it at the QR code in Page on your Mac." }, contentAlignment = Alignment.Center) {
                Box(Modifier.size(side - 36.dp).clip(RoundedCornerShape(22.dp)), content = camera)
                ScanCorners(Modifier.size(side), NW.Palette.teal.color)
                NWAnimated { t ->
                    val p = (0.5 + 0.5 * sin(t * 1.6)).toFloat()
                    Box(
                        Modifier.width(side - 40.dp).height(3.dp).offset(y = ((p - 0.5f) * (side.value - 60f)).dp).clip(CircleShape)
                            .background(Brush.horizontalGradient(listOf(Color.Transparent, NW.Palette.teal.color, Color.Transparent))),
                    )
                }
            }
            hint?.let { Text(it, style = NW.Typo.bodyStrong, color = NW.Palette.amber.color, textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 28.dp).padding(top = 16.dp).semantics { liveRegion = LiveRegionMode.Polite }) }
            Spacer(Modifier.height(20.dp))
            NWGlassCard(Modifier.padding(horizontal = 24.dp), radius = 24.dp, padding = PaddingValues(18.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(14.dp), modifier = Modifier.semantics(mergeDescendants = true) {}) {
                    for (f in OnboardingCopy.scanFacts) Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.Top) {
                        Icon(nwIcon(f.symbol), null, tint = NW.Palette.teal.color, modifier = Modifier.size(22.dp))
                        Text(f.text, style = NW.Typo.body, color = NW.Palette.textSecondary.color)
                    }
                }
            }
            NWButton(OnboardingCopy.pasteInstead, onPaste, Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 16.dp, bottom = 24.dp), leading = Icons.Outlined.ContentPaste)
        }
    }
}

// MARK: - Pairing steps

/** What the pairing flow shows between the scan and Paired: checking the relay, confirming the Mac, or a problem with its one fix. */
sealed interface PairStepContent {
    data class Checking(val host: String) : PairStepContent
    data class Confirm(val mac: String, val host: String, val online: Boolean?, val unused: Boolean) : PairStepContent
    data class Problem(val title: String, val message: String) : PairStepContent
}

@Composable
fun NWPairStep(
    content: PairStepContent, modifier: Modifier = Modifier, onPrimary: (() -> Unit)? = null, primaryTitle: String = "", onSecondary: () -> Unit = {}, secondaryTitle: String = "Start over",
) {
    Box(modifier.fillMaxSize().background(NW.Palette.backgroundDeep.color)) {
        NWBackdrop()
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(bottom = 30.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(22.dp)) {
            Box(Modifier.padding(top = 34.dp).size(150.dp).clearAndSetSemantics {}) {
                NWPulseOrb(when (content) { is PairStepContent.Checking -> NWPulseStyle.Style.WORKING; is PairStepContent.Confirm -> NWPulseStyle.Style.QUIET; is PairStepContent.Problem -> NWPulseStyle.Style.NEEDS_YOU }, Modifier.size(150.dp))
            }
            when (content) {
                is PairStepContent.Checking -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) {
                    CircularProgressIndicator(color = NW.Palette.textSecondary.color, strokeWidth = 2.dp)
                    Text("Checking ${content.host}…", style = NW.Typo.body, color = NW.Palette.textSecondary.color)
                }
                is PairStepContent.Confirm -> ConfirmCard(content)
                is PairStepContent.Problem -> NWGlassCard(radius = 22.dp, padding = PaddingValues(18.dp), tint = NW.Palette.amber) {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Outlined.WarningAmber, null, tint = NW.Palette.amber.color, modifier = Modifier.size(22.dp))
                            Text(content.title, style = NW.Typo.title, color = NW.Palette.amber.color)
                        }
                        Text(content.message, style = NW.Typo.body, color = NW.Palette.textSecondary.color)
                    }
                }
            }
            if (onPrimary != null) NWButton(primaryTitle, onPrimary, Modifier.fillMaxWidth(), kind = NWButtonKind.BRIGHT)
            NWButton(secondaryTitle, onSecondary, Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun ConfirmCard(c: PairStepContent.Confirm) {
    NWGlassCard(radius = 26.dp, padding = PaddingValues(20.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Pair with ${c.mac}?", style = NW.Typo.hero.copy(fontSize = 26.sp, letterSpacing = (-0.6).sp), color = NW.Palette.textPrimary.color)
            Text("Relay: ${c.host}", style = NW.Typo.monoSmall, color = NW.Palette.textTertiary.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
            when {
                c.online == true -> Line(nwIcon("checkmark.circle"), "Your Mac is connected to this relay.", NW.Palette.teal)
                c.online == false && c.unused -> Line(Icons.Outlined.WarningAmber, "No Mac has connected to this relay with this code yet. If it's an old screenshot, or you regenerated the token on your Mac, show the pairing code on your Mac again and scan the new one.", NW.Palette.amber)
                c.online == false -> Line(Icons.Outlined.ErrorOutline, "Your Mac isn't connected to this relay right now. That's fine — pages will arrive once it is.", NW.Palette.amber)
            }
            Text(OnboardingCopy.confirmWarning, style = NW.Typo.caption, color = NW.Palette.textTertiary.color)
        }
    }
}

@Composable
private fun Line(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String, c: Rgba) {
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top) {
        Icon(icon, null, tint = c.color, modifier = Modifier.size(18.dp))
        Text(text, style = NW.Typo.caption, color = c.color)
    }
}

// MARK: - Paired

/** Paired: the first star, what Page will and won't page you for, and the one place notifications are asked for. */
@Composable
fun NWPairedScreen(model: PairedWelcome, modifier: Modifier = Modifier, onAction: () -> Unit = {}, onSkip: () -> Unit = {}) {
    Box(modifier.fillMaxSize().background(NW.Palette.backgroundDeep.color)) {
        NWBackdrop()
        NWAnimated { t -> NWAuroraCanvas(pairedPalette, t, Modifier.fillMaxSize().fadeDown(0.30f, 0.58f)) }
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally) {
            Spacer(Modifier.weight(1f))
            Box(Modifier.padding(bottom = 24.dp).clearAndSetSemantics {}, contentAlignment = Alignment.Center) {
                NWAnimated { t ->
                    Canvas(Modifier.size(240.dp)) {
                        val c = Offset(size.width / 2, size.height / 2)
                        for (i in 0..1) {
                            val p = (((t / 4) + i / 2.0) % 1.0).toFloat()
                            drawCircle(NW.Palette.teal.opacity(0.4 * (1 - p)).color, (120.dp.toPx() + 120.dp.toPx() * p) / 2, c, style = Stroke(1.5.dp.toPx()))
                        }
                        drawCircle(NW.Palette.teal.opacity(0.18).color, 66.dp.toPx(), c)
                        drawCircle(Brush.radialGradient(listOf(NW.Palette.sky.color, NW.Palette.teal.color), center = Offset(c.x - 30.dp.toPx(), c.y - 30.dp.toPx()), radius = 90.dp.toPx()), 60.dp.toPx(), c)
                    }
                }
                Icon(Icons.Outlined.Check, null, tint = NW.Palette.onBright.color, modifier = Modifier.size(52.dp))
            }
            Text(model.title, style = NW.Typo.hero.copy(fontSize = 34.sp, letterSpacing = (-1.2).sp), color = NW.Palette.textPrimary.color, textAlign = TextAlign.Center, maxLines = 2, modifier = Modifier.padding(horizontal = 24.dp).semantics { heading() })
            Text(model.subtitle, style = NW.Typo.subline, color = NW.Palette.textSecondary.color, textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 36.dp).padding(top = 12.dp))
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.height(24.dp))
            NWGlassCard(Modifier.padding(horizontal = 24.dp), radius = 26.dp, padding = PaddingValues(20.dp)) {
                Column(verticalArrangement = Arrangement.spacedBy(14.dp), modifier = Modifier.semantics(mergeDescendants = true) {}) {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(nwIcon("bell.badge"), null, tint = NW.Palette.yellow.color, modifier = Modifier.size(22.dp))
                        Text(model.promiseTitle, style = NW.Typo.title, color = NW.Palette.textPrimary.color)
                    }
                    for (p in model.promises) Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
                        Icon(Icons.Outlined.Check, null, tint = NW.Palette.green.color, modifier = Modifier.size(18.dp))
                        Text(p, style = NW.Typo.body, color = NW.Palette.textSecondary.color)
                    }
                }
            }
            NWButton(model.action.title, onAction, Modifier.fillMaxWidth().heightIn(min = 60.dp).padding(horizontal = 24.dp).padding(top = 16.dp), kind = NWButtonKind.AMBER)
            model.skipTitle?.let { Text(it, style = NW.Typo.bodyStrong, color = NW.Palette.textTertiary.color, modifier = Modifier.heightIn(min = 48.dp).clickable(onClick = onSkip).padding(vertical = 14.dp, horizontal = 20.dp)) }
            Spacer(Modifier.height(14.dp))
        }
    }
}
