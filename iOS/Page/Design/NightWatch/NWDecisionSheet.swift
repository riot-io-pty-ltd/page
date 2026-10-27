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
    /// The delivery state of this sheet's action, drawn as its Receipt thread.
    var receipt: ReceiptThreadInput? = nil
    /// When an Irreversible approve passed biometrics here (it outlives the
    /// pending action, so the burst is not cut short by a quick relay).
    var holdCommittedAt: Date? = nil
    /// The first-time tip for the delivery preview ("Will type … shows exactly what lands on your Mac"), while it is unseen.
    var tip: NWTip? = nil
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
    var close: () -> Void = {}
    var retry: () -> Void = {}
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

private struct NWPinnedAskHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The Decision sheet's content: who is asking, the ask in full, why it is
/// the class it is, the delivery preview (what will be typed, where, on which
/// Mac) and the controls its class allows. Undoable and Considered approve
/// with a tap and the 1.2 s cancel ring; Irreversible only through the hold
/// ring, then Face ID / Touch ID / passcode. "Tell it instead" opens a
/// composer that sends Esc, then your message, then Return; while the sheet
/// is waiting on an approval, free text can never reach a live prompt any
/// other way. Every action is a closure for the container to route through
/// the existing services.
struct NWDecisionScreen: View {
    var state: DecisionScreenState
    var actions = DecisionScreenActions()
    @Binding var draft: String
    @Binding var composerOpen: Bool
    @FocusState private var focused: Bool

    /// The tallest the pinned command grows before it scrolls inside its own box.
    @ScaledMetric(relativeTo: .body) private var pinnedAskCap: CGFloat = 132
    @State private var pinnedAskHeight: CGFloat = 0

    /// Below this sheet height there is no room to pin the command, the preview
    /// and the controls and still read the headline above them.
    private static let pinnedMinHeight: CGFloat = 580

    var body: some View {
        GeometryReader { geo in
            // The answer picker is as tall as a screenful: it flows with the rest instead of being pinned.
            if geo.size.height >= Self.pinnedMinHeight, !(state.ask != nil && c.chip == .question) { pinnedLayout } else { flowingLayout }
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
                if let p = previewText { previewTip; NWDeliveryPreview(text: p) }
                statusBlock
            }
            .padding(.horizontal, NightWatch.Space.xl)
            controls
                .padding(.horizontal, NightWatch.Space.xl)
                .padding(.top, 8)
                .padding(.bottom, NightWatch.Space.lg)
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
                if let p = previewText { previewTip; NWDeliveryPreview(text: p) }
                statusBlock
                controls
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
        if let receipt = state.receipt, !receipt.isEmpty {
            // The Receipt thread: arm, sent, then typed and verified only on the Mac's word.
            NWReceiptThreadView(input: receipt, onTap: actions.cancel)
        } else if state.outcome != .none, accepts || state.pending != nil {
            NWOutcomeStrip(outcome: state.outcome, pending: state.pending, onCancel: actions.cancel)
        }
        // The line adds the detail ("typed into tmux pane %3"); a failure the thread already says is not said twice.
        if let s = state.phase.statusLine(legacyRelay: state.legacyRelay),
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
                    if let ask = state.ask, !composerOpen {
                        NWAnswerHost(ask: ask, delivery: state.askDelivery, route: c.route, mac: state.macName, agent: c.agent,
                                     fixedSheet: state.fixedSheet, showsChip: false, viaHook: state.askViaHook, onSubmit: actions.submitAnswers)
                        Button("Write a reply instead…") { composerOpen = true }
                            .buttonStyle(NWButtonStyle(kind: .quiet))
                    } else if state.ask != nil {
                        composer(label: "Answer", placeholder: "Type your answer…", alwaysOpen: false)
                    } else {
                        composer(label: "Answer", placeholder: "Type your answer…", alwaysOpen: true)
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
        if composerOpen {
            composer(label: "Send", placeholder: "Deny with instructions…", alwaysOpen: false)
        } else {
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
        if composerOpen {
            composer(label: "Send", placeholder: c.stoppable ? "Tell it what to do instead…" : "Tell it what to do next…", alwaysOpen: false)
        } else {
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

    @ViewBuilder private var reviewControls: some View {
        if composerOpen {
            composer(label: "Send", placeholder: "Tell it what to do next…", alwaysOpen: false)
        } else {
            if row.action(.carryOn) != nil {
                Button(action: actions.carryOn) { Text("Looks good ✦") }.buttonStyle(NWButtonStyle(kind: .bright))
            }
            if row.action(.tellInstead) != nil {
                Button("Steer…") { composerOpen = true }.buttonStyle(NWButtonStyle(kind: .quiet))
            }
        }
    }

    /// The composer. Locked until asked for: a written reply to a waiting
    /// prompt is Esc, then the text, then Return, and the label says so.
    private func composer(label: String, placeholder: String, alwaysOpen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(row.action(.tellInstead)?.preview?.components(separatedBy: " · ").first ?? "Your message").nwLabel()
                Spacer()
                if !alwaysOpen {
                    Button("Cancel") { composerOpen = false; draft = "" }
                        .font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.textSecondary.color)
                        .buttonStyle(.plain).frame(minHeight: 32)
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(NightWatch.Typo.body)
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .focused($focused)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.07)))
                Button(label) { actions.send(draft) }
                    .buttonStyle(NWButtonStyle(kind: .bright))
                    .frame(width: 92)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }
        }
        .onAppear { if !alwaysOpen { focused = true } }
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
