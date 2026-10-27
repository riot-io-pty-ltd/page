#if DEBUG
import SwiftUI

/// The DEBUG render harness: `-NWRender <screen>` (and optionally
/// `-NWGlow off|subtle|full`) shows one Night Watch screen on in-memory
/// fixtures, so screenshots can be taken with `xcrun simctl io <udid>
/// screenshot`. It builds its own fixtures and touches nothing else: no
/// Keychain, no network, no push registration, no shared stores (the live
/// stores are only created by `LiveApp`, which is not built in this mode),
/// and the glow override lives in memory only. The screens are the very views
/// the live app uses (`NWShell`, `NWNowScreen`, `NWSkyScreen`, ...), fed
/// fixtures instead of the stores.
enum RenderHarness {
    /// Every screen name, in the order the render script captures them.
    static let screens = [
        "now", "now-quiet", "now-working", "now-dusk", "now-brief", "now-brief-quiet", "now-arming", "now-swipe",
        "now-receipt", "now-banner", "now-new",
        "now-inflight", "now-inflight-long", "now-tip-undoable", "now-tip-irreversible", "now-tip-inflight",
        "now-flight", "now-flight-two", "now-flight-old", "now-flight-header", "now-flight-jump", "now-flight-quiet",
        "decision-irreversible", "decision-hold", "decision-considered", "decision-undoable", "decision-question", "decision-stuck",
        "decision-review", "decision-plan", "decision-standing", "decision-unknown", "decision-composer", "decision-delivered",
        "decision-failed", "decision-tip",
        "hold-stop", "stop-confirm", "stop-result", "stop-none",
        "sky", "sky-selected", "sky-crowded", "sky-empty", "sky-problem", "lanes", "lanes-standby",
        "tower", "tower-budget", "tower-glow", "tower-terminals", "tower-gestures",
        "dispatch", "dispatch-sending", "dispatch-off",
        "runway", "settled", "gallery", "glow-compare",
        "room-story", "room-screen", "room-changes", "room-workflows", "room-waiting", "room-codex", "room-local", "room-agent",
        "room-ended", "room-blocked", "room-stop", "room-draft", "room-receipt", "room-receipt-refused",
        "welcome", "welcome-notice", "scan", "scan-hint", "pair-checking", "pair-confirm", "pair-problem", "paired", "paired-denied",
        "problem-asleep", "problem-gone", "problem-stale", "problem-relay", "problem-pairing",
        "widgets",
    ] + RenderHarnessAnswers.screens + RenderHarnessMotion.screens + RenderHarnessHistory.screens

    /// The clock the fixtures pretend it is: Tue 27 Oct 2026, 01:12 UTC.
    static let now = Date(timeIntervalSince1970: 1_793_063_520)
    static let timeZone = TimeZone(identifier: "UTC")!
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }
}

/// Fixtures in the real wire shape: a page's `context` is what the Mac's
/// `describeToolUse` writes ("[Bash] command" then a description line).
enum RenderFixtures {
    static let mac = "Studio MBP"
    static let now = RenderHarness.now

    static func iv(_ id: String, _ project: String, _ kind: InterventionKind, _ ctx: String, ago: TimeInterval,
                   sub: String? = nil, backend: InterventionBackend = .claude, session: String? = nil) -> Intervention {
        Intervention(id: id, sessionId: session ?? "sess-\(id)", cwd: "/Users/you/projects/\(project)", projectName: project, kind: kind,
                     openedAt: now.addingTimeInterval(-ago), context: ctx, backend: backend,
                     source: .terminal, subtype: sub)
    }

    static var open: [Intervention] {
        [iv("p1", "bottle-flip", .approval, "[Bash] rm -rf Builds/Dev/*.app\nDelete every Dev build", ago: 240),
         // A bare command: the Mac cannot tell a description line from more command,
         // so a page that carries one is Considered. This one is the swipe-to-run row.
         iv("p2", "page", .approval, "[Bash] swift test --filter StuckTests", ago: 40),
         iv("p3", "llm-play", .idle, "Looks stuck in a loop: this has failed 6 times.\ncargo test", ago: 800, sub: "looping"),
         iv("p4", "mac-on-claude-code", .idle, "Changed 3 files (+120 −14) · tests passed\n\nAll done.", ago: 120)]
    }

