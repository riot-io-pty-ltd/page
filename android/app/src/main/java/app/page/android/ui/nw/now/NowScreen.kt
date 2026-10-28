@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package app.page.android.ui.nw.now

import android.content.Context
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.Dp
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.ActionCoordinator
import app.page.android.data.AppRouter
import app.page.android.data.AwayStore
import app.page.android.data.BiometricGate
import app.page.android.data.NowStore
import app.page.android.data.RelayClient
import app.page.android.data.SessionStore
import app.page.android.data.TipStore
import app.page.android.model.AnswerPicker
import app.page.android.model.ApproachModel
import app.page.android.model.CardOutcome
import app.page.android.model.ChipKind
import app.page.android.model.DepartingRows
import app.page.android.model.NowModel
import app.page.android.model.NowMotion
import app.page.android.model.HeaderJump
import app.page.android.model.NWDestination
import app.page.android.model.NWTip
import app.page.android.model.NowBanner
import app.page.android.model.NowRow
import app.page.android.model.NowTipInputs
import app.page.android.model.ProblemState
import app.page.android.model.ReceiptThread
import app.page.android.model.ReceiptThreadInput
import app.page.android.model.QueuedDelete
import app.page.android.model.RoomEntry
import app.page.android.model.RowAction
import app.page.android.model.TowerSection
import app.page.android.model.secondsSince
import app.page.android.notify.NotificationAccess
import app.page.android.ui.nw.components.NWBannerCard
import app.page.android.ui.nw.components.NWConcentricRings
import app.page.android.ui.nw.components.NWGlassCard
import app.page.android.ui.nw.components.NWMacChip
import app.page.android.ui.nw.components.NWNewPill
import app.page.android.ui.nw.components.NWPulseStyle
import app.page.android.ui.nw.components.NWReceiptLine
import app.page.android.ui.nw.components.NWRunwayBar
import app.page.android.ui.nw.components.rememberRunwayMotion
import app.page.android.ui.nw.components.rememberNowChange
import app.page.android.ui.nw.components.rememberNowClock
import app.page.android.ui.nw.components.NWSectionHeader
import app.page.android.ui.nw.components.NWTipCallout
import app.page.android.ui.nw.components.NWTonightCard
import app.page.android.ui.nw.components.color
import app.page.android.ui.nw.components.rememberNWNow
import app.page.android.ui.nw.components.NWOneShot
import app.page.android.ui.nw.components.nwClockAt
import app.page.android.ui.nw.shell.HorizonGeometry
import app.page.android.ui.nw.theme.LocalMotionPin
import app.page.android.ui.nw.theme.LocalReduceMotion
import app.page.android.ui.nw.theme.NWMotionPin
import app.page.android.ui.nw.theme.pinned
import app.page.android.ui.nw.shell.NWHorizon
import app.page.android.ui.nw.shell.WorkingJump
import app.page.android.ui.nw.theme.AuroraPalette
import app.page.android.ui.nw.theme.LocalDaypart
import app.page.android.ui.nw.theme.LocalFixedNow
import app.page.android.ui.nw.theme.NW
import java.time.Instant
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * NOW: the ranked stream, live. Horizon, Runway, what needs you (amber first), the Return Brief, in flight, then
 * Settled. If anything is blocked on you, the first card under the Runway is that card: nothing sits in front of
 * it. Builds from [NowStore] and routes every action through the existing services ([ActionCoordinator],
 * [AppRouter], [RelayClient]); the cards only draw and call back. (iOS NowContainer + NWNowScreen.)
 */
