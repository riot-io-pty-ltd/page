import AppKit
import SwiftUI

// The Night Watch dialog: what an NSAlert used to be. A glass card with a
// title, a body, an optional mono block (a diff, the lines about to be added to
// a file) and one to three buttons. It is shown as a sheet on the Tower when that
// is open (a floating panel otherwise), and answers with which button was pressed (0 is
// the first button, as `.alertFirstButtonReturn` was). It never blocks: there
// is no `runModal`, because a nested run loop started from inside a SwiftUI
// button action (every caller is one) leaves the dialog's own buttons dead.
// `present` shows it as a sheet on the Tower (or a floating panel when there
// is no window to sit on) and calls back; `ask` is the `await`able form.
// Return presses the first button, Esc the last (Cancel).

private typealias P = NightWatch.Palette

// MARK: - What a dialog says

struct NWDialogSpec: Equatable {
    enum Tone: Equatable { case info, warning }
    enum Role: Equatable { case primary, destructive, secondary }

    struct Button: Equatable {
        var title: String
        var role: Role
    }

    enum Detail: Equatable {
        /// Plain mono text.
        case mono(String)
        /// A unified diff: `+` green, `-` red, `@@` blue.
        case diff(String)
    }

    var title: String
    var body: String
    var tone: Tone = .info
    var detail: Detail?
    /// First = Return. With more than one, the last is Cancel (Esc).
    var buttons: [Button]

    /// Which button Esc presses: the last, or the only one.
    var cancelIndex: Int { max(0, buttons.count - 1) }

    /// One OK, as `NSAlert` with no extra buttons.
    static func notice(_ title: String, _ text: String, tone: Tone = .warning, ok: String = "OK") -> NWDialogSpec {
        NWDialogSpec(title: title, body: text, tone: tone, detail: nil, buttons: [Button(title: ok, role: .primary)])
    }

    /// An action and Cancel (`destructive`: the action is the careful kind).
    static func confirm(_ title: String, _ text: String, ok: String, cancel: String = "Cancel",
                        tone: Tone = .info, destructive: Bool = false, detail: Detail? = nil) -> NWDialogSpec {
        NWDialogSpec(title: title, body: text, tone: tone, detail: detail,
                     buttons: [Button(title: ok, role: destructive ? .destructive : .primary),
                               Button(title: cancel, role: .secondary)])
    }
}

/// How a dialog's text is laid out. Pure.
enum NWDialogBody {
    enum Block: Equatable {
        case text(String)
        /// A paragraph whose every line is indented four spaces (the lines
        /// Page will add to kitty.conf), shown in mono without the indent.
        case mono(String)
    }

    static func blocks(_ body: String) -> [Block] {
        body.components(separatedBy: "\n\n").compactMap { paragraph in
            let lines = paragraph.components(separatedBy: "\n")
            if !paragraph.isEmpty, lines.allSatisfy({ $0.hasPrefix("    ") }) {
                return .mono(lines.map { String($0.dropFirst(4)) }.joined(separator: "\n"))
            }
            return paragraph.isEmpty ? nil : .text(paragraph)
        }
    }

    /// Pure. The colour class of one diff line.
    enum DiffKind: Equatable { case header, hunk, added, removed, context }

    static func diffKind(_ line: String) -> DiffKind {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .header }
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("+") { return .added }
        if line.hasPrefix("-") { return .removed }
        return .context
    }
}

// MARK: - The mono block

/// A block of mono text on a dark inset, scrolling when it is long: a diff, a
/// config file's lines. Used by the dialog and by the pages that preview a change.
struct NWCodeBlock: View {
    var text: String
    var diff = false
    var maxHeight: CGFloat = 240

    private var lines: [String] { text.components(separatedBy: "\n") }
    private let lineHeight: CGFloat = 16

    private func color(_ line: String) -> NightWatch.RGBA {
        guard diff else { return P.textPrimary.opacity(0.88) }
        switch NWDialogBody.diffKind(line) {
        case .header: return P.textTertiary
        case .hunk: return P.sky
        case .added: return P.green
        case .removed: return P.red.mixed(with: P.amber, 0.2)
        case .context: return P.textPrimary.opacity(0.80)
        }
    }