    /// One page per Decision sheet variant.
    static func page(_ screen: String) -> Intervention {
        switch screen {
        case "decision-considered":
            return iv("c1", "page", .approval, "[Edit] /Users/you/projects/page/Sources/Relay/Router.swift\nRoute replies through the planner", ago: 95)
        case "decision-question":
            return iv("q1", "page", .userInput, "Which branch should I base this on: main or feat/relay-v2?", ago: 70)
        case "decision-plan":
            return iv("pl1", "page", .approval, "Plan ready for review\n1. Migrate the relay to v2\n2. Update the Worker routes\n3. Add the migration tests", ago: 130, sub: "plan")
        case "decision-standing":
            return iv("s1", "page", .approval, "[Bash] npm install\nInstall the packages\n1. Yes\n2. Yes, and don't ask again for npm commands in this project\n3. No, and tell Claude what to do differently", ago: 50)
        case "decision-unknown":
            var x = iv("u1", "payments-api", .approval, "Run the migration?", ago: 33)
            x.backend = nil
            x.backendRaw = "gemini"
            return x
        case "decision-stuck":
            return open[2]
        case "decision-review":
            return open[3]
        case "decision-undoable":
            return open[1]
        default:
            return open[0]
        }
    }

    private static func s(_ id: String, _ title: String, _ project: String, _ state: LiveSessionState, host: String = "cmux",
                          ago: TimeInterval, preview: String = "", iv: String? = nil, canType: Bool = true) -> LiveSession {
        LiveSession(id: id, backend: AgentBackend(wire: "claude"), title: title, cwd: "~/projects/\(project)", state: state,
                    host: host, canType: canType, typeBlocker: nil, canInterrupt: true, provider: "anthropic",
                    lastActivityAt: now.addingTimeInterval(-ago), interventionId: iv, preview: preview)
    }

    static var sessions: [LiveSession] {
        return [
            s("sess-p1", "builds", "bottle-flip", .waitingOnApproval, ago: 240, preview: "rm -rf Builds/Dev/*.app", iv: "p1"),
            s("sess-p2", "SessionsView", "page", .waitingOnApproval, ago: 40, preview: "swift test", iv: "p2"),
            s("sess-p3", "tokenizer", "llm-play", .active, ago: 700, preview: "cargo test ×6"),
            s("sess-p4", "docs", "mac-on-claude-code", .idle, ago: 120),
            s("w1", "relay", "page", .active, host: "tmux", ago: 9, preview: "[Bash] vitest · 212 passed"),
            s("w2", "pio run", "sate-t", .active, ago: 20, preview: "pio run"),
            s("w3", "flash", "sate-t", .active, host: "tmux", ago: 70, preview: "esptool write"),
            s("w4", "charges", "payments-api", .idle, ago: 3_000),
            s("w5", "web", "bottle-flip", .active, host: "Ghostty", ago: 31, preview: "npm run build"),
        ]
    }

    /// A full sky: 17 sessions over 11 projects, long names, several that need you, one stuck.
    /// The sky must label every constellation without a label touching another label or a star.
    static var crowdedSessions: [LiveSession] {
        sessions + [
            s("c1", "deploy", "relay-worker-edge-router-service", .waitingOnApproval, ago: 90, preview: "wrangler deploy --env production"),
            s("c2", "tests", "relay-worker-edge-router-service", .active, ago: 12, preview: "vitest"),
            s("c3", "audit", "a-very-long-project-name-for-the-fleet-dashboard", .active, ago: 25, preview: "npm audit"),
            s("c4", "migrate", "a-very-long-project-name-for-the-fleet-dashboard", .waitingOnApproval, ago: 200, preview: "psql -f migrate.sql"),
            s("c5", "widgets", "ios-widgets", .active, ago: 40, preview: "xcodebuild"),
            s("c6", "notes", "docs-site", .idle, ago: 1_800),
            s("c7", "scratch", "x", .active, ago: 15, preview: "ls"),
            s("c8", "lint", "mac-on-claude-code", .active, ago: 8, preview: "swiftlint"),
        ]
    }

