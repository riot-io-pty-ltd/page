import SwiftUI

// Answering the terminal's questions (Models/QuestionDraft.swift): the card
// that sits in the Story and over the Screen lens, and in the Decision sheet.
// One question at a time: tap to tick (a round mark for one answer, a square
// for several), "Other" opens a text field, a single answer moves on by
// itself, Back and the progress strip go back, and a last step lists every
// answer above the delivery preview and "Submit all". Nothing is typed until
// then. The card owns no state of its own: the draft is a binding, so the
// Story, the Screen lens and the sheet show the same one.
//
// The only motion is a short one-shot slide between steps (a plain fade under
// Reduce Motion). The glass follows the Card glow setting.

/// The question card over a draft binding. `compact` is the Screen lens's
/// panel: the same content, tighter, with descriptions on one line.
struct NWAnswerCard: View {
    @Binding var sheet: AnswerSheet
    /// Where the newest answers for this question stand (sending, answered, refused…).
    var delivery: SentSessionCommand?
    /// "cmux › page", when known.
    var route: String?
    var mac: String
    var agent = "Claude"
    var compact = false
    /// False where the surrounding screen already says "Question" (the Decision sheet).
    var showsChip = true
    /// The answers go as text through Claude's question hook (nothing is pressed).
    var viaHook = false
    var onSubmit: () -> Void = {}
    /// Called when the step changes, so a scroll view can bring the card's top back into view.
    var onStepChange: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var otherFocused: Bool

