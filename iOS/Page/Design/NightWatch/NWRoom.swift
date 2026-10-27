import SwiftUI

// The Session Room: one session, four lenses (Story, Screen, Changes,
// Workflows), a composer that follows the trust model, and Stop as a 0.6 s
// hold. These are plain views over values: the live container fills them
// from the stores and routes every closure through the existing services, the
// render harness fills them from fixtures. Nothing here types anything.

// MARK: - Agent colours

extension AgentCharacter {
    /// Claude copper, Codex slate, a local model's lime, anything else neutral.
    var tint: NightWatch.RGBA {
        switch kind {
        case .claude: return NightWatch.RGBA(hex: 0xE89E64)
        case .codex: return NightWatch.RGBA(hex: 0xC9CEDB)
        case .local: return NightWatch.RGBA(hex: 0xC6E86A)
        case .other: return NightWatch.RGBA(hex: 0xA3ADC2)
        }
    }
}

extension RoomChip.Tone {
    var color: NightWatch.RGBA {
        switch self {
        case .working: return NightWatch.Palette.teal
        case .needsYou: return NightWatch.Palette.amber
        case .quiet: return NightWatch.Palette.textSecondary
        case .warm: return NightWatch.Palette.amber
        case .local: return NightWatch.RGBA(hex: 0xC6E86A)
        }
    }
}

// MARK: - Data and actions

/// Everything the room draws.
struct SessionRoomData {
    var session: LiveSession
    var character: AgentCharacter
    var subtitle: String
    var chips: [RoomChip]
    var lenses: [RoomLens]
    var badges: [RoomLens: Int] = [:]
    var banners: [RoomBanner] = []
    var now: Date
    var macName: String

    // Story
    var story: [StoryBlock] = []
    var truncated = false
    /// "Loading…", "Nothing in this session yet." and so on, when the story is empty.
    var emptyStory: String? = nil
    var storyLoading = false
    var liveLine: String? = nil
    var timingNote: String? = nil
    /// The open page behind a waiting (or finished) session, pinned in the story.
    var pageRow: NowRow? = nil
    var pageOutcome: CardOutcome = .none
    var pagePending: PendingAction? = nil
    /// The question this session is blocked on, when it can be answered from the phone (picker).
    var ask: SessionAsk? = nil
    /// Where the newest answers for that question stand.
    var askDelivery: SentSessionCommand? = nil
    /// The page is one Claude's question hook holds: the answers go as text through it.
    var askViaHook = false

    // Screen
    var screen: SessionScreen? = nil
    var screenFreshness: ScreenFreshness? = nil
    var runs: [WorkflowRun] = []

    // Changes
    var changes: ChangesModel? = nil
    var changesLoad: ChangesModel.Load = .loading
    /// A finished-turn page the Changes lens can answer ("Looks good").
    var reviewRow: NowRow? = nil

    // Composer
    var composer: RoomComposerMode
    var composerCopy: RoomComposerMode.Copy
    var preview: String? = nil
    var composerProblem: String? = nil
    /// Who this room types into, as it showed the user (the header and the receipt read it).
    var target: SessionTarget? = nil
    /// Where the last message went, or why it did not.
    var receipt: SendReceipt? = nil
    /// A line above the composer: the Stop receipt, for instance.
    var stopNote: (text: String, tone: StopNoteTone)? = nil

    // Stop
    var stop: SessionStopPlan
    var stopping = false

    /// Draws the Stop ring part-way (the render harness).
    var fixedStop: Double? = nil
    var fixedHold: Double? = nil

    enum StopNoteTone { case working, good, problem }

    /// The header's folder line (`SessionTarget.whereLine`).
    var whereLine: String? { target?.whereLine }
}

