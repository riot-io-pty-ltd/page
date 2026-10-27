import AppKit
import SwiftUI
import Carbon.HIToolbox
import Combine

// The AppKit side of the Night Watch surfaces: borderless glass panels that
// take keys without activating Page (the terminal you were in stays the active
// app), the global hotkey, and the Welcome back drop. The views and the keys'
// meaning live elsewhere (NowPopoverView, NowStore, NowActions); this file only
// puts them on screen. None of it runs in the render harness.

// MARK: - Panel

/// A borderless glass panel that can become key without making Page the
/// active app.
final class NWPanel: NSPanel {
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    init(allowsKey: Bool) {
        self.allowsKey = allowsKey
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    /// Shows the content at its natural height, top edge at `top`, centred on
    /// `centerX` and kept on screen.
    func place(content host: NSView, width: CGFloat, centerX: CGFloat, top: CGFloat, screen: NSScreen?) {
        host.layoutSubtreeIfNeeded()
        let height = max(60, ceil(host.fittingSize.height))
        var x = centerX - width / 2
        if let vf = (screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, vf.minX + 8), vf.maxX - width - 8)
        }
        setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
    }

    /// Resizes to the content's height, keeping the top edge where it is.
    func refit(content host: NSView) {
        host.layoutSubtreeIfNeeded()
        let height = max(60, ceil(host.fittingSize.height))
        guard abs(height - frame.height) > 0.5 else { return }
        var f = frame
        f.origin.y += f.height - height
        f.size.height = height
        setFrame(f, display: true)
    }
}

/// Translates AppKit key events into `NowKeyPress` (pure part of it: `press`).
enum NowKeyTranslator {
    /// Pure. The key for a virtual key code and its unmodified characters, or
    /// nil for keys the panel ignores. Letters and punctuation go by the
    /// character the key types (so ⌘N and ⌘. are the keys labelled N and . on
    /// Dvorak and other layouts too); the key code is only the fallback when
    /// there are no characters.
    static func key(keyCode: UInt16, characters: String?) -> NowKeyPress.Key? {
        switch Int(keyCode) {
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        case kVK_Return, kVK_ANSI_KeypadEnter: return .ret
        case kVK_Escape: return .esc
        default:
            if let c = characters?.lowercased().first { return .char(c) }
            switch Int(keyCode) {
            case kVK_ANSI_Period: return .char(".")
            case kVK_ANSI_N: return .char("n")
            default: return nil
            }
        }
    }
}

// MARK: - Motion gate

/// Whether a panel's motion may run: the panel is on screen and not covered,
/// the display is awake and this is the active user session. Every timeline in
/// the panel pauses when it is false (Page's first promise is battery life).
final class NWMotionGate: ObservableObject {
    @Published private(set) var active = false
    private weak var window: NSWindow?
    private var shown = false
    private var screensAsleep = false
    private var sessionInactive = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        let ws = NSWorkspace.shared.notificationCenter
        watch(ws, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        watch(ws, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        watch(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        watch(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
    }

    deinit { observers.forEach { $0.0.removeObserver($0.1) } }

    /// The panel whose visibility and occlusion count.
    func attach(_ window: NSWindow) {
        self.window = window
        watch(NotificationCenter.default, NSWindow.didChangeOcclusionStateNotification, object: window) { _ in }
        recompute()
    }

    private func watch(_ center: NotificationCenter, _ name: Notification.Name, object: AnyObject? = nil,
                       _ body: @escaping (NWMotionGate) -> Void) {
        observers.append((center, center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            if let self { body(self); self.recompute() }
        }))
    }

    func setShown(_ on: Bool) {
        shown = on
        if !on { seenVisible = false }
        recompute()
        // A panel just ordered in may report its occlusion a moment later.
        if on { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.recompute() } }
    }

    /// The window server has said this showing is visible at least once.
    private var seenVisible = false

    private func recompute() {
        let ordered = window?.isVisible ?? false
        let unoccluded = window?.occlusionState.contains(.visible) ?? false
        if ordered && unoccluded { seenVisible = true }
        // Occlusion only ever pauses a panel it has first reported visible: a
        // non-activating panel can be reported occluded while on screen (seen
        // with the live check), and a frozen panel is worse than a few frames.
        let covered = seenVisible && !unoccluded
        let on = shown && ordered && !covered && !screensAsleep && !sessionInactive
        if on != active { active = on }
    }
}

/// Feeds a gate's state to the motion in a panel's SwiftUI tree.
struct NWMotionRoot<Content: View>: View {
    @ObservedObject var gate: NWMotionGate
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().environment(\.nwMotionActive, gate.active)
    }
}

// MARK: - The Now panel

