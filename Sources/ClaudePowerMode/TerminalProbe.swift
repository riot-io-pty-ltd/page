import AppKit

/// Gathers the facts `TerminalCatalog` turns into rows: which hosts are
/// installed, how many sessions run in each, and whether each host's own
/// setup is done. Blocking (process table, tmux, files, cmux's CLI): call it
/// off the main thread, and only while the Terminals page is on screen.
///
/// Read-only. It never types, never writes a config, and never makes macOS
/// show a permission prompt (that is `requestAutomation`, from a click).
enum TerminalProbe {
    struct Snapshot: Equatable {
        var facts: [TerminalCatalog.ID: TerminalCatalog.Facts]
        /// kitty.conf holds lines Page added (the row can offer Undo).
        var pageAddedKittyLines: Bool

        static let empty = Snapshot(facts: [:], pageAddedKittyLines: false)
    }

    /// macOS Automation, as `AEDeterminePermissionToAutomateTarget` reports it.
    enum Automation: Equatable {
        case granted
        /// -1743: the user said no (or turned it off in System Settings).
        case denied
        /// -1744: macOS would ask, and hasn't yet.
        case notAsked
        /// -600: macOS can only answer while the app runs.
        case appNotRunning
        case unknown
    }

    // MARK: pure

    /// Pure. The OSStatus of `AEDeterminePermissionToAutomateTarget`.
    static func automation(osStatus: Int32) -> Automation {
        switch osStatus {
        case 0: return .granted
        case -1743: return .denied
        case -1744: return .notAsked
        case -600: return .appNotRunning
        default: return .unknown
        }
    }

    /// Pure. What the Terminals row says about Automation.
    static func setupState(_ access: Automation, appName: String) -> TerminalCatalog.SetupState {
        switch access {
        case .granted: return .done
        case .denied:
            return .needed("macOS is blocking Page from controlling \(appName). Allow it in System Settings ▸ Privacy & Security ▸ Automation.")
        case .notAsked:
            return .needed("Page hasn't asked macOS for permission to control \(appName) yet. Click Allow…")
        case .appNotRunning, .unknown:
            return .unchecked
        }
    }

    /// Pure. kitty's setup state, plus: the lines are in kitty.conf, but a
    /// kitty that is running has no socket where `listen_on` says it would,
    /// so it started before the lines were added and needs a restart.
    static func kittySetup(_ state: TerminalCatalog.SetupState, listenOn: String?, pids: [Int32],
                           socketExists: (String) -> Bool) -> TerminalCatalog.SetupState {
        guard state == .done, !pids.isEmpty, let listenOn else { return state }
        let paths = pids.compactMap { KittyConfigFile.socketPath(listenOn: listenOn, pid: $0) }
        guard paths.count == pids.count else { return state }
        return paths.contains(where: socketExists) ? .done : .needsRestart
    }

    /// Pure. cmux's socket mode → setup state. `status` nil: the CLI couldn't
    /// say. Password mode counts only when a password is saved for Page.
    static func cmuxSetupState(_ status: CmuxBridge.SocketStatus?, passwordSaved: Bool) -> TerminalCatalog.SetupState {
        guard let status else {
            return .needed("Page couldn't read cmux's socket mode, so it can't tell whether cmux lets Page in. Click Set up…")
        }
        let mode = status.effectiveMode
        guard mode.admitsExternalClients else {
            return .needed("cmux's socket is set to “\(mode.displayName)”, which keeps Page out. Click Set up…")
        }
        if mode == .password, !passwordSaved {
            return .needed("cmux is in Password mode and Page has no password for it. Click Set up…")
        }
        return .done
    }

    static func bundleIdentifier(_ id: TerminalCatalog.ID) -> String? {
        switch id {
        case .terminal: return "com.apple.Terminal"
        case .iTerm: return "com.googlecode.iterm2"
        default: return nil
        }
    }

    // MARK: gathering

