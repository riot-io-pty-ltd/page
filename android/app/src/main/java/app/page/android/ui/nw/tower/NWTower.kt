package app.page.android.ui.nw.tower

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.page.android.model.CardGlow
import app.page.android.model.DeliveryPreview
import app.page.android.model.GestureEntry
import app.page.android.model.GestureGuide
import app.page.android.model.NotificationsState
import app.page.android.model.NowFormat
import app.page.android.model.TowerBudget
import app.page.android.model.TowerHosts
import app.page.android.model.TowerMacRow
import app.page.android.model.TowerPower
import app.page.android.model.TowerSection
import app.page.android.model.UsageGauge
import app.page.android.ui.nw.components.NWGlassCard
import app.page.android.ui.nw.components.NWRing
import app.page.android.ui.nw.components.NWSegmented
import app.page.android.ui.nw.components.NWSwitch
import app.page.android.ui.nw.components.nwIcon
import app.page.android.ui.nw.theme.LocalCardGlow
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba
import androidx.compose.runtime.CompositionLocalProvider
import java.time.Instant
import java.time.ZoneId

/** Everything the Tower draws, as values. */
data class TowerScreenData(
    val macName: String,
    val power: TowerPower,
    val budget: TowerBudget,
    val macs: List<TowerMacRow>,
    /** "online · 3 active sessions · Battery 54%, on power". */
    val macLine: String?,
    val relayHost: String?,
    val relayText: String,
    val notifications: NotificationsState,
    /** Stay connected (the foreground service that keeps the relay socket open for instant pages). */
    val stayConnected: Boolean,
    /** "3 live sessions · end-to-end encrypted". */
    val liveSessionsText: String,
    val glow: CardGlow,
    val version: String,
    val now: Instant,
    val zone: ZoneId = ZoneId.systemDefault(),
    /** Open the Tower scrolled to a section (the Runway opens Budget). */
    val scrollTo: TowerSection? = null,
    val feedbackUrl: String? = null,
    /** A demo pairing says "Leave the demo". */
    val isDemo: Boolean = false,
)

class TowerScreenActions(
    val close: () -> Unit = {},
    val unpair: () -> Unit = {},
    val openNotificationSettings: () -> Unit = {},
    val turnOnNotifications: () -> Unit = {},
    val setStayConnected: (Boolean) -> Unit = {},
    val setGlow: (CardGlow) -> Unit = {},
    val openHistory: () -> Unit = {},
    /** "Show the tips again": every first-time tip comes back. */
    val resetTips: () -> Unit = {},
    val openFeedback: () -> Unit = {},
)

/**
 * The Tower: power, budget, Macs, attention, pairing, appearance and about. It drops from the Mac chip and holds
 * every setting Page has next to the thing it controls. The phone reads the Mac's power and usage but cannot
 * change them (those are set in Page on the Mac), so those rows say where to change them instead of drawing a
 * switch that does nothing. (iOS NWTowerScreen.)
 */
@Composable
fun NWTowerScreen(data: TowerScreenData, actions: TowerScreenActions, modifier: Modifier = Modifier) {
    val scroll = rememberScrollState()
    var offsets by remember { mutableStateOf(mapOf<TowerSection, Int>()) }
    LaunchedEffect(data.scrollTo, offsets.size) {
        val s = data.scrollTo ?: return@LaunchedEffect
        offsets[s]?.let { scroll.scrollTo(maxOf(0, it - 24)) }
    }
    Column(modifier.fillMaxSize().verticalScroll(scroll).padding(horizontal = NW.Space.gutter).padding(top = 18.dp, bottom = 40.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(26.dp)) {
        Header(data, actions)
        Section(TowerSection.POWER, { offsets = offsets + (TowerSection.POWER to it) }) { Power(data) }
        Section(TowerSection.BUDGET, { offsets = offsets + (TowerSection.BUDGET to it) }) { Budget(data, actions) }
        Section(TowerSection.MACS, { offsets = offsets + (TowerSection.MACS to it) }) { Macs(data) }
        Section(TowerSection.ATTENTION, { offsets = offsets + (TowerSection.ATTENTION to it) }) { Attention(data, actions) }
        Section(TowerSection.GESTURES, { offsets = offsets + (TowerSection.GESTURES to it) }) { Gestures(actions) }
        Section(TowerSection.TERMINALS, { offsets = offsets + (TowerSection.TERMINALS to it) }) { Terminals() }
        Section(TowerSection.PAIRING, { offsets = offsets + (TowerSection.PAIRING to it) }) { Pairing(data, actions) }
        Section(TowerSection.APPEARANCE, { offsets = offsets + (TowerSection.APPEARANCE to it) }) { Appearance(data, actions) }
        Section(TowerSection.ABOUT, { offsets = offsets + (TowerSection.ABOUT to it) }) { About(data, actions) }
    }
}

@Composable
private fun Header(data: TowerScreenData, actions: TowerScreenActions) {
    Row(Modifier.fillMaxWidth().padding(top = 14.dp), verticalAlignment = Alignment.Top) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("THE TOWER", style = NW.Typo.labelLarge.copy(letterSpacing = 2.sp), color = NW.Palette.teal.color)
            Text(DeliveryPreview.macLabel(data.macName), style = NW.Typo.hero.copy(fontSize = 34.sp, letterSpacing = (-0.8).sp), color = NW.Palette.textPrimary.color, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.semantics { heading() })
            data.macLine?.let { Text(it, style = NW.Typo.caption, color = NW.Palette.textTertiary.color) }
        }
        Box(Modifier.size(48.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.08f)).clickable(role = Role.Button, onClickLabel = "Close", onClick = actions.close), contentAlignment = Alignment.Center) {
            Icon(Icons.Outlined.Close, "Close", tint = NW.Palette.textPrimary.color, modifier = Modifier.size(20.dp))
        }
    }
}

