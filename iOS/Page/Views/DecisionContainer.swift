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
    @EnvironmentObject var tips: TipStore
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
    /// When an Irreversible approve passed biometrics in this sheet (the hold ring's burst).
    @State private var holdCommittedAt: Date?
    /// The first-time tip was on screen: it is spent when this sheet closes.
    @State private var showedTip = false
    /// Steer opened this sheet: its message box comes up as soon as the page is known to take one.
    @State private var wantsComposer = false
    /// The X (or Open session, View changes, or another sheet asked for by the app) with a message written:
    /// ask before it is thrown away.
    @State private var confirmingDiscard = false
    /// What to do once the person says discard: close, open the session, show the changes. Nil means close.
    @State private var pendingLeave: (() -> Void)?
    /// The last "Now" / "When it finishes" choice (kept per device).
    @State private var lastChoice: SendChoice? = SendChoiceMemory.last
    @State private var choiceExplained = SendChoiceMemory.explained
    /// Words a killed countdown gave back: the note says why they are in the box.
    @State private var composerNote: String?
    /// The Mac couldn't take a message sent from here (When it finishes).
    @State private var composerProblem: String?
    @State private var restoredPending = false

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
        // A swipe must not eat a message that is being written or sent. The X still closes (after asking).
        .interactiveDismissDisabled(DecisionDraftGuard.blocksSwipeDismiss(draft: draft, sendPending: coordinator.pending[interventionId] != nil, phase: phase,
                                                                          countdownPending: countdownPending))
        .confirmationDialog("Discard your message?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard message", role: .destructive) {
                draft = ""
                if router.sheets.deferred != nil { router.resolveDeferredSheet(discard: true) }
                else { let go = pendingLeave ?? { dismiss() }; pendingLeave = nil; go() }
            }
            Button("Keep editing", role: .cancel) { pendingLeave = nil; router.resolveDeferredSheet(discard: false) }
        }
        // Another sheet asked for by the app (a notification, a link) waits while a message is written here.
        .onChange(of: router.sheets.deferred) { _, asked in if asked != nil { pendingLeave = nil; confirmingDiscard = true } }
        .onChange(of: DecisionDraftGuard.needsConfirm(draft: draft, countdownPending: countdownPending)) { _, held in router.setSheetDraft(held) }
        .onAppear {
            wantsComposer = router.takeComposerEntry(for: interventionId)
            // A message a killed countdown gave back.
            if let r = sessions.takeRestoredDraft(scope: OutboxRestore.scope(pageId: interventionId)) {
                draft = DraftRestore.merge(restored: r.text, current: draft)
                composerNote = r.note
                restoredPending = true
            }
            openComposerIfAsked()
        }
        .onChange(of: sessions.restoredDrafts[OutboxRestore.scope(pageId: interventionId)]) { _, d in
            guard d != nil, let r = sessions.takeRestoredDraft(scope: OutboxRestore.scope(pageId: interventionId)) else { return }
            draft = DraftRestore.merge(restored: r.text, current: draft)
            composerNote = r.note
            restoredPending = true
            openComposerIfAsked()
        }
        .onDisappear {
            if showedTip { tips.retire(.willType) }
            router.setSheetDraft(false)
        }
        .task { await lookUp(); openComposerIfAsked() }
        .task {
            // Fast while a ring runs, slow otherwise.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: coordinator.isArming(interventionId) ? 100_000_000 : 5_000_000_000)
                now = Date()
            }
        }
        .onChange(of: live) { _, newValue in if let newValue { snapshot = newValue }; openComposerIfAsked() }
        // The committed ring belongs to that one approve: any other action, or the
        // sheet taking input again after a failure, puts it away.
        .onChange(of: coordinator.pending[interventionId]) { _, p in
            if let p { holdCommittedAt = ActionGate.requiresBiometrics(kind: p.kind, commit: p.commit) ? p.startedAt : nil }
        }
        .onChange(of: phase.acceptsInput) { _, accepts in if accepts { holdCommittedAt = nil } }
        .task(id: phase == .checkingClose) {
            guard phase == .checkingClose else { return }
            await api.resolveCloseReason(interventionId)
            closeLookupFinished = true
        }
        .task(id: phase) {
            // A message written under a page that resolved is kept, with the sheet, rather than closed over.
            guard let delay = DecisionDraftGuard.autoCloseDelay(phase: phase, draft: draft) else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if !Task.isCancelled { dismiss() }
        }
    }

    /// Steer: opens the message box once, for a page that is live, offers a written reply and is not a decision
    /// (a decision opens on its buttons: Approve and Deny are what it is for).
    private func openComposerIfAsked() {
        guard wantsComposer || restoredPending, let iv = live else { return }
        let row = NowRowBuilder.row(for: iv, session: sessions.session(iv.sessionId), macName: macName)
        // Words that came back open the box wherever the page takes a reply; Steer opens it only off a decision.
        if restoredPending, row.action(.tellInstead) != nil { composerOpen = true }
        if wantsComposer, row.section != .decide, row.action(.tellInstead) != nil { composerOpen = true }
        wantsComposer = false
        restoredPending = false
    }

    /// A written message is waiting out its 10 s Undo: it is the app's now, whether the sheet stays.
    private var countdownPending: Bool { coordinator.pending[interventionId]?.isCountdown == true }

    /// Leaves the sheet (or goes somewhere from it) after asking about a message that would be thrown away.
    private func leave(_ action: @escaping () -> Void) {
        if DecisionDraftGuard.needsConfirm(draft: draft, countdownPending: countdownPending) {
            pendingLeave = action
            confirmingDiscard = true
        } else {
            action()
        }
    }

    /// How a Steer message goes: only on a page that looks in on a working session (a finished turn's session
    /// is idle, and a decision isn't a message to the session).
    private func steerPlan(_ row: NowRow, session: LiveSession?) -> SendChoicePlan {
        guard row.section == .look, let s = session else { return SendChoicePlan(mode: .none, selected: .now) }
        return SendChoicePlan.build(busy: s.state == .active, canType: s.canType, canHold: s.canHold, caps: sessions.macCaps, last: lastChoice)
    }

    private func sheet(_ iv: Intervention) -> some View {
        let session = sessions.session(iv.sessionId)
        let row = NowRowBuilder.row(for: iv, session: session, macName: macName)
        let content = DecisionContent.build(iv: iv, row: row, session: session, macName: macName)
        var outcome = CardOutcome.none
        if let why = coordinator.localProblems[iv.id] { outcome = .problem(why) }
        else if coordinator.isArming(iv.id, now: now) { outcome = .arming(progress: 0) }
        var state = DecisionScreenState(content: content, row: row, phase: phase, legacyRelay: legacyRelay, now: now,
                                        biometry: BiometricGate.displayName, pending: coordinator.pending[iv.id],
                                        outcome: outcome, hasSession: session != nil)
        // The Receipt thread, from the real delivery state only.
        state.receipt = ReceiptThreadInput(pending: coordinator.pending[iv.id], delivery: api.deliveries[iv.id],
                                           localProblem: coordinator.localProblems[iv.id], changedAt: api.deliveryTimes[iv.id])
        state.holdCommittedAt = holdCommittedAt
        // Queued messages: how a Steer goes, where a reply is waiting (and Delete), what is held on the Mac.
        state.sendChoice = steerPlan(row, session: session)
        state.explainChoice = !choiceExplained
        state.composerNote = composerNote
        state.composerProblem = composerProblem
        state.queue = ReplyQueueStatus.build(.init(delivery: api.deliveries[iv.id], isHook: iv.isBlockingHook,
                                                   relayFeatures: sessions.relayFeatures, macCaps: sessions.macCaps,
                                                   note: sessions.retractNotes[iv.id], resetsAt: session?.flight?.resetsAt,
                                                   hasList: sessions.hasList))
        if state.queue == nil {
            state.queueWhyNot = QueuedDelete.whyNot(delivery: api.deliveries[iv.id], isHook: iv.isBlockingHook, relayFeatures: sessions.relayFeatures,
                                                   macCaps: sessions.macCaps, hasList: sessions.hasList)
        }
        if let latest = sessions.latestInput(for: iv.sessionId), latest.state.isHeld || { if case .deleted = latest.state { return true }; return false }() {
            state.heldReceipt = SendReceipt.build(latest, agent: iv.agentName, now: now, canRetract: sessions.macCaps.contains(SendChoicePlan.retractCap),
                                                  note: sessions.retractNotes[latest.clientId])
        }
        state.tip = tips.book.decisionTip(hasPreview: row.focusPreview != nil && row.action(.openOnMac) == nil)
        // A question the session is blocked on, answerable by tapping: only for the page the Mac has open
        // for it (a hook-held page is answered through its own text reply).
        // A page Claude's question hook holds has no dialog on screen: its answers go as text through the hook.
        if let ask = AnswerPicker.ask(for: session, pageIsQuestion: content.chip == .question, hook: iv.isBlockingHook, pageContext: iv.context),
           iv.isBlockingHook || session?.interventionId == iv.id {
            state.ask = ask
            state.macName = macName
            state.askViaHook = iv.isBlockingHook
            state.askDelivery = iv.isBlockingHook
                ? AnswerPicker.delivery(from: CardOutcome.from(pending: coordinator.pending[iv.id], delivery: api.deliveries[iv.id], now: now),
                                        sessionId: iv.sessionId, promptKey: ask.id, now: now)
                : sessions.latestAnswer(for: iv.sessionId, promptKey: ask.id)
        }
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
            composerProblem = nil
            composerNote = nil
            let plan = steerPlan(row, session: sessions.session(iv.sessionId))
            if plan.mode != .none, !choiceExplained { choiceExplained = true; SendChoiceMemory.markExplained() }
            if plan.holds, let s = sessions.session(iv.sessionId) {
                // When it finishes: the Mac holds it (typed once the turn ends), and Delete takes it back.
                let target = SessionTarget(session: s, macName: macName)
                if let problem = sessions.sendInput(sessionId: iv.sessionId, text: text, target: target, hold: true) {
                    composerProblem = problem.message
                } else {
                    draft = ""; composerOpen = false
                }
                return
            }
            // A written reply: the phone says `custom`; the Mac's reply planner types the text, then Return.
            // To a working session it waits 10 s with Undo first.
            coordinator.begin(row: row, kind: .tellInstead, text: text, countdown: plan.countsDown ? SendCountdown.sendNow : nil) { outcome in
                if case .accepted = outcome { draft = ""; composerOpen = false }
            }
        }
        a.setChoice = { choice in lastChoice = choice; SendChoiceMemory.remember(choice) }
        a.deleteHeld = { id in sessions.deleteHeld(clientId: id, sessionId: iv.sessionId) }
        a.deleteQueued = {
            guard let status = ReplyQueueStatus.build(.init(delivery: api.deliveries[iv.id], isHook: iv.isBlockingHook, relayFeatures: sessions.relayFeatures,
                                                            macCaps: sessions.macCaps, note: sessions.retractNotes[iv.id], hasList: sessions.hasList)),
                  status.canDelete else { return }
            switch status.layer {
            case .relay: Task { await api.retractReply(iv.id) }
            case .macHold: sessions.deleteHeldReply(interventionId: iv.id, sessionId: iv.sessionId)
            }
        }
        a.submitAnswers = { sheet in
            switch AnswerPicker.submit(viaHook: iv.isBlockingHook, hasPage: true, sheet: sheet) {
            case .refuse: break
            case .hook(let text):
                // The hook maps the numbers to Claude's options; nothing is pressed.
                coordinator.begin(row: row, kind: .tellInstead, text: text)
            case .keys:
                let target = sessions.session(iv.sessionId).map { SessionTarget(session: $0, macName: macName) }
                sessions.sendAnswer(sessionId: iv.sessionId, sheet: sheet, target: target)
            }
        }
        // Undo of a message waiting out its countdown: the coordinator gives the words back (`restoredDrafts`, merged
        // above) only when the cancel landed, so a tap just after 0 never shows a sent message as undone.
        a.cancel = { coordinator.cancel(iv.id) }
        // Leaving the sheet any way at all asks first about a message that would be thrown away.
        a.openSession = {
            leave { if let onOpenSession { onOpenSession(iv.sessionId) } else { router.openSession(iv.sessionId) } }
        }
        a.viewChanges = { leave { showingDiff = true } }
        a.copy = { UIPasteboard.general.string = iv.context }
        a.close = { leave { dismiss() } }
        a.copyDraft = { UIPasteboard.general.string = $0 }
        a.dismissTip = { tips.retire($0) }
        a.tipShown = { _ in showedTip = true }
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