final class NowPanelController: NSObject {
    let store: NowStore
    private let panel = NWPanel(allowsKey: true)
    private let host: NSHostingView<AnyView>
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var appObserver: NSObjectProtocol?
    private var storeObserver: AnyObject?
    private var refitScheduled = false
    private var previousApp: NSRunningApplication?

    /// The status item button's frame in screen coordinates, to hang under.
    var anchorFrame: () -> NSRect? = { nil }
    /// True while a system sheet (Touch ID) is up: the panel must not close under it.
    var isAuthenticating = false
    var onVisibilityChange: ((Bool) -> Void)?

    var isShown: Bool { panel.isVisible }
    var contentView: NSView { host }
    var frame: NSRect { panel.frame }

    private let gate: NWMotionGate

    init(store: NowStore) {
        self.store = store
        let gate = NWMotionGate()
        self.gate = gate
        host = NSHostingView(rootView: AnyView(NWAppearanceRoot { NWMotionRoot(gate: gate) { NWNowPopover(store: store) } }
            .environment(\.colorScheme, .dark)))
        super.init()
        gate.attach(panel)
        panel.contentView = host
        // Resize when the content changes height; never replace the root view.
        storeObserver = store.objectWillChange.sink { [weak self] _ in self?.scheduleRefit() }
        // The hold ring's ticks, felt on a Force Touch trackpad.
        store.haptic = { _ in NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
    }

    deinit { removeMonitors() }

    func toggle() {
        if isShown { close(restoreFocus: true) } else { show() }
    }

    func show() {
        guard !isShown else { return }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        store.reset()
        let anchor = anchorFrame()
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor ?? .zero) } ?? NSScreen.main
        let vf = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let centerX = anchor?.midX ?? (vf.maxX - NightWatch.Space.popoverWidth / 2 - 12)
        let top = (anchor?.minY ?? vf.maxY) - 6
        panel.place(content: host, width: NightWatch.Space.popoverWidth, centerX: centerX, top: top, screen: screen)
        panel.makeKeyAndOrderFront(nil)
        store.animates = true
        gate.setShown(true)
        installMonitors()
        onVisibilityChange?(true)
    }

    /// `restoreFocus`: hand the keyboard back to the app that had it (for a
    /// close by key or hotkey; not for a click that already chose elsewhere).
    func close(restoreFocus: Bool) {
        guard isShown else { return }
        removeMonitors()
        panel.orderOut(nil)
        gate.setShown(false)
        store.animates = false
        store.reset()
        if restoreFocus, let app = previousApp { TerminalFocus.bringForward(app) }
        previousApp = nil
        onVisibilityChange?(false)
    }

    /// The point under the footer's ellipsis, for the More menu.
    func moreMenuAnchor() -> (view: NSView, point: NSPoint) {
        // The footer is the bottom 38 pt, whichever way the hosting view's y runs.
        (host, NSPoint(x: host.bounds.maxX - 14, y: host.isFlipped ? host.bounds.maxY - 38 : 38))
    }

    private func scheduleRefit() {
        guard !refitScheduled else { return }
        refitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refitScheduled = false
            if self.isShown { self.panel.refit(content: self.host) }
        }
    }

    // MARK: monitors

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.route(event) ? nil : event
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, !self.isAuthenticating else { return }
            // A click on the status button itself is the button's own toggle.
            if let a = self.anchorFrame(), a.contains(NSEvent.mouseLocation) { return }
            self.close(restoreFocus: false)
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, !self.isAuthenticating else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier { self.close(restoreFocus: false) }
        }
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        if let o = appObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        keyMonitor = nil; clickMonitor = nil; appObserver = nil
    }

    /// True when the event was ours (and must not reach the responder chain).
    private func route(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            // Letting go of Command ends a Stop-all hold (key-up for ⌘. may never arrive).
            if store.hold?.kind == .stopAll, !event.modifierFlags.contains(.command) {
                return store.handle(NowKeyPress(key: .char("."), phase: .up))
            }
            return false
        case .keyDown, .keyUp:
            guard let key = NowKeyTranslator.key(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers) else {
                // Tab is left alone: with Full Keyboard Access it moves between the buttons.
                return Int(event.keyCode) != kVK_Tab && event.type == .keyDown && store.composer == nil
            }
            let flags = event.modifierFlags
            let press = NowKeyPress(
                key: key, phase: event.type == .keyDown ? .down : .up,
                command: flags.contains(.command), option: flags.contains(.option), control: flags.contains(.control),
                isRepeat: event.type == .keyDown && event.isARepeat)
            return store.handle(press)
        default:
            return false
        }
    }
}

// MARK: - Hotkey

