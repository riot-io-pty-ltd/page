import SwiftUI

/// The Story lens: the transcript as a readable thread. Your messages are
/// right-aligned bubbles (stamped "from iPhone" when they came from here),
/// the agent's words sit on the left beside its mark, consecutive tool calls
/// fold into one "N STEPS" card, and an open decision is pinned inline as the
/// same card Now uses. The wire has no tool results, so a step shows only
/// what was done, never an invented count or exit code.
struct NWRoomStory: View {
    var data: SessionRoomData
    var actions: SessionRoomActions
    @State private var atBottom = true
    @State private var scrollRequest = 0
    @State private var openedGroups = Set<String>()
    /// Bumped when the question card changes step: its top (Back, the question) is brought into view.
    @State private var askStep = 0

    private static let bottomId = "story-bottom"
    private static let askId = "story-ask"

    var body: some View {
        let signature = data.story.map(\.id).joined(separator: "|") + "\(data.story.count)" + (data.liveLine ?? "")
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if data.truncated {
                        Text("Earlier messages aren't shown")
                            .font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textQuiet.color)
                            .frame(maxWidth: .infinity)
                    }
                    if let progress = data.character.privacyTitle, data.character.kind == .local {
                        privacyCard(progress)
                    }
                    if data.story.isEmpty { empty }
                    ForEach(Array(data.story.enumerated()), id: \.element.id) { i, block in
                        blockView(block, isLast: i == data.story.count - 1)
                    }
                    if let line = data.liveLine { NWLiveLine(text: line) }
                    if let row = data.pageRow { pinned(row) }
                    if let note = data.timingNote { NWInfoNote(text: note) }
                    Color.clear.frame(height: 1).id(Self.bottomId)
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, NightWatch.Space.lg)
                .padding(.top, 10).padding(.bottom, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: signature) { _, _ in if atBottom { scrollToBottom(proxy) } }
            .onChange(of: askStep) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.askId, anchor: .top) } }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom && !data.story.isEmpty {
                    Button { scrollToBottom(proxy) } label: {
                        Image(systemName: "arrow.down").font(.system(.body, weight: .semibold))
                            .foregroundColor(NightWatch.Palette.textPrimary.color)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(NightWatch.Palette.surfaceRaised.color))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                    .accessibilityLabel(Text("Jump to latest"))
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
    }

    // MARK: Blocks

    @ViewBuilder private func blockView(_ block: StoryBlock, isLast: Bool) -> some View {
        switch block {
        case .divider(_, let label):
            NWStoryDivider(label: label)
        case .user(let entry, let delivery):
            NWUserBubble(text: entry.displayText, photos: entry.photoCount, delivery: delivery, pending: false, agent: data.character.name,
                         pageId: data.session.interventionId, onOpenDecision: actions.openDecision, onCopy: actions.copy)
        case .pending(let c):
            NWUserBubble(text: c.text, photos: c.photos?.count ?? 0, delivery: c, pending: true, agent: data.character.name,
                         pageId: data.session.interventionId, onOpenDecision: actions.openDecision, onCopy: actions.copy,
                         onPutBack: data.putBackId == c.clientId ? actions.putBackPhotos : nil,
                         // The newest message's receipt (above the field) carries its own Delete: not twice.
                         canDelete: data.canDeleteHeld && !c.state.isHeldTyping && data.receipt?.id != c.clientId, note: data.retractNotes[c.clientId],
                         onDelete: actions.deleteHeld,
                         canUndo: SendReceipt.bubbleOffersUndo(c, receiptId: data.receipt?.id), onUndo: actions.undoSend)
        case .assistant(let e):
            HStack(alignment: .top, spacing: 12) {
                NWAgentGlyph(character: data.character, size: 34)
                Text(e.text)
                    .font(.system(.body)).foregroundColor(NightWatch.Palette.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelectionIfAvailable()
                    .contextMenu { Button { actions.copy(e.text) } label: { Label("Copy", systemImage: "doc.on.doc") } }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("\(data.character.name): \(e.text)"))
        case .steps(let id, let steps, let live):
            NWStepsCard(steps: steps, live: live, expanded: live || isLast || openedGroups.contains(id),
                        onToggle: { if openedGroups.contains(id) { openedGroups.remove(id) } else { openedGroups.insert(id) } })
        case .marker(_, let text):
            Text(text).font(NightWatch.Typo.caption).kerning(0.3)
                .foregroundColor(NightWatch.Palette.textTertiary.color)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .frame(maxWidth: .infinity)
        }
    }

    /// An open page, pinned inline: the same card as in Now.
    @ViewBuilder private func pinned(_ row: NowRow) -> some View {
        switch row.section {
        case .decide where row.chip == .question:
            if let ask = data.ask {
                NWAnswerHost(ask: ask, delivery: data.askDelivery, route: data.answerRoute, mac: data.macName,
                             agent: data.character.name, viaHook: data.askViaHook, onSubmit: actions.submitAnswers,
                             onStepChange: { askStep += 1 })
                    .id(Self.askId)
            } else {
                NWQuestionCard(row: row, now: data.now, onOpen: { actions.openDecision(row.id) })
            }
        case .decide where row.canSwipeApprove:
            NWUndoableRow(row: row, now: data.now, outcome: data.pageOutcome, pending: data.pagePending,
                          onApprove: { actions.approve(row) }, onOpen: { actions.openDecision(row.id) }, onCancel: { actions.cancel(row.id) })
        case .decide:
            NWDecideCard(row: row, now: data.now, outcome: data.pageOutcome, pending: data.pagePending, fixedHold: data.fixedHold,
                         onApprove: { actions.approve(row) }, onHoldComplete: { actions.holdComplete(row) },
                         onDeny: { actions.deny(row) }, onOpen: { actions.openDecision(row.id) }, onCancel: { actions.cancel(row.id) })
        case .look:
            NWLookCard(row: row, now: data.now, outcome: data.pageOutcome, pending: data.pagePending,
                       onSteer: { actions.openDecision(row.id) }, onOpen: { actions.openDecision(row.id) }, onCancel: { actions.cancel(row.id) })
        case .review:
            EmptyView()
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            if data.storyLoading { ProgressView().tint(NightWatch.Palette.textSecondary.color) }
            Text(data.emptyStory ?? "Nothing in this session yet.")
                .font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textTertiary.color)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private func privacyCard(_ title: String) -> some View {
        let lime = data.character.tint
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield").foregroundColor(lime.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                if let note = data.character.privacyNote {
                    Text(note).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(NWGlassBackground(radius: 18, fill: NightWatch.Palette.surface.mixed(with: lime.opacity(1), 0.06).opacity(0.95)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Story pieces

struct NWStoryDivider: View {
    var label: String
    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            Text(label.uppercased()).font(NightWatch.Typo.monoMicro).kerning(1.2)
                .foregroundColor(NightWatch.Palette.textTertiary.color).fixedSize()
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }
}

/// Your message: right-aligned, with its delivery state underneath. A
/// refusal says why and, for a waiting prompt, offers the decision.
struct NWUserBubble: View {
    var text: String
    /// Photos the message carried (`images-v1`): a chip on the bubble.
    var photos = 0
    var delivery: SentSessionCommand?
    var pending: Bool
    var agent: String
    var pageId: String?
    var onOpenDecision: (String) -> Void
    var onCopy: (String) -> Void
    /// A refused photo message, back into the message box (its photos are still held).
    var onPutBack: ((String) -> Void)? = nil
    /// Delete, offered on a held message whose receipt isn't already carrying one (`retract-v1`).
    var canDelete = false
    var note: RetractNote? = nil
    var onDelete: (String) -> Void = { _ in }
    /// Undo, offered on any message still counting down whose receipt isn't carrying one: not just the newest.
    var canUndo = false
    var onUndo: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack {
                Spacer(minLength: 56)
                VStack(alignment: .leading, spacing: text.isEmpty ? 0 : 8) {
                    if photos > 0 { NWPhotoChip(count: photos) }
                    if !text.isEmpty {
                        Text(text)
                            .font(.system(.body)).foregroundColor(NightWatch.Palette.textPrimary.color)
                            .textSelectionIfAvailable()
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 24, bottomTrailingRadius: 8, topTrailingRadius: 24, style: .continuous)
                    .fill(NightWatch.Palette.sky.mixed(with: NightWatch.Palette.backgroundDeep, pending ? 0.88 : 0.74).color))
                .contextMenu { if !text.isEmpty { Button { onCopy(text) } label: { Label("Copy", systemImage: "doc.on.doc") } } }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("You: \(text)" + (photos > 0 ? (text.isEmpty ? "" : ", ") + PhotoDraft.countLabel(photos) : "")))
            .accessibilityValue(Text(delivery.map { $0.spokenStatus(agent: agent) } ?? ""))
            if let delivery { deliveryLine(delivery) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func deliveryLine(_ message: SentSessionCommand) -> some View {
        let state = message.state
        let color: NightWatch.RGBA
        let icon: String?
        switch state {
        case .sending: color = NightWatch.Palette.textTertiary; icon = nil
        case .counting: color = NightWatch.Palette.textTertiary; icon = "clock"
        case .held: color = NightWatch.Palette.sky; icon = "clock"
        case .deleted: color = NightWatch.Palette.textTertiary; icon = "trash"
        case .unconfirmed: color = NightWatch.Palette.amber; icon = "questionmark.circle"
        case .typed: color = NightWatch.Palette.teal; icon = "checkmark"
        case .queued: color = NightWatch.Palette.textSecondary; icon = "clock"
        case .refused, .failed: color = NightWatch.Palette.amber; icon = "exclamationmark.triangle.fill"
        case .noAnswer: color = NightWatch.Palette.amber; icon = "questionmark.circle"
        }
        let explanation = message.statusExplanation(agent: agent)
        return VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon) } else { ProgressView().controlSize(.mini) }
                Text(message.statusLabel())
            }
            .font(.system(.caption2, weight: .semibold)).foregroundColor(color.color)
            .accessibilityHidden(true)
            if let explanation {
                Text(explanation).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
            if canUndo {
                Button { onUndo(message.clientId) } label: {
                    Text("Undo").font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                        .padding(.horizontal, 10).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Nothing is sent and your message goes back in the message box."))
            }
            if case .held = state, canDelete || note != nil {
                NWHeldActions(clientId: message.clientId, note: note, canDelete: canDelete, onDelete: onDelete)
            }
            if let onPutBack, message.photos != nil {
                switch state {
                case .refused, .failed:
                    Button { onPutBack(message.clientId) } label: {
                        Text("Put it back in the message box").font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                            .padding(.horizontal, 6).frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Your photos and caption go back in the message box to send again."))
                default: EmptyView()
                }
            }
            if case .refused(let reason, _) = state, reason == "waiting", let pageId {
                Button("Open decision") { onOpenDecision(pageId) }
                    .font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.amber.color).frame(minHeight: 36)
            }
        }
        .padding(.leading, 56)
    }
}

/// "5 STEPS": consecutive tool calls in one card. The newest one of a busy
/// session spins.
struct NWStepsCard: View {
    var steps: [StoryStep]
    var live: Bool
    var expanded: Bool
    var onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack {
                    Text("\(steps.count) STEP\(steps.count == 1 ? "" : "S")").font(NightWatch.Typo.label).kerning(1.4)
                        .foregroundColor(NightWatch.Palette.textTertiary.color)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(.footnote, weight: .semibold))
                        .foregroundColor(NightWatch.Palette.textTertiary.color)
                }
                .padding(.horizontal, 18).frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(steps.count) steps"))
            .accessibilityHint(Text(expanded ? "Collapses the steps" : "Shows the steps"))
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { i, s in
                        let isLive = live && i == steps.count - 1
                        HStack(spacing: 14) {
                            Group {
                                if isLive { ProgressView().controlSize(.small).tint(NightWatch.Palette.teal.color) }
                                else { Image(systemName: s.symbol).font(.system(.subheadline)).foregroundColor(NightWatch.Palette.textTertiary.color) }
                            }
                            .frame(width: 24)
                            Text(s.title)
                                .font(s.mono ? NightWatch.Typo.monoBody : NightWatch.Typo.body)
                                .foregroundColor((isLive ? NightWatch.Palette.teal : NightWatch.Palette.textPrimary).color)
                                .lineLimit(2).truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 18).frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text(s.title))
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .background(NWGlassBackground(radius: 20, fill: NightWatch.Palette.inset.opacity(0.9)))
    }
}

/// The live line at the foot of a busy story: three dots and what the agent
/// is doing now.
struct NWLiveLine: View {
    var text: String

    var body: some View {
        HStack(spacing: 12) {
            NWAnimated { t in
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle().fill(NightWatch.Palette.teal.opacity(0.35 + 0.65 * max(0, sin(t * 3 - Double(i) * 0.9))).color)
                            .frame(width: 8, height: 8)
                    }
                }
            }
            Text(text).font(NightWatch.Typo.subline).foregroundColor(NightWatch.Palette.teal.color).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Working: \(text)"))
    }
}

/// A quiet note with an info glyph (when a message lands, who can be typed to).
struct NWInfoNote: View {
    var text: String
    var symbol = "info.circle"

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundColor(NightWatch.Palette.textTertiary.color)
            Text(text).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.045)))
        .accessibilityElement(children: .combine)
    }
}