struct SessionRoomActions {
    var close: () -> Void = {}
    var send: (String) -> Void = { _ in }
    var stopCompleted: () -> Void = {}
    var openRun: (String) -> Void = { _ in }
    var openAgent: (String, String) -> Void = { _, _ in }
    var openDecision: (String) -> Void = { _ in }
    var banner: (RoomBanner.Action) -> Void = { _ in }
    var approve: (NowRow) -> Void = { _ in }
    var holdComplete: (NowRow) -> Void = { _ in }
    var deny: (NowRow) -> Void = { _ in }
    var looksGood: (NowRow) -> Void = { _ in }
    var cancel: (String) -> Void = { _ in }
    var refreshChanges: () -> Void = {}
    var copy: (String) -> Void = { _ in }
    var dismissReceipt: (String) -> Void = { _ in }
    /// "Submit all": the draft's answers, for the container to send.
    var submitAnswers: (AnswerSheet) -> Void = { _ in }
}

// MARK: - The room

struct NWSessionRoom: View {
    var data: SessionRoomData
    var actions = SessionRoomActions()
    @Binding var lens: RoomLens
    @Binding var draft: String
    /// The workflow run shown by the Workflows lens.
    @Binding var runId: String?
    /// The room was opened with Type: the composer takes the keyboard once it is on screen.
    var focusComposer = false
    /// The room was opened with Stop: say what holding the stop button does.
    var stopHint = false
    @Environment(\.nwTopInset) private var topInsetOverride
    /// Seconds the Stop button has been held, nil when it is not pressed.
    @State private var stopHeld: TimeInterval?

    private var stopShown: Bool { stopHeld != nil || data.fixedStop != nil || stopHint }

    var body: some View {
        ZStack(alignment: .top) {
            NWBackdrop()
            aurora
            VStack(spacing: 0) {
                topBar
                if stopShown { stopPreview }
                chips
                lensBar
                lensContent
            }
            .padding(.top, topInsetOverride ?? 0)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NWRoomComposer(data: data, draft: $draft, actions: actions, focusOnAppear: focusComposer)
        }
    }

    // MARK: Header

    private var palette: NightWatch.AuroraPalette {
        switch data.session.state {
        case .waitingOnApproval, .waitingOnUser: return .needsYou
        case .active: return .working
        default: return .quiet
        }
    }

