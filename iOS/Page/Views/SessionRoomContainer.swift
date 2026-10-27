import SwiftUI
import UIKit

/// The Session Room, live. It keeps what the old session screen did: it tells
/// the Mac it is watching (re-sent every 30 s, which is what makes the Mac
/// send this session's transcript at all), holds on to the last copy so the
/// room stays readable after the session ends, and routes every action
/// through the existing services:
///
/// - a message to a busy or idle session is `SessionStore.sendInput` (text
///   plus Return; the Mac's input gate still decides);
/// - a written reply to a waiting prompt is `ActionCoordinator` with
///   `.tellInstead`, which the page sends as Esc, then the text, then Return;
///   it is never sent as session input;
/// - Approve, Deny and Looks good on the pinned page are the same
///   `ActionCoordinator` calls Now makes;
/// - Stop is `SessionStore.interrupt`, behind a 0.6 s hold.
///
/// The drawing is `NWSessionRoom`.
struct SessionRoomContainer: View {
    let sessionId: String

    @EnvironmentObject var api: APIClient
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var pairing: PairingStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var coordinator: ActionCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var composerProblem: String?
    /// Last known copy, so the room stays readable after the session ends.
    @State private var snapshot: LiveSession?
    @State private var lens: RoomLens = .story
    @State private var runId: String?
    @State private var presentedPage: AppRouter.PresentedIntervention?
    @State private var agent: AgentRef?
    @State private var diffRequestedAt = Date.distantPast

    struct AgentRef: Identifiable, Equatable {
        let runId: String
        let agentId: String
        var id: String { runId + "/" + agentId }
    }

    private static let watchInterval: UInt64 = 30

    private var live: LiveSession? { sessions.session(sessionId) }
    private var session: LiveSession? { live ?? snapshot }
    private var ended: Bool { live == nil && sessions.hasList && snapshot != nil }
    private var macName: String { nwMacName(sessions: sessions, pairing: pairing) }

