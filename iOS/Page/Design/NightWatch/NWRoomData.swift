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
        var timeZone: TimeZone = .current
    }

    static func make(_ i: Inputs) -> SessionRoomData {
        let s = i.session
        let character = AgentCharacter.from(backend: s.backend, provider: s.provider)
        let ready = i.availability == .ready
        let items = TranscriptTimeline.merge(entries: i.transcript?.entries ?? [], sent: i.sent)
        let busy = s.state == .active && !i.ended

        // What the page and composer do is one pure decision (RoomPlan).
        let plan = RoomPlan.build(.init(session: s, character: character, pageRow: i.pageRow, ended: i.ended, ready: ready, macName: i.macName))
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
        data.pageRow = pinned
        data.pageOutcome = i.pageOutcome
        data.pagePending = i.pagePending
        data.screen = i.screen
        data.screenFreshness = i.screen.map { ScreenFreshness.evaluate(frameAt: $0.at, now: i.now, busy: busy) }
        data.runs = i.runs
        data.changes = i.diff.map(ChangesModel.build)
        data.changesLoad = ChangesModel.load(hasDiff: i.diff != nil, error: i.diffError, requestedAt: i.diffRequestedAt, now: i.now)
        data.reviewRow = review
        data.preview = plan.preview
        data.composerProblem = i.composerProblem
        if let stop = i.latestStop {
            switch stop.state {
            case .sending: data.stopNote = ("Stopping…", .working)
            case .typed, .queued:
                data.stopNote = ("Stopped. \(stop.state.explanation(.interrupt, agent: character.name) ?? "")", .good)
            case .refused, .failed, .noAnswer:
                data.stopNote = ("Couldn't stop: \(stop.state.explanation(.interrupt, agent: character.name) ?? "")", .problem)
            }
        }
        data.stopping = i.latestStop?.state.isPending == true
        return data
    }
}
