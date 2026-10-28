import Foundation

extension SessionRoomData {
    /// What a room is made from: the pieces the live stores hold (or the
    /// harness's fixtures). Everything the screen shows is derived from these
    /// by the pure builders in `Models/SessionRoom.swift`, so the live room
    /// and the render harness cannot disagree.
    struct Inputs {
        var session: LiveSession
        /// The session left the Mac's list while the room was open.
        var ended = false
        var availability: SessionAvailability = .ready
        var macName: String
        var now: Date
        var transcript: SessionTranscript? = nil
        var sent: [SentSessionCommand] = []
        var screen: SessionScreen? = nil
        var runs: [WorkflowRun] = []
        var diff: SessionDiff? = nil
        var diffError: String? = nil
        var diffRequestedAt: Date = .distantPast
        /// The Mac's 5-hour usage reading, for the header chip.
        var fiveHourPct: Double? = nil
        /// The page behind this session, as a row (decide, look or review).
        var pageRow: NowRow? = nil
        var pageOutcome: CardOutcome = .none
        var pagePending: PendingAction? = nil
        /// The newest Stop sent from this room, while it is worth showing.
        var latestStop: SentSessionCommand? = nil
        var composerProblem: String? = nil
        /// The newest message sent from this room, for its receipt.
        var latestInput: SentSessionCommand? = nil
        /// A receipt the user closed.
        var dismissedReceipt: String? = nil
        /// Where the newest answers sent for this session's question stand.
        var answerDelivery: SentSessionCommand? = nil
        /// The pinned page is one Claude's question hook holds (answered by text through the hook).
        var pageIsHook = false
        /// That page's text, to check it is about the question the session row carries.
        var pageContext: String? = nil
        /// What the Mac accepts (`list` `caps`): holding and taking back are offered only with these.
        var caps: Set<String> = []
        /// The choice made last time for a message to a busy session (kept per device).
        var lastChoice: SendChoice? = nil
        /// The one-line explanations under the choice were seen (a message has gone out with the choice shown).
        var choiceExplained = true
        /// Where each Delete stands, by held message clientId.
        var retractNotes: [String: RetractNote] = [:]
        /// A Yes or No in its 1.2 s arm ring (nothing has been sent; Cancel works).
        var yesNoArm: YesNoArm? = nil
        /// The photos in the composer (`images-v1`).
        var photos: [PhotoDraftItem] = []
        /// The message (clientId) whose photo bytes are still held, so a refused one can be put back in the composer.
        var putBackId: String? = nil
        var timeZone: TimeZone = .current
    }

