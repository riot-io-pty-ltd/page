import SwiftUI

/// What the Decision sheet shows and can do, as values.
struct DecisionScreenState {
    var content: DecisionContent
    var row: NowRow
    var phase: DecisionPhase
    var legacyRelay = false
    var now: Date
    /// Seen by the person: "Face ID", "Touch ID" or "passcode".
    var biometry = "Face ID"
    var pending: PendingAction? = nil
    var outcome: CardOutcome = .none
    /// Whether this sheet has a live session behind it to open.
    var hasSession = true
    /// The next Decide item, for "swipe up for the next".
    var nextTitle: String? = nil
    /// The question behind a question page, when it can be answered from the phone (picker).
    var ask: SessionAsk? = nil
    var askDelivery: SentSessionCommand? = nil
    /// The paired Mac's name, for the answers' delivery preview.
    var macName = ""
    /// The page is one Claude's question hook holds: the answers go as text through it.
    var askViaHook = false
    /// Draws this draft instead of the live one (the render harness).
    var fixedSheet: AnswerSheet? = nil
    /// Draws the hold ring part-way (the render harness).
    var fixedHold: Double? = nil
    /// The height of the keyboard the harness drew under this screen. The harness cannot raise the real one, so
    /// it frames the screen above a stand-in, and the screen adds it back where it measures without the keyboard.
    var fixedKeyboard: CGFloat? = nil
    /// The delivery state of this sheet's action, drawn as its Receipt thread.
    var receipt: ReceiptThreadInput? = nil
    /// When an Irreversible approve passed biometrics here (it outlives the
    /// pending action, so the burst is not cut short by a quick relay).
    var holdCommittedAt: Date? = nil
    /// The first-time tip for the delivery preview ("Will type … shows exactly what lands on your Mac"), while it is unseen.
    var tip: NWTip? = nil
    /// How a Steer message to a busy session goes: Now (behind a 10 s Undo) or When it finishes (held on the Mac).
    var sendChoice = SendChoicePlan(mode: .none, selected: .now)
    /// Say what each way means (until a message has gone out with the choice in front of the person).
    var explainChoice = false
    /// This reply is waiting somewhere it can be deleted: at the relay for an offline Mac, or on the Mac until a limit resets.
    var queue: ReplyQueueStatus? = nil
    /// A queued reply on a page a blocking hook holds has no block (it isn't waiting for the Mac), but it says why it can't be deleted.
    var queueWhyNot: String? = nil
    /// A message sent here "when it finishes": held on the Mac, with Delete.
    var heldReceipt: SendReceipt? = nil
    /// Why the message box was opened with text in it (a countdown the app was killed on), or a send problem.
    var composerNote: String? = nil
    /// The Mac couldn't take this message here (a problem to say above the field).
    var composerProblem: String? = nil
}

struct DecisionScreenActions {
    var approve: () -> Void = {}
    var holdComplete: () -> Void = {}
    var deny: () -> Void = {}
    var carryOn: () -> Void = {}
    var stop: () -> Void = {}
    var send: (String) -> Void = { _ in }
    /// "Submit all": the draft's answers.
    var submitAnswers: (AnswerSheet) -> Void = { _ in }
    var cancel: () -> Void = {}
    var openSession: () -> Void = {}
    var viewChanges: () -> Void = {}
    var copy: () -> Void = {}
    /// Copies the message being written (kept when the page resolves under it).
    var copyDraft: (String) -> Void = { _ in }
    var close: () -> Void = {}
    var retry: () -> Void = {}
    /// "Now" / "When it finishes" chosen.
    var setChoice: (SendChoice) -> Void = { _ in }
    /// Delete the reply waiting at the relay or held on the Mac.
    var deleteQueued: () -> Void = {}
    /// Delete a message held on the Mac, by its clientId.
    var deleteHeld: (String) -> Void = { _ in }
    /// The first-time tip was dismissed.
    var dismissTip: (NWTip) -> Void = { _ in }
    /// The first-time tip is on screen (it is retired when the sheet closes).
    var tipShown: (NWTip) -> Void = { _ in }
}

