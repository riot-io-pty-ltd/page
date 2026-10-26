import AppKit

/// "O" in the panel: bring the exact terminal, iTerm2 or cmux pane a session
/// runs in to the front. It never types anything (no text, no Return, no Esc,
/// no digits): it only selects a tab, window or pane and activates the app.
/// Where the exact pane can't be named it falls back to activating the host
/// app, and says so.
///
/// Resolving the host runs ps, tmux and the cmux socket and AppleScript can
/// block: call `focus` and `activateAnyTerminal` off the main thread.
enum TerminalFocus {
    struct Outcome: Equatable {
        let ok: Bool
        /// Short and plain: "Brought cmux forward", "Couldn't tell which terminal".
        let detail: String
    }

    // MARK: pure

    /// Pure. "cmux › page" for the preview, from the phone's host name for a
    /// session and its project. nil when Page can't name where it runs.
    static func routeLabel(host: String, project: String) -> String? {
        switch host {
        case "unknown", "desktop", "background", "": return nil
        default: return project.isEmpty ? host : "\(host) › \(project)"
        }
    }

    /// Pure. A tty path as `ps` reports it, nothing else (it goes into AppleScript).
    static func isSafeTTY(_ tty: String) -> Bool {
        tty.range(of: #"^/dev/ttys?[0-9]+$"#, options: .regularExpression) != nil
    }

    /// Pure. tmux pane ids look like %12.
    static func isSafePane(_ id: String) -> Bool {
        id.range(of: #"^%[0-9]+$"#, options: .regularExpression) != nil
    }

    /// Pure. The tmux commands that show a pane: its window, then the pane.
    static func tmuxCommands(paneId: String) -> [[String]] {
        guard isSafePane(paneId) else { return [] }
        return [["select-window", "-t", paneId], ["select-pane", "-t", paneId]]
    }

    /// Pure. The cmux commands that show a surface: its workspace, then the pane.
    static func cmuxCommands(surfaceId: String, workspaceId: String?) -> [[String]] {
        var out: [[String]] = []
        if let ws = workspaceId, !ws.isEmpty {
            out.append(["select-workspace", "--workspace", ws])
            out.append(["focus-panel", "--panel", surfaceId, "--workspace", ws])
        } else {
            out.append(["focus-panel", "--panel", surfaceId])
        }
        return out
    }

    /// Pure. WezTerm's CLI arguments that activate a pane.
    static func weztermArgs(paneId: String) -> [String] { ["cli", "activate-pane", "--pane-id", paneId] }

    /// Pure. kitty's arguments that focus a window.
    static func kittyArgs(socket: String, windowId: String) -> [String] {
        ["@", "--to", socket, "focus-window", "--match", "id:\(windowId)"]
    }

    /// Pure. Selects the Terminal.app tab whose tty is `tty` and raises its window.
    static func terminalScript(tty: String) -> String {
        """
        with timeout of 10 seconds
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        set tTTY to ""
                        try
                            set tTTY to (tty of t as string)
                        end try
                        if tTTY is \(ProcessRunner.appleScriptQuote(tty)) then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
                return "none"
            end tell
        end timeout
        """
    }

    /// Pure. Selects the iTerm2 session whose tty is `tty`.
    static func iTermScript(tty: String) -> String {
        """
        with timeout of 10 seconds
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with tb in tabs of w
                        repeat with s in sessions of tb
                            set sTTY to ""
                            try
                                set sTTY to (tty of s as string)
                            end try
                            if sTTY is \(ProcessRunner.appleScriptQuote(tty)) then
                                tell w to select
                                tell tb to select
                                tell s to select
                                activate
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
                return "none"
            end tell
        end timeout
        """
    }

    /// Terminal apps, in the order `activateAnyTerminal` prefers them.
    static let terminalAppNames = ["cmux", "iTerm2", "iTerm", "Terminal", "Ghostty", "WezTerm", "kitty", "Warp", "Alacritty", "Hyper"]

    // MARK: blocking

    /// Shows the session's pane. Falls back to its host app, then to any
    /// terminal app, rather than failing silently.
    static func focus(candidates: [ClaudeLiveSession], table: [ProcessRunner.ProcessInfoRow]) -> Outcome {
        guard case .success(let session) = InjectionExecutor.pickSession(candidates, pagePid: nil, pageStateStart: nil),
              session.tty != nil else {
            return activateAnyTerminal(prefix: "Couldn't tell which pane")
        }
        let host = InjectionExecutor.resolveHost(for: session, processTable: table)
        let hostApp = InjectionExecutor.hostApp(forPid: session.pid, processTable: table)

        switch host {
        case .tmux(let tmux, let pane, _, _):
            for args in tmuxCommands(paneId: pane) {
                let r = ProcessRunner.run(tmux, args, timeout: 3)
                if !r.succeeded { return activateAnyTerminal(prefix: "Couldn't select the tmux pane") }
            }
            // The app showing the tmux client, when there is exactly one.
            let clients = ProcessRunner.run(tmux, ["list-clients", "-F", "#{client_pid}"], timeout: 3)
            let apps = Set(clients.stdout.split(separator: "\n").compactMap { Int32($0) }.compactMap {
                InjectionExecutor.hostApp(forPid: $0, processTable: table)
            })
            if apps.count == 1, let app = apps.first { return activate(appNamed: app, shown: "tmux pane \(pane)") }
            return activateAnyTerminal(prefix: "Selected the tmux pane")

        case .terminalApp(let tty):
            guard isSafeTTY(tty) else { return activate(appNamed: "Terminal", shown: nil) }
            return runScript(terminalScript(tty: tty), app: "Terminal")

        case .iTerm(let tty):
            guard isSafeTTY(tty) else { return activate(appNamed: "iTerm2", shown: nil) }
            return runScript(iTermScript(tty: tty), app: "iTerm2")

        case .cmux(let target):
            switch CmuxBridge.connect(cliPath: target.cliPath) {
            case .failure:
                return activate(appNamed: "cmux", shown: nil)
            case .success(let client):
                for args in cmuxCommands(surfaceId: target.surfaceId, workspaceId: target.workspaceId) {
                    if case .failure = client.run(args, timeout: 4, fallback: "cmux didn't switch") {
                        return activate(appNamed: "cmux", shown: nil)
                    }
                }
                return activate(appNamed: "cmux", shown: "cmux pane")
            }

        case .wezterm(let target):
            _ = WezTermBridge.run(target, Array(weztermArgs(paneId: target.paneId).dropFirst()))
            return activate(appNamed: "WezTerm", shown: target.label)

        case .kitty(let target):
            _ = ProcessRunner.run(target.kittenPath, kittyArgs(socket: target.socket, windowId: target.windowId), timeout: 3)
            return activate(appNamed: "kitty", shown: target.label)

        case .herdr, .unreachable, .unsupported, .unknown:
            if let app = hostApp { return activate(appNamed: app, shown: nil) }
            return activateAnyTerminal(prefix: "Couldn't tell which pane")
        }
    }

    private static func runScript(_ source: String, app: String) -> Outcome {
        let r = InjectionExecutor.runAppleScript(source)
        if let err = r.error {
            switch r.errorNumber {
            case .some(-1743): return Outcome(ok: false, detail: "Allow Page to control \(app) in System Settings → Privacy & Security → Automation")
            case .some(-600): return Outcome(ok: false, detail: "\(app) isn't running")
            default: return activate(appNamed: app, shown: nil, note: err)
            }
        }
        if r.value == "ok" { return activate(appNamed: app, shown: "\(app) tab") }
        return activate(appNamed: app, shown: nil)
    }

    /// Brings `appNamed` forward. `shown` names the exact pane when one was
    /// selected; without it the message says only the app came forward.
    @discardableResult
    static func activate(appNamed name: String, shown: String?, note: String? = nil) -> Outcome {
        guard let app = runningApp(named: name) else { return Outcome(ok: false, detail: "\(name) isn't running") }
        bringForward(app)
        if let shown { return Outcome(ok: true, detail: "Showing the \(shown)") }
        return Outcome(ok: true, detail: "Brought \(name) forward — Page couldn't pick the exact pane")
    }

    /// Brings an app to the front. Page is not the active app while its panel is
    /// up (the panel takes keys without activating it), and on recent macOS an
    /// app that isn't active can't always force another forward, so this asks
    /// the system to open the app with activation, then falls back to activate.
    static func bringForward(_ app: NSRunningApplication) {
        DispatchQueue.main.async {
            if let url = app.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                    if error != nil { app.activate(options: [.activateIgnoringOtherApps]) }
                }
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }

    /// The first terminal app that is running.
    static func activateAnyTerminal(prefix: String? = nil) -> Outcome {
        for name in terminalAppNames {
            if runningApp(named: name) != nil {
                let r = activate(appNamed: name, shown: nil)
                return Outcome(ok: r.ok, detail: prefix.map { "\($0) — brought \(name) forward" } ?? r.detail)
            }
        }
        return Outcome(ok: false, detail: "Couldn't find a terminal to bring forward")
    }

    private static func runningApp(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            app.activationPolicy == .regular && (app.localizedName == name
                || app.bundleURL?.deletingPathExtension().lastPathComponent == name)
        }
    }
}