@Composable
private fun Section(s: TowerSection, onOffset: (Int) -> Unit, content: @Composable () -> Unit) {
    Column(Modifier.onGloballyPositioned { onOffset(it.positionInParent().y.toInt()) }, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(s.title.uppercase(), style = NW.Typo.labelLarge.copy(letterSpacing = 1.4.sp), color = NW.Palette.textTertiary.color, modifier = Modifier.semantics { heading() })
        content()
    }
}

@Composable
private fun Card(content: @Composable () -> Unit) {
    NWGlassCard(padding = PaddingValues(0.dp)) { content() }
}

@Composable
private fun Divider() { Box(Modifier.fillMaxWidth().padding(start = 70.dp).height(1.dp).background(Color.White.copy(alpha = 0.07f))) }

// MARK: Power

@Composable
private fun Power(data: TowerScreenData) {
    Card {
        Column(Modifier.fillMaxWidth().padding(16.dp).semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                Text(data.power.headline, style = NW.Typo.title, color = NW.Palette.textPrimary.color, modifier = Modifier.weight(1f))
                Text(data.power.state, style = NW.Typo.captionStrong, color = (if (data.power.warn) NW.Palette.amber else NW.Palette.textSecondary).color, modifier = Modifier.padding(start = 8.dp))
            }
            data.power.fraction?.let { f ->
                Box(Modifier.fillMaxWidth().height(10.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.08f))) {
                    Box(Modifier.fillMaxWidth(f.toFloat().coerceIn(0.03f, 1f)).height(10.dp).clip(CircleShape).background(Brush.horizontalGradient(listOf(NW.Palette.amber.color, NW.Palette.green.color))))
                    data.power.cutoffFraction?.let { c -> Box(Modifier.fillMaxWidth(c.toFloat().coerceIn(0f, 1f)).height(18.dp), contentAlignment = Alignment.CenterEnd) { Box(Modifier.width(3.dp).height(18.dp).clip(RoundedCornerShape(1.5.dp)).background(NW.Palette.red.color)) } }
                }
            }
            Text(data.power.note, style = NW.Typo.caption, color = NW.Palette.textTertiary.color)
        }
    }
}

// MARK: Budget

@Composable
private fun Budget(data: TowerScreenData, actions: TowerScreenActions) {
    Card {
        val m = data.budget.model
        if (m != null) {
            Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    m.fiveHour?.let { Gauge(it, data, Modifier.weight(1f)) }
                    m.sevenDay?.let { Gauge(it, data, Modifier.weight(1f)) }
                }
                val verdict = m.verdict { NowFormat.clock(it, zone = data.zone) }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
                    Icon(nwIcon(if (verdict.warning) "exclamationmark.triangle" else "checkmark.seal"), null, tint = (if (verdict.warning) NW.Palette.amber else NW.Palette.teal).color, modifier = Modifier.size(16.dp))
                    Text(
                        verdict.text + (m.staleMinutes?.let { "  as of ${if (it < 60) "${it}m" else "${it / 60}h"} ago" } ?: ""), style = NW.Typo.caption,
                        color = (if (verdict.warning) NW.Palette.amber else NW.Palette.teal).color,
                    )
                }
            }
        } else {
            Text(data.budget.emptyNote, style = NW.Typo.caption, color = NW.Palette.textSecondary.color, modifier = Modifier.padding(16.dp))
        }
        Divider()
        TRow("clock.arrow.circlepath", NW.Palette.sky, "History and stats", "everything you've settled, and the day's numbers", chevron = true, onClick = actions.openHistory)
    }
}