/// The sheet's own surface: near-black, tinted by the card's class, with the
/// top corners rounded. No glow, ever: this is a plain fill.
struct NWDecisionBackground: View {
    var tint: NightWatch.RGBA?
    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: 34, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 34, style: .continuous)
            .fill((tint.map { NightWatch.Palette.surface.mixed(with: $0.opacity(1), 0.10) } ?? NightWatch.Palette.surface).color)
    }
}

private struct NWSheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct NWPinnedAskHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The Decision sheet's content: who is asking, the ask in full, why it is
/// the class it is, the delivery preview (what will be typed, where, on which
/// Mac) and the controls its class allows. Undoable and Considered approve
/// with a tap and the 1.2 s cancel ring; Irreversible only through the hold
/// ring, then Face ID / Touch ID / passcode. "Tell it instead" opens a
/// composer for a message to the session; while the sheet is waiting on an
/// approval, free text can never reach a live prompt any other way. The
/// composer lives in a dock under the content, not in either layout, so the
/// keyboard moves only the dock: the layout is chosen from the sheet's height
/// without the keyboard and kept while a message is being written, and the
/// dock stays (locked, with its receipt) while that message is on its way.
/// Every action is a closure for the container to route through the existing
/// services.
struct NWDecisionScreen: View {
    var state: DecisionScreenState
    var actions = DecisionScreenActions()
    @Binding var draft: String
    @Binding var composerOpen: Bool
    @FocusState private var focused: Bool

    /// The tallest the pinned command grows before it scrolls inside its own box.
    @ScaledMetric(relativeTo: .body) private var pinnedAskCap: CGFloat = 132
    @State private var pinnedAskHeight: CGFloat = 0
    /// The sheet's height with the keyboard (and the composer dock) ignored; 0 until it is measured.
    @State private var sheetHeight: CGFloat = 0
    /// The layout in force while a message is being written, so nothing can swap it under the field.
    @State private var latchedPinned: Bool?

    var body: some View {
        Group {
            if sheetHeight > 0 { layout }
            else { Color.clear }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if composing { composerDock }
        }
        // Measured past the keyboard: opening it must not change which layout the sheet draws.
        .background(alignment: .top) {
            GeometryReader { g in
                Color.clear.preference(key: NWSheetHeightKey.self, value: g.size.height + (state.fixedKeyboard ?? 0))
            }
            .ignoresSafeArea(.keyboard)
        }
        .onPreferenceChange(NWSheetHeightKey.self) { new in
            // The first measurement after the composer opened at height 0 decides the layout it keeps.
            latchedPinned = DecisionLayout.relatch(latched: latchedPinned, composing: composing, oldHeight: sheetHeight, newHeight: new,
                                                   questionPicker: questionPicker)
            sheetHeight = new
        }
        .onChange(of: composing) { _, on in
            latchedPinned = DecisionLayout.latch(height: sheetHeight, questionPicker: questionPicker, composing: on)
        }
    }

    private var questionPicker: Bool { state.ask != nil && c.chip == .question }

    @ViewBuilder private var layout: some View {
        if DecisionLayout.pinned(height: sheetHeight, questionPicker: questionPicker, latched: latchedPinned, composing: composing) {
            pinnedLayout
        } else {
            flowingLayout
        }
    }