    var body: some View {
        let rows = lines
        let height = min(maxHeight, CGFloat(rows.count) * lineHeight + 24)
        ScrollView([.vertical, .horizontal], showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(Font.system(size: 11.5, design: .monospaced))
                        .foregroundColor(color(line).color)
                        .fixedSize()
                        .frame(height: lineHeight, alignment: .leading)
                }
            }
            .padding(12)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.36)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .accessibilityLabel(Text(diff ? "Change preview" : "Text"))
        .accessibilityValue(Text(text))
    }
}

// MARK: - The card

struct NWDialogCard: View {
    var spec: NWDialogSpec
    var choose: (Int) -> Void
    /// The card's own drop shadow: for a floating panel, which has room around the card
    /// for it. A sheet has none (AppKit draws the sheet's own), so the card fills it.
    var shadow = true

    static let width: CGFloat = 460
    static let wideWidth: CGFloat = 600

    private var width: CGFloat { spec.detail == nil ? Self.width : Self.wideWidth }

    private var icon: (name: String, color: NightWatch.RGBA) {
        switch spec.tone {
        case .warning: return ("exclamationmark.triangle.fill", P.amber)
        case .info: return ("info.circle.fill", P.teal)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon.name)
                    .font(Font.system(size: 17, weight: .semibold))
                    .foregroundColor(icon.color.color)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(icon.color.opacity(0.14).color))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(spec.title)
                        .font(Font.system(size: 16, weight: .bold)).kerning(-0.2)
                        .foregroundColor(P.textPrimary.color)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(NWDialogBody.blocks(spec.body).enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .text(let t):
                            Text(t)
                                .font(Font.system(size: 12.5))
                                .foregroundColor(P.textSecondary.color)
                                .fixedSize(horizontal: false, vertical: true)
                        case .mono(let t):
                            NWCodeBlock(text: t, maxHeight: 140)
                        }
                    }
                }
            }
            if let detail = spec.detail {
                switch detail {
                case .mono(let t): NWCodeBlock(text: t, maxHeight: 260)
                case .diff(let t): NWCodeBlock(text: t, diff: true, maxHeight: 260)
                }
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                // The first button is the default and sits at the right, as in NSAlert.
                ForEach(Array(spec.buttons.enumerated().reversed()), id: \.offset) { i, b in
                    NWButton(title: b.title, kind: kind(b.role),
                             shortcut: shortcut(for: i)) { choose(i) }
                }
            }
            .background(hiddenEsc)
        }
        .padding(22)
        .frame(width: width, alignment: .leading)
        .background(NWGlassBackground(radius: 18, fill: NightWatch.RGBA(hex: 0x0B0E14, alpha: 1), glowHeight: 18))
        .shadow(color: Color.black.opacity(shadow ? 0.55 : 0), radius: 26, x: 0, y: 12)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(spec.title))
    }

    private func kind(_ role: NWDialogSpec.Role) -> NWButton.Kind {
        switch role {
        case .primary: return .primary
        case .destructive: return .destructive
        case .secondary: return .secondary
        }
    }

    private func shortcut(for index: Int) -> KeyboardShortcut? {
        if index == 0 { return .defaultAction }
        if index == spec.cancelIndex { return .cancelAction }
        return nil
    }

    /// A lone OK takes Esc as well as Return.
    @ViewBuilder private var hiddenEsc: some View {
        if spec.buttons.count == 1 {
            Button("") { choose(0) }
                .keyboardShortcut(.cancelAction)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }
}

// MARK: - The panel