@Composable
private fun Gauge(g: UsageGauge, data: TowerScreenData, modifier: Modifier) {
    val tone: Rgba = if (g.tone == UsageGauge.Tone.CALM) NW.Palette.teal else NW.Palette.amber
    Row(modifier.semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(contentAlignment = Alignment.Center) {
            NWRing(g.fraction, tone, lineWidth = 7.dp, size = 64.dp)
            Text("${Math.round(g.pct).toInt()}", style = NW.Typo.title.copy(fontWeight = FontWeight.Bold), color = NW.Palette.textPrimary.color)
        }
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(g.label, style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color)
            g.resetsAt?.let { Text("resets ${NowFormat.clock(it, zone = data.zone)}", style = NW.Typo.caption, color = NW.Palette.textTertiary.color) }
            g.paceLine?.let { Text(it, style = NW.Typo.monoMicro, color = tone.color) }
        }
    }
}

// MARK: Macs

@Composable
private fun Macs(data: TowerScreenData) {
    Card {
        data.macs.forEachIndexed { i, m ->
            if (i > 0) Divider()
            Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp).semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
                IconTile("display", NW.Palette.green)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(m.name, style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color)
                    Text(m.subtitle, style = NW.Typo.caption, color = NW.Palette.textTertiary.color, maxLines = 2)
                }
                Text(m.trailing, style = NW.Typo.bodyStrong, color = NW.Palette.textSecondary.color)
            }
        }
    }
}

// MARK: Attention

@Composable
private fun Attention(data: TowerScreenData, actions: TowerScreenActions) {
    Card {
        TRow(
            "bell.badge", NW.Palette.violet, "Notifications", data.notifications.text,
            trailing = if (data.notifications == NotificationsState.OFF) "Open Settings" else if (data.notifications == NotificationsState.NOT_SET) "Turn on" else null,
            onClick = if (data.notifications == NotificationsState.OFF) actions.openNotificationSettings else if (data.notifications == NotificationsState.NOT_SET) actions.turnOnNotifications else null,
        )
        Divider()
        // Android has no push provider: pages arrive over the relay connection, kept open by this service.
        Row(
            Modifier.fillMaxWidth().heightIn(min = 64.dp)
                .clickable(role = Role.Switch, onClickLabel = if (data.stayConnected) "Turn off Stay connected" else "Turn on Stay connected") { actions.setStayConnected(!data.stayConnected) }
                .padding(horizontal = 14.dp, vertical = 10.dp).semantics(mergeDescendants = true) { stateDescription = if (data.stayConnected) "on" else "off" },
            horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically,
        ) {
            IconTile("antenna.radiowaves.left.and.right", NW.Palette.sky)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("Stay connected", style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color)
                Text(
                    if (data.stayConnected) "Page keeps its connection open in the background and pages you instantly. Shows an ongoing notification; uses a little battery."
                    else "Off: pages are checked every 15 minutes while the app is closed. Turn on to be paged the moment an agent needs you.",
                    style = NW.Typo.caption, color = NW.Palette.textTertiary.color,
                )
            }
            NWSwitch(data.stayConnected)
        }
        Divider()
        TRow("sparkle", NW.Palette.teal, "Live sessions", data.liveSessionsText)
        Divider()
        TRow("moon", NW.Palette.textTertiary, "Quiet hours and when to page", "set in Page on your Mac, where they apply")
    }
}

// MARK: Gestures & shortcuts

@Composable
private fun Gestures(actions: TowerScreenActions) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Card {
            GestureGuide.entries.forEachIndexed { i, e ->
                if (i > 0) Divider()
                RowBody(e.symbol, NW.Palette.teal, "${e.gesture} ${e.context}", e.effect)
            }
        }
        Text(
            "Everything here can also be done without the gesture: TalkBack offers each one as an action on the row.",
            style = NW.Typo.caption, color = NW.Palette.textTertiary.color, modifier = Modifier.padding(horizontal = 4.dp),
        )
        if (GestureGuide.shortcuts.isNotEmpty()) Card {
            GestureGuide.shortcuts.forEachIndexed { i, e ->
                if (i > 0) Divider()
                RowBody(e.symbol, NW.Palette.teal, e.gesture, "${e.context} · ${e.effect}")
            }
        }
        Text(
            GestureGuide.showAgainLabel, style = NW.Typo.captionStrong, color = NW.Palette.teal.color,
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.06f)).clickable(role = Role.Button, onClick = actions.resetTips).padding(vertical = 14.dp),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
    }
}

