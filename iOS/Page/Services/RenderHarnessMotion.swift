#if DEBUG
import SwiftUI

/// The signature motions, one moment at a time, for the render harness:
/// `-NWRender motion-<name> -NWTime <seconds>` draws the real screen (the
/// shell, Now, Lanes, the Decision sheet) with that motion pinned `seconds`
/// in, so a contact sheet can be built frame by frame (iOS/Tools/
/// render-motion.sh). In-memory fixtures only, like the rest of the harness.
enum RenderHarnessMotion {
    static let screens = [
        "motion-pulse-quiet", "motion-pulse-working", "motion-pulse-waiting1", "motion-pulse-waiting3", "motion-pulse-exhale",
        "motion-approach",
        "motion-receipt-arm", "motion-receipt-sending", "motion-receipt-sent", "motion-receipt-typed", "motion-receipt-verified",
        "motion-receipt-fold", "motion-receipt-failed", "motion-receipt-sheet",
        "motion-hold", "motion-hold-burst",
        "motion-dusk", "motion-dawn", "motion-dusk-now", "motion-dawn-now", "motion-brief",
        "motion-inflight-enter", "motion-inflight-advance", "motion-inflight-complete", "motion-inflight-vanish", "motion-inflight-stuck",
        "motion-inflight-quiet", "motion-inflight-live",
        "motion-now-enter", "motion-now-enter-low", "motion-now-change", "motion-now-change-low", "motion-now-runway", "motion-now-quiet",
        "motion-now-live", "motion-now-live-low",
    ]

    /// The board's moment for each screen, when `-NWTime` is not given.
    static func defaultTime(_ screen: String) -> Double {
        switch screen {
        case "motion-approach": return 0.18
        case "motion-pulse-exhale": return 0.4
        case "motion-receipt-arm": return 0.6
        case "motion-receipt-sending": return 0.3
        case "motion-receipt-sent": return 0.8
        case "motion-receipt-typed": return 0.45
        case "motion-receipt-verified", "motion-receipt-sheet": return 0.95
        case "motion-receipt-fold": return 1.25
        case "motion-receipt-failed": return 0.12
        case "motion-hold": return 0.9
        case "motion-hold-burst": return 0.2
        case "motion-dusk", "motion-dusk-now": return 0.8
        case "motion-dawn", "motion-dawn-now": return 1.2
        case "motion-brief": return 0.9
        case "motion-inflight-enter": return 0.6
        case "motion-inflight-advance", "motion-inflight-vanish": return 2.2
        case "motion-inflight-complete": return 2.6
        case "motion-now-enter", "motion-now-enter-low": return 0.35
        case "motion-now-change", "motion-now-change-low", "motion-now-runway": return 2.2
        default: return 3
        }
    }

    static func time(_ args: RenderArguments) -> Double { args.time ?? defaultTime(args.screen) }

    /// The aurora's and the pulse's clock: the pinned time for a motion
    /// screen (so its ripples sit where the board's do), 3 s otherwise. The
    /// Workflows lens's frames keep the room's sky at 3 s, so only the lens moves.
    static func phase(_ args: RenderArguments) -> Double {
        if workflow(args.screen) || inflight(args.screen) || nowMotion(args.screen) { return 3.0 }
        return args.screen.hasPrefix("motion-") ? time(args) : (args.time ?? 3.0)
    }

    /// The room screens whose workflow motion `-NWTime` pins: seconds since the lens (or the agent) opened.
    /// (Not room-workflows-live or -many: those run on the real clock.)
    static func workflow(_ screen: String) -> Bool {
        (screen.hasPrefix("room-workflows") && screen != "room-workflows-live" && screen != "room-workflows-many") || screen == "room-agent"
    }

    /// The Now screens whose In flight motion `-NWTime` pins: seconds since the section appeared.
    /// (The sky stays at 3 s, so only In flight moves. Not motion-inflight-live: it runs on the real clock.)
    static func inflight(_ screen: String) -> Bool { screen.hasPrefix("motion-inflight") && screen != "motion-inflight-live" }

