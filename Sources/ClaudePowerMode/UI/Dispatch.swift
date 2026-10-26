import SwiftUI

// Dispatch (⌘N): start a new Claude session from the Mac. The same fenced path
// the phone uses (`SessionStarter`: prompt clean-up, the known-folders
// allowlist, a fixed `claude` command in cmux), only the user is at the Mac.

/// Pure state of the Dispatch panel.
struct DispatchModel: Equatable {
    enum Phase: Equatable {
        case editing
        case sending
        /// The session was started (message from the starter).
        case done(String)
        case failed(String)
    }

    var prompt = ""
    var folders: [SessionStarter.Folder] = []
    var folderIndex = 0
    var phase: Phase = .editing
    /// Folders are still being read (it reads transcripts, off main).
    var loadingFolders = false

    /// The agent chip. Page starts Claude (the command is fixed); the model is
    /// whatever Claude's own settings pick.
    var agentLabel: String { "Claude" }
    /// The when chip. Only "Now" exists: there is no scheduled start.
    var whenLabel: String { "Now" }

    var folder: SessionStarter.Folder? {
        folders.indices.contains(folderIndex) ? folders[folderIndex] : nil
    }

    var folderLabel: String { folder?.name ?? (loadingFolders ? "Loading…" : "No folder") }

    /// Pure. Ready to send: a folder from the list and some prompt text, and
    /// not already sending or done (a failed attempt can be sent again).
    var canSend: Bool {
        guard folder != nil, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch phase {
        case .editing, .failed: return true
        case .sending, .done: return false
        }
    }

    /// Pure. Moves the folder chip, wrapping.
    mutating func cycleFolder(by step: Int) {
        guard !folders.isEmpty else { return }
        folderIndex = ((folderIndex + step) % folders.count + folders.count) % folders.count
    }

    /// Pure. Puts a new list in, keeping the chosen folder if it is still there.
    mutating func setFolders(_ list: [SessionStarter.Folder]) {
        let keep = folder?.path
        folders = list
        folderIndex = keep.flatMap { p in list.firstIndex { $0.path == p } } ?? 0
        loadingFolders = false
    }

    /// Pure. The key hints under the chips.
    var hint: String {
        switch phase {
        case .editing: return "↵ dispatch · ⌘↑↓ change folder · esc"
        case .sending: return "starting…"
        case .done: return "esc to close"
        case .failed: return "↵ try again · esc"
        }
    }

    /// Pure. A shortened path for the folder menu ("~/projects/page").
    static func displayPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        // Whole path components only: "/Users/xy/p" is not under "/Users/x".
        guard !home.isEmpty, path == home || path.hasPrefix(home.hasSuffix("/") ? home : home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

/// The Dispatch panel's state holder (no Coordinator or window inside).
final class DispatchStore: ObservableObject {
    @Published var model = DispatchModel()
    @Published var focusToken = 0
    /// Sends the prompt: set by the owner; gets the chosen folder's path.
    var send: (_ folderPath: String, _ prompt: String) -> Void = { _, _ in }
    var close: () -> Void = {}
    /// Opens the folder list (a menu the owner shows).
    var pickFolder: () -> Void = {}

    init(model: DispatchModel = DispatchModel()) {
        self.model = model
    }

    func submit() {
        guard model.canSend, let folder = model.folder else { return }
        let text = model.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        model.phase = .sending
        send(folder.path, text)
    }

    func finish(_ result: SessionCommandResult) {
        if result.code == .delivered || result.code == .queued {
            model.phase = .done(result.detail.isEmpty ? "Started Claude" : result.detail)
        } else {
            model.phase = .failed(result.detail.isEmpty ? "Couldn't start the session" : result.detail)
        }
    }
}

/// The Dispatch panel: prompt field, then folder · agent · when chips.
struct NWDispatchView: View {
    @ObservedObject var store: DispatchStore
    @FocusState private var focused: Bool
    @Environment(\.nwFixedPhase) private var fixedPhase

    private var model: DispatchModel { store.model }

    var body: some View {
        NWGlassCard(radius: 22, glowHeight: 26, padding: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "paperplane")
                        .font(Font.system(size: 15, weight: .medium))
                        .foregroundColor(NightWatch.Palette.teal.color)
                    Text("Dispatch")
                        .font(Font.system(size: 17, weight: .bold))
                        .foregroundColor(NightWatch.Palette.textPrimary.color)
                    Spacer()
                    Text("⌘N").font(NightWatch.Typo.monoMicro)
                        .foregroundColor(NightWatch.Palette.textTertiary.color)
                }
                TextField("What should it work on?", text: Binding(get: { store.model.prompt },
                                                                    set: { store.model.prompt = $0 }))
                    .textFieldStyle(.plain)
                    .font(Font.system(size: 15))
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .focused($focused)
                    .disabled(model.phase == .sending)
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.45)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(NightWatch.Palette.glass.opacity(0.55).color, lineWidth: 1))
                HStack(spacing: 8) {
                    folderChip
                    chip(model.agentLabel, dot: Color(red: 0.96, green: 0.62, blue: 0.45))
                    chip(model.whenLabel, dot: Color.white)
                    Spacer(minLength: 8)
                    Text(model.hint)
                        .font(NightWatch.Typo.monoMicro)
                        .foregroundColor(NightWatch.Palette.textTertiary.color)
                        .lineLimit(1)
                }
                status
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 18)
        }
        .frame(width: 560)
        .onAppear { if fixedPhase == nil { focused = true } }
        .onChange(of: store.focusToken) { _ in focused = true }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .done(let text):
            Label(text, systemImage: "checkmark.circle")
                .font(NightWatch.Typo.subline)
                .foregroundColor(NightWatch.Palette.green.color)
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle")
                .font(NightWatch.Typo.subline)
                .foregroundColor(NightWatch.Palette.amber.color)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    private var folderChip: some View {
        Button { store.pickFolder() } label: {
            chipBody(model.folderLabel, dot: NightWatch.Palette.teal.color, chevron: model.folders.count > 1)
        }
        .buttonStyle(.plain)
        .disabled(model.folders.isEmpty)
        .accessibilityLabel(Text("Folder: \(model.folderLabel)"))
    }

    private func chip(_ text: String, dot: Color) -> some View {
        chipBody(text, dot: dot, chevron: false)
    }

    private func chipBody(_ text: String, dot: Color, chevron: Bool) -> some View {
        HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(text)
                .font(Font.system(size: 12.5, weight: .medium))
                .foregroundColor(NightWatch.Palette.textPrimary.opacity(0.9).color)
                .lineLimit(1)
            if chevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(Font.system(size: 8, weight: .bold))
                    .foregroundColor(NightWatch.Palette.textTertiary.color)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}
