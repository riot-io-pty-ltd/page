import AppKit

/// Onboarding for the cmux bridge: shows which cmux is installed and
/// whether its socket lets Page in, explains how to switch it to Password
/// mode, stores the password in the Keychain, tests the connection (only
/// when the user clicks), and suggests turning off cmux's own iPhone
/// forwarding so each alert pages the phone once.
///
/// Opening the window only runs commands that never touch cmux's socket
/// (`--version`, `socket-status`). The one socket call, `cmux ping`, runs
/// on the Test button.
final class CmuxSetupWindowController: NSWindowController, NSWindowDelegate {
    static let shared = CmuxSetupWindowController()

    private let secrets: SecretStore = KeychainSecretStore.cmuxSocketPassword
    private let workQueue = DispatchQueue(label: "ClaudePowerMode.CmuxSetup", qos: .userInitiated)
    /// Bumped on every refresh so a slow, older probe can't overwrite a newer one.
    private var probeGeneration = 0

    private lazy var versionLabel = NSTextField(labelWithString: "cmux: checking…")
    private lazy var modeLabel = NSTextField(wrappingLabelWithString: "Socket mode: checking…")
    private lazy var passwordField = NSSecureTextField(string: "")
    private lazy var passwordStatus = NSTextField(wrappingLabelWithString: "")
    private lazy var testStatus = NSTextField(wrappingLabelWithString: "")
    private lazy var testButton = NSButton(title: "Test connection", target: nil, action: nil)
    private lazy var removeButton = NSButton(title: "Remove", target: nil, action: nil)

    /// The window is built on first `show()` (always on main), so touching
    /// `shared` from another thread never creates AppKit objects there.
    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows (or brings forward) the window and re-reads cmux's state.
    func show() {
        if Thread.isMainThread { present() } else { DispatchQueue.main.async { self.present() } }
    }