    static var status: MacStatusSnapshot {
        var st = MacStatusSnapshot(macConnected: true, lastHeartbeatAt: now, activeSessions: 9, battery: 41, onAC: false, working: 5)
        st.forecast = MacBatteryForecast(cutoff: 10, minutes: 148, drainPerHour: 12)
        st.usage = MacUsage(fiveHour: .init(pct: 62, resetsAt: now.addingTimeInterval(110 * 60)),
                            sevenDay: .init(pct: 87, resetsAt: now.addingTimeInterval(3 * 86_400)), hitAt: now.addingTimeInterval(88 * 60), updatedAt: now)
        return st
    }

    static var history: [Intervention] {
        func done(_ id: String, _ kind: InterventionKind, _ ctx: String, action: String?, text: String? = nil, ago: TimeInterval,
                  sub: String? = nil, delivered: Bool = true) -> Intervention {
            var x = iv(id, "page", kind, ctx, ago: ago + 60, sub: sub)
            x.closedAt = now.addingTimeInterval(-ago)
            if let action {
                x.repliedAt = now.addingTimeInterval(-ago)
                x.repliedAction = action
                x.repliedText = text
                x.deliveryStatus = delivered ? "delivered" : "pending"
                x.closeReason = "replied"
            }
            return x
        }
        let day = 86_400.0 * 0.5  // yesterday afternoon, clear of midnight
        var list = [
            done("h1", .approval, "[Bash] npm test\nRun the tests", action: "approve", ago: 12 * 60),
            done("h2", .userInput, "Should I use the cache?", action: "custom", text: "use the cache", ago: 31 * 60),
        ]
        // Yesterday: a headline card.
        for i in 0..<14 { list.append(done("y\(i)", .approval, "[Bash] ls\nList", action: "approve", ago: day + Double(i) * 600)) }
        for i in 0..<6 { list.append(done("f\(i)", .idle, "Changed 2 files (+10 −2) · tests passed\n\nDone", action: nil, ago: day + 9_000 + Double(i) * 700)) }
        for i in 0..<2 { list.append(done("s\(i)", .idle, "No progress for 15 min", action: nil, ago: day + 20_000 + Double(i) * 300, sub: "stuck")) }
        list.append(done("b0", .idle, "Paused for battery", action: nil, ago: day + 30_000, sub: "low_battery"))
        return list
    }

    static func inputs(open: [Intervention] = RenderFixtures.open, status: MacStatusSnapshot? = RenderFixtures.status,
                       sessions: [LiveSession] = RenderFixtures.sessions) -> NowInputs {
        NowInputs(interventions: open, inbox: .loaded, sessions: sessions, hasSessionList: !sessions.isEmpty, status: status,
                  history: history, deliveries: ["h1": .delivered(detail: nil)], now: now, macName: mac,
                  timeZone: RenderHarness.timeZone, calendar: RenderHarness.calendar)
    }

    /// The sessions a Now screen shows. The In flight and tip screens are staged by hand: one waiting page and
    /// two working sessions, a long list, or exactly the one thing a tip is about.
    static func nowSessions(_ screen: String) -> [LiveSession] {
        func pick(_ ids: [String], from all: [LiveSession]) -> [LiveSession] { ids.compactMap { id in all.first { $0.id == id } } }
        switch screen {
        case "now-flight", "now-flight-two", "now-flight-header", "now-flight-jump":
            return pick(["sess-p1", "w1", "sess-p3"], from: sessionsWithFlight)
        case "now-flight-old": return pick(["sess-p1", "w1", "sess-p3"], from: sessions)
        case "now-flight-quiet": return pick(["w1", "sess-p3"], from: sessionsWithFlight)
        case "now-inflight", "now-tip-irreversible": return pick(["sess-p1", "w1", "w2"], from: sessions)
        case "now-inflight-long": return pick(["sess-p2", "w1", "w2", "w3", "w5", "c2", "c3", "c5", "c7"], from: crowdedSessions)
        case "now-tip-undoable": return pick(["sess-p2"], from: sessions)
        case "now-tip-inflight": return pick(["w1", "w2"], from: sessions)
        default: return sessions
        }
    }

