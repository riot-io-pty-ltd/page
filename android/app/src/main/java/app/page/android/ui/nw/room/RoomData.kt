package app.page.android.ui.nw.room

import app.page.android.model.AgentCharacter
import app.page.android.model.AnswerPicker
import app.page.android.model.CardOutcome
import app.page.android.model.HeldDelete
import app.page.android.model.PhotoOffer
import app.page.android.model.PhotoProgress
import app.page.android.model.QueuedDelete
import app.page.android.model.SendChoice
import app.page.android.model.SendOutbox
import app.page.android.model.SendWhen
import app.page.android.model.SessionCaps
import app.page.android.model.ChangesModel
import app.page.android.model.LiveSession
import app.page.android.model.LiveSessionState
import app.page.android.model.NowRow
import app.page.android.model.PendingAction
import app.page.android.model.RoomBanner
import app.page.android.model.RoomChip
import app.page.android.model.RoomComposerMode
import app.page.android.model.RoomHeader
import app.page.android.model.RoomLens
import app.page.android.model.RoomPlan
import app.page.android.model.ScreenFreshness
import app.page.android.model.SendReceipt
import app.page.android.model.SentSessionCommand
import app.page.android.model.SessionAsk
import app.page.android.model.SessionAvailability
import app.page.android.model.SessionDeliveryState
import app.page.android.model.SessionDiff
import app.page.android.model.SessionScreen
import app.page.android.model.SessionStopPlan
import app.page.android.model.SessionTarget
import app.page.android.model.SessionTranscript
import app.page.android.model.StoryBlock
import app.page.android.model.StoryBuilder
import app.page.android.model.TranscriptTimeline
import app.page.android.model.WorkflowRun
import app.page.android.model.YesNoArm
import app.page.android.model.YesNoReply
import java.time.Instant