    /// The Now screens whose whole motion (the Runway, the Horizon's words, the badges, the chips, Settled and
    /// In flight) `-NWTime` pins: seconds since Now appeared. (The sky stays at 3 s. Not motion-now-live(-low): they run on the real clock.)
    static func nowMotion(_ screen: String) -> Bool { screen.hasPrefix("motion-now-") && !screen.hasPrefix("motion-now-live") }

    /// Which motion the pinned time belongs to.
    static func pin(_ args: RenderArguments) -> NWMotionPin? {
        let t = time(args)
        switch args.screen {
        case "motion-approach": return NWMotionPin(kind: .approach, time: t)
        case "motion-pulse-exhale": return NWMotionPin(kind: .exhale, time: t)
        case "motion-hold-burst": return NWMotionPin(kind: .hold, time: t)
        case "motion-dusk", "motion-dusk-now": return NWMotionPin(kind: .dusk, time: t)
        case "motion-dawn", "motion-dawn-now": return NWMotionPin(kind: .dawn, time: t)
        case "motion-brief": return NWMotionPin(kind: .brief, time: t)
        case _ where workflow(args.screen): return NWMotionPin(kind: .workflow, time: t)
        case _ where inflight(args.screen): return NWMotionPin(kind: .inflight, time: t)
        case _ where nowMotion(args.screen): return NWMotionPin(kind: .now, time: t)
        default: return nil
        }
    }
}

/// A motion screen.
struct HarnessMotion: View {
    let screen: String
    let time: Double
    @Environment(\.nwDaypart) private var daypart

    private var now: Date { RenderHarness.now }