    /// The Mac's richer list rows for the two working sessions: one with workflows, one it calls stuck.
    static var sessionsWithFlight: [LiveSession] {
        sessions.map { s in
            var s = s
            switch s.id {
            case "w1":
                s.flight = SessionFlight.make(
                    busySince: now.addingTimeInterval(-12 * 60), startedAt: now.addingTimeInterval(-(2 * 3600 + 10 * 60)), model: "Opus 4.7",
                    recentSteps: ["Reading Session.swift", "Editing SessionRoom.swift", "Running swift build"],
                    health: nil, healthNote: nil,
                    workflows: [WorkflowBrief(name: "Review changes", phase: "Reviewing", done: 3, total: 5, status: "running"),
                                WorkflowBrief(name: "Docs sweep", phase: "Writing", done: 1, total: 4, status: "running")],
                    workflowsRunning: 2)
            case "sess-p3":
                s.flight = SessionFlight.make(
                    busySince: now.addingTimeInterval(-41 * 60), startedAt: now.addingTimeInterval(-5 * 3600), model: "Sonnet 4.5",
                    recentSteps: ["Reading lib.rs", "Running cargo test", "Running cargo test"], health: "stuck", healthNote: "the same test failed 6 times",
                    workflows: [])
            default: break
            }
            return s
        }
    }

    static func model(_ screen: String) -> NowModel {
        switch screen {
        case "now-flight", "now-flight-two", "now-flight-old", "now-flight-header", "now-flight-jump":
            return NowModel.build(inputs(open: [open[0]], sessions: nowSessions(screen)))
        case "now-flight-quiet":
            var st = status; st.onAC = true; st.forecast = nil
            return NowModel.build(inputs(open: [], status: st, sessions: nowSessions(screen)))
        case "now-inflight", "now-tip-irreversible":
            return NowModel.build(inputs(open: [open[0]], sessions: nowSessions(screen)))
        case "now-inflight-long", "now-tip-undoable":
            return NowModel.build(inputs(open: [open[1]], sessions: nowSessions(screen)))
        case "now-tip-inflight":
            var st = status; st.onAC = true; st.forecast = nil
            return NowModel.build(inputs(open: [], status: st, sessions: nowSessions(screen)))
        case "now-quiet", "now-brief-quiet":
            var st = status; st.working = 0; st.forecast = nil; st.usage = nil; st.onAC = true
            return NowModel.build(inputs(open: [], status: st, sessions: sessions.filter { $0.state != .waitingOnApproval }))
        case "now-working":
            var st = status; st.onAC = true; st.forecast = nil
            return NowModel.build(inputs(open: [], status: st, sessions: sessions.filter { $0.state != .waitingOnApproval }))
        case "now-dusk":
            let paused = iv("pz", "bottle-flip", .idle, "Page paused your agents at 10% battery.", ago: 600, sub: "low_battery")
            return NowModel.build(inputs(open: [paused], status: status))
        default:
            return NowModel.build(inputs())
        }
    }

    static var log: SettledLog {
        SettledLog.build(history: history, now: now, calendar: RenderHarness.calendar, timeZone: RenderHarness.timeZone)
    }

    static func brief(urgent: Bool) -> ReturnBrief {
        ReturnBrief.build(since: now.addingTimeInterval(-(13 * 3600 + 5 * 60)), now: now, history: history, open: urgent ? open : [],
                          sessions: sessions, hasSessionList: true, status: status, timeZone: RenderHarness.timeZone)
    }

    /// Four hours of sampled lanes, as if Page had been open all night.
    static var activity: ActivityLog {
        var log = ActivityLog()
        let all = sessions
        for step in stride(from: 48, through: 0, by: -1) {
            let at = now.addingTimeInterval(-Double(step) * 300)
            var states: [String: StarState] = [:]
            for (i, s) in all.enumerated() {
                let seed = StableHash.unit(s.id, salt: step)
                switch s.state {
                case .active:
                    // Working with the odd quiet bucket; llm-play stalls near the end.
                    states[s.id] = s.id == "sess-p3" && step < 14 ? .stuck : (seed > 0.18 ? .working : .idle)
                    if step > 40 - (i % 4) * 4 { states[s.id] = nil }
                case .waitingOnApproval:
                    states[s.id] = step < 6 ? .needsYou : (seed > 0.25 ? .working : .idle)
                case .idle:
                    states[s.id] = step > 24 ? (seed > 0.4 ? .working : .idle) : .idle
                default: break
                }
            }
            log.record(states, at: at)
        }
        return log
    }

    static func sky(sessions list: [LiveSession] = sessions, paused: Bool = false) -> SkyModel {
        SkyModel.build(sessions: list, interventions: open, status: status, rings: model("now").rings, macName: mac, paused: paused, now: now)
    }