/** Everything the room draws. (iOS SessionRoomData.) */
data class SessionRoomData(
    val session: LiveSession,
    val character: AgentCharacter,
    val subtitle: String,
    val chips: List<RoomChip>,
    val lenses: List<RoomLens>,
    val badges: Map<RoomLens, Int> = emptyMap(),
    val banners: List<RoomBanner> = emptyList(),
    val now: Instant,
    val macName: String,
    // Story
    val story: List<StoryBlock> = emptyList(),
    val truncated: Boolean = false,
    /** "Loading...", "Nothing in this session yet." and so on, when the story is empty. */
    val emptyStory: String? = null,
    val storyLoading: Boolean = false,
    val liveLine: String? = null,
    val timingNote: String? = null,
    /** The open page behind a waiting (or finished) session, pinned in the story. */
    val pageRow: NowRow? = null,
    val pageOutcome: CardOutcome = CardOutcome.None,
    val pagePending: PendingAction? = null,
    /** The question this session is blocked on, when it can be answered from the phone (picker). */
    val ask: SessionAsk? = null,
    val askDelivery: SentSessionCommand? = null,
    val askViaHook: Boolean = false,
    /** The plain-text yes/no question Claude's last message ends on, while the session waits for its next message (Yes and No send those words). */
    val yesNo: String? = null,
    // Screen
    val screen: SessionScreen? = null,
    val screenFreshness: ScreenFreshness? = null,
    val runs: List<WorkflowRun> = emptyList(),
    // Changes
    val changes: ChangesModel? = null,
    val changesLoad: ChangesModel.Load = ChangesModel.Load.Loading,
    val reviewRow: NowRow? = null,
    // Composer
    val composer: RoomComposerMode,
    val composerCopy: RoomComposerMode.Copy,
    val preview: String? = null,
    val composerProblem: String? = null,
    val target: SessionTarget? = null,
    val receipt: SendReceipt? = null,
    val stopNote: StopNote? = null,
    /** How a message to this busy session goes ("Now" / "When it finishes"); null when idle or nothing is on offer. */
    val choice: SendChoice.Plan? = null,
    /** The one-line explanations under the choice have been shown once. */
    val choiceExplained: Boolean = true,
    /** The Mac's caps, so a held bubble offers Delete only where it can work. */
    val caps: Set<String> = emptySet(),
    /** Where a delete of each held message stands, by its clientId. */
    val deletes: Map<String, HeldDelete> = emptyMap(),
    /** The Yes / No chip tapped and still in its 1.2 s window (nothing has been sent; Cancel works). */
    val yesNoArm: YesNoArm? = null,
    /** The photo button (`images-v1`): there or not, working or not, and the lines that explain it. */
    val photos: PhotoOffer = PhotoOffer.none,
    /** Photos going up, by the sending bubble's clientId. */
    val uploads: Map<String, PhotoProgress> = emptyMap(),
    // Stop
    val stop: SessionStopPlan,
    val stopping: Boolean = false,
    val fixedStop: Double? = null,
    val fixedHold: Double? = null,
) {
    enum class StopNoteTone { WORKING, GOOD, PROBLEM }
    data class StopNote(val text: String, val tone: StopNoteTone)

    /** The header's folder line ([SessionTarget.whereLine]). */
    val whereLine: String? get() = target?.whereLine

    /** "cmux > page": the terminal and the project the answers go to. */
    val answerRoute: String? get() = app.page.android.model.DeliveryPreview.route(session.host, target?.project ?: session.title)

    /** What a room is made from: the pieces the live stores hold (or the harness's fixtures). */
    data class Inputs(
        val session: LiveSession,
        val ended: Boolean = false,
        val availability: SessionAvailability = SessionAvailability.Ready,
        val macName: String,
        val now: Instant,
        val transcript: SessionTranscript? = null,
        val sent: List<SentSessionCommand> = emptyList(),
        val screen: SessionScreen? = null,
        val runs: List<WorkflowRun> = emptyList(),
        val diff: SessionDiff? = null,
        val diffError: String? = null,
        val diffRequestedAt: Instant = Instant.EPOCH,
        val fiveHourPct: Double? = null,
        val pageRow: NowRow? = null,
        val pageOutcome: CardOutcome = CardOutcome.None,
        val pagePending: PendingAction? = null,
        val latestStop: SentSessionCommand? = null,
        val composerProblem: String? = null,
        val latestInput: SentSessionCommand? = null,
        val dismissedReceipt: String? = null,
        val answerDelivery: SentSessionCommand? = null,
        val pageIsHook: Boolean = false,
        val pageContext: String? = null,
        val zone: java.time.ZoneId = java.time.ZoneId.systemDefault(),
        /** The Mac's caps (`hold-v1`, `retract-v1`, ...); a Mac that sends none has none. */
        val caps: Set<String> = emptySet(),
        /** The last "Now" / "When it finishes" picked on this device. */
        val sendWhen: SendWhen? = null,
        val choiceExplained: Boolean = true,
        /** Messages counting down before their POST. */
        val outbox: SendOutbox = SendOutbox(),
        val deletes: Map<String, HeldDelete> = emptyMap(),
        /** "Page closed before this was sent..." for a draft put back in the box. */
        val restoredNote: String? = null,
        val yesNoArm: YesNoArm? = null,
        /** Photos going up (`images-v1`), by the sending bubble's clientId. */
        val uploads: Map<String, PhotoProgress> = emptyMap(),
        /** Photos already in the composer's tray: a Mac that stops offering photos meanwhile is said out loud. */
        val stagedPhotos: Int = 0,
    )

    companion object {
        fun make(i: Inputs): SessionRoomData {
            val s = i.session
            val character = AgentCharacter.from(s.backend, s.provider)
            val ready = i.availability == SessionAvailability.Ready
            val items = TranscriptTimeline.merge(i.transcript?.entries ?: emptyList(), i.sent)
            val busy = s.state == LiveSessionState.ACTIVE && !i.ended

            // What the page and composer do is one pure decision (RoomPlan).
            val busyChoice = SendChoice.forSession(s, i.ended, i.caps, i.sendWhen)
            val plan = RoomPlan.build(
                RoomPlan.Inputs(s, character, i.pageRow, i.ended, ready, i.macName, canHold = SessionCaps.canHold(i.caps, s), sendWhen = busyChoice?.selected ?: SendWhen.NOW),
            )
            val pinned = plan.pinned
            val review = plan.review
            val mode = plan.mode

            val runningWorkflows = i.runs.count { it.isRunning }
            val lenses = RoomLens.available(RoomLens.Inputs(character, i.screen != null, i.runs.size, !i.ended && ready))
            val badges = HashMap<RoomLens, Int>()
            for (l in lenses) RoomLens.badge(l, i.diff?.files?.size, runningWorkflows)?.let { badges[l] = it }

            var emptyStory: String? = null
            var loading = false
            if (items.isEmpty()) {
                if (i.transcript != null) emptyStory = "Nothing in this session yet."
                else if (!ready) emptyStory = "The story appears once your Mac is connected."
                else { emptyStory = "Loading the story…"; loading = true }
            }
            val story = StoryBuilder.build(items, busy, i.zone)
            val trailingLive = (story.lastOrNull() as? StoryBlock.Steps)?.live == true
            val ask = AnswerPicker.ask(if (i.ended) null else s, pinned?.chip == app.page.android.model.ChipKind.QUESTION, i.pageIsHook, i.pageContext)
            val askViaHook = ask != null && i.pageIsHook
            val askDelivery = ask?.let { a ->
                if (i.pageIsHook) AnswerPicker.delivery(i.pageOutcome, s.id, a.id, i.now)
                else i.answerDelivery?.takeIf { it.promptKey == a.id }
            }
            // Only where a typed message would go to a session that has finished its turn; a question picker has its own taps.
            val yesNo = YesNoReply.roomOffer(mode, s.state, i.ended, ready, ask != null, items)
            // The choice belongs to the busy composer only (a waiting or idle session has none).
            val choice = busyChoice?.takeIf { mode == RoomComposerMode.Steer || mode == RoomComposerMode.HoldOnly }
            val latest = i.latestInput
            val receipt = (
                SendReceipt.build(
                    latest, character.name, i.now, scheduled = i.outbox.next(s.id), delete = latest?.let { i.deletes[it.clientId] },
                    canDelete = latest != null && QueuedDelete.heldMessage(latest.state, i.caps, i.deletes[latest.clientId]),
                    uploading = latest?.let { i.uploads[it.clientId] },
                ) ?: i.restoredNote?.let { SendReceipt("restored", it, null, SendReceipt.Tone.NOTE) }
                )?.takeIf { it.id != i.dismissedReceipt }
            val stopNote = i.latestStop?.let { stop ->
                SendReceipt.stopLine(stop, character.name)?.let { line ->
                    when (stop.state) {
                        SessionDeliveryState.Sending -> StopNote(line, StopNoteTone.WORKING)
                        is SessionDeliveryState.Typed, is SessionDeliveryState.Queued -> StopNote(line, StopNoteTone.GOOD)
                        else -> StopNote(line, StopNoteTone.PROBLEM)
                    }
                }
            }
            return SessionRoomData(
                session = s, character = character, subtitle = character.subtitle(s.backend, s.provider, s.hostLabel),
                chips = RoomHeader.chips(s, character, i.ended, i.pageRow?.waitingSince, review != null, i.fiveHourPct, i.now),
                lenses = lenses, badges = badges,
                banners = RoomBanner.build(i.ended, i.availability, s, character.name, pinned != null),
                now = i.now, macName = i.macName, story = story, truncated = i.transcript?.truncated ?: false, emptyStory = emptyStory, storyLoading = loading,
                liveLine = if (i.ended) null else StoryBuilder.liveLine(s, character, trailingLive),
                timingNote = RoomComposerMode.timingNote(character, busy),
                pageRow = pinned, pageOutcome = i.pageOutcome, pagePending = i.pagePending, ask = ask, askViaHook = askViaHook, askDelivery = askDelivery, yesNo = yesNo,
                screen = i.screen, screenFreshness = i.screen?.let { ScreenFreshness.evaluate(it.at, i.now, busy) }, runs = i.runs,
                changes = i.diff?.let { ChangesModel.build(it) }, changesLoad = ChangesModel.load(i.diff != null, i.diffError, i.diffRequestedAt, i.now),
                reviewRow = review, composer = mode, composerCopy = mode.copy(character), preview = plan.preview, composerProblem = i.composerProblem,
                target = SessionTarget.of(s, i.macName), receipt = receipt, stopNote = stopNote,
                choice = choice, choiceExplained = i.choiceExplained, caps = i.caps, deletes = i.deletes, yesNoArm = i.yesNoArm,
                photos = PhotoOffer.evaluate(i.caps, s, mode, staged = i.stagedPhotos, ended = i.ended), uploads = i.uploads,
                stop = SessionStopPlan.build(s, ready, i.ended, i.macName), stopping = i.latestStop?.state?.isPending == true,
            )
        }
    }
}