    /// Roomy sheets: what will be done stays in view with the controls that do
    /// it. The command itself and the delivery preview (what is typed, where,
    /// on which Mac) are never scrolled out from under a live Approve or ring.
    private var pinnedLayout: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if !pinsAsk { askBlock }
                    if let n = c.screenNote { screenNoteView(n) }
                    reasonBlock
                    optionsBlock
                    secondaryLinks
                }
                .padding(.horizontal, NightWatch.Space.xl)
                .padding(.top, 10)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            VStack(spacing: 10) {
                if pinsAsk { pinnedAsk }
                // While a message is being written the dock carries the preview and the receipt.
                if !composing {
                    if let p = previewText { previewTip; NWDeliveryPreview(text: p) }
                    statusBlock
                }
            }
            .padding(.horizontal, NightWatch.Space.xl)
            if !composing {
                controls
                    .padding(.horizontal, NightWatch.Space.xl)
                    .padding(.top, 8)
                    .padding(.bottom, NightWatch.Space.lg)
            }
        }
    }

    /// Short sheets (a small phone, large Dynamic Type): one scroll, in reading
    /// order. The controls come last, directly under the command and the
    /// preview, so they are never on screen without them above.
    private var flowingLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                askBlock
                if let n = c.screenNote { screenNoteView(n) }
                if !composing {
                    if let p = previewText { previewTip; NWDeliveryPreview(text: p) }
                    statusBlock
                    controls
                }
                reasonBlock
                optionsBlock
                secondaryLinks
            }
            .padding(.horizontal, NightWatch.Space.xl)
            .padding(.top, 10)
            .padding(.bottom, NightWatch.Space.lg)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// A command or edit is pinned above the controls whenever they can approve it.
    private var pinsAsk: Bool {
        (c.askKind == .command || c.askKind == .edit) && c.section == .decide && c.informational == nil
            && row.action(.openOnMac) == nil
    }

    /// The command in full, in a box that scrolls once it passes `pinnedAskCap`.
    private var pinnedAsk: some View {
        ScrollView(.vertical, showsIndicators: true) {
            askBlock
                .background(GeometryReader { g in Color.clear.preference(key: NWPinnedAskHeightKey.self, value: g.size.height) })
        }
        .frame(height: pinnedAskHeight == 0 ? pinnedAskCap : min(pinnedAskHeight, pinnedAskCap))
        .onPreferenceChange(NWPinnedAskHeightKey.self) { pinnedAskHeight = $0 }
    }

    private var c: DecisionContent { state.content }
    private var row: NowRow { state.row }
    private var accepts: Bool { state.phase.acceptsInput }
    private var irreversible: Bool { c.chip == .irreversible }

    // MARK: Header and ask

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule().fill(Color.white.opacity(0.22)).frame(width: 40, height: 4)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            HStack(spacing: 10) {
                NWChip(kind: c.chip, pill: true)
                Spacer(minLength: 0)
                Button(action: actions.close) {
                    Image(systemName: "xmark").font(.system(.footnote, weight: .bold))
                        .foregroundColor(NightWatch.Palette.textSecondary.color)
                        .frame(width: 44, height: 44)
                        // A glass disc where there is glass, as a sheet's close button is; bare before it.
                        .nwChromeGlass(in: Circle()) { Color.clear }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close"))
            }
            Text("\(c.project) · \(c.agent) · \(row.waitingText(now: state.now))")
                .font(NightWatch.Typo.caption)
                .foregroundColor(NightWatch.Palette.textTertiary.color)
                .lineLimit(2)
                .offset(y: -6)
            Text(c.headline)
                .font(NightWatch.Typo.hero).kerning(NightWatch.Typo.heroTracking)
                .foregroundColor(NightWatch.Palette.textPrimary.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let blurb = c.blurb {
                Text(blurb).font(NightWatch.Typo.subline).foregroundColor(NightWatch.Palette.textSecondary.color)
            }
        }
    }

    @ViewBuilder private var askBlock: some View {
        switch c.askKind {
        case .command, .edit:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(c.askKind == .command ? "$" : "✎")
                        .foregroundColor((irreversible ? NightWatch.Palette.red : NightWatch.Palette.textTertiary).color)
                    Text(c.ask)
                        .foregroundColor((irreversible ? NightWatch.Palette.red.mixed(with: .init(1, 1, 1), 0.2) : NightWatch.Palette.textPrimary).color)
                        .textSelectionIfAvailable()
                }
                .font(NightWatch.Typo.mono)
                if let d = c.detail {
                    Text(d).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textTertiary.color)
                }
                if let cwd = c.cwd {
                    Text(cwd).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textQuiet.color)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: NightWatch.Radius.inset, style: .continuous).fill(NightWatch.Palette.inset.color))
            .overlay(RoundedRectangle(cornerRadius: NightWatch.Radius.inset, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        case .plan, .question, .note:
            VStack(alignment: .leading, spacing: 10) {
                if let s = c.turnSummary {
                    let chips = TurnSummaryChips.parse(s)
                    HStack(spacing: 8) { ForEach(Array(chips.enumerated()), id: \.offset) { _, ch in NWTurnChip(chip: ch) } }
                }
                Text(c.ask.isEmpty ? "No details were sent with this page." : c.ask)
                    .font(NightWatch.Typo.body)
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelectionIfAvailable()
                if let cwd = c.cwd {
                    Text(cwd).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textQuiet.color)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: NightWatch.Radius.inset, style: .continuous).fill(NightWatch.Palette.inset.color))
        }
    }

    private func screenNoteView(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash").foregroundColor(NightWatch.Palette.amber.color)
            Text(text).font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: NightWatch.Radius.inset, style: .continuous).fill(NightWatch.Palette.amber.opacity(0.10).color))
    }

    /// Why it is this class, and what undoing would look like. A hint, never a "safe" badge.
    @ViewBuilder private var reasonBlock: some View {
        if row.reversibility != nil, !c.reason.isEmpty || c.undoNote != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !c.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(c.tags, id: \.rawValue) { t in
                            Text(t.rawValue).font(NightWatch.Typo.monoMicro)
                                .foregroundColor(NightWatch.Palette.textSecondary.color)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.07)))
                        }
                    }
                }
                if !c.reason.isEmpty {
                    (Text("WHY  ").font(NightWatch.Typo.label).foregroundColor(NightWatch.Palette.textQuiet.color)
                        + Text(c.reason).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color))
                }
                if let u = c.undoNote { Text(u).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color) }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The prompt's own options, as read from the page. Shown, not offered:
    /// Approve types 1 and nothing else does. An option that would stand for
    /// the future ("don't ask again") reads "Open in terminal to choose this".
    @ViewBuilder private var optionsBlock: some View {
        if c.options.count >= 2 {
            VStack(alignment: .leading, spacing: 8) {
                Text("THE PROMPT OFFERS").nwLabel()
                ForEach(c.options) { o in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(o.number)").font(NightWatch.Typo.monoSmall).foregroundColor(NightWatch.Palette.textQuiet.color).frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(o.text).font(NightWatch.Typo.body)
                                .foregroundColor((o.isStanding ? NightWatch.Palette.textTertiary : NightWatch.Palette.textSecondary).color)
                            if let i = o.instead {
                                Text(i).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.amber.color)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// The tip that points down at the delivery preview, once.
    @ViewBuilder private var previewTip: some View {
        if let tip = state.tip {
            NWTipCallout(text: tip.text(biometry: state.biometry), symbol: tip.symbol, pointer: .down,
                         onDismiss: { actions.dismissTip(tip) })
                .transition(.opacity)
                .onAppear { actions.tipShown(tip) }
        }
    }

    /// The delivery preview of the action in focus: Tell it instead while the
    /// composer is open, else the approve line, else the first action that sends.
    private var previewText: String? {
        if composerOpen, let t = row.action(.tellInstead)?.preview { return t }
        // The answer picker carries its own preview (the review step names exactly what will be chosen).
        if state.ask != nil, c.chip == .question { return nil }
        // Nothing will be typed: the controls below already say why, so a second line adds nothing.
        if row.action(.openOnMac) != nil { return nil }
        return row.focusPreview
    }

    @ViewBuilder private var statusBlock: some View {
        if let p = state.pending, p.isCountdown, case .arming = p.phase(now: state.now) {
            // A message to a busy session waits 10 s with Undo; nothing has left the phone.
            NWSendReceiptView(receipt: SendReceipt(id: "page-send", headline: "", detail: "Nothing has been sent yet.", tone: .working,
                                                   countdown: SendCountdown(startedAt: p.startedAt, duration: p.armDuration)),
                              onUndo: { _ in actions.cancel() })
        } else if let receipt = state.receipt, !receipt.isEmpty {
            // The Receipt thread: arm, sent, then typed and verified only on the Mac's word.
            NWReceiptThreadView(input: receipt, onTap: actions.cancel)
        } else if state.outcome != .none, accepts || state.pending != nil {
            NWOutcomeStrip(outcome: state.outcome, pending: state.pending, onCancel: actions.cancel)
        }
        // Waiting somewhere it can be taken back from: where it is, and Delete.
        if let q = state.queue { NWReplyQueueBlock(status: q, onDelete: actions.deleteQueued) }
        else if let why = state.queueWhyNot {
            Text(why).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
        if let h = state.heldReceipt { NWSendReceiptView(receipt: h, onDelete: actions.deleteHeld) }
        // The line adds the detail ("typed into tmux pane %3"); a failure the thread already says is not said twice.
        if state.queue == nil, let s = state.phase.statusLine(legacyRelay: state.legacyRelay),
           !(state.receipt.map { r in r.frame(now: state.now).word == s.text } ?? false) {
            NWReceiptLine(text: s.text, failed: s.tone == .problem || s.tone == .warn)
        }
    }

    /// An Irreversible approve that passed biometrics: the full ring and its
    /// burst stay while the thread below carries the delivery (until the
    /// sheet takes input again, after a failure).
    private var committedAt: Date? {
        guard irreversible else { return nil }
        if let p = state.pending, ActionGate.requiresBiometrics(kind: p.kind, commit: p.commit) { return p.startedAt }
        return accepts ? nil : state.holdCommittedAt
    }

    @ViewBuilder private var secondaryLinks: some View {
        HStack(spacing: 16) {
            if state.hasSession {
                Button(action: actions.openSession) { Label("Open session", systemImage: "terminal") }
            }
            if c.turnSummary != nil {
                Button(action: actions.viewChanges) { Label("View changes", systemImage: "doc.text.magnifyingglass") }
            }
            Button(action: actions.copy) { Label("Copy", systemImage: "doc.on.doc") }
        }
        .font(NightWatch.Typo.captionStrong)
        .foregroundColor(NightWatch.Palette.textSecondary.color)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        Text(c.footer).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textQuiet.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        let busy = state.pending != nil || !accepts
        VStack(spacing: 10) {
            if let info = c.informational {
                Text(info).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Close", action: actions.close).buttonStyle(NWButtonStyle(kind: .quiet))
            } else if row.action(.openOnMac) != nil {
                Text(c.screenNote != nil ? "Answer this one on your Mac." : (row.action(.openOnMac)?.preview ?? "Page can't type here. Answer this one on your Mac."))
                    .font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if state.hasSession { Button("Open session", action: actions.openSession).buttonStyle(NWButtonStyle(kind: .quiet)) }
            } else if let at = committedAt {
                VStack(spacing: 8) {
                    NWHoldRing(spec: .irreversible, burstStart: at, onComplete: {})
                    Text("Approved with \(state.biometry)")
                        .font(NightWatch.Typo.bodyStrong)
                        .foregroundColor(NightWatch.Palette.textSecondary.color)
                }
                .frame(maxWidth: .infinity)
            } else if !busy || state.phase == .unconfirmed {
                switch c.section {
                case .decide where c.chip == .question:
                    // The composer, when it is up, is in the dock; this is the picker and the way to the composer.
                    if let ask = state.ask {
                        NWAnswerHost(ask: ask, delivery: state.askDelivery, route: c.route, mac: state.macName, agent: c.agent,
                                     fixedSheet: state.fixedSheet, showsChip: false, viaHook: state.askViaHook, onSubmit: actions.submitAnswers)
                        Button("Write a reply instead…") { composerOpen = true }
                            .buttonStyle(NWButtonStyle(kind: .quiet))
                    }
                case .decide:
                    approvalControls
                case .look:
                    lookControls
                case .review:
                    reviewControls
                }
            } else if state.phase.isDelivered {
                EmptyView()
            }
        }
        .disabled(false)
    }

    @ViewBuilder private var approvalControls: some View {
        if !composerOpen {
            if irreversible, row.action(.approve) != nil {
                VStack(spacing: 8) {
                    NWHoldRing(spec: .irreversible, fixedProgress: state.fixedHold, onComplete: actions.holdComplete)
                    Text(HoldRingSpec.prompt(progress: state.fixedHold ?? 0, biometry: state.biometry))
                        .font(NightWatch.Typo.bodyStrong)
                        .foregroundColor(NightWatch.Palette.red.mixed(with: .init(1, 1, 1), 0.35).color)
                }
                .frame(maxWidth: .infinity)
            } else if let approve = row.action(.approve) {
                Button(approve.label, action: actions.approve).buttonStyle(NWButtonStyle(kind: .bright))
            }
            HStack(spacing: 10) {
                if let deny = row.action(.deny) { Button(deny.label, action: actions.deny).buttonStyle(NWButtonStyle(kind: .quiet)) }
                if row.action(.tellInstead) != nil, c.canTell {
                    Button("Tell it instead…") { composerOpen = true }.buttonStyle(NWButtonStyle(kind: .quiet))
                }
            }
        }
    }

    @ViewBuilder private var lookControls: some View {
        if !composerOpen {
            if c.stoppable, row.action(.stop) != nil {
                Button("Stop it", action: actions.stop).buttonStyle(NWButtonStyle(kind: .quiet))
            }
            if row.action(.tellInstead) != nil {
                Button("Steer…") { composerOpen = true }.buttonStyle(NWButtonStyle(kind: .amber))
            }
            Text(c.stoppable ? "Stop presses Esc in the session. A message is queued until its current step ends."
                 : "Your message is typed into the session that started it.")
                .font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Claude's last message asks a yes/no question and this page takes a written reply (the same path as Steer,
    /// so the same gate decides): "Yes" and "No" send exactly those words.
    private var yesNoQuestion: String? {
        YesNoReply.reviewOffer(question: c.yesNo, takesReply: row.action(.tellInstead) != nil, open: accepts && state.pending == nil)
    }

    @ViewBuilder private var reviewControls: some View {
        if !composerOpen {
            if let q = yesNoQuestion {
                NWYesNoReplies(question: q, agent: c.agent, onReply: actions.send)
            }
            if row.action(.carryOn) != nil {
                Button(action: actions.carryOn) { Text("Looks good ✦") }
                    .buttonStyle(NWButtonStyle(kind: yesNoQuestion == nil ? .bright : .quiet))
            }
            if row.action(.tellInstead) != nil {
                Button("Steer…") { composerOpen = true }.buttonStyle(NWButtonStyle(kind: .quiet))
            }
        }
    }

    // MARK: Composer

    /// A message is being written (or is on its way): the dock is up. Never for a page that types nothing.
    private var composing: Bool {
        guard committedAt == nil else { return false }
        guard c.informational == nil, row.action(.openOnMac) == nil else {
            // The row stopped offering a reply under a message being written: the dock stays, locked, with the text.
            return DecisionDraftGuard.keepsDock(composerOpen: composerOpen, draft: draft, rowTakesReply: false)
        }
        return composerOpen || alwaysComposing || DecisionDraftGuard.keepsDock(composerOpen: composerOpen, draft: draft, rowTakesReply: rowTakesReply)
    }

    /// The row still takes a written reply (its actions can change under a message being written).
    private var rowTakesReply: Bool { c.informational == nil && row.action(.openOnMac) == nil && row.action(.tellInstead) != nil }

    /// A question page with no picker to answer from: the composer is the way to answer, so it is always up.
    private var alwaysComposing: Bool { c.section == .decide && c.chip == .question && state.ask == nil }

    private var composerLabels: (label: String, placeholder: String) {
        switch c.section {
        case .decide where c.chip == .question: return ("Answer", "Type your answer…")
        case .decide: return ("Send", "Deny with instructions…")
        case .look: return ("Send", c.stoppable ? "Tell it what to do instead…" : "Tell it what to do next…")
        case .review: return ("Send", "Tell it what to do next…")
        }
    }

    /// A message the person wrote is kept after its page resolved under it (answered at the Mac, superseded).
    private var keptDraft: Bool { DecisionDraftGuard.keepsDraft(phase: state.phase, draft: draft) || (composerOpen && !rowTakesReply && !draft.isEmpty) }

    /// The composer, docked: it is the one part the keyboard moves. Its receipt and delivery preview sit with it,
    /// and it stays (locked) while the message is on its way, so the keyboard and the thread never jump.
    private var composerDock: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusBlock
            if keptDraft { keptNote }
            if let n = state.composerNote { composerNote(n) }
            if let p = state.composerProblem {
                Text(p).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.amber.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            composer(label: composerLabels.label, placeholder: composerLabels.placeholder, alwaysOpen: alwaysComposing)
        }
        .padding(.horizontal, NightWatch.Space.xl)
        .padding(.top, 10)
        .padding(.bottom, 12)
        // Solid under the field (content scrolls beneath it), with a short fade above, in the sheet's own colour.
        .background(alignment: .top) {
            let ground = (row.tint.map { NightWatch.Palette.surface.mixed(with: $0.opacity(1), 0.10) } ?? NightWatch.Palette.surface)
            ZStack(alignment: .top) {
                ground.color.ignoresSafeArea(edges: .bottom)
                LinearGradient(colors: [ground.opacity(0).color, ground.color], startPoint: .top, endPoint: .bottom)
                    .frame(height: 24).offset(y: -24)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Why the box came up with words in it: a countdown the app was killed on, so the message was never sent.
    private func composerNote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.badge.checkmark").foregroundColor(NightWatch.Palette.amber.color)
            Text(text).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NightWatch.Palette.amber.opacity(0.10).color))
        .accessibilityElement(children: .combine)
    }

    private var keptNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.badge.checkmark").foregroundColor(NightWatch.Palette.amber.color)
            Text(rowTakesReply ? "This page is no longer waiting, so nothing was sent. Your message is kept here."
                 : "This page no longer takes a reply here, so nothing was sent. Your message is kept here.")
                .font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Copy") { actions.copyDraft(draft) }
                .font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                .buttonStyle(.plain).frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(Text("Copy your message"))
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NightWatch.Palette.amber.opacity(0.10).color))
        .accessibilityElement(children: .contain)
    }

    /// The composer. Locked until asked for (a message goes only where the page allows). While the message
    /// is on its way it stays, locked, with its progress; the receipt above it says where it has got to.
    private func composer(label: String, placeholder: String, alwaysOpen: Bool) -> some View {
        NWDecisionComposer(
            label: label, placeholder: placeholder, alwaysOpen: alwaysOpen,
            preview: state.sendChoice.holds ? "Your message, then Return · held on your Mac until this turn ends" : row.action(.tellInstead)?.preview,
            yesNo: yesNoQuestion, agent: c.agent, onReply: actions.send,
            choice: state.sendChoice, explainChoice: state.explainChoice, onChoose: actions.setChoice,
            sending: state.pending != nil, locked: !accepts || !rowTakesReply, draft: $draft,
            onCancel: { composerOpen = false; draft = "" }, onSend: { actions.send($0) })
    }
}

/// The composer's box: the field, Send, and the line that says what will be typed and where. One value for
/// the dock to draw, so it keeps its focus for as long as it is on screen.
private struct NWDecisionComposer: View {
    let label: String
    let placeholder: String
    let alwaysOpen: Bool
    let preview: String?
    /// Claude's last message asks this yes/no question: "Yes" and "No" show above an empty field.
    let yesNo: String?
    let agent: String
    var onReply: (String) -> Void
    /// Busy session: Now or When it finishes, in front of the field.
    var choice = SendChoicePlan(mode: .none, selected: .now)
    var explainChoice = false
    var onChoose: (SendChoice) -> Void = { _ in }
    /// The message is being sent (arming or in flight): the field and Send are locked, and progress shows.
    let sending: Bool
    /// The page no longer takes a message: Send is off, the draft can still be read, edited and copied.
    let locked: Bool
    @Binding var draft: String
    var onCancel: () -> Void
    var onSend: (String) -> Void
    @FocusState private var focused: Bool
    /// The draft as it was when the send began. While it is on its way the field keeps its focus (disabling it
    /// would drop the keyboard and the dock with it, Cancel included) and holds this text.
    @State private var heldDraft: String?

    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSend: Bool { hasText && !sending && !locked }
    /// "Your message, then Return" then where it goes.
    private var previewParts: (lead: String, rest: String?) {
        let parts = (preview ?? "").components(separatedBy: " · ")
        let rest = parts.dropFirst().joined(separator: " · ")
        return (parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "Your message", rest.isEmpty ? nil : rest)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(previewParts.lead).nwLabel()
                Spacer()
                if sending {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(NightWatch.Palette.textSecondary.color)
                        Text("Sending…").font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.textSecondary.color)
                    }
                    .accessibilityElement(children: .combine)
                } else if !alwaysOpen {
                    Button("Cancel", action: onCancel)
                        .font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.textSecondary.color)
                        .buttonStyle(.plain).frame(minWidth: 44, minHeight: 44, alignment: .trailing).contentShape(Rectangle())
                        .accessibilityHint(Text("Closes the message box and discards what you wrote."))
                }
            }
            if let rest = previewParts.rest {
                Text(rest).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textQuiet.color)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let q = yesNo, !hasText, !sending, !locked {
                NWYesNoReplies(question: q, agent: agent, onReply: onReply)
            }
            if choice.mode != .none, !sending, !locked {
                NWSendChoiceControl(plan: choice, agent: agent, explain: explainChoice, onChoose: onChoose)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(NightWatch.Typo.body)
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .focused($focused)
                    .submitLabel(.send)
                    // The keyboard's Send key is the same Send as the button. A vertical field may insert the
                    // Return instead of submitting: one Return typed at the end counts too (as in the room).
                    .onSubmit { submit(draft) }
                    .onChange(of: draft) { old, new in
                        if sending { if let held = heldDraft, new != held { draft = held }; return }
                        if DraftSubmit.isReturnKey(old: old, new: new) { draft = old; submit(old) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(sending ? 0.04 : 0.07)))
                    .opacity(sending ? 0.7 : 1)
                    .accessibilityLabel(Text(label == "Answer" ? "Your answer" : "Your message"))
                Button(label) { submit(draft) }
                    .buttonStyle(NWButtonStyle(kind: .bright))
                    .frame(width: 92)
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.45)
                    .accessibilityHint(Text(choice.holds ? "Holds your message on your Mac until the turn ends. You can delete it until then."
                                            : (preview ?? "Sends your message to the session.")))
            }
        }
        // Focus once per opening, after the sheet has settled; and again if a refused send gives the field back.
        .task {
            guard !alwaysOpen else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { focused = true }
        }
        .onChange(of: sending) { was, now in
            heldDraft = now ? draft : nil
            if was && !now && !locked { focused = true }
        }
    }

    private func submit(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSend else { return }
        onSend(text)
    }
}

extension View {
    /// Selectable text where the platform has it.
    @ViewBuilder func textSelectionIfAvailable() -> some View {
        #if os(iOS)
        self.textSelection(.enabled)
        #else
        self
        #endif
    }
}