    static var macRows: [TowerMacRow] {
        let saved = [
            SavedMac(id: "m1", name: "Studio MBP", relayURL: "https://relay.example.workers.dev", token: "t1", sessionKey: nil,
                     pairedAt: Date(timeIntervalSince1970: 1_790_900_000)),
            SavedMac(id: "m2", name: "MacBook Air", relayURL: "https://relay.example.workers.dev", token: "t2", sessionKey: nil,
                     pairedAt: Date(timeIntervalSince1970: 1_791_900_000)),
        ]
        let other = WidgetStatus(macName: "MacBook Air", presence: .online, needsYou: 1, working: 2, live: 3, batteryLine: nil, usageLine: nil, fetchedAt: now)
        return TowerMacRow.build(saved: saved, activeId: "m1", activeStatus: status, others: ["m2": other], now: now, calendar: RenderHarness.calendar)
    }

    static func tower(scroll: TowerSection? = nil, glow: CardGlow) -> TowerScreenData {
        TowerScreenData(
            macName: mac, power: TowerPower.build(status: status), budget: TowerBudget.build(usage: status.usage, now: now), macs: macRows,
            macLine: "online · 9 active sessions · Battery 41%", relayHost: "relay.example.workers.dev", relayText: "Connected",
            notifications: .allowed, push: .registered, liveSessionsText: "9 live sessions · end-to-end encrypted", glow: glow,
            version: "0.1.0 (1)", now: now, timeZone: RenderHarness.timeZone, scrollTo: scroll,
            feedbackURL: URL(string: "https://github.com/riot-io-pty-ltd/page/issues"))
    }

    static var folders: [StartFolders.Folder] {
        [("page", 2), ("bottle-flip", 18), ("llm-play", 60), ("sate-t-production", 300), ("payments-api", 1_400)].map {
            StartFolders.Folder(path: "/Users/you/projects/\($0.0)", name: $0.0, lastUsedAt: now.addingTimeInterval(-Double($0.1) * 60))
        }
    }

    static func nowData(_ screen: String) -> NowScreenData {
        let m = model(screen)
        var chipStatus = status
        if screen == "now-quiet" || screen == "now-brief-quiet" || screen == "now-working" || screen == "now-flight-quiet" { chipStatus.onAC = true }
        var d = NowScreenData(model: m, log: log, chip: MacChipModel.build(macName: mac, status: chipStatus, now: now), now: now)
        d.inFlight = InFlightSection.build(sessions: nowSessions(screen), hasSessionList: true, now: now)
        // Only the tip screens show a tip, and the real picker chooses it: a fresh phone, the rows as staged.
        if screen.hasPrefix("now-tip") {
            d.tip = TipBook().nowTip(NowTipInputs(rows: m.rows.map { ($0.id, $0.chip) }, inFlight: d.inFlight.rows.map(\.id)))
            // Frame the row the tip points at, with the tip under it.
            if let t = d.tip { d.scrollTo = t.tip == .inFlight ? "inflight-\(t.anchorId)" : t.anchorId }
        }
        if screen == "now-inflight" { d.scrollTo = "inflight-w1" }
        if ["now-flight", "now-flight-old", "now-flight-jump"].contains(screen) { d.scrollToId = HeaderJump.sectionId }
        if screen == "now-flight-two" { d.scrollTo = "inflight-sess-p3" }
        if screen == "now-inflight-long", let last = d.inFlight.rows.last { d.scrollTo = "inflight-\(last.id)" }
        if screen == "now-brief" { d.brief = brief(urgent: true); d.briefExpanded = false }
        if screen == "now-brief-quiet" { d.brief = brief(urgent: false); d.briefExpanded = true }
        if screen == "now-arming" {
            let rows = m.rows
            if let r = rows.first(where: { $0.chip == .considered || $0.chip == .undoable }) {
                d.pending[r.id] = PendingAction(rowId: r.id, kind: .approve, text: "", commit: r.commit, startedAt: now.addingTimeInterval(-0.5), armed: true,
                                                 preview: r.action(.approve)?.preview)
                d.outcomes[r.id] = .arming(progress: 0.4)
            }
        }
        if screen == "now-swipe" {
            d.fixedDrag = 84
            d.scrollTo = m.rows.first(where: { $0.chip == .undoable })?.id
        }
        if screen == "now-arming" { d.scrollTo = m.rows.first(where: { $0.chip == .considered || $0.chip == .undoable })?.id }
        if screen == "now-receipt" {
            if let r = m.rows.first(where: { $0.chip == .undoable }) { d.outcomes[r.id] = .delivered("typed into cmux › page") }
            if let r = m.rows.first(where: { $0.section == .review }) { d.outcomes[r.id] = .problem("Didn't confirm in time · Check on Mac") }
            d.scrollTo = m.rows.first(where: { $0.chip == .undoable })?.id
        }
        if screen == "now-banner" {
            d.banners = NowBanner.build(.init(authRejected: false, inboxFailure: nil, connected: true,
                                              presence: .offline(lastSeen: now.addingTimeInterval(-1_500)), notifications: .off, push: .registered, now: now))
            d.banners += NowBanner.otherMacs(macRows)
        }
        if screen == "now-new" { d.queuedNew = 1 }
        return d
    }