    static func make(_ i: Inputs) -> SessionRoomData {
        let s = i.session
        let character = AgentCharacter.from(backend: s.backend, provider: s.provider)
        let ready = i.availability == .ready
        // The Mac's held messages this phone has no command for (typed from another device, or before a
        // relaunch) are pending bubbles too, oldest first.
        let items = TranscriptTimeline.merge(entries: i.transcript?.entries ?? [],
                                             sent: HeldTimeline.pending(sent: i.sent, held: s.held, sessionId: s.id))
        let busy = s.state == .active && !i.ended

        // What the page and composer do is one pure decision (RoomPlan).
        let plan = RoomPlan.build(.init(session: s, character: character, pageRow: i.pageRow, ended: i.ended, ready: ready, macName: i.macName,
                                        caps: i.caps, lastChoice: i.lastChoice, stagedPhotos: i.photos.count))
        let pinned = plan.pinned
        let review = plan.review
        let mode = plan.mode

        var runningWorkflows = 0
        for r in i.runs where r.isRunning { runningWorkflows += 1 }
        let lenses = RoomLens.available(.init(
            character: character, hasScreen: i.screen != nil, workflowCount: i.runs.count,
            canAskForChanges: !i.ended && ready))
        var badges: [RoomLens: Int] = [:]
        for l in lenses {
            if let n = RoomLens.badge(for: l, changedFiles: i.diff?.files.count, runningWorkflows: runningWorkflows) { badges[l] = n }
        }

        var emptyStory: String?
        var loading = false
        if items.isEmpty {
            if i.transcript != nil { emptyStory = "Nothing in this session yet." }
            else if !ready { emptyStory = "The story appears once your Mac is connected." }
            else { emptyStory = "Loading the story…"; loading = true }
        }

        var data = SessionRoomData(
            session: s, character: character,
            subtitle: character.subtitle(backend: s.backend, provider: s.provider, host: s.hostLabel),
            chips: RoomHeader.chips(session: s, character: character, ended: i.ended, waitingSince: i.pageRow?.waitingSince,
                                    hasReviewPage: review != nil, fiveHourPct: i.fiveHourPct, now: i.now),
            lenses: lenses, badges: badges,
            banners: RoomBanner.build(ended: i.ended, availability: i.availability, session: s, agent: character.name,
                                      pageShownInStory: pinned != nil),
            now: i.now, macName: i.macName,
            composer: mode, composerCopy: mode.copy(for: character),
            stop: SessionStopPlan.build(session: s, ready: ready, ended: i.ended, macName: i.macName))
        data.story = StoryBuilder.build(items: items, active: busy, timeZone: i.timeZone)
        data.truncated = i.transcript?.truncated ?? false
        data.emptyStory = emptyStory
        data.storyLoading = loading
        var trailingLive = false
        if case .steps(_, _, true)? = data.story.last { trailingLive = true }
        data.liveLine = i.ended ? nil : StoryBuilder.liveLine(session: s, character: character, trailingStepsAreLive: trailingLive)
        data.timingNote = RoomComposerMode.timingNote(character: character, busy: busy)
        data.choice = plan.choice
        data.explainChoice = !i.choiceExplained
        data.canDeleteHeld = i.caps.contains(SendChoicePlan.retractCap)
        data.retractNotes = i.retractNotes
        data.yesNoArm = i.yesNoArm
        data.photoOffer = plan.photos
        data.photos = i.photos
        data.putBackId = i.putBackId
        data.pageRow = pinned
        data.pageOutcome = i.pageOutcome
        data.pagePending = i.pagePending
        data.ask = AnswerPicker.ask(for: i.ended ? nil : s, pageIsQuestion: pinned?.chip == .question, hook: i.pageIsHook, pageContext: i.pageContext)
        data.askViaHook = data.ask != nil && i.pageIsHook
        data.yesNo = YesNoReply.roomOffer(mode: mode, state: s.state, ended: i.ended, ready: ready, hasAsk: data.ask != nil, items: items)
        // A hook page has no `answer` command: its delivery is the page's own outcome.
        data.askDelivery = data.ask.flatMap { ask in
            i.pageIsHook ? AnswerPicker.delivery(from: i.pageOutcome, sessionId: s.id, promptKey: ask.id, now: i.now)
                         : (i.answerDelivery?.promptKey == ask.id ? i.answerDelivery : nil)
        }
        data.screen = i.screen
        data.screenFreshness = i.screen.map { ScreenFreshness.evaluate(frameAt: $0.at, now: i.now, busy: busy) }
        data.runs = i.runs
        data.changes = i.diff.map(ChangesModel.build)
        data.changesLoad = ChangesModel.load(hasDiff: i.diff != nil, error: i.diffError, requestedAt: i.diffRequestedAt, now: i.now)
        data.reviewRow = review
        data.preview = plan.preview
        // Photos in the box: the line under the field says how they go.
        if !i.photos.isEmpty, mode.usesSessionInput, let tail = plan.photos.previewTail {
            let route = DeliveryPreview.route(host: s.host, project: SessionTarget(session: s, macName: i.macName).project)
            data.preview = DeliveryPreview.line("Your photos and message · \(tail)", route: route, mac: i.macName)
        }
        data.composerProblem = i.composerProblem
        data.target = SessionTarget(session: s, macName: i.macName)
        if let r = SendReceipt.build(i.latestInput, agent: character.name, now: i.now, canRetract: data.canDeleteHeld,
                                     note: i.latestInput.flatMap { i.retractNotes[$0.clientId] }), r.id != i.dismissedReceipt { data.receipt = r }
        if let stop = i.latestStop, let line = SendReceipt.stopLine(stop, agent: character.name) {
            switch stop.state {
            case .sending: data.stopNote = (line, .working)
            case .typed, .queued: data.stopNote = (line, .good)
            case .refused, .failed, .noAnswer: data.stopNote = (line, .problem)
            // A Stop is never counted down, held or taken back.
            case .counting, .held, .deleted, .unconfirmed: break
            }
        }
        data.stopping = i.latestStop?.state.isPending == true
        return data
    }
}