// MARK: Works with

@Composable
private fun Terminals() {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Card {
            TowerHosts.hosts.forEachIndexed { i, h ->
                if (i > 0) Divider()
                RowBody(h.symbol, NW.Palette.teal, h.name, h.line)
            }
        }
        Text(TowerHosts.setUpLine, style = NW.Typo.caption, color = NW.Palette.textSecondary.color, modifier = Modifier.padding(horizontal = 4.dp))
        Text(TowerHosts.othersLine, style = NW.Typo.caption, color = NW.Palette.textTertiary.color, modifier = Modifier.padding(horizontal = 4.dp))
    }
}

// MARK: Pairing

@Composable
private fun Pairing(data: TowerScreenData, actions: TowerScreenActions) {
    Card {
        TRow("key", NW.Palette.textSecondary, "End-to-end encrypted", "session key from the pairing QR")
        Divider()
        TRow("arrow.triangle.2.circlepath", NW.Palette.sky, "Relay", listOfNotNull(data.relayText, data.relayHost).joinToString(" · "))
        Divider()
        TRow(
            "xmark.circle", NW.Palette.amber, if (data.isDemo) "Leave the demo" else "Unpair ${DeliveryPreview.macLabel(data.macName)}",
            if (data.isDemo) "goes back to the pairing screen" else "this phone stops receiving pages until you scan a pairing code again", chevron = true, onClick = actions.unpair,
        )
    }
}

// MARK: Appearance

@Composable
private fun Appearance(data: TowerScreenData, actions: TowerScreenActions) {
    Card {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Card glow", style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color)
            NWSegmented(CardGlow.entries.map { it to it.label }, data.glow, actions.setGlow)
            Text("A soft light along the bottom edge of cards. It follows the card's shape and fades inside it. Off by default.", style = NW.Typo.caption, color = NW.Palette.textTertiary.color)
            // A live sample, so the choice can be judged right here.
            CompositionLocalProvider(LocalCardGlow provides data.glow) {
                NWGlassCard(Modifier.heightIn(min = 84.dp).semantics { contentDescription = "" }) { Text("Sample card", style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color, modifier = Modifier.heightIn(min = 52.dp)) }
            }
        }
    }
}

// MARK: About

@Composable
private fun About(data: TowerScreenData, actions: TowerScreenActions) {
    Card {
        TRow("info.circle", NW.Palette.textSecondary, "Version", data.version)
        if (data.feedbackUrl != null) {
            Divider()
            TRow("bubble.left.and.bubble.right", NW.Palette.teal, "Help & feedback", "opens the Page issue tracker on GitHub", chevron = true, onClick = actions.openFeedback)
        }
    }
}

// MARK: Rows

@Composable
private fun IconTile(icon: String, tint: Rgba) {
    Box(Modifier.size(44.dp).clip(RoundedCornerShape(12.dp)).background(tint.opacity(0.14).color), contentAlignment = Alignment.Center) {
        Icon(nwIcon(icon), null, tint = tint.color, modifier = Modifier.size(22.dp))
    }
}

@Composable
private fun RowBody(icon: String, tint: Rgba, title: String, detail: String?, trailing: String? = null, chevron: Boolean = false) {
    Row(Modifier.fillMaxWidth().heightIn(min = 64.dp).padding(horizontal = 14.dp, vertical = 10.dp).semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
        IconTile(icon, tint)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color)
            detail?.let { Text(it, style = NW.Typo.caption, color = NW.Palette.textTertiary.color) }
        }
        trailing?.let { Text(it, style = NW.Typo.captionStrong, color = NW.Palette.teal.color) }
        if (chevron) Icon(Icons.Outlined.ChevronRight, null, tint = NW.Palette.textQuiet.color, modifier = Modifier.size(16.dp))
    }
}

@Composable
private fun TRow(icon: String, tint: Rgba, title: String, detail: String?, trailing: String? = null, chevron: Boolean = false, onClick: (() -> Unit)? = null) {
    if (onClick != null) Box(Modifier.clickable(role = Role.Button, onClick = onClick)) { RowBody(icon, tint, title, detail, trailing, chevron) }
    else RowBody(icon, tint, title, detail, trailing, chevron)
}