    static func decision(_ screen: String) -> (state: DecisionScreenState, composer: Bool, draft: String) {
        let page = RenderFixtures.page(screen)
        let session = sessions.first { $0.id == page.sessionId }
        let row = NowRowBuilder.row(for: page, session: session, macName: mac)
        let content = DecisionContent.build(iv: page, row: row, session: session, macName: mac)
        var st = DecisionScreenState(content: content, row: row, phase: .open, now: now, hasSession: session != nil)
        var composer = false
        var draft = ""
        switch screen {
        case "decision-hold": st.fixedHold = 0.62
        case "decision-tip": st.tip = TipBook().decisionTip(hasPreview: row.focusPreview != nil)
        case "decision-composer": composer = true; draft = "Use the staging bucket instead"
        case "decision-delivered":
            st.phase = .delivered(nil); st.outcome = .delivered("typed into cmux › page")
        case "decision-failed":
            st.phase = .failed("Didn't confirm in time · Check on Mac")
        default: break
        }
        return (st, composer, draft)
    }
}

/// What the harness shows instead of the app.
struct RenderHarnessRoot: View {
    let args: RenderArguments
    @StateObject private var glowStore: CardGlowStore

    init(args: RenderArguments) {
        self.args = args
        _glowStore = StateObject(wrappedValue: CardGlowStore(fixed: args.glow ?? .off))
    }

    var body: some View {
        ZStack {
            NWBackdrop()
            screen
        }
        .environment(\.nwCardGlow, glowStore.glow)
        .environment(\.nwFixedPhase, RenderHarnessMotion.phase(args))
        .environment(\.nwMotion, RenderHarnessMotion.pin(args))
        .environment(\.nwFixedNow, RenderHarness.now)
        .environmentObject(glowStore)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var screen: some View {
        let s = args.screen
        switch s {
        case _ where s.hasPrefix("ask-"):
            HarnessAnswers(screen: s)
        case _ where s.hasPrefix("history"):
            HarnessHistory(screen: s)
        case _ where s.hasPrefix("room-"):
            HarnessRoom(screen: s)
        case _ where s.hasPrefix("welcome") || s.hasPrefix("scan") || s.hasPrefix("pair"):
            HarnessOnboarding(screen: s)
        case _ where s.hasPrefix("problem-"):
            HarnessProblem(screen: s)
        case "widgets":
            HarnessWidgets()
        case _ where s.hasPrefix("motion-"):
            HarnessMotion(screen: s, time: RenderHarnessMotion.time(args))
        case _ where s.hasPrefix("now"):
            HarnessShell(screen: s, destination: .now)
        case _ where s.hasPrefix("sky") || s.hasPrefix("lanes"):
            HarnessShell(screen: s, destination: .sky)
        case _ where s.hasPrefix("decision"):
            HarnessDecision(screen: s)
        case "hold-stop", "stop-confirm", "stop-result", "stop-none":
            HarnessShell(screen: s, destination: .now)
        case _ where s.hasPrefix("tower"):
            HarnessTower(screen: s, glow: glowStore.glow)
        case _ where s.hasPrefix("dispatch"):
            HarnessDispatch(screen: s)
        case "runway":
            let m = RenderFixtures.model("now")
            VStack(alignment: .leading, spacing: 20) {
                NWGlassCard { NWRunwayBar(model: m.runway) }
                NWGlassCard { NWRunwayBar(model: RunwayModel(markers: [], onAC: true, clearUntil: nil)) }
            }
            .padding(16).frame(maxHeight: .infinity, alignment: .center)
        case "settled":
            ScrollView { NWSettledList(log: RenderFixtures.log, onSeeAll: {}).padding(20) }
        case "gallery":
            NWGallery(model: RenderFixtures.model("now"))
        case "glow-compare":
            NWGlowCompare()
        default:
            Text("Unknown screen \(s)").foregroundColor(.white)
        }
    }
}

/// Now, Sky or Lanes inside the real shell (capsule and Stop ring included).
struct HarnessShell: View {
    let screen: String
    @State var destination: NWDestination
    @State private var held: TimeInterval?
    @State private var mode: SkyMode
    @State private var selected: String?

