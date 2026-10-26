import SwiftUI

struct DispatchScreenData {
    var macName: String
    var availability: DispatchAvailability
    var folders: [StartFolders.Folder]
    var now: Date
    var status: DispatchStatus? = nil
    var sending = false
    var runway: RunwayModel = .empty
}

struct DispatchScreenActions {
    var start: () -> Void = {}
    var close: () -> Void = {}
    var paste: () -> Void = {}
    var openTower: () -> Void = {}
    var retry: () -> Void = {}
}

/// Wraps its children onto new lines, like text.
struct NWFlowLayout: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

/// DISPATCH: start new work. Where (a folder the Mac already knows), who
/// (Claude; the other agents are started on the Mac), what (an optional
/// prompt) and when (now). The button always names the Mac. Starting goes
/// through the existing start path; the sheet says plainly where to look if
/// nothing shows up.
struct NWDispatchScreen: View {
    var data: DispatchScreenData
    var actions = DispatchScreenActions()
    @Binding var draft: DispatchDraft
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    Text("Dispatch").font(.system(size: 36, weight: .bold)).kerning(-1)
                        .foregroundColor(NightWatch.Palette.textPrimary.color).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(action: actions.close) {
                        Image(systemName: "xmark").font(.system(.footnote, weight: .bold)).foregroundColor(NightWatch.Palette.textSecondary.color)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel(Text("Close"))
                }
                switch data.availability {
                case .ready: form
                case .loading:
                    HStack(spacing: 10) { ProgressView().tint(NightWatch.Palette.textSecondary.color); Text("Asking \(DeliveryPreview.macLabel(data.macName))…").foregroundColor(NightWatch.Palette.textSecondary.color) }
                        .font(NightWatch.Typo.body)
                case .disabledOnMac:
                    problem(symbol: "lock", title: "Starting sessions from your phone is off",
                            text: "On your Mac, open Page → Settings → Phone and turn on “Let my phone start new Claude sessions”.")
                case .noFolders:
                    problem(symbol: "folder.badge.questionmark", title: "No folders yet",
                            text: "Page hasn't seen Claude work in any folder in the last 30 days. Run claude in a project on your Mac once, and it appears here.")
                case .failed(let why):
                    problem(symbol: "wifi.exclamationmark", title: "Couldn't ask your Mac", text: why, action: ("Try again", actions.retry))
                }
            }
            .padding(.horizontal, NightWatch.Space.xl)
            .padding(.top, 16).padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Text("WHERE").nwLabel()
                if data.folders.count > 7 {
                    TextField("Search folders", text: $draft.search)
                        .font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textPrimary.color)
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
                }
                NWFlowLayout(spacing: 10) {
                    ForEach(draft.visibleFolders(data.folders, now: data.now)) { f in folderChip(f) }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("WHO").nwLabel()
                HStack(spacing: 10) { ForEach(DispatchAgent.allCases) { agentCard($0) } }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("WHAT").nwLabel()
                VStack(alignment: .leading, spacing: 10) {
                    TextField("What should Claude do? (optional)", text: $draft.prompt, axis: .vertical)
                        .lineLimit(3...8)
                        .font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textPrimary.color)
                        .focused($focused)
                    HStack {
                        Button(action: actions.paste) { Image(systemName: "doc.on.clipboard") }
                            .buttonStyle(.plain).foregroundColor(NightWatch.Palette.textTertiary.color)
                            .frame(width: 36, height: 36).accessibilityLabel(Text("Paste"))
                        Spacer()
                        Text(draft.promptProblem ?? "optional · max \(SessionComposer.maxCharacters)").font(NightWatch.Typo.monoMicro)
                            .foregroundColor((draft.promptProblem == nil ? NightWatch.Palette.textQuiet : NightWatch.Palette.amber).color)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("WHEN").nwLabel()
                HStack(spacing: 10) {
                    Text("Now").font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                        .padding(.horizontal, 18).frame(height: 40)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                    Text("Starting later isn't available yet").font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textQuiet.color)
                }
            }
            if !data.runway.markers.isEmpty || !data.runway.onAC {
                NWGlassCard(radius: 20, padding: 4) { NWRunwayBar(model: data.runway) }
                    .contentShape(Rectangle()).onTapGesture(perform: actions.openTower)
            }
            if let s = data.status { statusLine(s) }
            VStack(spacing: 10) {
                Button(action: actions.start) {
                    HStack(spacing: 8) {
                        if data.sending { ProgressView().controlSize(.small).tint(NightWatch.Palette.onBright.color) } else { Image(systemName: "paperplane") }
                        Text(draft.startTitle(mac: data.macName))
                    }
                }
                .buttonStyle(NWButtonStyle(kind: .bright))
                .disabled(!draft.canStart(availability: data.availability, sending: data.sending))
                .opacity(draft.canStart(availability: data.availability, sending: data.sending) ? 1 : 0.45)
                Text(DispatchDraft.footer(mac: data.macName)).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textQuiet.color)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
        }
    }

    private func folderChip(_ f: DispatchFolder) -> some View {
        let on = draft.selectedPath == f.path
        return Button { draft.selectedPath = f.path } label: {
            HStack(spacing: 8) {
                Circle().fill(f.hue.color.color).frame(width: 9, height: 9)
                Text(f.name).font(NightWatch.Typo.mono).foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(1)
            }
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(Capsule().fill(on ? NightWatch.Palette.teal.opacity(0.14).color : Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(on ? NightWatch.Palette.teal.opacity(0.7).color : Color.white.opacity(0.10), lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(f.name + (f.lastUsed.map { ", used \($0)" } ?? "")))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func agentCard(_ a: DispatchAgent) -> some View {
        let on = draft.agent == a
        let enabled = a.canStartFromPhone
        return Button { if enabled { draft.agent = a } } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: a.symbol).font(.system(.title3, weight: .regular))
                    .foregroundColor((enabled ? NightWatch.RGBA(hex: 0xE89E64) : NightWatch.Palette.textQuiet).color)
                Text(a.name).font(NightWatch.Typo.bodyStrong)
                    .foregroundColor((enabled ? NightWatch.Palette.textPrimary : NightWatch.Palette.textTertiary).color)
                Text(a.note).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textQuiet.color).lineLimit(2)
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(on ? NightWatch.RGBA(hex: 0xE89E64).opacity(0.10).color : Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(on ? NightWatch.RGBA(hex: 0xE89E64).opacity(0.6).color : Color.white.opacity(0.08), lineWidth: 1))
            .opacity(enabled ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text("\(a.name), \(a.note)"))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func statusLine(_ s: DispatchStatus) -> some View {
        let tone: NightWatch.RGBA = s.tone == .good ? NightWatch.Palette.teal : (s.tone == .working ? NightWatch.Palette.textSecondary : NightWatch.Palette.amber)
        return HStack(alignment: .top, spacing: 10) {
            if s.waiting { ProgressView().controlSize(.small).tint(tone.color) }
            else { Image(systemName: s.tone == .good ? "checkmark.circle" : "exclamationmark.triangle").foregroundColor(tone.color) }
            Text(s.text).font(NightWatch.Typo.caption).foregroundColor(tone.color).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: NightWatch.Radius.inset, style: .continuous).fill(tone.opacity(0.08).color))
        .accessibilityElement(children: .combine)
    }

    private func problem(symbol: String, title: String, text: String, action: (String, () -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(NightWatch.Typo.title).foregroundColor(NightWatch.Palette.textPrimary.color)
            Text(text).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color).fixedSize(horizontal: false, vertical: true)
            if let action { Button(action.0, action: action.1).buttonStyle(NWButtonStyle(kind: .quiet)) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(NWGlassBackground(radius: NightWatch.Radius.card, tint: NightWatch.Palette.amber))
    }
}