/// A panel that takes keys and answers Esc. Not activating on its own: the
/// presenter activates Page first (as the alerts it replaces did).
final class NWDialogPanel: NSPanel {
    var onCancel: (() -> Void)?
    /// Transparent room around the card (for a floating panel's shadow); zero as a sheet.
    var inset: CGFloat = 0
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// One dialog on screen, from `present` until its button is pressed. It owns
/// the panel, answers exactly once, and takes the sheet down (or the floating
/// panel off screen) before it calls back.
final class NWDialogPresentation: NSObject {
    let panel: NWDialogPanel
    private let spec: NWDialogSpec
    private weak var parent: NSWindow?
    private var completion: ((Int) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private(set) var finished = false
    /// Shown as a sheet on `parent`, not as a floating panel.
    private(set) var isSheet = false

    init(_ spec: NWDialogSpec, over window: NSWindow?, completion: @escaping (Int) -> Void) {
        self.spec = spec
        self.completion = completion
        panel = NWDialogPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        super.init()
        panel.onCancel = { [weak self] in self?.finish(spec.cancelIndex) }
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.title = spec.title
        panel.setAccessibilitySubrole(.dialog)
        if let window, window.isVisible, !window.isMiniaturized, window.sheets.isEmpty {
            parent = window
            isSheet = true
        }
        // A sheet is the card alone (AppKit draws its edge and shadow); a floating panel has room for the card's shadow.
        let inset = isSheet ? 0 : NWDialog.inset
        panel.inset = inset
        let host = NSHostingView(rootView: NWAppearanceRoot { NWDialogCard(spec: spec, choose: { [weak self] in self?.finish($0) }, shadow: inset > 0) }
            .padding(inset))
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        panel.setContentSize(size)
        if !isSheet {
            panel.isFloatingPanel = true
            panel.level = .modalPanel
            panel.isMovableByWindowBackground = true
            panel.setFrameOrigin(NWDialog.origin(for: size, over: window))
        }
    }

    /// Puts it on screen: a sheet on the Tower (which it blocks, with no
    /// nested run loop), or a key floating panel.
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            self?.finish(self?.spec.cancelIndex ?? 0)
        })
        if let parent {
            // The Tower closing under its sheet answers Cancel; nothing is left hanging.
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
                self?.finish(self?.spec.cancelIndex ?? 0)
            })
            parent.makeKeyAndOrderFront(nil)
            parent.beginSheet(panel, completionHandler: nil)
            panel.makeKey()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Answers once: takes the dialog down, then calls back on main.
    func finish(_ index: Int) {
        guard !finished else { return }
        finished = true
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let parent, parent.sheets.contains(panel) { parent.endSheet(panel) }
        panel.orderOut(nil)
        let done = completion
        completion = nil
        // Keep the panel alive past the SwiftUI button action that is calling us.
        DispatchQueue.main.async { NWDialog.release(self) }
        done?(index)
    }
}

enum NWDialog {
    /// Room around the card for its shadow.
    static let inset: CGFloat = 44

    /// Dialogs on screen, held until they answer.
    private(set) static var live: [NWDialogPresentation] = []

    static func release(_ presentation: NWDialogPresentation) {
        live.removeAll { $0 === presentation }
    }

    /// Shows the dialog and returns at once; `completion` runs on main, once,
    /// with the pressed button's index (0 = the first) after the dialog is gone.
    /// Nothing is shown from the caller's stack: callers are SwiftUI button
    /// actions, so this hops to the next main-queue turn first. `window`: the
    /// Tower or other window to sit on as a sheet (when it is on screen);
    /// otherwise a floating panel centred on the screen.
    static func present(_ spec: NWDialogSpec, over window: NSWindow? = nil, completion: @escaping (Int) -> Void = { _ in }) {
        DispatchQueue.main.async {
            let presentation = NWDialogPresentation(spec, over: window, completion: completion)
            live.append(presentation)
            presentation.show()
        }
    }

    /// `await`able form: `if await NWDialog.ask(spec) == 0 { … }`.
    static func ask(_ spec: NWDialogSpec, over window: NSWindow? = nil) async -> Int {
        await withCheckedContinuation { continuation in
            present(spec, over: window) { continuation.resume(returning: $0) }
        }
    }

    /// Pure. The panel's origin: centred on `window` when it is on screen, else on the main screen's visible area.
    static func origin(for size: CGSize, over window: NSWindow?) -> NSPoint {
        let area: NSRect
        if let window, window.isVisible { area = window.frame }
        else { area = (NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)) }
        return NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2 + min(60, area.height * 0.06))
    }
}