    init(screen: String, destination: NWDestination) {
        self.screen = screen
        _destination = State(initialValue: destination)
        _mode = State(initialValue: screen.hasPrefix("lanes") ? .lanes : .sky)
        _selected = State(initialValue: screen == "sky-selected" ? "w1" : nil)
    }

    private var stop: StopFlowPhase {
        switch screen {
        case "hold-stop": return .holding(progress: 0.7)
        case "stop-confirm": return .authenticating
        case "stop-result": return .result(.asked)
        case "stop-none": return .result(.nothingBusy)
        default: return .idle
        }
    }

    private var plan: StopPlan {
        StopPlan.build(sessions: screen == "stop-none" ? [] : RenderFixtures.sessions, hasSessionList: true,
                       macName: RenderFixtures.mac)
    }

    var body: some View {
        let model = RenderFixtures.model(screen.hasPrefix("now") ? screen : "now")
        NWShell(destination: $destination, decideCount: model.needYouCount, workingCount: model.workingCount, pulseWaiting: model.pulseWaiting,
                pulseLongestWait: PulseModel.longestWait(since: model.pulseRows.map(\.waitingSince), now: RenderFixtures.now), stop: stop, stopPlan: plan,
                biometry: "Face ID", held: $held) {
            NWNowScreen(data: RenderFixtures.nowData(screen.hasPrefix("now") ? screen : "now"))
        } sky: {
            NWSkyScreen(data: skyData, actions: SkyScreenActions(setMode: { mode = $0 }, select: { selected = $0 }))
        }
        .environment(\.nwTopInset, 54)
    }

    private var skyData: SkyScreenData {
        let list = screen == "sky-empty" ? [] : (screen == "sky-crowded" ? RenderFixtures.crowdedSessions : RenderFixtures.sessions)
        let sky = RenderFixtures.sky(sessions: list, paused: false)
        var d = SkyScreenData(sky: sky, lanes: LanesModel.build(sky: sky, log: RenderFixtures.activity, now: RenderFixtures.now),
                              mode: mode, now: RenderFixtures.now, standby: screen == "lanes-standby" ? RenderFixtures.macRows : [], selectedStar: selected)
        if screen == "sky-problem" { d.availability = SessionAvailabilityCopy(.needsRepair(keyMismatch: false)) }
        return d
    }
}

/// The Decision sheet over its scene, as it sits when it has grown from a card.
struct HarnessDecision: View {
    let screen: String
    @State private var draft: String
    @State private var composer: Bool

    init(screen: String) {
        self.screen = screen
        let d = RenderFixtures.decision(screen)
        _draft = State(initialValue: d.draft)
        _composer = State(initialValue: d.composer)
    }

