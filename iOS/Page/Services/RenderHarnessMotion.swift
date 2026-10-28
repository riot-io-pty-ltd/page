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
        default: return 3
        }
    }

    static func time(_ args: RenderArguments) -> Double { args.time ?? defaultTime(args.screen) }

    /// The aurora's and the pulse's clock: the pinned time for a motion
    /// screen (so its ripples sit where the board's do), 3 s otherwise. The
    /// Workflows lens's frames keep the room's sky at 3 s, so only the lens moves.
    static func phase(_ args: RenderArguments) -> Double {
        if workflow(args.screen) { return 3.0 }
        return args.screen.hasPrefix("motion-") ? time(args) : (args.time ?? 3.0)
    }

    /// The room screens whose workflow motion `-NWTime` pins: seconds since the lens (or the agent) opened.
    /// (Not room-workflows-live or -many: those run on the real clock.)
    static func workflow(_ screen: String) -> Bool {
        (screen.hasPrefix("room-workflows") && screen != "room-workflows-live" && screen != "room-workflows-many") || screen == "room-agent"
    }

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