    private func present() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "Set up cmux"
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
            buildUI()
        }
        refreshStatus()
        refreshPasswordStatus()
        testStatus.stringValue = ""
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: layout

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])

        let width: CGFloat = 528
        func heading(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .boldSystemFont(ofSize: 13)
            return l
        }
        func body(_ s: String) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: s)
            l.font = .systemFont(ofSize: 12)
            l.preferredMaxLayoutWidth = width
            return l
        }
        func row(_ views: [NSView]) -> NSStackView {
            let r = NSStackView(views: views)
            r.orientation = .horizontal
            r.spacing = 8
            r.alignment = .centerY
            return r
        }
        func button(_ b: NSButton, _ action: Selector) -> NSButton {
            b.target = self
            b.action = action
            b.bezelStyle = .rounded
            return b
        }

        root.addArrangedSubview(body("Page types phone replies into your cmux sessions and answers the approvals cmux is holding. cmux only lets apps it started control it, so it needs one setting changed first."))

        // Status
        root.addArrangedSubview(heading("This Mac"))
        versionLabel.font = .systemFont(ofSize: 12)
        modeLabel.font = .systemFont(ofSize: 12)
        modeLabel.preferredMaxLayoutWidth = width
        root.addArrangedSubview(versionLabel)
        root.addArrangedSubview(row([modeLabel, button(NSButton(title: "Refresh", target: nil, action: nil), #selector(refreshClicked))]))

        // Steps
        root.addArrangedSubview(heading("Switch cmux to Password mode"))
        root.addArrangedSubview(body("""
        1. In cmux, open Settings ▸ Automation ▸ Socket Control Mode and choose “Password mode”.
        2. Under Socket Password, click Set and choose a password.
        3. Enter the same password below and click Save. Page keeps it in your Keychain and hands it only to cmux’s own command-line tool (signed by cmux’s developer), in an environment variable, never on the command line.
        """))
        root.addArrangedSubview(body("Prefer a config file? Set \"automation.socketControlMode\": \"password\" in ~/.config/cmux/cmux.json. “Automation mode” also works without a password, but then any app running as you can control cmux."))

        passwordField.placeholderString = "cmux socket password"
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        passwordField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let save = button(NSButton(title: "Save", target: nil, action: nil), #selector(savePassword))
        save.keyEquivalent = "\r"
        root.addArrangedSubview(row([passwordField, save, button(removeButton, #selector(removePassword))]))
        passwordStatus.font = .systemFont(ofSize: 11)
        passwordStatus.textColor = .secondaryLabelColor
        passwordStatus.preferredMaxLayoutWidth = width
        root.addArrangedSubview(passwordStatus)

        // Test
        root.addArrangedSubview(row([button(testButton, #selector(testConnection)), testStatus]))
        testStatus.font = .systemFont(ofSize: 12)
        testStatus.preferredMaxLayoutWidth = 380

        // Phone forwarding
        root.addArrangedSubview(heading("One page per alert"))
        root.addArrangedSubview(body("Page pages your iPhone itself. If you also use cmux on your iPhone, turn off cmux ▸ Settings ▸ Notifications ▸ “Forward notifications to my iPhone” (also under Settings ▸ Mobile ▸ “Forward Notifications to iPhone”), or every alert will reach your phone twice."))
        root.addArrangedSubview(row([
            button(NSButton(title: "Open cmux", target: nil, action: nil), #selector(openCmux)),
            button(NSButton(title: "cmux iPhone docs", target: nil, action: nil), #selector(openPhoneDocs)),
        ]))

        let close = button(NSButton(title: "Done", target: nil, action: nil), #selector(closeWindow))
        close.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = row([spacer, close])
        root.addArrangedSubview(bottom)
        bottom.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    // MARK: status (offline commands only)

    private func refreshStatus() {
        probeGeneration += 1
        let generation = probeGeneration
        versionLabel.stringValue = "cmux: checking…"
        modeLabel.stringValue = "Socket mode: checking…"
        modeLabel.textColor = .labelColor
        workQueue.async { [weak self] in
            CmuxBridge.invalidateStatusCache()
            let cli = CmuxBridge.cliPath(forBundlePath: nil)
            let version = cli.flatMap { path -> String? in
                let r = CmuxBridge.defaultRunner(path, ["--version"], nil, CmuxBridge.cliEnvironment(password: nil), 5)
                return r.succeeded ? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            }
            let status = cli.flatMap { CmuxBridge.socketStatus(cliPath: $0, useCache: false) }
            DispatchQueue.main.async {
                guard let self, generation == self.probeGeneration else { return }
                self.render(cliFound: cli != nil, version: version, status: status)
            }
        }
    }

    private func render(cliFound: Bool, version: String?, status: CmuxBridge.SocketStatus?) {
        guard cliFound else {
            versionLabel.stringValue = "cmux: not installed (looked for cmux.app)"
            modeLabel.stringValue = "Install cmux, or use tmux, Terminal.app or iTerm2 for sessions you want to answer from your phone."
            modeLabel.textColor = .secondaryLabelColor
            testButton.isEnabled = false
            return
        }
        testButton.isEnabled = true
        versionLabel.stringValue = "cmux: \(version ?? "installed (version unknown)")"
        guard let status else {
            modeLabel.stringValue = "Socket mode: couldn't read it (cmux socket-status failed)."
            modeLabel.textColor = .systemOrange
            return
        }
        let mode = status.effectiveMode
        switch mode {
        case .password:
            modeLabel.stringValue = "Socket mode: \(mode.displayName) — Page can connect with the password below."
            modeLabel.textColor = .systemGreen
        case .automation, .allowAll:
            modeLabel.stringValue = "Socket mode: \(mode.displayName) — Page can connect (no password needed)."
            modeLabel.textColor = .systemGreen
        case .cmuxOnly, .off, .unknown:
            modeLabel.stringValue = "Socket mode: \(mode.displayName) — cmux blocks Page. Follow the steps below."
            modeLabel.textColor = .systemOrange
        }
        if let configured = status.configuredMode, configured != mode {
            modeLabel.stringValue += " (configured: \(configured.displayName))"
        }
    }

    private func refreshPasswordStatus() {
        switch secrets.read(allowUI: false) {
        case .found:
            passwordStatus.stringValue = "A password is saved in your Keychain."
            removeButton.isEnabled = true
        case .notFound:
            passwordStatus.stringValue = "No password saved."
            removeButton.isEnabled = false
        case .interactionRequired:
            passwordStatus.stringValue = "A password is saved, but macOS needs it saved again since Page was updated — enter it and click Save."
            removeButton.isEnabled = true
        case .failed(let status):
            passwordStatus.stringValue = "Couldn't read the Keychain (error \(status))."
            removeButton.isEnabled = true
        }
    }

    // MARK: actions

    @objc private func refreshClicked() {
        refreshStatus()
        refreshPasswordStatus()
    }

    @objc private func savePassword() {
        let pw = passwordField.stringValue
        guard !pw.isEmpty else {
            passwordStatus.stringValue = "Enter the password you set in cmux first."
            return
        }
        if let error = secrets.write(pw) {
            passwordStatus.stringValue = error
            return
        }
        passwordField.stringValue = ""
        refreshPasswordStatus()
        CmuxBridge.invalidateStatusCache()
        Logger.shared.log("cmux socket password saved to the Keychain")
    }

    @objc private func removePassword() {
        secrets.delete()
        refreshPasswordStatus()
        Logger.shared.log("cmux socket password removed from the Keychain")
    }

    /// The one call that talks to cmux's socket: `cmux ping`, on request.
    @objc private func testConnection() {
        testButton.isEnabled = false
        testStatus.textColor = .labelColor
        testStatus.stringValue = "Testing…"
        let secrets = self.secrets
        workQueue.async { [weak self] in
            let outcome: (ok: Bool, text: String)
            if let cli = CmuxBridge.cliPath(forBundlePath: nil) {
                CmuxBridge.invalidateStatusCache()
                // The user is here: a Keychain prompt (after an update) is fine.
                switch CmuxBridge.connect(cliPath: cli, secrets: secrets, allowKeychainUI: true) {
                case .failure(let f):
                    outcome = (false, f.detail)
                case .success(let client):
                    switch client.ping() {
                    case .success: outcome = (true, "Connected — Page can reach your cmux sessions.")
                    case .failure(let f): outcome = (false, f.detail)
                    }
                }
            } else {
                outcome = (false, "cmux isn't installed.")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.testButton.isEnabled = true
                self.testStatus.textColor = outcome.ok ? .systemGreen : .systemOrange
                self.testStatus.stringValue = outcome.text
                self.refreshPasswordStatus()
            }
        }
    }

    @objc private func openCmux() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CmuxBridge.bundleIdentifier) else {
            testStatus.textColor = .systemOrange
            testStatus.stringValue = "cmux isn't installed."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    @objc private func openPhoneDocs() {
        if let url = URL(string: "https://cmux.com/docs/ios") { NSWorkspace.shared.open(url) }
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }
}