    var body: some View {
        let d = RenderFixtures.decision(screen)
        VStack(spacing: 0) {
            NWHorizon(palette: .needsYou, pulse: .needsYou, headline: "", subline: "", height: 230, topInset: 0).opacity(0.5)
            Spacer(minLength: 0)
            NWDecisionScreen(state: d.state, draft: $draft, composerOpen: $composer)
                .background(NWDecisionBackground(tint: d.state.row.tint))
                .frame(maxHeight: 650)
        }
        .ignoresSafeArea()
    }
}

struct HarnessTower: View {
    let screen: String
    let glow: CardGlow
    var body: some View {
        NWTowerScreen(data: RenderFixtures.tower(scroll: screen == "tower-budget" ? .budget : (screen == "tower-glow" ? .appearance : (screen == "tower-terminals" ? .terminals : (screen == "tower-gestures" ? .gestures : nil))), glow: glow))
            .padding(.top, 50)
    }
}

struct HarnessDispatch: View {
    let screen: String
    @State private var draft = DispatchDraft(search: "", selectedPath: "/Users/you/projects/page",
                                             prompt: "Make the History tab collapse into Settled days in Now.", agent: .claude)
    var body: some View {
        let folders = RenderFixtures.folders
        let availability: DispatchAvailability = screen == "dispatch-off" ? .disabledOnMac : .ready
        let status: DispatchStatus? = screen == "dispatch-sending" ? DispatchStatus.from(state: .sending, startWaitExpired: false) : nil
        VStack(spacing: 0) {
            NWHorizon(palette: .working, pulse: .working, headline: "", subline: "", height: 150, topInset: 0).opacity(0.6)
            NWDispatchScreen(data: DispatchScreenData(macName: RenderFixtures.mac, availability: availability, folders: folders,
                                                      now: RenderHarness.now, status: status, sending: screen == "dispatch-sending",
                                                      runway: RenderFixtures.model("now").runway), draft: $draft)
                .background(NWDecisionBackground(tint: nil))
        }
        .ignoresSafeArea()
    }
}

/// Every control in one place, for a quick look at the components.
struct NWGallery: View {
    var model: NowModel
    @State private var seg = CardGlow.subtle
    @State private var on = true
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Components").font(NightWatch.Typo.hero).foregroundColor(NightWatch.Palette.textPrimary.color)
                HStack(spacing: 12) { ForEach([ChipKind.irreversible, .considered, .undoable], id: \.self) { NWChip(kind: $0) } }
                HStack(spacing: 12) { ForEach([ChipKind.looksStuck, .question, .forecast], id: \.self) { NWChip(kind: $0) } }
                HStack(spacing: 12) { ForEach([ChipKind.rateLimited, .review], id: \.self) { NWChip(kind: $0) } }
                HStack(spacing: 8) { ForEach([ChipKind.irreversible, .considered, .undoable], id: \.self) { NWChip(kind: $0, pill: true) } }
                NWGlassCard { NWRingsList(rings: model.rings) }
                NWTonightCard(rings: model.rings)
                NWDeliveryPreview(text: "Will type 1 · cmux › bottle-flip · Studio MBP")
                NWReceiptLine(text: "Approved npm test → cmux › page · verified 23:47:12")
                NWReceiptLine(text: "npm test · Didn't confirm in time · Check on Mac", failed: true)
                NWSegmented(options: CardGlow.allCases.map { ($0, $0.label) }, selection: $seg)
                Toggle("Night Watch", isOn: $on).toggleStyle(NWToggleStyle())
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                HStack(spacing: 10) {
                    Button("Deny") {}.buttonStyle(NWButtonStyle(kind: .quiet))
                    Button("Looks good ✦") {}.buttonStyle(NWButtonStyle(kind: .bright))
                    Button("Steer") {}.buttonStyle(NWButtonStyle(kind: .amber))
                }
                NWHoldButton(fixedProgress: 0.5, onComplete: {})
                HStack(spacing: 24) {
                    ForEach([NWPulseOrb.Style.needsYou, .working, .quiet, .dusk], id: \.self) { NWPulseOrb(style: $0).frame(width: 74, height: 74) }
                }
                HStack(spacing: 18) { ForEach([1, 2, 3, 4, 5, 6], id: \.self) { NWStarGlyph(seed: StableHash.fnv1a("p\($0)"), color: ProjectHue.allCases[$0 - 1].color, size: 40) } }
            }
            .padding(20)
        }
    }
}

/// The same card with the glow Off, Subtle and Full, side by side in one
/// frame, so the setting can be judged at a glance.
struct NWGlowCompare: View {
    var body: some View {
        VStack(spacing: 22) {
            ForEach(CardGlow.allCases) { g in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Card glow: \(g.label)").font(NightWatch.Typo.captionStrong)
                        .foregroundColor(NightWatch.Palette.textTertiary.color)
                    NWGlassCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Tonight").font(NightWatch.Typo.title).foregroundColor(NightWatch.Palette.textPrimary.color)
                            Text("Calm ring closed ✦ Unblocked 11/12 · Shipped 7/10")
                                .font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color)
                            Spacer(minLength: 22)
                        }
                        .frame(height: 96)
                    }
                    .environment(\.nwCardGlow, g)
                }
            }
        }
        .padding(20)
    }
}
#endif