@Composable
fun NowScreen(modifier: Modifier = Modifier) {
    val screen by NowStore.screen.collectAsStateWithLifecycle()
    val pending by ActionCoordinator.pending.collectAsStateWithLifecycle()
    val problems by ActionCoordinator.localProblems.collectAsStateWithLifecycle()
    val deliveries by RelayClient.deliveries.collectAsStateWithLifecycle()
    val deliveryTimes by RelayClient.deliveryTimes.collectAsStateWithLifecycle()
    val inbox by RelayClient.inbox.collectAsStateWithLifecycle()
    val sessionState by SessionStore.state.collectAsStateWithLifecycle()
    val retractNotes by RelayClient.retractNotes.collectAsStateWithLifecycle()
    val connection by RelayClient.connection.collectAsStateWithLifecycle()
    val book by TipStore.book.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val biometry = remember { BiometricGate.methodName(context) }
    val scope = rememberCoroutineScope()
    val listState = rememberLazyListState()
    val topInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()

    var touching by remember { mutableStateOf(false) }
    var briefExpanded by remember { mutableStateOf(false) }
    var refreshing by remember { mutableStateOf(false) }
    var ghostTick by remember { mutableIntStateOf(0) }
    var lastRows by remember { mutableStateOf(emptyList<NowRow>()) }

    // A card is never re-sorted under a finger: touching or scrolling freezes the order, arrivals wait behind the pill.
    LaunchedEffect(touching) { if (touching) { delay(3000); touching = false } }
    LaunchedEffect(touching, listState.isScrollInProgress) { NowStore.setFrozen(touching || listState.isScrollInProgress) }

    val armingUntil = pending.values.filter { it.armed }.maxOfOrNull { it.startedAt.plusSeconds(2) }
    // 10 Hz is enough for the cards' outcomes; the arm ring keeps its own 30 fps clock (ArmingStrip), so the whole
    // list is not recomposed 30 times a second while something arms.
    val liveNow by rememberNWNow(until = armingUntil, fastMs = 100)
    val now = LocalFixedNow.current ?: liveNow

    // A card confirmed a moment ago stays, as a ghost, while its thread resolves.
    @Suppress("UNUSED_EXPRESSION") ghostTick
    // On the current clock: the screen's `now` ticks slowly when nothing is arming, and a confirmation newer than it
    // would read as not yet happened, so the row would vanish instead of folding.
    val departing = DepartingRows.merge(lastRows, screen.rows, deliveries, deliveryTimes, LocalFixedNow.current ?: Instant.now())
    LaunchedEffect(departing.rows.map { it.id }) { lastRows = departing.rows }
    LaunchedEffect(departing.ghosts) {
        val at = DepartingRows.nextExpiry(departing.ghosts, deliveryTimes) ?: return@LaunchedEffect
        delay(maxOf(0L, at.toEpochMilli() - System.currentTimeMillis()) + 50)
        ghostTick++
    }

    val rows = departing.rows
    val m = screen.model
    val reduce = LocalReduceMotion.current
    val pin = LocalMotionPin.current
    val density = LocalDensity.current
    val quiet = m.rows.isEmpty()
    val macName = screen.macName
    val problem = screen.problem

    // One first-time tip at a time, under the first row of its kind that has nothing under way.
    val busy = pending.keys + problems.keys + rows.filter { r -> deliveries[r.id] != null }.map { it.id }
    val tip = book.nowTip(NowTipInputs(rows.filter { (it.chip != ChipKind.UNDOABLE && it.chip != ChipKind.IRREVERSIBLE) || it.action(RowAction.Kind.APPROVE) != null }.map { it.id to it.chip }, screen.inFlight.rows.map { it.id }, busy))

    val answerable = rows.filter { r ->
        val page = inbox.firstOrNull { it.id == r.id }
        r.chip == ChipKind.QUESTION && AnswerPicker.ask(sessionState.session(r.sessionId), true, page?.isBlockingHook ?: false, page?.context) != null
    }.map { it.id }.toSet()

    fun statusOf(row: NowRow): RowStatus {
        val receipt = ReceiptThreadInput(pending[row.id], deliveries[row.id], problems[row.id], deliveryTimes[row.id])
        val outcome = problems[row.id]?.let { CardOutcome.Problem(it) } ?: CardOutcome.from(pending[row.id], deliveries[row.id], now)
        // Delete for a reply that is queued and not yet sent, where the relay (or the Mac) says it can take it back.
        val layer = QueuedDelete.reply(deliveries[row.id], inbox.firstOrNull { it.id == row.id }?.isBlockingHook ?: false, sessionState.relayFeatures, sessionState.caps)
        val onDelete: (() -> Unit)? = when (layer) {
            QueuedDelete.Layer.RELAY_QUEUE -> ({ scope.launch { RelayClient.retractReply(row.id) }; Unit })
            QueuedDelete.Layer.MAC_RATE_LIMIT -> ({ RelayClient.deleteHeldReply(row.id) })
            else -> null
        }
        return RowStatus(outcome, pending[row.id], receipt.takeIf { !it.isEmpty }, onDelete, retractNotes[row.id])
    }

    fun actionsOf(row: NowRow) = RowActions(
        open = { AppRouter.open(row.id, switchTab = false) },
        approve = { if (row.chip == ChipKind.UNDOABLE) TipStore.retire(NWTip.SWIPE_TO_APPROVE); ActionCoordinator.begin(row, RowAction.Kind.APPROVE) },
        holdComplete = { TipStore.retire(NWTip.HOLD_TO_APPROVE); ActionCoordinator.commitHold(row, macName) },
        deny = { ActionCoordinator.begin(row, RowAction.Kind.DENY) },
        looksGood = { ActionCoordinator.begin(row, RowAction.Kind.CARRY_ON) },
        steer = { AppRouter.open(row.id, switchTab = false, composer = true) },
        // The ring, if it is still running; otherwise the sheet, to see and retry.
        cancel = { if (ActionCoordinator.isArming(row.id)) ActionCoordinator.cancel(row.id) else AppRouter.open(row.id, switchTab = false) },
    )

    val spec = app.page.android.ui.nw.shell.RenderHarness.spec.value
    val sections = NowRow.Section.entries.map { sec -> sec to rows.filter { it.section == sec } }.filter { it.second.isNotEmpty() }
    // The render harness folds a row in place without its page closing.
    val ghosts = departing.ghosts + (spec?.ghosts ?: emptySet())

    // FINAL APPROACH: anything new descends from the pulse. Decided as each row first appears (ArrivalBook); nothing
    // arrives on the first look at a loaded inbox, and nothing while a finger is on the stream (those wait behind the
    // "New" pill, outside `rows`, and arrive when it is tapped).
    val arrivals = remember { ArrivalBook() }
    arrivals.observe(sections.flatMap { (_, list) -> list.map { it.id } }, screen.inboxLoaded, animate = !reduce)
    val horizonHeight = if (quiet && problem == null) 470.dp else 244.dp
    // The Horizon gives up its room at once when the first item arrives (or takes it back when the last goes): the
    // stream jumps with it in that one frame, so the only thing moving is the arrival, not the Runway sliding up
    // through it.
    // Each reconnect starts In flight's motion afresh: the first snapshot after it carries old changes, never news.
    val reconnects = remember { object { var last: RelayClient.ConnectionState? = null; var count = 0 } }
    if (connection == RelayClient.ConnectionState.CONNECTED && reconnects.last != null && reconnects.last != connection) reconnects.count++
    reconnects.last = connection
    val flightEpoch = reconnects.count
    val lastHorizon = remember { object { var height: Dp? = null } }
    val horizonJumped = lastHorizon.height != null && lastHorizon.height != horizonHeight
    lastHorizon.height = horizonHeight
    val pinnedArrival = spec?.pinnedArrival
    val approachAt = pin.pinned(NWMotionPin.Kind.APPROACH)
    val arrivalHeight = remember { mutableFloatStateOf(0f) }
    /** Where the card [key] sits relative to the pulse, read while drawing (it follows the scroll without recomposing). */
    fun geometry(key: String): () -> ArrivalGeometry? = geometry@{
        val info = listState.layoutInfo
        val item = info.visibleItemsInfo.firstOrNull { it.key == key } ?: return@geometry null
        val horizon = info.visibleItemsInfo.firstOrNull { it.key == "horizon" }
        with(density) {
            // Scrolled away, the pulse is just above the top of the screen: the card still comes down from it.
            val hTop = horizon?.offset?.toFloat() ?: -(horizonHeight + topInset + HorizonGeometry.textRoom(fontScale)).toPx()
            val pulseY = hTop + HorizonGeometry.pulseY(horizonHeight, topInset).toPx()
            ArrivalGeometry(
                distance = maxOf(0f, item.offset - pulseY),
                wordsTop = horizon?.let { hTop + HorizonGeometry.wordsTop(horizonHeight, topInset).toPx() - item.offset },
                wordsBottom = horizon?.let { hTop + HorizonGeometry.wordsBottom(horizonHeight, topInset, fontScale).toPx() - item.offset },
            )
        }
    }
    // The receipt line of a reply on its way: when it appeared (it rises in then; its words cross-fade as it goes on).
    val receiptChange = rememberNowChange(m.receiptLine)
    val receiptAt = receiptChange.at?.takeIf { receiptChange.from == null }
    // Every item's key in the order drawn, so a section can be scrolled to ("2 working" jumps to In flight).
    val keys = remember { ArrayList<String>() }
    keys.clear()
    fun jumpTo(key: String) {
        // Land the section below the status bar, not under the clock.
        scope.launch { val i = keys.indexOf(key); if (i >= 0) listState.animateScrollToItem(i, scrollOffset = -with(density) { (topInset + 12.dp).roundToPx() }) }
    }

    // The render harness frames a card below the fold.
    LaunchedEffect(spec?.scrollTo, spec?.scrollTop, rows.size, screen.inFlight.rows.size) {
        val target = spec?.scrollTop ?: spec?.scrollTo ?: return@LaunchedEffect
        delay(600)
        val i = keys.indexOf(target)
        if (i >= 0) {
            if (spec?.scrollTop != null) listState.scrollToItem(i, -with(density) { (topInset + 12.dp).roundToPx() }) else listState.scrollToItem(i, -250)
        }
    }
    PullToRefreshBox(
        isRefreshing = refreshing,
        onRefresh = {
            refreshing = true
            scope.launch {
                SessionStore.refresh()
                if (!RelayClient.isDemoMode) RelayClient.refreshAll()
                delay(400)
                refreshing = false
            }
        },
        modifier = modifier.fillMaxSize(),
    ) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize().pointerInput(Unit) {
                awaitPointerEventScope {
                    while (true) {
                        val e = awaitPointerEvent(PointerEventPass.Initial)
                        touching = e.changes.any { it.pressed }
                    }
                }
            },
            contentPadding = PaddingValues(bottom = 132.dp), verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            fun addItem(key: String, fade: Boolean, content: @Composable LazyItemScope.(Modifier) -> Unit) {
                keys.add(key)
                item(key = key) {
                    // The cards below a new arrival make room on its spring (response 0.5, damping 0.8: stiffness
                    // (2π/0.5)²); nothing above moves. The arrival draws its own entrance; a departure fades. [fade]:
                    // the queued receipt, which fades out over 0.3 s as the rows under it close up (a plain 0.2 s
                    // cross-fade, in and out, under Reduce Motion).
                    val placed = when {
                        fade && reduce -> Modifier.animateItem(fadeInSpec = tween(200), placementSpec = null, fadeOutSpec = tween(200))
                        reduce -> Modifier
                        else -> Modifier.animateItem(
                            fadeInSpec = null, placementSpec = if (horizonJumped) null else spring(dampingRatio = 0.8f, stiffness = 157.9f),
                            fadeOutSpec = tween(if (fade) (NowMotion.queuedFade * 1000).toInt() else 220),
                        )
                    }
                    // The render harness pins the approach: the cards below are drawn part-way down.
                    val pushed = if (pinnedArrival != null && approachAt != null) Modifier.graphicsLayer {
                        val a = keys.indexOf("row-$pinnedArrival")
                        val i = keys.indexOf(key)
                        if (a >= 0 && i > a) translationY = ApproachModel.pushOffset((arrivalHeight.floatValue + 16.dp.toPx()).toDouble(), approachAt).toFloat()
                    } else Modifier
                    content(placed.then(pushed))
                }
            }
            fun add(key: String, content: @Composable LazyItemScope.(Modifier) -> Unit) = addItem(key, false, content)
            fun pad(content: @Composable () -> Unit): @Composable LazyItemScope.(Modifier) -> Unit = { m -> Box(m.padding(horizontal = NW.Space.gutter)) { content() } }

            add("horizon") { im ->
                val showJump = problem == null && screen.handover == null
                val jump = if (showJump && HeaderJump.target(m.workingCount, screen.inFlight.rows.size) != null) {
                    HeaderJump.split(NowModel.sublineBesideChip(m.subline, screen.macChip.text), m.workingCount)?.let { (j, rest) -> WorkingJump(j, rest) { jumpTo(HeaderJump.sectionId) } }
                } else null
                Box(im) {
                    val p = problem
                    NWHorizon(
                        palette = p?.let { if (it.tone == ProblemState.Tone.SLATE) AuroraPalette.asleep else AuroraPalette.problem } ?: AuroraPalette.of(m.mood, LocalDaypart.current),
                        pulse = p?.let { if (it.tone == ProblemState.Tone.SLATE) NWPulseStyle.Style.HOLLOW_SLATE else NWPulseStyle.Style.HOLLOW_AMBER } ?: NWPulseStyle.Style.of(m.mood),
                        headline = p?.title ?: screen.handover ?: m.headline,
                        subline = p?.subtitle ?: (if (screen.handover == null) NowModel.sublineBesideChip(m.subline, screen.macChip.text) else m.headline),
                        footnote = if (p == null && quiet && m.headline == "All quiet") "Page is keeping watch. Go to sleep." else null,
                        height = horizonHeight, topInset = topInset, model = screen.pulse, workingJump = jump,
                        onPulseTap = { AppRouter.openTower() }, onSwipe = AppRouter::selectDestination, current = NWDestination.NOW,
                    )
                    Row(Modifier.fillMaxWidth().padding(horizontal = NW.Space.gutter).padding(top = topInset + 6.dp), verticalAlignment = Alignment.Top) {
                        NWMacChip(screen.macChip, onTap = { AppRouter.openTower() })
                        Box(Modifier.weight(1f))
                        SettingsOrb(m.rings)
                    }
                }
            }
            problem?.let { p -> add("problem", pad { NWProblemCard(p, onAction = { a -> problemAction(a) }) }) }
            for (b in screen.banners) {
                if (problem?.replacesBanners?.contains(b.id) == true) continue
                add("banner-${b.id}", pad { NWBannerCard(b, onAction = { a -> bannerAction(a, context) }) })
            }
            // With the Mac out of reach the Runway would be a stale promise, so it steps aside.
            if (problem?.kind != ProblemState.Kind.MAC_ASLEEP) add("runway", pad {
                NWGlassCard(
                    Modifier.clickable(role = Role.Button, onClickLabel = "Opens the Tower at Budget") { AppRouter.openTower(TowerSection.BUDGET) },
                    radius = 24.dp, padding = PaddingValues(6.dp),
                ) {
                    // The NOW dot breathes with the pulse while agents work, never at dusk.
                    NWRunwayBar(m.runway, motion = rememberRunwayMotion(m.runway, breathing = m.workingCount > 0 && !m.paused, period = screen.pulse.breathPeriod))
                }
            })
            val brief = screen.brief
            if (brief != null && !brief.hasUrgent) add("brief", pad {
                NWBriefCard(brief, briefExpanded || quiet, { briefExpanded = !briefExpanded }, { AwayStore.dismissBrief(); briefExpanded = false }, { briefExpanded = false; jumpTo("section-review") })
            })
            val hasReview = sections.any { it.first == NowRow.Section.REVIEW }
            fun inFlight() {
                if (screen.inFlight.rows.isEmpty()) return
                add(HeaderJump.sectionId, pad {
                    NWInFlightSection(
                        screen.inFlight, tip = tip?.takeIf { it.tip == NWTip.IN_FLIGHT }, biometry = biometry, epoch = flightEpoch,
                        onOpen = { id, entry -> TipStore.retire(NWTip.IN_FLIGHT); AppRouter.openSession(id, entry) },
                        onToggle = NowStore::toggleInFlightExpanded, onHeader = { AppRouter.selectDestination(NWDestination.LANES) }, onDismissTip = { TipStore.retire(it) },
                    )
                })
            }
            val lastUrgent = sections.lastOrNull { it.first != NowRow.Section.REVIEW }?.first
            for ((section, list) in sections) {
                // In flight sits between what needs you and what has finished.
                if (section == NowRow.Section.REVIEW) inFlight()
                add("section-${section.title.lowercase()}", pad { NWSectionHeader(section.title.lowercase().replaceFirstChar { it.uppercase() }, section.color, count = list.count { it.id !in ghosts }) })
                for (row in list) {
                    val key = "row-${row.id}"
                    add(key, pad {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            val card: @Composable () -> Unit = { RowCard(row, now, statusOf(row), actionsOf(row), answerable, spec) }
                            if (row.id in ghosts) {
                                ResolveFold(deliveryTimes[row.id]) { card() }
                            } else {
                                val pinnedHere = if (row.id == pinnedArrival) approachAt else null
                                NWArrival(
                                    arrivals.start(row.id), row.section.color, cardRadius(row), geometry(key),
                                    modifier = if (pinnedHere != null) Modifier.onSizeChanged { arrivalHeight.floatValue = it.height.toFloat() } else Modifier,
                                    pinned = pinnedHere,
                                ) { card() }
                            }
                            if (tip != null && tip.anchorId == row.id) {
                                val pinnedHere = if (row.id == pinnedArrival) approachAt else null
                                NWArrivalTail(
                                    arrivals.start(row.id).takeIf { row.id !in ghosts }, pinnedHere,
                                    push = { with(density) { ApproachModel.pushOffset((arrivalHeight.floatValue + 16.dp.toPx()).toDouble(), pinnedHere ?: 1.0).toFloat() } },
                                ) { NWTipCallout(tip.tip.text(biometry), symbol = tip.tip.symbol, onDismiss = { TipStore.retire(tip.tip) }) }
                            }
                        }
                    })
                }
                // The Brief sits after Decide and Look when something needs you.
                if (brief != null && brief.hasUrgent && section == lastUrgent) add("brief", pad {
                    NWBriefCard(brief, briefExpanded, { briefExpanded = !briefExpanded }, { AwayStore.dismissBrief(); briefExpanded = false }, { briefExpanded = false; jumpTo("section-review") })
                })
            }
            if (!hasReview) inFlight()
            if (brief != null && brief.hasUrgent && lastUrgent == null) add("brief", pad {
                NWBriefCard(brief, briefExpanded, { briefExpanded = !briefExpanded }, { AwayStore.dismissBrief(); briefExpanded = false }, { briefExpanded = false; jumpTo("section-review") })
            })
            m.receiptLine?.let { line -> addItem("receipt", true, pad { QueuedReceipt(line, m.receiptFailed, receiptAt) }) }
            if (quiet && problem == null) add("tonight", pad { NWTonightCard(m.rings) })
            add("settled", pad { NWSettledList(screen.settled, Modifier.padding(top = 6.dp), onSeeAll = AppRouter::openHistory, now = screen.now) })
        }
        // The stream scrolls under the status bar: a soft scrim keeps the clock readable once the Horizon has gone.
        if (listState.firstVisibleItemIndex > 0) {
            // Solid behind the clock, then a short fade: the content never prints over the status bar.
            val bg = NW.Palette.background.opacity(0.96).color
            Box(
                Modifier.fillMaxWidth().height(topInset + 20.dp).background(
                    androidx.compose.ui.graphics.Brush.verticalGradient(
                        0f to bg, (topInset.value / (topInset.value + 20f)) to bg, 1f to androidx.compose.ui.graphics.Color.Transparent,
                    ),
                ),
            )
        }
        val queued = maxOf(screen.queuedNew, spec?.queuedNew ?: 0)
        if (queued > 0) {
            Box(Modifier.fillMaxWidth().padding(top = topInset + 56.dp), contentAlignment = Alignment.TopCenter) { NWNewPill(queued) { NowStore.releaseNew() } }
        }
    }
}

