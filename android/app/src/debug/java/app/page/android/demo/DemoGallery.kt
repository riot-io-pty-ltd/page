package app.page.android.demo

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.page.android.model.CardGlow
import app.page.android.model.ChipKind
import app.page.android.model.NowInputs
import app.page.android.model.NowModel
import app.page.android.model.PulseModel
import app.page.android.model.RunwayModel
import app.page.android.model.SettledLog
import app.page.android.model.StableHash
import app.page.android.model.ProjectHue
import app.page.android.ui.nw.components.NWAnimated
import app.page.android.ui.nw.components.NWArmRing
import app.page.android.ui.nw.components.NWBackdrop
import app.page.android.ui.nw.components.NWButton
import app.page.android.ui.nw.components.NWButtonKind
import app.page.android.ui.nw.components.NWChip
import app.page.android.ui.nw.components.NWConcentricRings
import app.page.android.ui.nw.components.NWDeliveryPreview
import app.page.android.ui.nw.components.NWGlassCard
import app.page.android.ui.nw.components.NWHoldButton
import app.page.android.ui.nw.components.NWHoldRing
import app.page.android.ui.nw.components.NWMacChip
import app.page.android.ui.nw.components.NWPulseOrb
import app.page.android.ui.nw.components.NWPulseStyle
import app.page.android.ui.nw.components.NWReceiptLine
import app.page.android.ui.nw.components.NWRingsList
import app.page.android.ui.nw.components.NWRunwayBar
import app.page.android.ui.nw.components.NWSectionHeader
import app.page.android.ui.nw.components.NWSegmented
import app.page.android.ui.nw.components.NWStarGlyph
import app.page.android.ui.nw.components.NWSwitch
import app.page.android.ui.nw.components.NWTipCallout
import app.page.android.ui.nw.components.NWTonightCard
import app.page.android.ui.nw.components.NWTurnChip
import app.page.android.ui.nw.components.color
import app.page.android.ui.nw.theme.LocalCardGlow
import app.page.android.ui.nw.theme.NW
import app.page.android.model.HoldRingSpec
import app.page.android.model.MacChipModel
import app.page.android.model.TurnChip

private fun model(): NowModel = NowModel.build(
    NowInputs(
        interventions = DemoFixtures.open, sessions = DemoFixtures.sessions, hasSessionList = true, status = DemoFixtures.status,
        history = DemoFixtures.history, now = DemoFixtures.now, macName = DemoFixtures.mac, zone = DemoFixtures.zone,
    ),
)