    private var amber: NightWatch.RGBA { NightWatch.Palette.amber }
    private var sending: Bool { delivery?.state.isPending == true }
    private var answered: Bool {
        switch delivery?.state { case .typed?, .queued?: return true; default: return false }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            topLine
            progress
            if answered {
                answeredBlock
            } else {
                Group {
                    if sheet.isReview { reviewStep } else if let q = sheet.currentIndex { questionStep(q) }
                }
                .id(sheet.step)
                .transition(stepTransition)
                if !compact { footer }
            }
        }
    }

    /// What the step ends with: how the last send went, and the button that moves on. Over the
    /// terminal it is pinned under the scrolling panel, so Next and Submit all are never scrolled away.
    @ViewBuilder private var footer: some View {
        if !answered {
            VStack(alignment: .leading, spacing: 10) {
                deliveryNote
                if sheet.isReview {
                    Button(action: onSubmit) { Text(retrying ? "Try again" : "Submit all") }
                        .buttonStyle(NWButtonStyle(kind: .bright))
                        .disabled(!sheet.canSubmit || sending)
                        .opacity(sheet.canSubmit && !sending ? 1 : 0.45)
                        .accessibilityHint(Text(sheet.previewLine(route: route, mac: mac, viaHook: viaHook)))
                } else if let q = sheet.currentIndex, sheet.ask.questions[q].multi || sheet.otherChosen(q) {
                    nextButton(q)
                }
            }
        }
    }

    var body: some View {
        let radius: CGFloat = compact ? 22 : NightWatch.Radius.card
        Group {
            if compact {
                // Over the terminal: only as tall as it needs, scrolling past that.
                VStack(spacing: 0) {
                    NWFitScroll(maxHeight: 380, resetKey: AnyHashable(sheet.step)) { content.padding([.horizontal, .top], 14).padding(.bottom, 8) }
                    footer.padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 14)
                }
            } else {
                content.padding(NightWatch.Space.lg)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ZStack {
            // Solid underneath: the terminal's text must not show through the glass.
            if compact { RoundedRectangle(cornerRadius: radius, style: .continuous).fill(NightWatch.Palette.backgroundDeep.color) }
            NWGlassBackground(radius: radius, tint: amber)
        })
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onChange(of: sheet.step) { _, _ in onStepChange() }
        .accessibilityElement(children: .contain)
    }

    private var stepTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity)
    }

    /// A short one-shot slide; none under Reduce Motion.
    private func step(_ change: () -> Void) {
        if reduceMotion { change() } else { withAnimation(.easeOut(duration: 0.2), change) }
    }

    // MARK: Header and progress

    private var topLine: some View {
        HStack(spacing: 10) {
            if showsChip { NWChip(kind: .question, pill: true) }
            Text(positionText)
                .font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
                .lineLimit(1).minimumScaleFactor(0.75)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            if !answered, !sending, sheet.isReview || (sheet.currentIndex ?? 0) > 0 {
                Button { step { sheet.back() } } label: {
                    HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("Back") }
                        .font(NightWatch.Typo.captionStrong)
                        .foregroundColor(NightWatch.Palette.textSecondary.color)
                        .padding(.horizontal, 12).frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Goes back one step. Your answers are kept."))
            }
        }
    }

    private var positionText: String {
        if answered { return "Answered" }
        if sheet.isReview { return "Review · \(sheet.count) answer\(sheet.count == 1 ? "" : "s")" }
        let q = sheet.currentIndex ?? 0
        return "Question \(q + 1) of \(sheet.count) · choose \(sheet.ask.questions[q].multi ? "any" : "one")"
    }

    /// One segment per question, then the review. A tap opens it (never past an unanswered one).
    @ViewBuilder private var progress: some View {
        if sheet.count > 1 || sheet.isReview, !answered {
            HStack(spacing: 6) {
                ForEach(0..<sheet.count, id: \.self) { q in
                    segment(filled: sheet.isAnswered(q), on: sheet.currentIndex == q, reachable: sheet.isReachable(q) && !sending) {
                        step { sheet.go(to: q) }
                    }
                    .accessibilityLabel(Text("Question \(q + 1) of \(sheet.count)" + (sheet.ask.questions[q].header.isEmpty ? "" : ", \(sheet.ask.questions[q].header)")))
                    .accessibilityValue(Text(sheet.isAnswered(q) ? "answered" : "not answered"))
                }
                segment(filled: sheet.canSubmit, on: sheet.isReview, reachable: sheet.canSubmit && !sending) {
                    step { sheet.goToReview() }
                }
                .accessibilityLabel(Text("Review"))
            }
        }
    }

    private func segment(filled: Bool, on: Bool, reachable: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Capsule()
                .fill(on ? amber.color : (filled ? NightWatch.Palette.teal.opacity(0.7).color : Color.white.opacity(0.14)))
                .frame(height: 5)
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!reachable)
    }

    // MARK: A question

    private func questionStep(_ q: Int) -> some View {
        let question = sheet.ask.questions[q]
        return VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            VStack(alignment: .leading, spacing: 4) {
                if !question.header.isEmpty {
                    Text(question.header.uppercased()).font(NightWatch.Typo.label).kerning(NightWatch.Typo.labelTracking)
                        .foregroundColor(amber.color)
                }
                Text(question.text)
                    .font(compact ? NightWatch.Typo.bodyStrong : NightWatch.Typo.title)
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 8) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { i, option in
                    optionRow(q, i, option, multi: question.multi)
                }
                if sheet.allowsOther {
                    otherRow(q, multi: question.multi)
                } else {
                    Text("To answer in your own words, write a reply instead.")
                        .font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                }
            }
            .disabled(sending)
        }
    }

    private func mark(_ on: Bool, multi: Bool) -> some View {
        ZStack {
            if multi {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder((on ? NightWatch.Palette.teal : NightWatch.Palette.textQuiet).color, lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? NightWatch.Palette.teal.opacity(0.2).color : .clear))
                if on { Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundColor(NightWatch.Palette.teal.color) }
            } else {
                Circle().strokeBorder((on ? NightWatch.Palette.teal : NightWatch.Palette.textQuiet).color, lineWidth: 2)
                if on { Circle().fill(NightWatch.Palette.teal.color).frame(width: 12, height: 12) }
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    private func rowBackground(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: NightWatch.Radius.inset, style: .continuous)
            .fill(on ? NightWatch.Palette.teal.opacity(0.10).color : Color.white.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: NightWatch.Radius.inset, style: .continuous)
                .strokeBorder(on ? NightWatch.Palette.teal.opacity(0.55).color : Color.white.opacity(0.07), lineWidth: 1))
    }

    private func optionRow(_ q: Int, _ i: Int, _ option: AskOption, multi: Bool) -> some View {
        let on = sheet.isPicked(q, option: i)
        return Button {
            if multi { sheet.tap(option: i) } else { step { sheet.tap(option: i) } }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                mark(on, multi: multi)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    if !option.detail.isEmpty {
                        Text(option.detail).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
                            .multilineTextAlignment(.leading).lineLimit(compact ? 1 : 3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: compact ? 44 : 48, alignment: .leading)
            .background(rowBackground(on))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(option.label + (option.detail.isEmpty ? "" : ". " + option.detail)))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(Text(multi ? "Ticks or unticks it" : "Picks it and moves to the next step"))
    }

    private func otherRow(_ q: Int, multi: Bool) -> some View {
        let on = sheet.otherChosen(q)
        let text = Binding(get: { sheet.otherText(q) }, set: { sheet.setOther($0) })
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                sheet.toggleOther()
                otherFocused = sheet.otherChosen(q)
            } label: {
                HStack(spacing: 12) {
                    mark(on, multi: multi)
                    Text("Other…").font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                    Spacer(minLength: 0)
                    Image(systemName: "pencil").font(.system(.footnote)).foregroundColor(NightWatch.Palette.textTertiary.color)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Other"))
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint(Text("Opens a box to type your own answer"))
            if on {
                TextField("Type your answer", text: text)
                    .font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textPrimary.color)
                    .focused($otherFocused)
                    .submitLabel(multi ? .done : .next)
                    .onSubmit { if !multi { step { sheet.commitOther() } } }
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.35)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                    .accessibilityLabel(Text("Your own answer"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(on))
    }

    private func nextButton(_ q: Int) -> some View {
        let ready = sheet.isAnswered(q) && !sheet.otherNeedsText(q)
        let last = q == sheet.count - 1 || (0..<sheet.count).allSatisfy { $0 == q || sheet.isAnswered($0) }
        return Button { step { sheet.next() } } label: { Text(last ? "Review answers" : "Next") }
            .buttonStyle(NWButtonStyle(kind: .bright))
            .disabled(!ready || sending)
            .opacity(ready ? 1 : 0.45)
            .accessibilityHint(Text(ready ? "Moves on. Nothing is sent yet." : "Choose an answer first"))
    }

    // MARK: Review

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            Text("Check your answers").font(compact ? NightWatch.Typo.bodyStrong : NightWatch.Typo.title)
                .foregroundColor(NightWatch.Palette.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 8) {
                ForEach(sheet.reviewRows(), id: \.index) { row in
                    Button { step { sheet.go(to: row.index) } } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.header.uppercased()).font(NightWatch.Typo.label).kerning(NightWatch.Typo.labelTracking)
                                    .foregroundColor(NightWatch.Palette.textQuiet.color)
                                if !compact {
                                    Text(row.question).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                }
                                Text(row.answer).font(NightWatch.Typo.bodyStrong)
                                    .foregroundColor((sheet.isAnswered(row.index) ? NightWatch.Palette.textPrimary : NightWatch.Palette.amber).color)
                                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "pencil").font(.system(.footnote)).foregroundColor(NightWatch.Palette.textQuiet.color)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: NightWatch.Radius.inset, style: .continuous).fill(Color.white.opacity(0.05)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(sending)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("\(row.header). \(row.question) Your answer: \(row.answer)"))
                    .accessibilityHint(Text("Opens this question to change it"))
                }
            }
            previewBlock
        }
    }

    /// The delivery preview, in full: what will be chosen, where, on which Mac. It may take a few lines
    /// (the shared preview stops at two, which would cut off the route).
    private var previewBlock: some View {
        let text = sheet.previewLine(route: route, mac: mac, viaHook: viaHook)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "keyboard").font(.system(.footnote, weight: .medium))
                .foregroundColor(NightWatch.Palette.textTertiary.color)
            Text(text).font(NightWatch.Typo.monoSmall).foregroundColor(NightWatch.Palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: NightWatch.Radius.inset, style: .continuous).fill(Color.white.opacity(0.05)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }

    private var retrying: Bool {
        switch delivery?.state { case .refused?, .failed?, .noAnswer?: return true; default: return false }
    }

    // MARK: Delivery

    @ViewBuilder private var deliveryNote: some View {
        if let d = delivery {
            switch d.state {
            case .sending:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(NightWatch.Palette.textSecondary.color)
                    Text("Sending your answers to \(DeliveryPreview.macLabel(mac))…")
                        .font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            case .refused, .failed, .noAnswer:
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(amber.color)
                    Text(d.state.explanation(.answer, agent: agent) ?? "").font(NightWatch.Typo.caption)
                        .foregroundColor(NightWatch.Palette.textSecondary.color).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(amber.opacity(0.10).color))
                .accessibilityElement(children: .combine)
            case .typed, .queued:
                EmptyView()
            }
        }
    }

    private var answeredBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(NightWatch.Palette.teal.color)
                Text("Answered").font(NightWatch.Typo.title).foregroundColor(NightWatch.Palette.textPrimary.color)
            }
            Text(sheet.summaryLine).font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = delivery?.state.explanation(.answer, agent: agent) {
                Text(detail).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textTertiary.color)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Live host