    var body: some View {
        switch screen {
        case _ where screen.hasPrefix("motion-pulse"), "motion-approach", "motion-dusk-now", "motion-dawn-now":
            MotionShell(data: nowData, destination: .now)
        case "motion-brief":
            // The Brief card itself, at the top where the eye lands (it sits below the fold in Now).
            VStack {
                // A productive night (six turns finished), so the sunrise is at its brightest.
                NWBriefCard(brief: ReturnBrief.build(since: now.addingTimeInterval(-18 * 3600), now: now, history: RenderFixtures.history,
                                                     open: [], sessions: RenderFixtures.sessions, hasSessionList: true,
                                                     status: RenderFixtures.status, timeZone: RenderHarness.timeZone),
                            expanded: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NightWatch.Space.gutter)
            .padding(.top, 64)
        case _ where screen.hasPrefix("motion-receipt") && screen != "motion-receipt-sheet":
            MotionShell(data: receiptData, destination: .now)
        case "motion-receipt-sheet":
            decision
        case "motion-hold", "motion-hold-burst":
            hold
        case "motion-dusk", "motion-dawn":
            MotionShell(data: RenderFixtures.nowData("now"), destination: .lanes, lanes: lanesData)
        case _ where RenderHarnessMotion.inflight(screen):
            MotionShell(data: flightData, destination: .now)
                .environment(\.nwFlightScript, flightScript)
        case "motion-inflight-live":
            // On the real clock, as the live app draws it: the 1/4 line ends done 2 s after Now appears.
            FlightLive(data: flightData, stages: [flightSection(stage: 0), flightSection(stage: 1)])
        case _ where RenderHarnessMotion.nowMotion(screen):
            MotionShell(data: nowStage(nowChanges && time >= 2 ? 1 : 0), destination: .now)
                .environment(\.nwNowScript, nowScript)
                .environment(\.nwFlightScript, nowFlightScript)
        case "motion-now-live":
            // On the real clock: -change's look, changing 2 s after Now appears (the numbers roll, the badge bumps).
            NowLive(stages: [nowStage(0), nowStage(1)])
        case "motion-now-live-low":
            // On the real clock, framed on Settled: a reply on its way comes, changes its word and goes, 2 s apart.
            NowLive(stages: (0...3).map(queuedStage))
        default:
            Text("Unknown motion \(screen)").foregroundColor(.white)
        }
    }

    // MARK: Now

    private func model(open: [Intervention], sessions: [LiveSession], onAC: Bool = true, paused: Bool = false) -> NowModel {
        var st = RenderFixtures.status
        st.onAC = onAC
        if onAC { st.forecast = nil }
        st.working = sessions.filter { $0.state == .active }.count
        return NowModel.build(RenderFixtures.inputs(open: open, status: st, sessions: sessions))
    }

    private var nowData: NowScreenData {
        let open = RenderFixtures.open
        let all = RenderFixtures.sessions
        let idle = all.map { $0.state == .active || $0.state == .waitingOnApproval ? $0.with(state: .idle) : $0 }
        let working = all.filter { $0.state != .waitingOnApproval }
        var d = RenderFixtures.nowData("now")
        switch screen {
        case "motion-pulse-quiet": d.model = model(open: [], sessions: idle)
        case "motion-pulse-working", "motion-pulse-exhale", "motion-dawn-now": d.model = model(open: [], sessions: working)
        case "motion-pulse-waiting1": d.model = model(open: [open[0]], sessions: working)
        case "motion-pulse-waiting3":
            // Three decisions (the stock fixture's third page is a Look), so the headline
            // says "3 need you" over the three rings the pulse draws for them.
            let third = RenderFixtures.iv("p5", "sate-t", .approval, "[Bash] pio run -t upload\nFlash the board", ago: 90, session: "w2")
            d.model = model(open: [open[0], open[1], third], sessions: working)
        case "motion-dusk-now": d = RenderFixtures.nowData("now-dusk")
        case "motion-brief": d = RenderFixtures.nowData("now-brief-quiet")
        case "motion-approach": d.pinnedArrival = "p1"
        default: break
        }
        if d.model.rows.isEmpty { d.inFlight = .empty }
        return d
    }

    /// The Undoable row with an action under way, at the receipt stage named.
    private var receiptData: NowScreenData {
        var d = RenderFixtures.nowData("now")
        guard let row = d.model.rows.first(where: { $0.chip == .undoable }) else { return d }
        let id = row.id
        var input = ReceiptThreadInput(pending: nil, delivery: nil)
        switch screen {
        case "motion-receipt-arm":
            let p = PendingAction(rowId: id, kind: .approve, text: "", commit: row.commit, startedAt: now.addingTimeInterval(-time), armed: true,
                                  preview: row.action(.approve)?.preview)
            input.pending = p
            d.pending[id] = p
        case "motion-receipt-sending":
            input.delivery = .sending; input.changedAt = now.addingTimeInterval(-time)
        case "motion-receipt-sent":
            input.delivery = .sent(queued: false, at: now.addingTimeInterval(-time)); input.changedAt = now.addingTimeInterval(-time)
        case "motion-receipt-typed", "motion-receipt-verified", "motion-receipt-fold":
            input.delivery = .delivered(detail: "Typed into cmux › page"); input.changedAt = now.addingTimeInterval(-time)
            if screen == "motion-receipt-fold" { d.ghosts = [id] }
        case "motion-receipt-failed":
            input.delivery = .failed("Prompt changed before your answer · Review again"); input.changedAt = now.addingTimeInterval(-time)
        default: break
        }
        d.receipts[id] = input
        d.outcomes[id] = CardOutcome.from(pending: input.pending, delivery: input.delivery, now: now)
        d.scrollTo = id
        return d
    }

    // MARK: In flight

    /// The In flight screens: a waiting page above; "page" (w1) running two
    /// workflows and "sate-t" (w2) on a long command, as the Mac's list sends
    /// them; at 2.0 s the change each screen is about. Scrolled so the
    /// section is at the top. Every screen but -enter opens with the
    /// entrance long played, so the change is the only thing that moves.
    private var flightData: NowScreenData {
        if screen == "motion-inflight-quiet" { return RenderFixtures.nowData("now-still") }
        var d = RenderFixtures.nowData("now-flight")
        d.model = model(open: [RenderFixtures.open[0]], sessions: flightSessions(stage: 0))
        d.inFlight = flightScript.flatMap { NowMotion.replay($0, until: time)?.section } ?? flightSection(stage: 0)
        d.scrollTo = nil
        d.scrollToId = HeaderJump.sectionId
        return d
    }

    private var flightScript: NowMotion.FlightScript? {
        guard RenderHarnessMotion.inflight(screen), screen != "motion-inflight-quiet" else { return nil }
        let still = screen == "motion-inflight-enter" || screen == "motion-inflight-stuck"
        let steps = [NowMotion.FlightStep(at: 0, section: flightSection(stage: 0))] + (still ? [] : [NowMotion.FlightStep(at: 2, section: flightSection(stage: 1))])
        return NowMotion.FlightScript(base: now.timeIntervalSinceReferenceDate, steps: steps, entered: screen != "motion-inflight-enter")
    }

    private func flightSection(stage: Int) -> InFlightSection {
        InFlightSection.build(sessions: flightSessions(stage: stage), hasSessionList: true, workflows: flightRuns(stage: stage), now: now)
    }

    /// -complete: the watched session's full runs, which say how a run ended (the list only lists running ones).
    private func flightRuns(stage: Int) -> [String: [WorkflowRun]] {
        guard screen == "motion-inflight-complete" || screen == "motion-inflight-live" else { return [:] }
        let ended = stage > 0
        return ["w1": [WorkflowRun(id: "wf_review", name: "Review changes", status: "running", phase: "Reviewing", done: 3, total: 5,
                                   startedAt: now.addingTimeInterval(-600)),
                       WorkflowRun(id: "wf_docs", name: "Docs sweep", status: ended ? "completed" : "running", phase: "Writing",
                                   done: ended ? 4 : 1, total: 4, startedAt: now.addingTimeInterval(-420), endedAt: ended ? now.addingTimeInterval(2) : nil)]]
    }

    /// The fixture's sessions at stage 0 (the opening) or 1 (from 2.0 s).
    private func flightSessions(stage: Int) -> [LiveSession] {
        let later = stage > 0
        let stuck = screen == "motion-inflight-stuck"
        return ["sess-p1", "w1", "w2"].compactMap { id in RenderFixtures.sessions.first { $0.id == id } }.map { s in
            var s = s
            switch s.id {
            case "w1":
                let advance = later && screen == "motion-inflight-advance"
                var flows = [WorkflowBrief(name: "Review changes", phase: "Reviewing", done: advance ? 4 : 3, total: 5),
                             WorkflowBrief(name: "Docs sweep", phase: "Writing", done: 1, total: 4)]
                // -vanish: the second line is simply no longer listed (no status): it leaves without a word.
                if later && screen == "motion-inflight-vanish" { flows.removeLast() }
                s.flight = SessionFlight.make(
                    busySince: now.addingTimeInterval(-12 * 60), startedAt: now.addingTimeInterval(-(2 * 3600 + 10 * 60)), model: "Opus 4.7",
                    recentSteps: advance ? ["Editing SessionRoom.swift", "Running swift build", "Running swift test"]
                        : ["Reading Session.swift", "Editing SessionRoom.swift", "Running swift build"],
                    health: stuck ? "rateLimited" : nil, healthNote: nil, workflows: flows, workflowsRunning: flows.count,
                    resetsAt: stuck ? now.addingTimeInterval(48 * 60) : nil)
            case "w2":
                s.flight = SessionFlight.make(
                    busySince: now.addingTimeInterval(-41 * 60), startedAt: now.addingTimeInterval(-5 * 3600), model: "Sonnet 4.5",
                    recentSteps: ["Reading platformio.ini", "Running pio run", "Running pio test"],
                    health: stuck ? "stuck" : "longRunning", healthNote: stuck ? "the same test failed 6 times" : nil,
                    workflows: stuck ? [WorkflowBrief(name: "Fix tests", phase: "Fixing", done: 2, total: 6)] : [],
                    workflowsRunning: stuck ? 1 : nil, stepSince: now.addingTimeInterval(-4 * 60))
            default: break
            }
            return s
        }
    }

    // MARK: The rest of Now

    /// The rest of Now's screens, staged on "page" (w1, two workflows) and
    /// "llm-play" (stuck) working, as now-flight is. -enter: Now's first
    /// appearance this app process, one decision and one finished turn (the
    /// Runway draws in, In flight rises and sweeps, the chips count up).
    /// -change: two decisions; at 2.0 s a third arrives (the headline's
    /// count and the Now badge go 2 → 3), a receipt lands in Settled and the
    /// battery forecast moves the cutoff marker 30 min nearer. -runway: at
    /// 2.0 s the 5-hour reset reaches now and the next one comes into the six
    /// hours. -quiet: nothing running, nothing changing. "-low" frames Review
    /// (-enter) or Settled (-change) instead of the top.
    private var nowChanges: Bool { screen.hasPrefix("motion-now-change") || screen == "motion-now-runway" || screen == "motion-now-live" }

    private func nowStage(_ stage: Int) -> NowScreenData {
        if screen == "motion-now-quiet" { return RenderFixtures.nowData("now-still") }
        let later = stage > 0
        let runway = screen == "motion-now-runway"
        let arrives = later && nowChanges && !runway
        var open = screen.hasPrefix("motion-now-enter") ? [RenderFixtures.open[1], RenderFixtures.open[3]] : [RenderFixtures.open[0], RenderFixtures.open[1]]
        if arrives { open.append(RenderFixtures.iv("p6", "page", .approval, "[Bash] swift build", ago: 2)) }
        var st = RenderFixtures.status
        if runway {
            st.usage = MacUsage(fiveHour: .init(pct: later ? 0 : 99, resetsAt: now.addingTimeInterval(later ? 5 * 3600 : 1)),
                                sevenDay: st.usage?.sevenDay, hitAt: nil, updatedAt: now)
        } else if arrives {
            st.forecast = MacBatteryForecast(cutoff: 10, minutes: 118, drainPerHour: 12)
        }
        var history = RenderFixtures.history
        if arrives {
            var h = RenderFixtures.iv("h0", "page", .approval, "[Bash] git push\nPush the branch", ago: 30)
            h.closedAt = now.addingTimeInterval(-2); h.repliedAt = now.addingTimeInterval(-2)
            h.repliedAction = "approve"; h.deliveryStatus = "delivered"; h.closeReason = "replied"
            history.insert(h, at: 0)
        }
        let sessions = RenderFixtures.nowSessions("now-flight")
        var inputs = RenderFixtures.inputs(open: open, status: st, sessions: sessions)
        inputs.history = history
        var d = NowScreenData(model: NowModel.build(inputs),
                              log: SettledLog.build(history: history, now: now, calendar: RenderHarness.calendar, timeZone: RenderHarness.timeZone),
                              chip: MacChipModel.build(macName: RenderFixtures.mac, status: st, now: now), now: now)
        d.inFlight = InFlightSection.build(sessions: sessions, hasSessionList: true, now: now)
        if screen == "motion-now-enter-low" { d.scrollToId = "section-review" }
        if screen == "motion-now-change-low" { d.scrollToId = "section-settled" }
        return d
    }

    /// motion-now-live-low, framed on Settled: nothing on its way (0); at 2 s a reply approved a moment ago
    /// is held on the Mac until a limit resets, with its Delete, and lands in Settled (1); at 4 s it has been
    /// typed (2); at 6 s its line has gone (3).
    private func queuedStage(_ stage: Int) -> NowScreenData {
        let sessions = RenderFixtures.nowSessions("now-flight")
        var history = RenderFixtures.history
        var deliveries: [String: ReplyDelivery] = [:]
        if stage >= 1 {
            var q = RenderFixtures.iv("q1", "page", .approval, "[Bash] npm run deploy\nDeploy the preview", ago: 40, session: "w1")
            q.closedAt = now.addingTimeInterval(-3); q.repliedAt = now.addingTimeInterval(-3)
            q.repliedAction = "approve"; q.deliveryStatus = stage >= 2 ? "delivered" : "pending"; q.closeReason = "replied"
            history.insert(q, at: 0)
        }
        if stage == 1 { deliveries["q1"] = .heldOnMac(detail: nil) }
        if stage == 2 { deliveries["q1"] = .delivered(detail: nil) }
        var inputs = RenderFixtures.inputs(open: [RenderFixtures.open[0], RenderFixtures.open[1]], sessions: sessions)
        inputs.history = history
        inputs.deliveries = deliveries
        inputs.macCaps = [SendChoicePlan.retractCap]
        var d = NowScreenData(model: NowModel.build(inputs),
                              log: SettledLog.build(history: history, now: now, calendar: RenderHarness.calendar, timeZone: RenderHarness.timeZone),
                              chip: MacChipModel.build(macName: RenderFixtures.mac, status: RenderFixtures.status, now: now), now: now)
        d.inFlight = InFlightSection.build(sessions: sessions, hasSessionList: true, now: now)
        d.scrollToId = "section-settled"
        return d
    }

    private var nowScript: NowMotion.NowScript? {
        let steps = [NowMotion.NowStep(at: 0, look: nowStage(0).look)] + (nowChanges ? [NowMotion.NowStep(at: 2, look: nowStage(1).look)] : [])
        return NowMotion.NowScript(base: now.timeIntervalSinceReferenceDate, steps: steps, entered: !screen.hasPrefix("motion-now-enter"))
    }

    /// In flight under Now's pin: it enters with Now on -enter, and has long since everywhere else.
    private var nowFlightScript: NowMotion.FlightScript? {
        NowMotion.FlightScript(base: now.timeIntervalSinceReferenceDate, steps: [NowMotion.FlightStep(at: 0, section: nowStage(0).inFlight)],
                               entered: !screen.hasPrefix("motion-now-enter"))
    }

    // MARK: Lanes

    private var lanesData: LanesScreenData {
        let dawn = screen == "motion-dawn"
        var sessions = RenderFixtures.sessions
        // Who has been seen working again since power came back, in order.
        let resumes: [(String, TimeInterval)] = [("w1", 0.3), ("w5", 0.5), ("w2", 1.1)]
        if dawn {
            // The rest have not confirmed a resume yet: they stay dim, and say so by being idle.
            let back = Set(resumes.map(\.0))
            sessions = sessions.map { $0.state == .active && !back.contains($0.id) ? $0.with(state: .idle) : $0 }
        }
        let sky = RenderFixtures.sky(sessions: sessions, paused: !dawn)
        var d = LanesScreenData(fleet: sky, lanes: LanesModel.build(sky: sky, log: RenderFixtures.activity, now: now), now: now)
        var log = DuskDawnLog()
        let active = Set(RenderFixtures.sessions.filter { $0.state == .active }.map(\.id))
        log.observe(paused: false, working: active, at: now.addingTimeInterval(-900))
        if dawn {
            log.observe(paused: true, working: [], at: now.addingTimeInterval(-600))
            log.observe(paused: false, working: [], at: now)
            var back = Set<String>()
            for (id, at) in resumes { back.insert(id); log.observe(paused: false, working: back, at: now.addingTimeInterval(at)) }
        } else {
            log.observe(paused: true, working: active, at: now)
        }
        d.duskDawn = log
        d.daypart = daypart
        return d
    }

    // MARK: Hold ring

    /// The hold ring and the controls round it, as the Decision sheet draws
    /// them, centred (a short simulator screen cuts the sheet's bottom off).
    private var hold: some View {
        let p = screen == "motion-hold-burst" ? 1 : HoldRingSpec.irreversible.progress(elapsed: time)
        return VStack(spacing: 14) {
            NWDeliveryPreview(text: "Will type 1 · cmux › builds · Studio MBP")
            NWHoldRing(spec: .irreversible, fixedProgress: p, onComplete: {})
            Text(screen == "motion-hold-burst" ? "Approved with Face ID" : HoldRingSpec.prompt(progress: p, biometry: "Face ID"))
                .font(NightWatch.Typo.bodyStrong)
                .foregroundColor((screen == "motion-hold-burst" ? NightWatch.Palette.textSecondary : NightWatch.Palette.red.mixed(with: .init(1, 1, 1), 0.35)).color)
            HStack(spacing: 10) {
                Button("Deny") {}.buttonStyle(NWButtonStyle(kind: .quiet))
                Button("Tell it instead…") {}.buttonStyle(NWButtonStyle(kind: .quiet))
            }
        }
        .padding(20)
        .background(NWDecisionBackground(tint: NightWatch.Palette.red))
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
    }

    // MARK: Decision sheet

    private var decision: some View {
        var d = RenderFixtures.decision(screen == "motion-receipt-sheet" ? "decision-considered" : "decision-irreversible")
        switch screen {
        case "motion-hold": d.state.fixedHold = HoldRingSpec.irreversible.progress(elapsed: time)
        case "motion-hold-burst": d.state.fixedHold = 1
        case "motion-receipt-sheet":
            d.state.phase = .delivered("typed into cmux › page")
            d.state.receipt = ReceiptThreadInput(pending: nil, delivery: .delivered(detail: "typed into cmux › page"),
                                                 changedAt: now.addingTimeInterval(-time))
        default: break
        }
        return VStack(spacing: 0) {
            NWHorizon(palette: .needsYou, pulse: .needsYou, headline: "", subline: "", height: 230, topInset: 0).opacity(0.5)
            Spacer(minLength: 0)
            NWDecisionScreen(state: d.state, draft: .constant(""), composerOpen: .constant(false))
                .background(NWDecisionBackground(tint: d.state.row.tint))
                .frame(maxHeight: 650)
        }
        .ignoresSafeArea()
    }
}

private extension LiveSession {
    /// The same session in another state (fixtures only).
    func with(state: LiveSessionState) -> LiveSession {
        LiveSession(id: id, backend: backend, title: title, cwd: cwd, state: state, host: host, canType: canType, typeBlocker: typeBlocker,
                    canInterrupt: canInterrupt, provider: provider, lastActivityAt: lastActivityAt, interventionId: interventionId, preview: preview)
    }
}

/// motion-inflight-live: Now unpinned, on the display clock, with the
/// container's grace (`NowMotion.FlightGrace`) as `NowContainer` keeps it,
/// so the live path (the clocks, the book, the provisional closing line)
/// can be checked with a few screenshots of one launch.
private struct FlightLive: View {
    let data: NowScreenData
    let stages: [InFlightSection]
    @State private var stage = 0
    @State private var grace = NowMotion.FlightGrace()
    @State private var tick = 0

