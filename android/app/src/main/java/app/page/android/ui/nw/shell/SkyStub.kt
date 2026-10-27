package app.page.android.ui.nw.shell

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.AppRouter
import app.page.android.data.NowStore
import app.page.android.model.NWDestination
import app.page.android.model.SkyMode
import app.page.android.model.StarState
import app.page.android.ui.nw.components.NWAuroraCanvas
import app.page.android.ui.nw.components.NWAnimated
import app.page.android.ui.nw.components.NWGlassCard
import app.page.android.ui.nw.components.NWSegmented
import app.page.android.ui.nw.components.NWStarGlyph
import app.page.android.ui.nw.components.NWTonightCard
import app.page.android.ui.nw.components.color
import app.page.android.ui.nw.theme.AuroraPalette
import app.page.android.ui.nw.theme.NW

/**
 * Sky, for the foundation stage: the fleet from [app.page.android.model.SkyModel] as one glass card per project
 * (its stars, what they are doing), the moon's line, the day's rings, and the Sky / Lanes switch (remembered).
 * The screens stage draws the constellations (star layout, label layout, hit targets) and Lanes; this keeps the
 * sessions reachable meanwhile.
 */
@Composable
fun SkyStub(modifier: Modifier = Modifier) {
    val screen by NowStore.screen.collectAsStateWithLifecycle()
    val router by AppRouter.state.collectAsStateWithLifecycle()
    val sky = screen.sky
    val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    Box(modifier.fillMaxSize()) {
        NWAnimated(active = true) { t -> NWAuroraCanvas(AuroraPalette.working, t, Modifier.fillMaxWidth().padding(bottom = 0.dp).defaultMinSize(minHeight = 330.dp)) }
        LazyColumn(contentPadding = PaddingValues(top = top + 12.dp, bottom = 132.dp, start = NW.Space.gutter, end = NW.Space.gutter), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            item {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Sky", style = NW.Typo.hero.copy(fontSize = 40.sp), color = NW.Palette.textPrimary.color, modifier = Modifier.weight(1f))
                    Box(Modifier.width(190.dp)) {
                        NWSegmented(SkyMode.entries.map { it to it.label }, router.skyMode, AppRouter::selectSkyMode)
                    }
                }
            }
            item { Text("${sky.headline} · ${sky.moon.percent} ${sky.moon.detail}", style = NW.Typo.subline, color = NW.Palette.textSecondary.color) }
            if (sky.isEmpty) item { Text("No live sessions yet. Start an agent on your Mac and it appears here.", style = NW.Typo.body, color = NW.Palette.textTertiary.color) }
            for (c in sky.constellations) {
                item(key = c.key) {
                    NWGlassCard {
                        Text(c.name.uppercase(), style = NW.Typo.label, color = c.hue.color.color)
                        for (s in c.stars) {
                            Row(
                                Modifier.fillMaxWidth().defaultMinSize(minHeight = 52.dp)
                                    .clickable(role = Role.Button, onClickLabel = if (s.interventionId != null) "Open its decision" else "Open the session") {
                                        if (s.interventionId != null) AppRouter.open(s.interventionId, switchTab = false) else AppRouter.openSession(s.id)
                                    }.padding(top = 8.dp),
                                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
                            ) {
                                NWStarGlyph(s.seed, s.state.color, size = 30.dp, brightness = s.brightness)
                                Column(Modifier.weight(1f)) {
                                    Text(s.title, style = NW.Typo.mono, color = NW.Palette.textPrimary.color, maxLines = 1)
                                    if (s.lastAction.isNotEmpty()) Text(s.lastAction, style = NW.Typo.monoMicro, color = NW.Palette.textTertiary.color, maxLines = 1)
                                }
                                Text(s.state.label, style = NW.Typo.label, color = s.state.color.color)
                            }
                        }
                    }
                }
            }
            item { NWTonightCard(sky.rings) }
        }
    }
}