/// The card over the shared draft store (`AnswerDraftStore`), so the Story, the
/// Screen lens and the Decision sheet show one draft. `fixedSheet` draws a
/// given draft instead (the render harness).
struct NWAnswerHost: View {
    var ask: SessionAsk
    var delivery: SentSessionCommand?
    var route: String?
    var mac: String
    var agent = "Claude"
    var compact = false
    var fixedSheet: AnswerSheet? = nil
    var showsChip = true
    var viaHook = false
    var onSubmit: (AnswerSheet) -> Void = { _ in }
    var onStepChange: () -> Void = {}
    @ObservedObject private var drafts = AnswerDraftStore.shared

    var body: some View {
        let binding: Binding<AnswerSheet> = fixedSheet.map { .constant($0) } ?? drafts.binding(for: ask, allowsOther: !viaHook)
        NWAnswerCard(sheet: binding, delivery: delivery, route: route, mac: mac, agent: agent, compact: compact, showsChip: showsChip, viaHook: viaHook,
                     onSubmit: { onSubmit(binding.wrappedValue) }, onStepChange: onStepChange)
    }
}

extension SessionRoomData {
    /// "cmux › page": the terminal and the project the answers go to.
    var answerRoute: String? { DeliveryPreview.route(host: session.host, project: target?.project ?? session.title) }
}

private struct NWFitHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A scroll view only as tall as its content, up to `maxHeight` (then it
/// scrolls), so a panel over the terminal leaves the screen above it
/// tappable and readable. `resetKey` changing scrolls back to the top.
struct NWFitScroll<Content: View>: View {
    var maxHeight: CGFloat
    var resetKey: AnyHashable? = nil
    @ViewBuilder var content: () -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("nw-fit-top")
                    content()
                }
                .background(GeometryReader { g in Color.clear.preference(key: NWFitHeightKey.self, value: g.size.height) })
            }
            .frame(height: height == 0 ? maxHeight : min(height, maxHeight))
            .onPreferenceChange(NWFitHeightKey.self) { height = $0 }
            .onChange(of: resetKey) { _, _ in proxy.scrollTo("nw-fit-top", anchor: .top) }
        }
    }
}
