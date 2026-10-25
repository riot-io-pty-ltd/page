package app.page.android.ui.sessions

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.page.android.model.UsageCardModel
import app.page.android.model.UsageGauge
import app.page.android.model.UsageText
import app.page.android.ui.components.UsageRing
import app.page.android.ui.components.usage
import app.page.android.ui.theme.PageType
import app.page.android.ui.theme.Space
import app.page.android.ui.theme.colors
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * Claude subscription usage on the Sessions tab (iOS Views/UsageCard.swift):
 * the 5-hour and 7-day windows as rings, when each resets, how usage compares
 * with an even pace, and one line saying whether you'll run out. From the
 * Mac's heartbeat (`usage`), which needs usage tracking on in Page on the Mac.
 */
@Composable
fun UsageCard(model: UsageCardModel, now: Instant) {
    val shape = RoundedCornerShape(18.dp)
    val clock = remember { DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withZone(ZoneId.systemDefault()) }
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Brush.linearGradient(listOf(colors.surfaceRaised, colors.surfaceInset), start = Offset.Zero, end = Offset.Infinite))
            .border(1.dp, colors.hairline, shape)
            .padding(Space.l),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "CLAUDE USAGE", style = PageType.chip11.copy(letterSpacing = 0.8.sp), color = colors.textMuted,
                modifier = Modifier.semantics { heading() },
            )
            Spacer(Modifier.weight(1f))
            model.staleText?.let { Text(it, style = PageType.caption12, color = colors.textMuted) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Space.l), verticalAlignment = Alignment.Top) {
            model.fiveHour?.let { UsageColumn(it, now, Modifier.weight(1f)) }
            model.sevenDay?.let { UsageColumn(it, now, Modifier.weight(1f)) }
        }
        val verdict = model.verdict { clock.format(it) }
        val tint = if (verdict.warning) colors.warning else colors.success
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(tint.copy(alpha = 0.10f))
                .padding(horizontal = 10.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(if (verdict.warning) Icons.Filled.Warning else Icons.Filled.Verified, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
            Text(verdict.text, style = PageType.caption12.copy(fontWeight = FontWeight.SemiBold), color = tint, modifier = Modifier.weight(1f))
        }
    }
}

/** One window: the ring, its label, when it resets and the pace tag. Read as one line. */
@Composable
private fun UsageColumn(g: UsageGauge, now: Instant, modifier: Modifier) {
    val tone = colors.usage(g.tone)
    val spoken = UsageText.spoken(g, now)
    Column(
        modifier.clearAndSetSemantics { contentDescription = spoken },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        UsageRing(g, Modifier.size(104.dp), lineWidth = 11.dp)
        Text(g.label, style = PageType.bodyEm, color = colors.text)
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            g.resetLine(now)?.let {
                Text(
                    it, style = PageType.caption12.copy(fontWeight = FontWeight.SemiBold, fontFeatureSettings = TABULAR),
                    color = colors.text, textAlign = TextAlign.Center,
                )
            }
            g.resetsAt?.let { Text(UsageText.resetTime(it, now), style = PageType.caption12, color = colors.textMuted, textAlign = TextAlign.Center) }
            g.paceLine?.let { pace ->
                Text(
                    pace,
                    style = PageType.chip11.copy(letterSpacing = 0.4.sp),
                    color = tone,
                    modifier = Modifier
                        .padding(top = 4.dp)
                        .border(1.dp, tone.copy(alpha = 0.5f), RoundedCornerShape(50))
                        .padding(horizontal = 7.dp, vertical = 2.dp),
                )
            }
        }
    }
}

/** Tabular figures, so the countdown doesn't jitter as it ticks. */
private const val TABULAR = "tnum"