    /// One pass. `sessions`: the live sessions the coordinator knows;
    /// `probeHosts`: where each runs (`Coordinator.probeHosts`).
    static func gather(sessions: [AgentSession],
                       probeHosts: ([AgentSession]) -> [String: SessionHostInfo],
                       automation: (String) -> Automation = { automationAccess(bundleIdentifier: $0, askUser: false) },
                       kittyURL: URL = KittyConfigFile.defaultURL,
                       isInstalled: (TerminalCatalog.ID) -> Bool = TerminalProbe.isInstalled,
                       cmuxSetup: (_ installed: Bool) -> TerminalCatalog.SetupState = TerminalProbe.cmuxSetup,
                       kittyPIDs: () -> [Int32] = TerminalProbe.runningKittyPIDs,
                       socketExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Snapshot {
        let live = sessions.filter { $0.state != .offline }
        let use = TerminalCatalog.hostUse(from: live.isEmpty ? [] : Array(probeHosts(live).values))
        var facts: [TerminalCatalog.ID: TerminalCatalog.Facts] = [:]
        for entry in TerminalCatalog.entries {
            let u = use[entry.id] ?? TerminalCatalog.HostUse()
            var f = TerminalCatalog.Facts(installed: isInstalled(entry.id) || u.total > 0, use: u)
            switch entry.setup {
            case .none: f.setup = .notNeeded
            case .automation:
                if let bundle = bundleIdentifier(entry.id), f.installed {
                    f.setup = setupState(automation(bundle), appName: entry.name)
                } else {
                    f.setup = .unchecked
                }
            case .kittyConfig:
                if f.installed {
                    f.setup = kittySetup(KittyConfigFile.setupState(url: kittyURL), listenOn: KittyConfigFile.listenOn(url: kittyURL),
                                         pids: kittyPIDs(), socketExists: socketExists)
                } else {
                    f.setup = .unchecked
                }
            case .cmuxSocket:
                f.setup = cmuxSetup(f.installed)
            }
            facts[entry.id] = f
        }
        return Snapshot(facts: facts, pageAddedKittyLines: KittyConfigFile.hasPageLines(at: kittyURL))
    }

    static func isInstalled(_ id: TerminalCatalog.ID) -> Bool {
        let ws = NSWorkspace.shared
        switch id {
        case .terminal: return true
        case .iTerm:
            return ws.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
                || FileManager.default.fileExists(atPath: "/Applications/iTerm.app")
        case .tmux: return ProcessRunner.findExecutable("tmux") != nil
        case .cmux: return CmuxBridge.cliPath(forBundlePath: nil) != nil
        case .wezterm: return WezTermBridge.cliPath(forBundlePath: nil) != nil
        case .kitty: return KittyBridge.kittenPath(forBundlePath: nil) != nil
        case .herdr:
            return ProcessRunner.findExecutable("herdr") != nil
                || FileManager.default.isExecutableFile(atPath: NSHomeDirectory() + "/.cargo/bin/herdr")
        case .claudeSquad:
            return ProcessRunner.findExecutable("claude-squad") != nil || ProcessRunner.findExecutable("cs") != nil
                || ClaudeSquad.directoryExists(ClaudeSquad.directory)
        }
    }

    /// The kitty app's processes that are running (`{kitty_pid}` in `listen_on`).
    static func runningKittyPIDs() -> [Int32] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "net.kovidgoyal.kitty").map(\.processIdentifier)
    }

    /// cmux's socket mode, from its CLI (`socket-status` never connects to
    /// the socket), and whether a password is saved: an attributes-only
    /// Keychain query, so the password itself is never read here.
    static func cmuxSetup(installed: Bool) -> TerminalCatalog.SetupState {
        guard installed, let cli = CmuxBridge.cliPath(forBundlePath: nil) else { return .unchecked }
        let status = CmuxBridge.socketStatus(cliPath: cli)
        return cmuxSetupState(status, passwordSaved: status?.effectiveMode == .password && KeychainSecretStore.cmuxSocketPassword.exists())
    }

    // MARK: Automation

    /// `askUser` false never prompts. The target app must be running to get
    /// an answer.
    static func automationAccess(bundleIdentifier: String, askUser: Bool) -> Automation {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard let desc = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), askUser)
        return automation(osStatus: status)
    }

    /// The click on Allow…: starts the app if needed (without bringing it
    /// forward), then asks macOS, which shows its own prompt. Blocking.
    static func requestAutomation(_ id: TerminalCatalog.ID) -> Automation {
        guard let bundle = bundleIdentifier(id) else { return .unknown }
        let running = { !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty }
        if !running() {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return .unknown }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.hides = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
            let deadline = Date().addingTimeInterval(6)
            while !running(), Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return automationAccess(bundleIdentifier: bundle, askUser: true)
    }

    /// System Settings ▸ Privacy & Security ▸ Automation.
    static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}