    private var aurora: some View {
        ZStack(alignment: .top) {
            NWAnimated { t in NWAuroraCanvas(palette: palette, seconds: t) }
            LinearGradient(stops: [.init(color: .clear, location: 0.0),
                                   .init(color: NightWatch.Palette.backgroundDeep.opacity(0.7).color, location: 0.7),
                                   .init(color: NightWatch.Palette.backgroundDeep.color, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(height: 230)
        .frame(maxWidth: .infinity)
        .clipped()
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: actions.close) {
                Image(systemName: "chevron.down").font(.system(.body, weight: .semibold))
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.white.opacity(0.09)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
            NWAgentGlyph(character: data.character, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(data.session.title)
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(data.subtitle)
                    .font(NightWatch.Typo.subline)
                    .foregroundColor(NightWatch.Palette.textTertiary.color)
                    .lineLimit(1).minimumScaleFactor(0.8)
                // Where this session lives, so two rooms can never read alike: the folder, and the id's first four.
                if let line = data.whereLine {
                    Text(line)
                        .font(NightWatch.Typo.monoMicro)
                        .foregroundColor(NightWatch.Palette.textQuiet.color)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            NWRoomStopButton(plan: data.stop, stopping: data.stopping, agent: data.character.name,
                             fixedProgress: data.fixedStop, held: $stopHeld, onComplete: actions.stopCompleted)
        }
        .padding(.horizontal, NightWatch.Space.lg)
        .padding(.top, 14)
        .accessibilityElement(children: .contain)
    }

    /// What the hold will do, in words, while the ring fills: nothing is a surprise.
    private var stopPreview: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard").foregroundColor(NightWatch.Palette.textTertiary.color)
            Text(data.stop.preview).font(NightWatch.Typo.monoSmall).foregroundColor(NightWatch.Palette.textSecondary.color)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.35)))
        .padding(.horizontal, NightWatch.Space.lg).padding(.top, 10)
        .accessibilityElement(children: .combine)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(data.chips) { c in NWRoomChipView(chip: c) }
            }
            .padding(.horizontal, NightWatch.Space.lg)
        }
        .padding(.top, 12)
    }

    // MARK: Lenses

    private var lensBar: some View {
        HStack(spacing: 2) {
            ForEach(data.lenses) { l in
                let on = l == lens
                Button { lens = l } label: {
                    HStack(spacing: 6) {
                        Text(l.title)
                            .font(.system(.subheadline, weight: on ? .semibold : .medium))
                            .foregroundColor((on ? NightWatch.Palette.textPrimary : NightWatch.Palette.textTertiary).color)
                            .lineLimit(1).minimumScaleFactor(0.75)
                        if let n = data.badges[l] {
                            Text("\(n)").font(.system(.caption2, weight: .bold))
                                .foregroundColor(NightWatch.Palette.teal.color)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(NightWatch.Palette.teal.opacity(0.18).color))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(on ? Color.white.opacity(0.13) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                .accessibilityLabel(Text(l.title + (data.badges[l].map { ", \($0)" } ?? "")))
            }
        }
        .padding(4)
        .background(NWGlassBackground(radius: 22, fill: NightWatch.Palette.surface.opacity(0.9)))
        .padding(.horizontal, NightWatch.Space.lg)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    @ViewBuilder private var lensContent: some View {
        VStack(spacing: 0) {
            ForEach(data.banners) { b in
                NWRoomBannerView(banner: b, onAction: actions.banner)
                    .padding(.horizontal, NightWatch.Space.lg).padding(.top, 8)
            }
            switch lens {
            case .story: NWRoomStory(data: data, actions: actions)
            case .screen: NWRoomScreenLens(data: data, actions: actions)
            case .changes: NWRoomChangesLens(data: data, actions: actions)
            case .workflows: NWRoomWorkflowsLens(data: data, actions: actions, runId: $runId)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Pieces

/// The agent's mark: a rounded square in its colour with its glyph.
struct NWAgentGlyph: View {
    var character: AgentCharacter
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: character.symbol)
            .font(.system(size: size * 0.46, weight: .regular))
            .foregroundColor(character.tint.color)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(character.tint.opacity(0.16).color))
            .accessibilityHidden(true)
    }
}

struct NWRoomChipView: View {
    var chip: RoomChip

    var body: some View {
        let c = chip.tone.color
        HStack(spacing: 7) {
            if let s = chip.symbol {
                Image(systemName: s).font(.system(.caption, weight: .semibold))
            } else {
                Circle().fill(c.color).frame(width: 9, height: 9)
            }
            Text(chip.text).font(.system(.footnote, weight: .bold)).lineLimit(1)
        }
        .foregroundColor(c.color)
        .padding(.horizontal, 14).frame(minHeight: 40)
        .background(Capsule().fill(c.opacity(chip.tone == .quiet ? 0.07 : 0.12).color))
        .overlay(Capsule().strokeBorder(c.opacity(chip.tone == .quiet ? 0.22 : 0.45).color, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(chip.text.capitalized))
    }
}

/// Stop in the room: hold for 0.6 s (a ring fills round the button, amber
/// warming to red), then Esc goes to the session. Letting go early unwinds
/// the ring and sends nothing. While it is held, `held` reports the seconds
/// so the room can say what will be pressed, where, on which Mac.
struct NWRoomStopButton: View {
    var plan: SessionStopPlan
    var stopping: Bool
    var agent: String
    var fixedProgress: Double? = nil
    var held: Binding<TimeInterval?>? = nil
    var onComplete: () -> Void

    var body: some View {
        if stopping {
            ProgressView().tint(NightWatch.Palette.textSecondary.color)
                .frame(width: 52, height: 52)
                .accessibilityLabel(Text("Stopping"))
        } else if plan.canStop {
            NWHoldSurface(spec: SessionStopPlan.spec, fixedProgress: fixedProgress, held: held, onComplete: onComplete) { p in
                let tone = NightWatch.Palette.amber.mixed(with: NightWatch.Palette.red, HoldRingSpec.warmth(progress: p))
                ZStack {
                    Circle().fill(NightWatch.Palette.red.opacity(0.14 + 0.08 * p).color)
                    Circle().stroke(NightWatch.Palette.red.opacity(0.30).color, lineWidth: 2)
                    Circle().trim(from: 0, to: CGFloat(p))
                        .stroke(tone.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke((p > 0 ? tone : NightWatch.Palette.red).color, lineWidth: 2)
                        .frame(width: 16, height: 16)
                }
                .frame(width: 52, height: 52)
            }
            .frame(width: 52, height: 52)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Stop \(agent)"))
            .accessibilityHint(Text("Hold for a moment. \(plan.preview)"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text("Stop")) { onComplete() }
        } else {
            Color.clear.frame(width: 52, height: 52)
        }
    }
}

struct NWRoomBannerView: View {
    var banner: RoomBanner
    var onAction: (RoomBanner.Action) -> Void

    var body: some View {
        let tone: NightWatch.RGBA = banner.tone == .info ? NightWatch.Palette.textSecondary : NightWatch.Palette.amber
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: banner.symbol).font(.system(.body, weight: .semibold)).foregroundColor(tone.color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(banner.title).font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                    Text(banner.message).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let title = banner.actionTitle, let action = banner.action {
                Button(title) { onAction(action) }
                    .buttonStyle(NWButtonStyle(kind: banner.tone == .info ? .quiet : .amber))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NWGlassBackground(radius: 18, tint: banner.tone == .info ? nil : NightWatch.Palette.amber))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Composer

/// The composer, pinned. Its mode follows the session: it types only where
/// the trust model allows, and the delivery preview always says what will be
/// typed, where and on which Mac. While the agent waits on a prompt it is
/// "Tell it instead…", which the page sends as Esc, then your words.
struct NWRoomComposer: View {
    var data: SessionRoomData
    @Binding var draft: String
    var actions: SessionRoomActions
    /// Take the keyboard once, after the room has finished opening (the Type button on Now).
    var focusOnAppear = false
    @FocusState private var focused: Bool
    @State private var didFocus = false

    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 8) {
            if let n = data.stopNote { stopNote(n) }
            if let r = data.receipt { receiptView(r) }
            if let p = data.composerProblem {
                Text(p).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.amber.color)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            }
            if data.composer.offersQuickReplies, data.character.kind != .local, draft.isEmpty { quickReplies }
            switch data.composer {
            case .locked(let why), .disabled(let why):
                lockedBlock(symbol: data.composer.routesThroughPage ? "keyboard" : "lock", title: data.composerCopy.placeholder, text: why)
            case .blocked(let why):
                lockedBlock(symbol: "keyboard.badge.ellipsis", title: why,
                            text: "You can still follow along here, and answer pages from Now.")
            default:
                field
            }
        }
        .padding(.horizontal, NightWatch.Space.lg)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .task(id: data.composer.acceptsText) {
            // After the sheet has settled, and only once there is a field to focus (the mode can still be arriving).
            guard focusOnAppear, !didFocus, data.composer.acceptsText else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !Task.isCancelled { focused = true; didFocus = true }
        }
        // Content scrolls under the composer, so it sits on a fade to the page colour.
        // Solid behind the chips and the field (nothing shows through them), with the fade just above.
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                NightWatch.Palette.backgroundDeep.color.ignoresSafeArea(edges: .bottom)
                LinearGradient(colors: [NightWatch.Palette.backgroundDeep.opacity(0).color, NightWatch.Palette.backgroundDeep.color],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 28).offset(y: -28)
                    .allowsHitTesting(false)
            }
        }
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                TextField(data.composerCopy.placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.system(.body))
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .focused($focused)
                    .submitLabel(.send)
                    // The keyboard's Send key is the same Send as the button. A vertical field may
                    // insert the Return instead of submitting: one Return typed at the end counts too.
                    .onSubmit { submit(draft) }
                    .onChange(of: draft) { old, new in
                        if DraftSubmit.isReturnKey(old: old, new: new) { draft = old; submit(old) }
                    }
                Text(data.preview ?? data.composerCopy.hint)
                    .font(NightWatch.Typo.monoMicro)
                    .foregroundColor(NightWatch.Palette.textQuiet.color)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if draft.count >= SessionComposer.counterFrom {
                    Text("\(draft.count) / \(SessionComposer.maxCharacters)")
                        .font(NightWatch.Typo.monoMicro).monospacedDigit()
                        .foregroundColor((draft.count > SessionComposer.maxCharacters ? NightWatch.Palette.amber : NightWatch.Palette.textTertiary).color)
                }
            }
            .padding(.leading, 6)
            Button {
                submit(draft)
            } label: {
                Image(systemName: "arrow.up").font(.system(.body, weight: .bold))
                    .foregroundColor(NightWatch.Palette.onBright.color)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(hasText
                        ? AnyShapeStyle(LinearGradient(colors: [NightWatch.Palette.teal.color, NightWatch.Palette.sky.color],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(Color.white.opacity(0.14))))
            }
            .buttonStyle(.plain)
            .disabled(!hasText)
            .accessibilityLabel(Text(data.composerCopy.sendLabel))
            .accessibilityHint(Text(data.preview ?? data.composerCopy.hint))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(NWGlassBackground(radius: 30, fill: NightWatch.Palette.surface.opacity(0.95)))
    }

    /// Send, from the button or the keyboard. An empty draft sends nothing: the button is greyed for the same reason.
    private func submit(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        actions.send(text)
    }

    private func receiptView(_ r: SendReceipt) -> some View {
        let tone: NightWatch.RGBA = r.tone == .good ? NightWatch.Palette.teal : (r.tone == .problem ? NightWatch.Palette.amber : NightWatch.Palette.textSecondary)
        return HStack(alignment: .top, spacing: 8) {
            if r.tone == .working { ProgressView().controlSize(.small).tint(tone.color) }
            else { Image(systemName: r.tone == .good ? "checkmark.circle" : "exclamationmark.triangle").foregroundColor(tone.color) }
            VStack(alignment: .leading, spacing: 2) {
                Text(r.headline).font(NightWatch.Typo.captionStrong).foregroundColor(tone.color).fixedSize(horizontal: false, vertical: true)
                if let d = r.detail {
                    Text(d).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textTertiary.color).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if r.tone == .problem {
                Button { actions.dismissReceipt(r.id) } label: {
                    Image(systemName: "xmark").font(.system(.caption, weight: .bold)).foregroundColor(NightWatch.Palette.textTertiary.color)
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tone.opacity(0.09).color))
        .accessibilityElement(children: .combine)
    }

    private var quickReplies: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RoomComposerMode.quickReplies, id: \.self) { q in
                    Button { draft = q; focused = true } label: {
                        Text(q).font(NightWatch.Typo.captionStrong)
                            .foregroundColor(NightWatch.Palette.textSecondary.color)
                            .padding(.horizontal, 14).frame(minHeight: 36)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Puts this in the message box. Nothing is sent until you send it."))
                }
            }
        }
    }

    private func lockedBlock(symbol: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundColor(NightWatch.Palette.textTertiary.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                Text(text).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NWGlassBackground(radius: 22, fill: NightWatch.Palette.surface.opacity(0.95)))
        .accessibilityElement(children: .combine)
    }

    private func stopNote(_ n: (text: String, tone: SessionRoomData.StopNoteTone)) -> some View {
        let tone: NightWatch.RGBA = n.tone == .good ? NightWatch.Palette.teal : (n.tone == .problem ? NightWatch.Palette.amber : NightWatch.Palette.textSecondary)
        return HStack(spacing: 8) {
            if n.tone == .working { ProgressView().controlSize(.small).tint(tone.color) }
            else { Image(systemName: n.tone == .good ? "stop.circle" : "exclamationmark.triangle").foregroundColor(tone.color) }
            Text(n.text).font(NightWatch.Typo.caption).foregroundColor(tone.color).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tone.opacity(0.09).color))
        .accessibilityElement(children: .combine)
    }
}