/**
 * The receipt line of the latest reply ("held until 15:00", "sending", "delivered"): it rises 6 dp as it fades in
 * when it appears ([appearedAt], on the [nwClockSeconds] base), and its words cross-fade as the reply goes on. Its
 * leaving is the list's: a 0.3 s fade as the rows under it close up.
 */
@Composable
private fun QueuedReceipt(line: String, failed: Boolean, appearedAt: Double?) {
    val reduce = LocalReduceMotion.current
    val clock = rememberNowClock(appearedAt?.plus(NowMotion.queuedFade))
    val rise = if (appearedAt == null) Modifier else Modifier.graphicsLayer {
        val s = NowMotion.queuedIn(clock.value - appearedAt, reduce)
        translationY = s.offset.dp.toPx()
        alpha = s.opacity.toFloat()
    }
    NWReceiptLine(line, rise, failed = failed, crossfade = true)
}

@Composable
private fun RowCard(row: NowRow, now: Instant, status: RowStatus, actions: RowActions, answerable: Set<String>, spec: app.page.android.ui.nw.shell.RenderHarness.Spec? = null) {
    when {
        row.section == NowRow.Section.DECIDE && row.canSwipeApprove -> NWUndoableRow(row, now, status, actions, fixedDrag = spec?.dragDp?.let { with(androidx.compose.ui.platform.LocalDensity.current) { it.dp.toPx() } })
        row.section == NowRow.Section.DECIDE && row.chip == ChipKind.QUESTION -> NWQuestionCard(row, now, row.id in answerable, actions.open)
        row.section == NowRow.Section.DECIDE -> NWDecideCard(row, now, status, actions, fixedHold = spec?.hold)
        row.section == NowRow.Section.LOOK -> NWLookCard(row, now, status, actions)
        else -> NWReviewCard(row, now, status, actions)
    }
}