/// A system-wide hotkey through Carbon's RegisterEventHotKey, which needs no
/// Accessibility permission.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onPress: () -> Void = {}

    /// nil when the combination is already taken.
    init?(keyCode: Int, modifiers: Int, onPress: @escaping () -> Void) {
        self.onPress = onPress
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.onPress() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard status == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x50414745), id: 1)   // 'PAGE'
        let reg = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard reg == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Option-Command-P.
    static let optionCommandP = (keyCode: kVK_ANSI_P, modifiers: cmdKey | optionKey)
}

// MARK: - Dispatch panel

final class DispatchPanelController: NSObject {
    let store: DispatchStore
    private let panel = NWPanel(allowsKey: true)
    private let host: NSHostingView<AnyView>
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var previousApp: NSRunningApplication?
    /// Reads the folders (off main) and calls back on main.
    var loadFolders: (@escaping ([SessionStarter.Folder]) -> Void) -> Void = { $0([]) }

    var isShown: Bool { panel.isVisible }

    init(store: DispatchStore) {
        self.store = store
        host = NSHostingView(rootView: AnyView(NWAppearanceRoot { NWDispatchView(store: store) }.environment(\.colorScheme, .dark)))
        super.init()
        panel.contentView = host
        store.close = { [weak self] in self?.close(restoreFocus: true) }
        store.pickFolder = { [weak self] in self?.showFolderMenu() }
    }

    /// The folder list, as a menu under the pointer.
    private func showFolderMenu() {
        let menu = NSMenu()
        for (i, f) in store.model.folders.enumerated() {
            let item = NSMenuItem(title: "\(f.name) — \(DispatchModel.displayPath(f.path))",
                                  action: #selector(folderChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == store.model.folderIndex ? .on : .off
            menu.addItem(item)
        }
        let p = host.convert(panel.mouseLocationOutsideOfEventStream, from: nil)
        menu.popUp(positioning: nil, at: p, in: host)
    }

    @objc private func folderChosen(_ sender: NSMenuItem) {
        store.model.folderIndex = sender.tag
        store.focusToken += 1
    }

    func show() {
        guard !isShown else { store.focusToken += 1; return }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        store.model = DispatchModel(prompt: "", folders: store.model.folders, folderIndex: store.model.folderIndex,
                                    phase: .editing, loadingFolders: true)
        let screen = NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.place(content: host, width: 560, centerX: vf.midX, top: vf.maxY - vf.height * 0.2, screen: screen)
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
        loadFolders { [weak self] folders in self?.store.model.setFolders(folders) }
    }

    func close(restoreFocus: Bool) {
        guard isShown else { return }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil; clickMonitor = nil
        panel.orderOut(nil)
        if restoreFocus, let app = previousApp { TerminalFocus.bringForward(app) }
        previousApp = nil
    }

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let flags = event.modifierFlags
            switch Int(event.keyCode) {
            case kVK_Escape:
                self.close(restoreFocus: true)
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if !event.isARepeat { self.store.submit() }
                return nil
            case kVK_UpArrow where flags.contains(.command):
                self.store.model.cycleFolder(by: -1)
                return nil
            case kVK_DownArrow where flags.contains(.command):
                self.store.model.cycleFolder(by: 1)
                return nil
            default:
                return event
            }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close(restoreFocus: false)
        }
    }
}

// MARK: - Welcome back

/// Drops the Welcome back glass below the menu bar for a few seconds. Never
/// takes the keyboard; a click dismisses it.
final class WelcomeBackController: NSObject {
    private let panel = NWPanel(allowsKey: false)
    private var dismissTimer: Timer?
    private lazy var gate: NWMotionGate = {
        let g = NWMotionGate()
        g.attach(panel)
        return g
    }()

    func show(_ model: WelcomeBack, near anchor: NSRect?, duration: TimeInterval = WelcomeBack.displayDuration) {
        dismissTimer?.invalidate()
        let gate = self.gate
        // The sunrise plays from the moment it drops in.
        let shownAt = Date()
        let host = NSHostingView(rootView: AnyView(
            NWAppearanceRoot { NWMotionRoot(gate: gate) { NWWelcomeBackView(model: model, shownAt: shownAt) } }
                .environment(\.colorScheme, .dark)
                .onTapGesture { [weak self] in self?.dismiss() }))
        panel.contentView = host
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor ?? .zero) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let centerX = anchor?.midX ?? (vf.maxX - 200)
        let top = (anchor?.minY ?? vf.maxY) - 8
        panel.place(content: host, width: 380, centerX: centerX, top: top, screen: screen)
        let reduce = NightWatch.systemReduceMotion
        if reduce {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            let final = panel.frame
            panel.setFrame(final.offsetBy(dx: 0, dy: 14), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(final, display: true)
            }
        }
        gate.setShown(true)
        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in self?.dismiss() }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        gate.setShown(false)
        guard panel.isVisible else { return }
        if NightWatch.systemReduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.panel.orderOut(nil) })
    }
}