    var body: some View {
        let _ = tick
        let section = stages[stage]
        var d = data
        d.inFlight = grace.merged(section, now: Date())
        return MotionShell(data: d, destination: .now)
            .environment(\.nwFixedPhase, nil)
            .environment(\.nwMotion, nil)
            .onAppear { grace.observe(section, at: Date(), silent: true) }
            .onChange(of: stage) { _, s in grace.observe(stages[s], at: Date()) }
            .task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                stage = 1
                try? await Task.sleep(nanoseconds: UInt64((NowMotion.grace + 0.1) * 1_000_000_000))
                tick += 1
            }
    }
}

/// motion-now-live(-low): Now unpinned, on the display clock, moving to
/// its next look every 2 s after it appears, so what the harness cannot pin
/// (the numbers rolling, what is queued coming and going) can be checked
/// in a recording of one launch.
private struct NowLive: View {
    let stages: [NowScreenData]
    @State private var stage = 0

    var body: some View {
        MotionShell(data: stages[stage], destination: .now)
            .environment(\.nwFixedPhase, nil)
            .environment(\.nwMotion, nil)
            .task {
                for s in stages.indices.dropFirst() {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    stage = s
                }
            }
    }
}

/// The real shell around a motion screen.
private struct MotionShell: View {
    let data: NowScreenData
    @State var destination: NWDestination
    var lanes: LanesScreenData? = nil
    @State private var held: TimeInterval?

    init(data: NowScreenData, destination: NWDestination, lanes: LanesScreenData? = nil) {
        self.data = data
        _destination = State(initialValue: destination)
        self.lanes = lanes
    }

    var body: some View {
        let plan = StopPlan.build(sessions: RenderFixtures.sessions, hasSessionList: true, macName: RenderFixtures.mac)
        NWShell(destination: $destination, decideCount: data.model.needYouCount, workingCount: data.model.workingCount,
                pulseWaiting: data.model.pulseWaiting,
                pulseLongestWait: PulseModel.longestWait(since: data.model.pulseRows.map(\.waitingSince), now: data.now), stopPlan: plan,
                biometry: "Face ID", held: $held) {
            NWNowScreen(data: data)
        } lanes: {
            if let lanes { NWLanesScreen(data: lanes) }
        }
        .environment(\.nwTopInset, 54)
    }
}
#endif