/** The corner a card is drawn with, which its arriving outline follows. */
private fun cardRadius(row: NowRow): Dp = if (row.section == NowRow.Section.DECIDE && row.canSwipeApprove) NW.Radius.row else NW.Radius.card

/**
 * A card whose reply the Mac confirmed has left the inbox: it stays in its place while the thread resolves, then folds
 * into a teal hairline that drifts down into Settled (iOS NWResolveFold). Its own one-shot from the moment the
 * confirmation reached the phone; the render harness pins it with the fixed clock.
 */
@Composable
private fun ResolveFold(changedAt: Instant?, content: @Composable () -> Unit) {
    // Remove animations: the card holds still with its verified thread while it stays, then goes (a cut, not a fold).
    if (changedAt == null || LocalReduceMotion.current) { content(); return }
    val fixed = LocalFixedNow.current
    if (fixed != null) {
        FoldFrame(ReceiptThread.resolved(maxOf(0.0, fixed.secondsSince(changedAt))), content)
        return
    }
    val start = remember(changedAt) { nwClockAt(changedAt) }
    NWOneShot(start, ReceiptThread.resolveDuration) { e -> FoldFrame(ReceiptThread.resolved(e ?: ReceiptThread.resolveDuration), content) }
}

@Composable
private fun FoldFrame(f: ReceiptThread, content: @Composable () -> Unit) {
    val fold = f.fold.toFloat()
    val drift = f.drift.toFloat()
    Box(if (fold > 0) Modifier.clearAndSetSemantics {} else Modifier) {
        Box(Modifier.graphicsLayer { alpha = 1f - fold; scaleY = maxOf(0.004f, 1f - fold) }) { content() }
        // The hairline the card becomes, teal like the receipt it now is.
        Box(
            Modifier.matchParentSize().drawBehind {
                val a = 0.8 * fold * (1 - drift)
                if (a > 0.003) {
                    val inset = 24.dp.toPx() * drift
                    drawRect(
                        NW.Palette.teal.opacity(a).color, Offset(inset, size.height / 2 + 28.dp.toPx() * drift - 0.5.dp.toPx()),
                        androidx.compose.ui.geometry.Size(size.width - 2 * inset, 1.dp.toPx()),
                    )
                }
            },
        )
    }
}