    var body: some View {
        ZStack {
            NightWatch.Palette.backgroundDeep.color.ignoresSafeArea()
            if session != nil {
                // Ages, presence and the arm ring re-evaluate every few seconds.
                TimelineView(.periodic(from: .now, by: 2)) { context in
                    room(now: context.date)
                }
            } else {
                placeholder
            }
        }
        .preferredColorScheme(.dark)
        // Set before the sheets below, so a page or agent that covers the room
        // holds the room's ribbon still while the sheet itself keeps animating.
        // Backgrounding is already handled inside `NWAnimated`.
        .environment(\.nwAnimationsPaused, agent != nil || presentedPage != nil)
        .onAppear {
            if let live { snapshot = live }
            requestChanges()
        }
        .onChange(of: live) { old, new in
            if let new { snapshot = new }
            // A turn that just finished: refresh the Changes badge.
            if old?.state == .active, new?.state != .active { requestChanges() }
        }
        // Watch while visible and connected; the store re-arms it after a
        // reconnect, and sends nothing while the socket is down.
        .task(id: api.connection == .connected) {
            while !Task.isCancelled {
                sessions.watch(sessionId)
                try? await Task.sleep(nanoseconds: Self.watchInterval * 1_000_000_000)
            }
        }
        .onDisappear { sessions.watch(nil) }
        .sheet(item: $agent) { ref in
            AgentRoomContainer(sessionId: sessionId, runId: ref.runId, agentId: ref.agentId)
                .environmentObject(sessions)
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $presentedPage) { item in
            // "Open session" there just comes back here.
            DecisionContainer(interventionId: item.id, onOpenSession: { _ in presentedPage = nil })
                .presentationDetents([.fraction(0.92), .large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(34)
        }
    }

    // MARK: Room

    private func room(now: Date) -> some View {
        let s = session!
        let presence = MacPresence.evaluate(api.macStatus, now: Date())
        let availability = sessions.availability(presence: presence, socketConnected: api.connection == .connected, now: Date())
        let page = api.inbox.first { $0.sessionId == sessionId }
        let row = page.map { NowRowBuilder.row(for: $0, session: s, macName: macName) }
        var outcome = CardOutcome.none
        if let row {
            if let why = coordinator.localProblems[row.id] { outcome = .problem(why) }
            else { outcome = CardOutcome.from(pending: coordinator.pending[row.id], delivery: api.deliveries[row.id], now: now) }
        }
        var inputs = SessionRoomData.Inputs(session: s, ended: ended, availability: availability, macName: macName, now: now)
        inputs.transcript = sessions.transcripts[sessionId]
        inputs.sent = sessions.sentMessages(for: sessionId)
        inputs.screen = sessions.screens[sessionId]
        inputs.runs = sessions.workflows[sessionId] ?? []
        inputs.diff = sessions.diffs[sessionId]
        inputs.diffError = sessions.diffErrors[sessionId]
        inputs.diffRequestedAt = diffRequestedAt
        inputs.fiveHourPct = UsageCardModel(api.macStatus?.usage, now: now)?.fiveHour?.pct
        inputs.pageRow = row
        inputs.pageOutcome = outcome
        inputs.pagePending = row.flatMap { coordinator.pending[$0.id] }
        inputs.latestStop = sessions.latestInterrupt(for: sessionId, now: now)
        inputs.composerProblem = composerProblem
        let data = SessionRoomData.make(inputs)
        return NWSessionRoom(data: data, actions: actions(row: row, data: data),
                             lens: Binding(get: { RoomLens.resolve(lens, offered: data.lenses) }, set: { setLens($0) }),
                             draft: $draft, runId: $runId)
            .onChange(of: draft) { _, _ in if composerProblem != nil { composerProblem = nil } }
    }

    private func setLens(_ l: RoomLens) {
        lens = l
        if l == .changes, sessions.diffs[sessionId] == nil { requestChanges() }
    }

    private func requestChanges() {
        guard !ended, session != nil else { return }
        diffRequestedAt = Date()
        sessions.requestDiff(sessionId: sessionId)
    }

    private func actions(row: NowRow?, data: SessionRoomData) -> SessionRoomActions {
        var a = SessionRoomActions()
        a.close = { dismiss() }
        a.send = { text in send(text, mode: data.composer, row: row) }
        a.stopCompleted = {
            // The hold is the confirmation; Esc goes to the session through the existing path.
            guard data.stop.canStop else { return }
            sessions.interrupt(sessionId: sessionId)
        }
        a.openRun = { id in runId = id; lens = .workflows }
        a.openAgent = { run, agentId in agent = AgentRef(runId: run, agentId: agentId) }
        a.openDecision = { presentedPage = .init(id: $0) }
        a.banner = { action in
            switch action {
            case .retry: sessions.refresh(); Task { await api.refreshAll() }
            case .repair: router.requestUnpair()
            case .openDecision(let id): presentedPage = .init(id: id)
            }
        }
        a.approve = { coordinator.begin(row: $0, kind: .approve) }
        a.holdComplete = { coordinator.commitHold(row: $0, macName: macName) }
        a.deny = { coordinator.begin(row: $0, kind: .deny) }
        a.looksGood = { coordinator.begin(row: $0, kind: .carryOn) }
        a.cancel = { id in
            // The ring, if it is still running; otherwise the decision, to see and retry.
            if coordinator.isArming(id) { coordinator.cancel(id) } else { presentedPage = .init(id: id) }
        }
        a.refreshChanges = { requestChanges() }
        a.copy = { UIPasteboard.general.string = $0 }
        return a
    }

    /// The composer's text goes to exactly one place, chosen by the mode.
    private func send(_ text: String, mode: RoomComposerMode, row: NowRow?) {
        switch mode {
        case .tellInstead:
            // Esc, then your words, then Return: the page's own path, with its arm ring.
            guard let row, row.action(.tellInstead) != nil else { return }
            coordinator.begin(row: row, kind: .tellInstead, text: text) { outcome in
                if case .accepted = outcome { draft = "" }
            }
        case .steer, .nextTask:
            if let problem = sessions.sendInput(sessionId: sessionId, text: text) {
                composerProblem = problem.message
                return
            }
            draft = ""
            composerProblem = nil
        case .locked, .blocked, .disabled:
            break
        }
    }

    // MARK: Placeholder

    @ViewBuilder private var placeholder: some View {
        VStack(spacing: 14) {
            Spacer()
            if sessions.hasList {
                Image(systemName: "checkmark.circle").font(.system(.largeTitle)).foregroundColor(NightWatch.Palette.textTertiary.color)
                Text("This session isn't running").font(NightWatch.Typo.headline).foregroundColor(NightWatch.Palette.textPrimary.color)
                Text("It's not on your Mac's list of live sessions anymore.").font(NightWatch.Typo.body)
                    .foregroundColor(NightWatch.Palette.textSecondary.color).multilineTextAlignment(.center)
                Button("Close") { dismiss() }.buttonStyle(NWButtonStyle(kind: .quiet)).frame(maxWidth: 200)
            } else {
                ProgressView("Loading…").tint(NightWatch.Palette.textSecondary.color)
            }
            Spacer()
        }
        .padding(32)
    }
}

/// A workflow agent's room, live: its transcript, sent by the Mac while this
/// screen is open. Read-only.
struct AgentRoomContainer: View {
    let sessionId: String
    let runId: String
    let agentId: String

    @EnvironmentObject var sessions: SessionStore
    @Environment(\.dismiss) private var dismiss
    /// Last known copy, so the screen stays readable if the run drops off.
    @State private var snapshot: WorkflowRun?

    private var live: WorkflowRun? { sessions.workflows[sessionId]?.first { $0.id == runId } }
    private var run: WorkflowRun? { live ?? snapshot }
    private var agent: WorkflowRun.Agent? { run?.agents.first { $0.id == agentId } }

    var body: some View {
        let transcript = sessions.agentTranscript(sessionId: sessionId, runId: runId, agentId: agentId)
        let state = agent.map(WorkflowOrbit.nodeState) ?? .stopped
        NWAgentRoomScreen(
            runName: run?.name ?? "Workflow", agentLabel: agent?.label ?? "Agent", state: state,
            model: transcript.map { AgentRoomModel.build(entries: $0.entries, finished: state != .running, truncated: $0.truncated) },
            onBack: { dismiss() })
            .preferredColorScheme(.dark)
            .onAppear {
                if let live { snapshot = live }
                sessions.watchAgent(sessionId: sessionId, runId: runId, agentId: agentId)
            }
            .onChange(of: live) { _, new in if let new { snapshot = new } }
            .onDisappear { sessions.watchAgent(sessionId: sessionId, runId: nil, agentId: nil) }
    }
}
