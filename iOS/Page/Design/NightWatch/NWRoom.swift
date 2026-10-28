import SwiftUI
import PhotosUI

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
    /// A plain-text yes/no question Claude's last message ends on, for an idle session that takes a message:
    /// the composer offers "Yes" and "No" (`YesNoReply.roomOffer`).
    var yesNo: String? = nil
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
    /// How a message to a busy session goes: the "Now" / "When it finishes" choice, or one fixed way.
    var choice = SendChoicePlan(mode: .none, selected: .now)
    /// Say what each way means (once, until a message has gone out with the choice shown).
    var explainChoice = false
    /// The Mac takes held messages back (`retract-v1`): a Delete on each held bubble.
    var canDeleteHeld = false
    /// Where each Delete stands, by the held message's clientId.
    var retractNotes: [String: RetractNote] = [:]
    /// A Yes or No in its arm ring.
    var yesNoArm: YesNoArm? = nil
    /// The photo button (`images-v1`), and the photos waiting in the composer.
    var photoOffer = PhotoOffer.hidden
    var photos: [PhotoDraftItem] = []
    /// The refused photo message (clientId) that can be put back in the composer (its bytes are still held).
    var putBackId: String? = nil

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
    /// "Now" / "When it finishes" chosen.
    var setChoice: (SendChoice) -> Void = { _ in }
    /// Undo, by the message's clientId: nothing was sent, the text goes back to the composer.
    var undoSend: (String) -> Void = { _ in }
    /// Delete a held message, by its clientId.
    var deleteHeld: (String) -> Void = { _ in }
    /// A Yes or No tapped: arm it. `cancelArm` puts it away before anything is sent.
    var armReply: (String) -> Void = { _ in }
    var cancelArm: () -> Void = {}
    /// "Submit all": the draft's answers, for the container to send.
    var submitAnswers: (AnswerSheet) -> Void = { _ in }
    /// Photos picked (`images-v1`); the container loads and re-encodes them.
    var pickPhotos: ([PhotosPickerItem]) -> Void = { _ in }
    /// A thumbnail's ×, by the draft item's id.
    var removePhoto: (String) -> Void = { _ in }
    /// The dimmed photo button tapped: the container says why it can't be used now.
    var photoBlocked: (String) -> Void = { _ in }
    /// A refused photo message back into the composer, by its clientId.
    var putBackPhotos: (String) -> Void = { _ in }
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
    @Environment(\.nwChromeGlassOn) private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The top bar's glass: the Stop button and the words of its hold.
    @Namespace private var glassSpace

    private var stopShown: Bool { stopHeld != nil || data.fixedStop != nil || stopHint }

    var body: some View {
        ZStack(alignment: .top) {
            NWBackdrop()
            aurora
            VStack(spacing: 0) {
                // One glass group: what the hold will do comes out of the Stop button and goes back into it.
                NWChromeGlassGroup {
                    VStack(spacing: 0) {
                        topBar
                        if stopShown { stopPreview }
                    }
                }
                chips
                lensBar
                lensContent
            }
            // Only glass morphs; without it the words come and go at once, as they always have.
            .animation(glass && !reduceMotion ? .smooth(duration: 0.3) : nil, value: stopShown)
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
                    .nwChromeGlass(in: Circle()) { Circle().fill(Color.white.opacity(0.09)) }
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
                .nwChromeGlassID("stop", in: glassSpace)
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
        .nwChromeGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: false) {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.35))
        }
        .nwChromeGlassID("stop-preview", in: glassSpace)
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

    /// Every lens title in one size. Equal widths when they all fit, then all
    /// one step smaller together; past that (large Dynamic Type) each takes its
    /// own width and the bar scrolls, as Android's does. A title never shrinks
    /// on its own, so Story and Workflows never differ in size.
    private var lensBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 2) { lensButtons(equal: true, style: .subheadline) }
            // A narrow phone: every title one step smaller, together.
            HStack(spacing: 2) { lensButtons(equal: true, style: .footnote) }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) { lensButtons(equal: false, style: .subheadline) }
                }
                // The lens in use is always in view, whichever way it was chosen.
                .onAppear { proxy.scrollTo(lens, anchor: .center) }
                .onChange(of: lens) { _, l in withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(l, anchor: .center) } }
            }
        }
        .padding(4)
        // The lenses are the room's tabs: chrome, so glass where there is glass.
        .nwChromeGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous)) {
            NWGlassBackground(radius: 22, fill: NightWatch.Palette.surface.opacity(0.9))
        }
        .padding(.horizontal, NightWatch.Space.lg)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private func lensButtons(equal: Bool, style: Font.TextStyle) -> some View {
        ForEach(data.lenses) { l in
            let on = l == lens
            Button { lens = l } label: {
                HStack(spacing: 6) {
                    // Semibold is reserved underneath the medium title, so selecting a lens never changes its width.
                    Text(l.title)
                        .font(.system(style, weight: .semibold)).hidden()
                        .overlay(Text(l.title)
                            .font(.system(style, weight: on ? .semibold : .medium))
                            .foregroundColor((on ? NightWatch.Palette.textPrimary : NightWatch.Palette.textTertiary).color))
                        .lineLimit(1).fixedSize()
                    if let n = data.badges[l] {
                        Text("\(n)").font(.system(.caption2, weight: .bold))
                            .foregroundColor(NightWatch.Palette.teal.color)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(NightWatch.Palette.teal.opacity(0.18).color))
                            .fixedSize()
                    }
                }
                .padding(.horizontal, equal ? 8 : 12)
                .frame(maxWidth: equal ? .infinity : nil, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(on ? Color.white.opacity(0.13) : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(l)
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel(Text(l.title + (data.badges[l].map { ", \($0)" } ?? "")))
        }
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
                    Circle().stroke(NightWatch.Palette.red.opacity(0.30).color, lineWidth: 2)
                    Circle().trim(from: 0, to: CGFloat(p))
                        .stroke(tone.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke((p > 0 ? tone : NightWatch.Palette.red).color, lineWidth: 2)
                        .frame(width: 16, height: 16)
                }
                .frame(width: 52, height: 52)
                // Red glass, warming as the hold goes on. Not interactive: the ring is the feedback.
                .nwChromeGlass(in: Circle(), tint: NightWatch.Palette.chromeGlass.mixed(with: NightWatch.Palette.red.opacity(0.6), 0.3 + 0.12 * p),
                               interactive: false) {
                    Circle().fill(NightWatch.Palette.red.opacity(0.14 + 0.08 * p).color)
                }
            }
            .frame(width: 52, height: 52)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Stop \(agent)"))
            .accessibilityHint(Text("Hold for 10 seconds. \(plan.preview)"))
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

    /// Words or photos, and every photo encoded.
    private var canSend: Bool { PhotoDraft.canSend(text: draft, items: data.photos) }

    var body: some View {
        VStack(spacing: 8) {
            if let n = data.stopNote { stopNote(n) }
            if let r = data.receipt {
                NWSendReceiptView(receipt: r, onUndo: actions.undoSend, onDelete: actions.deleteHeld, onDismiss: actions.dismissReceipt)
            }
            if let p = data.composerProblem {
                Text(p).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.amber.color)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            }
            if let arm = data.yesNoArm {
                // Tapped: the 1.2 s ring runs and Cancel works, so a mis-tap on "Should I deploy?" is not final.
                NWArmedReply(arm: arm, onCancel: actions.cancelArm)
            } else if draft.isEmpty, let question = data.yesNo {
                // Primary pair, in place of the generic replies, until the person types, sends, or the session moves on.
                NWYesNoReplies(question: question, agent: data.character.name, onReply: { actions.armReply($0) })
            } else if data.composer.offersQuickReplies, data.character.kind != .local, draft.isEmpty { quickReplies }
            switch data.composer {
            case .locked(let why), .disabled(let why):
                lockedBlock(symbol: data.composer.routesThroughPage ? "keyboard" : "lock", title: data.composerCopy.placeholder, text: why)
            case .blocked(let why):
                lockedBlock(symbol: "keyboard.badge.ellipsis", title: why,
                            text: "You can still follow along here, and answer pages from Now.")
            default:
                // Mid-turn: Now or When it finishes, in front of the field it applies to.
                NWSendChoiceControl(plan: data.choice, agent: data.character.name, explain: data.explainChoice,
                                    onChoose: actions.setChoice)
                if !data.photos.isEmpty { NWPhotoStrip(items: data.photos, onRemove: actions.removePhoto) }
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
            NWPhotoButton(offer: data.photoOffer, slots: PhotoDraft.slots(data.photos), onPick: actions.pickPhotos, onBlocked: actions.photoBlocked)
            VStack(alignment: .leading, spacing: 4) {
                TextField(data.photos.isEmpty ? data.composerCopy.placeholder : "Add a caption…", text: $draft, axis: .vertical)
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
                // The path route's one line, or why this row takes no photos.
                if let note = data.photoOffer.note {
                    Text(note).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                    .background(Circle().fill(canSend
                        ? AnyShapeStyle(LinearGradient(colors: [NightWatch.Palette.teal.color, NightWatch.Palette.sky.color],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(Color.white.opacity(0.14))))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(Text(data.choice.holds ? "Send when it finishes" : data.composerCopy.sendLabel))
            .accessibilityHint(Text(data.preview ?? data.composerCopy.hint))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        // Glass on the page colour (the composer's own solid ground keeps the receipts and notes above it legible).
        .nwChromeGlass(in: RoundedRectangle(cornerRadius: 30, style: .continuous)) {
            NWGlassBackground(radius: 30, fill: NightWatch.Palette.surface.opacity(0.95))
        }
    }

    /// Send, from the button or the keyboard. An empty draft sends nothing: the button is greyed for the same reason.
    private func submit(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PhotoDraft.canSend(text: text, items: data.photos) else { return }
        actions.send(text)
    }

    private var quickReplies: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RoomComposerMode.quickReplies, id: \.self) { q in
                    Button { draft = q; focused = true } label: {
                        Text(q).font(NightWatch.Typo.captionStrong)
                            .foregroundColor(NightWatch.Palette.textSecondary.color)
                            .padding(.horizontal, 14).frame(minHeight: 36)
                            .nwChromeGlass(in: Capsule()) {
                                Capsule().fill(Color.white.opacity(0.07))
                                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                            }
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