@OptIn(kotlinx.coroutines.DelicateCoroutinesApi::class)
private fun problemAction(a: ProblemState.Action) {
    when (a) {
        ProblemState.Action.RECHECK -> { SessionStore.refresh(); kotlinx.coroutines.GlobalScope.launch { RelayClient.refreshAll() } }
        ProblemState.Action.REPAIR -> AppRouter.requestUnpair()
    }
}

@OptIn(kotlinx.coroutines.DelicateCoroutinesApi::class)
private fun bannerAction(a: NowBanner.Action, context: Context) {
    when (a) {
        NowBanner.Action.REPAIR -> AppRouter.requestUnpair()
        NowBanner.Action.RETRY -> { SessionStore.refresh(); kotlinx.coroutines.GlobalScope.launch { RelayClient.refreshAll() } }
        NowBanner.Action.OPEN_NOTIFICATION_SETTINGS -> NotificationAccess.openSettings(context)
    }
}

@Composable
private fun SettingsOrb(rings: List<app.page.android.model.RingStat>) {
    Box(
        Modifier.size(56.dp).clip(CircleShape).clickable(role = Role.Button, onClickLabel = "Opens the Tower") { AppRouter.openTower() }
            .semantics { contentDescription = "Settings. " + rings.joinToString(", ") { "${it.kind.name.lowercase()} ${it.detail}" } },
        contentAlignment = Alignment.Center,
    ) {
        if (rings.isEmpty()) Box(Modifier.size(40.dp).drawBehind { drawCircle(Color.White.copy(alpha = 0.28f), style = Stroke(4.dp.toPx()), radius = size.minDimension / 2 - 2.dp.toPx()) })
        else NWConcentricRings(rings, size = 46.dp)
    }
}
