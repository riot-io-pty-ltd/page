import SwiftUI
import UIKit

/// The Decision sheet, live: finds the page (even on a cold launch from a
/// notification), derives what the sheet is showing from live state, and
/// routes every action through `ActionCoordinator` and `APIClient`. It watches
/// the live inbox: if the page is answered elsewhere, superseded or resolved
/// while open, the controls go away, a short result shows, and the sheet closes
/// itself, so a stale screen can never approve a prompt that's no longer there.
struct DecisionContainer: View {
    let interventionId: String
    /// "Open session" handler. Nil hands over to the session room through the
    /// router; a sheet opened from inside that room passes one that closes itself.
    var onOpenSession: ((String) -> Void)? = nil

    @EnvironmentObject var api: APIClient
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var pairing: PairingStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var coordinator: ActionCoordinator
    @Environment(\.dismiss) private var dismiss

    /// Last known copy, so content stays readable after the page closes.
    @State private var snapshot: Intervention?
    @State private var lookupFinished = false
    @State private var draft = ""
    @State private var composerOpen = false
    /// Ticks so "sent but unconfirmed" and the arm ring are noticed without other changes.
    @State private var now = Date()
    /// The archive lookup for a close that arrived without a reason is done.
    @State private var closeLookupFinished = false
    /// The session's changes, opened from a turn summary.
    @State private var showingDiff = false

    private var live: Intervention? { api.inbox.first { $0.id == interventionId } }
    private var intervention: Intervention? { live ?? snapshot }
    private var macName: String { nwMacName(sessions: sessions, pairing: pairing) }

    /// Only a relay known to predate delivery reporting gets the short
    /// legacy window; anything else holds a second answer for the Worker's ack window.
    private var legacyRelay: Bool { api.relayIsLegacy && live?.deliveryStatus == nil }

    private var phase: DecisionPhase {
        DecisionPhase.derive(.init(delivery: api.deliveries[interventionId], isLive: live != nil, hasSnapshot: snapshot != nil,
                                   lookupFinished: lookupFinished,
                                   closeReason: api.recentCloseReasons[interventionId] ?? snapshot?.closeReason,
                                   closeLookupFinished: closeLookupFinished, now: now, legacyRelay: legacyRelay))
    }

    var body: some View {
        ZStack {
            if let iv = intervention {
                sheet(iv)
            } else {
                placeholder
            }
        }
        .preferredColorScheme(.dark)
        .task { await lookUp() }
        .task {
            // Fast while a ring runs, slow otherwise.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: coordinator.isArming(interventionId) ? 100_000_000 : 5_000_000_000)
                now = Date()
            }
        }
        .onChange(of: live) { _, newValue in if let newValue { snapshot = newValue } }
        .task(id: phase == .checkingClose) {
            guard phase == .checkingClose else { return }
            await api.resolveCloseReason(interventionId)
            closeLookupFinished = true
        }
        .task(id: phase) {
            guard let delay = phase.autoCloseDelay else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if !Task.isCancelled { dismiss() }
        }
    }

    private func sheet(_ iv: Intervention) -> some View {
        let session = sessions.session(iv.sessionId)
        let row = NowRowBuilder.row(for: iv, session: session, macName: macName)
        let content = DecisionContent.build(iv: iv, row: row, session: session, macName: macName)
        var outcome = CardOutcome.none
        if let why = coordinator.localProblems[iv.id] { outcome = .problem(why) }
        else if coordinator.isArming(iv.id, now: now) { outcome = .arming(progress: 0) }
        let state = DecisionScreenState(content: content, row: row, phase: phase, legacyRelay: legacyRelay, now: now,
                                        biometry: BiometricGate.displayName, pending: coordinator.pending[iv.id],
                                        outcome: outcome, hasSession: session != nil)
        return NWDecisionScreen(state: state, actions: actions(iv, row), draft: $draft, composerOpen: $composerOpen)
            .background(NWDecisionBackground(tint: row.tint).ignoresSafeArea())
            .sheet(isPresented: $showingDiff) { DiffView(sessionId: iv.sessionId, title: iv.projectName) }
    }

    private func actions(_ iv: Intervention, _ row: NowRow) -> DecisionScreenActions {
        var a = DecisionScreenActions()
        a.approve = { coordinator.begin(row: row, kind: .approve) }
        a.holdComplete = { coordinator.commitHold(row: row, macName: macName) }
        a.deny = { coordinator.begin(row: row, kind: .deny) }
        a.carryOn = { coordinator.begin(row: row, kind: .carryOn) }
        a.stop = { coordinator.begin(row: row, kind: .stop) }
        a.send = { text in
            // A written reply: Esc, then the text, then Return, which the Mac's reply planner does.
            coordinator.begin(row: row, kind: .tellInstead, text: text) { outcome in
                if case .accepted = outcome { draft = ""; composerOpen = false }
            }
        }
        a.cancel = { coordinator.cancel(iv.id) }
        a.openSession = {
            if let onOpenSession { onOpenSession(iv.sessionId) } else { router.openSession(iv.sessionId) }
        }
        a.viewChanges = { showingDiff = true }
        a.copy = { UIPasteboard.general.string = iv.context }
        a.close = { dismiss() }
        return a
    }

    /// Finds the intervention even on a cold launch from a notification,
    /// when the inbox hasn't loaded yet.
    private func lookUp() async {
        if let live { snapshot = live }
        if snapshot == nil {
            if api.inboxLoad != .loaded || lookupFinished == false { await api.refreshInbox() }
            snapshot = live ?? api.history.first { $0.id == interventionId }
        }
        if snapshot == nil {
            await api.refreshHistory()
            snapshot = api.history.first { $0.id == interventionId }
        }
        lookupFinished = true
    }

    @ViewBuilder private var placeholder: some View {
        VStack(spacing: 14) {
            Spacer()
            if phase == .missing, let failure = api.inboxLoad.failureMessage {
                Image(systemName: "wifi.exclamationmark").font(.system(.largeTitle)).foregroundColor(NightWatch.Palette.textTertiary.color)
                Text("Couldn't load this page").font(NightWatch.Typo.headline).foregroundColor(NightWatch.Palette.textPrimary.color)
                Text(failure).font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textSecondary.color).multilineTextAlignment(.center)
                Button("Try again") { lookupFinished = false; Task { await lookUp() } }.buttonStyle(NWButtonStyle(kind: .quiet)).frame(maxWidth: 200)
            } else if phase == .missing {
                Image(systemName: "checkmark.circle").font(.system(.largeTitle)).foregroundColor(NightWatch.Palette.textTertiary.color)
                Text("This page is no longer available").font(NightWatch.Typo.headline).foregroundColor(NightWatch.Palette.textPrimary.color)
                Text("It was probably answered or resolved on your Mac.").font(NightWatch.Typo.body)
                    .foregroundColor(NightWatch.Palette.textSecondary.color).multilineTextAlignment(.center)
                Button("Close") { dismiss() }.buttonStyle(NWButtonStyle(kind: .quiet)).frame(maxWidth: 200)
            } else {
                ProgressView("Loading…").tint(NightWatch.Palette.textSecondary.color)
            }
            Spacer()
        }
        .padding(32)
        .background(NWDecisionBackground(tint: nil).ignoresSafeArea())
    }
}