/** Every component in one place, for a quick look at the foundation. */
@Composable
fun DemoGallery(widgetsPlaceholder: Boolean = false, lower: Boolean = false) {
    val m = model()
    var seg by remember { mutableStateOf(CardGlow.SUBTLE) }
    var on by remember { mutableStateOf(true) }
    val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    Box(Modifier.fillMaxSize()) {
        NWBackdrop()
        LazyColumn(state = androidx.compose.foundation.lazy.rememberLazyListState(if (lower) 12 else 0), contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = top + 12.dp, bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
            item { Text(if (widgetsPlaceholder) "Widgets (screens stage)" else "Components", style = NW.Typo.hero, color = NW.Palette.textPrimary.color) }
            item { Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) { listOf(ChipKind.IRREVERSIBLE, ChipKind.CONSIDERED, ChipKind.UNDOABLE).forEach { NWChip(it) } } }
            item { Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) { listOf(ChipKind.LOOKS_STUCK, ChipKind.QUESTION, ChipKind.FORECAST).forEach { NWChip(it) } } }
            item { Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { listOf(ChipKind.IRREVERSIBLE, ChipKind.CONSIDERED, ChipKind.UNDOABLE).forEach { NWChip(it, pill = true) } } }
            item { Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { listOf(ChipKind.RATE_LIMITED, ChipKind.REVIEW).forEach { NWChip(it, pill = true) } } }
            item { NWSectionHeader("Decide", NW.Palette.amber, count = 2) }
            item { NWGlassCard { NWRingsList(m.rings) } }
            item { NWTonightCard(m.rings) }
            item { NWDeliveryPreview("Will type 1 · cmux › bottle-flip · Studio MBP") }
            item { NWReceiptLine("Approved npm test → cmux › page · verified 23:47:12") }
            item { NWReceiptLine("npm test · Didn't confirm in time · Check on Mac", failed = true) }
            item { NWSegmented(CardGlow.entries.map { it to it.label }, seg, { seg = it }) }
            item { Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) { Text("Night Watch", style = NW.Typo.body, color = NW.Palette.textPrimary.color, modifier = Modifier.weight(1f)); NWSwitch(on, onChange = { on = it }) } }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    NWButton("Deny", {}, Modifier.weight(1f))
                    NWButton("Looks good", {}, Modifier.weight(1f), kind = NWButtonKind.BRIGHT)
                    NWButton("Steer", {}, Modifier.weight(1f), kind = NWButtonKind.AMBER)
                }
            }
            item { NWHoldButton({}, fixedProgress = 0.5) }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                    listOf(NWPulseStyle.Style.NEEDS_YOU, NWPulseStyle.Style.WORKING, NWPulseStyle.Style.QUIET, NWPulseStyle.Style.DUSK).forEach { NWPulseOrb(it, Modifier.size(74.dp)) }
                }
            }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                    for (i in 1..6) NWStarGlyph(StableHash.fnv1a("p$i"), ProjectHue.entries[i - 1].color, size = 40.dp)
                }
            }
            item { Row(horizontalArrangement = Arrangement.spacedBy(20.dp), verticalAlignment = Alignment.CenterVertically) { NWConcentricRings(m.rings, size = 64.dp); NWArmRing(0.42, size = 32.dp); NWHoldRing(HoldRingSpec.irreversible, {}, size = 96.dp, fixedProgress = 0.62) } }
            item { NWMacChip(MacChipModel.build(DemoFixtures.mac, DemoFixtures.status, DemoFixtures.now)) }
            item { Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { listOf(TurnChip("3 files", TurnChip.Tone.NEUTRAL), TurnChip("+120", TurnChip.Tone.ADDED), TurnChip("−14", TurnChip.Tone.REMOVED), TurnChip("tests ✓", TurnChip.Tone.PASS)).forEach { NWTurnChip(it) } } }
            item { NWTipCallout("Swipe right to approve — it can be undone") }
            item { NWGlassCard { NWRunwayBar(m.runway) } }
        }
    }
}

/** The same card with the glow Off, Subtle and Full, side by side in one frame, so the setting can be judged at a glance. */
@Composable
fun DemoGlowCompare() {
    val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    Box(Modifier.fillMaxSize()) {
        NWBackdrop()
        Column(Modifier.padding(start = 20.dp, end = 20.dp, top = top + 20.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
            for (g in CardGlow.entries) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Card glow: ${g.label}", style = NW.Typo.captionStrong, color = NW.Palette.textTertiary.color)
                    CompositionLocalProvider(LocalCardGlow provides g) {
                        NWGlassCard {
                            Text("Tonight", style = NW.Typo.title, color = NW.Palette.textPrimary.color)
                            Text("Calm ring closed ✦ Unblocked 11/12 · Shipped 7/10", style = NW.Typo.caption, color = NW.Palette.textSecondary.color)
                            Box(Modifier.size(width = 1.dp, height = 56.dp))
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun DemoRunway() {
    val m = model()
    Box(Modifier.fillMaxSize()) {
        NWBackdrop()
        Column(Modifier.padding(16.dp).align(Alignment.Center), verticalArrangement = Arrangement.spacedBy(20.dp)) {
            NWGlassCard { NWRunwayBar(m.runway) }
            NWGlassCard { NWRunwayBar(RunwayModel(emptyList(), true, null)) }
        }
    }
}

@Composable
fun DemoSettled() {
    val log = SettledLog.build(DemoFixtures.history, DemoFixtures.now, DemoFixtures.zone)
    val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    Box(Modifier.fillMaxSize()) {
        NWBackdrop()
        LazyColumn(contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = top + 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item { NWSectionHeader("Settled", NW.Palette.textTertiary) }
            for (l in log.today) item { Row(Modifier.fillMaxWidth()) { Text(l.text, style = NW.Typo.body, color = NW.Palette.textSecondary.color, modifier = Modifier.weight(1f)); Text(listOfNotNull(l.age, l.status).joinToString(" · "), style = NW.Typo.caption, color = NW.Palette.textTertiary.color) } }
            for (d in log.days) item { NWGlassCard { Text(d.headline, style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color) } }
        }
    }
}
