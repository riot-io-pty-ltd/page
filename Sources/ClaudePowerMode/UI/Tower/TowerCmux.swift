import SwiftUI
import Combine

private typealias P = NightWatch.Palette

// MARK: - Model

/// The cmux setup: which cmux is installed and whether its socket lets Page
/// in, one click to Automation mode, or a password kept in the Keychain, a
/// test, and the reminder to turn off cmux's own iPhone forwarding.
///
/// Opening it only runs commands that never touch cmux's socket (`--version`,
/// `socket-status`). The one socket call, `cmux ping`, runs on Test connection.
/// The Keychain store, the cmux CLI checks and the Automation-mode rollback
/// are the ones the old window used, unchanged. Main thread only.
final class TowerCmuxModel: ObservableObject {
    enum Tone: Equatable { case quiet, good, warn }

    struct Line: Equatable {
        var text: String
        var tone: Tone = .quiet
    }

    @Published private(set) var version = Line(text: "cmux: checking…")
    @Published private(set) var mode = Line(text: "Socket mode: checking…")
    @Published private(set) var passwordStatus = Line(text: "")
    @Published private(set) var canRemovePassword = false
    @Published private(set) var canTest = true
    @Published private(set) var testStatus = Line(text: "")
    @Published private(set) var enabling = false
    @Published private(set) var enableStatus = Line(text: "")
    /// What is typed in the password field (never stored here beyond Save).
    @Published var passwordInput = ""

    private weak var store: TowerStore?
    private let workQueue = DispatchQueue(label: "ClaudePowerMode.CmuxSetup", qos: .userInitiated)
    /// Bumped on every refresh so a slow, older probe can't overwrite a newer one.
    private var probeGeneration = 0

    init(store: TowerStore) { self.store = store }

    private var secrets: SecretStore? { store?.env.cmuxSecrets }

    /// The page opened (or Refresh): re-read cmux's state, clear the old test result.
    func open() {
        refreshStatus()
        refreshPasswordStatus()
        testStatus = Line(text: "")
    }

    /// Sets what the page shows without probing anything: the render harness and tests.
    func setFixture(version: Line, mode: Line, passwordStatus: Line, canRemovePassword: Bool = false,
                    testStatus: Line = Line(text: ""), enableStatus: Line = Line(text: "")) {
        probeGeneration += 1
        self.version = version
        self.mode = mode
        self.passwordStatus = passwordStatus
        self.canRemovePassword = canRemovePassword
        self.testStatus = testStatus
        self.enableStatus = enableStatus
    }

    // MARK: status (offline commands only)

    func refreshStatus() {
        guard secrets != nil else { return }
        probeGeneration += 1
        let generation = probeGeneration
        version = Line(text: "cmux: checking…")
        mode = Line(text: "Socket mode: checking…")
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
            self.version = Line(text: "cmux: not installed (looked for cmux.app)")
            mode = Line(text: "Install cmux, or use tmux or iTerm2 for sessions whose questions you want to answer from your phone.")
            canTest = false
            return
        }
        canTest = true
        self.version = Line(text: "cmux: \(version ?? "installed (version unknown)")")
        guard let status else {
            mode = Line(text: "Socket mode: couldn't read it (cmux socket-status failed).", tone: .warn)
            return
        }
        mode = Self.modeLine(status)
    }

    /// Pure. The socket mode line for a `socket-status` answer.
    static func modeLine(_ status: CmuxBridge.SocketStatus) -> Line {
        let m = status.effectiveMode
        var line: Line
        switch m {
        case .password:
            line = Line(text: "Socket mode: \(m.displayName) — Page can connect with the password below.", tone: .good)
        case .automation, .allowAll:
            line = Line(text: "Socket mode: \(m.displayName) — Page can connect (no password needed).", tone: .good)
        case .cmuxOnly, .off, .unknown:
            line = Line(text: "Socket mode: \(m.displayName) — cmux blocks Page. Follow the steps below.", tone: .warn)
        }
        if let configured = status.configuredMode, configured != m {
            line.text += " (configured: \(configured.displayName))"
        }
        return line
    }

    func refreshPasswordStatus() {
        guard let secrets else { return }
        switch secrets.read(allowUI: false) {
        case .found:
            passwordStatus = Line(text: "A password is saved in your Keychain.")
            canRemovePassword = true
        case .notFound:
            passwordStatus = Line(text: "No password saved.")
            canRemovePassword = false
        case .interactionRequired:
            passwordStatus = Line(text: "A password is saved, but macOS needs it saved again since Page was updated — enter it and click Save.")
            canRemovePassword = true
        case .failed(let status):
            passwordStatus = Line(text: "Couldn't read the Keychain (error \(status)).")
            canRemovePassword = true
        }
    }

    // MARK: actions

    func refreshClicked() {
        refreshStatus()
        refreshPasswordStatus()
    }

    func savePassword() {
        guard let secrets else { return }
        let pw = passwordInput
        guard !pw.isEmpty else {
            passwordStatus = Line(text: "Enter the password you set in cmux first.")
            return
        }
        if let error = secrets.write(pw) {
            passwordStatus = Line(text: error)
            return
        }
        passwordInput = ""
        refreshPasswordStatus()
        CmuxBridge.invalidateStatusCache()
        store?.env.log("cmux socket password saved to the Keychain")
    }

    func removePassword() {
        guard let secrets else { return }
        secrets.delete()
        refreshPasswordStatus()
        store?.env.log("cmux socket password removed from the Keychain")
    }

    /// The one call that talks to cmux's socket: `cmux ping`, on request.
    func testConnection() {
        guard let secrets else { return }
        canTest = false
        testStatus = Line(text: "Testing…")
        workQueue.async { [weak self] in
            let outcome: (ok: Bool, text: String)
            if let cli = CmuxBridge.cliPath(forBundlePath: nil) {
                CmuxBridge.invalidateStatusCache()
                // The user is here: a Keychain prompt (after an update) is fine.
                switch CmuxBridge.connect(cliPath: cli, secrets: secrets, allowKeychainUI: true) {
                case .failure(let f):
                    outcome = (false, f.detail)
                case .success(let client):
                    switch client.verifyAccess() {
                    case .success: outcome = (true, "Connected — Page can reach your cmux sessions.")
                    case .failure(let f): outcome = (false, f.detail)
                    }
                }
            } else {
                outcome = (false, "cmux isn't installed.")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.canTest = true
                self.testStatus = Line(text: outcome.text, tone: outcome.ok ? .good : .warn)
                self.refreshPasswordStatus()
            }
        }
    }

    /// One click: Automation mode in cmux.json (backed up) → wait for cmux
    /// to pick the file up → prove Page gets in. Any failure after the file
    /// changed puts the backup back.
    func enableForPage() {
        guard let secrets, !enabling else { return }
        enabling = true
        enableStatus = Line(text: "Setting up…")
        let log = store?.env.log ?? { _ in }
        workQueue.async { [weak self] in
            let outcome = Self.enable(secrets: secrets, log: log)
            DispatchQueue.main.async {
                guard let self else { return }
                self.enabling = false
                self.enableStatus = Line(text: outcome.text, tone: outcome.ok ? .good : .warn)
                self.refreshStatus()
                self.refreshPasswordStatus()
            }
        }
    }

    private static func enable(secrets: SecretStore, log: @escaping (String) -> Void) -> (ok: Bool, text: String) {
        guard let cli = CmuxBridge.cliPath(forBundlePath: nil) else { return (false, "cmux isn't installed.") }
        guard CmuxBridge.isTrustedCLI(cli) else { return (false, CmuxBridge.unverifiedCLIDetail) }
        CmuxBridge.invalidateStatusCache()
        if let status = CmuxBridge.socketStatus(cliPath: cli, useCache: false), status.effectiveMode.admitsExternalClients,
           case .success(let client) = CmuxBridge.connect(cliPath: cli, secrets: secrets, allowKeychainUI: true),
           case .success = client.verifyAccess() {
            return (true, "Already set up — Page can type into your cmux sessions.")
        }
        let backup: URL?
        switch CmuxConfigFile.enableAutomationMode() {
        case .failure(let e): return (false, e.message)
        case .success(let b): backup = b
        }
        func undo(_ why: String) -> (ok: Bool, text: String) {
            CmuxConfigFile.restore(backup: backup)
            CmuxBridge.invalidateStatusCache()
            log("cmux one-click setup rolled back: \(why)")
            return (false, "\(why) Your cmux settings were put back.")
        }
        // cmux applies cmux.json changes on its own within about a second.
        var admitted = false
        for _ in 0..<16 {
            usleep(500_000)
            CmuxBridge.invalidateStatusCache()
            guard CmuxBridge.socketStatus(cliPath: cli, useCache: false)?.effectiveMode == .automation else { continue }
            if case .success(let client) = CmuxBridge.connect(cliPath: cli, secrets: secrets),
               case .success = client.verifyAccess() {
                admitted = true
                break
            }
        }
        guard admitted else { return undo("cmux didn't let Page in within 8 seconds.") }
        log("cmux switched to Automation mode for Page (backup: \(backup?.lastPathComponent ?? "none"))")
        return (true, "Done — Page can type into your cmux sessions.")
    }

    func openCmux() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CmuxBridge.bundleIdentifier) else {
            testStatus = Line(text: "cmux isn't installed.", tone: .warn)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    func openPhoneDocs() {
        if let url = URL(string: "https://cmux.com/docs/ios") { store?.env.openURL(url) }
    }
}

// MARK: - Page

/// A password field in the Night Watch field style.
struct NWSecureField: View {
    @Binding var text: String
    var placeholder = ""
    var onSubmit: () -> Void = {}

    var body: some View {
        SecureField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Font.system(size: 13))
            .foregroundColor(P.textPrimary.color)
            .onSubmit(onSubmit)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }
}

/// The Terminals page's cmux setup: a page under Terminals, with a way back.
struct NWCmuxSetupPage: View {
    @ObservedObject var store: TowerStore
    @ObservedObject var model: TowerCmuxModel

    init(store: TowerStore) {
        self.store = store
        self.model = store.cmux
    }

    private func tone(_ t: TowerCmuxModel.Tone) -> TowerStatusLine.Tone {
        switch t {
        case .quiet: return .quiet
        case .good: return .good
        case .warn: return .bad
        }
    }

    private func color(_ t: TowerCmuxModel.Tone) -> NightWatch.RGBA {
        switch t {
        case .quiet: return P.textTertiary
        case .good: return P.green
        case .warn: return P.amber
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                NWButton(title: "‹  Terminals", kind: .quiet) { store.closeCmuxSetup() }
                    .padding(.leading, -14)
                Text("Set up cmux")
                    .font(Font.system(size: 28, weight: .bold)).kerning(-0.6)
                    .foregroundColor(P.textPrimary.color)
                Text("Page types phone replies into your cmux sessions and answers the approvals cmux is holding. cmux only lets apps it started control it, so it needs one setting changed first.")
                    .font(Font.system(size: 14))
                    .foregroundColor(P.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            NWCard(title: "THIS MAC") {
                NWRow(title: model.version.text, detail: nil) {
                    NWButton(title: "Refresh", kind: .secondary) { model.refreshClicked() }
                }
                NWDivider()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: model.mode.tone == .good ? "checkmark.circle.fill" : (model.mode.tone == .warn ? "exclamationmark.triangle.fill" : "ellipsis.circle"))
                    Text(model.mode.text).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(Font.system(size: 12))
                .foregroundColor(color(model.mode.tone).color)
                .padding(.horizontal, 16).padding(.vertical, 13)
            }

            NWCard(title: "LET PAGE IN") {
                NWRow(title: "Let Page type into cmux",
                      detail: "Switches cmux to Automation mode by adding one setting to ~/.config/cmux/cmux.json, after backing the file up. No password needed. In this mode any app running as you can control cmux, much as any app can script Terminal.") {
                    NWButton(title: model.enabling ? "Setting up…" : "Let Page type into cmux", kind: .primary, enabled: !model.enabling) { model.enableForPage() }
                }
                if !model.enableStatus.text.isEmpty {
                    NWNote(text: model.enableStatus.text, tone: tone(model.enableStatus.tone))
                        .padding(.horizontal, 16).padding(.bottom, 12)
                }
            }

            NWCard(title: "OR USE PASSWORD MODE INSTEAD (KEEPS OTHER APPS OUT)") {
                VStack(alignment: .leading, spacing: 8) {
                    step("1", "In cmux, open Settings ▸ Automation ▸ Socket Control Mode and choose “Password mode”.")
                    step("2", "Under Socket Password, click Set and choose a password.")
                    step("3", "Enter the same password below and click Save. Page keeps it in your Keychain and hands it only to cmux’s own command-line tool (signed by cmux’s developer), in an environment variable, never on the command line.")
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                NWDivider()
                NWNote(text: "Prefer a config file? Set \"automation.socketControlMode\": \"password\" in ~/.config/cmux/cmux.json, with \"socketPassword\" beside it.", mono: false)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                NWDivider()
                HStack(spacing: 10) {
                    NWSecureField(text: Binding(get: { model.passwordInput }, set: { model.passwordInput = $0 }),
                                  placeholder: "cmux socket password", onSubmit: { model.savePassword() })
                        .frame(maxWidth: 300)
                    NWButton(title: "Save", kind: .primary) { model.savePassword() }
                    NWButton(title: "Remove", kind: .secondary, enabled: model.canRemovePassword) { model.removePassword() }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, model.passwordStatus.text.isEmpty ? 13 : 8)
                if !model.passwordStatus.text.isEmpty {
                    NWNote(text: model.passwordStatus.text).padding(.horizontal, 16).padding(.bottom, 12)
                }
            }

            NWCard(title: "TEST") {
                NWRow(title: "Test connection", detail: "Runs cmux ping, the one call that talks to cmux’s socket.") {
                    NWButton(title: "Test connection", kind: .secondary, enabled: model.canTest) { model.testConnection() }
                }
                if !model.testStatus.text.isEmpty {
                    NWNote(text: model.testStatus.text, tone: tone(model.testStatus.tone))
                        .padding(.horizontal, 16).padding(.bottom, 12)
                }
            }

            NWCard(title: "ONE PAGE PER ALERT") {
                NWNote(text: "Page pages your iPhone itself. If you also use cmux on your iPhone, turn off cmux ▸ Settings ▸ Notifications ▸ “Forward notifications to my iPhone” (also under Settings ▸ Mobile ▸ “Forward Notifications to iPhone”), or every alert will reach your phone twice.")
                    .padding(16)
                NWDivider()
                HStack(spacing: 8) {
                    NWButton(title: "Open cmux", kind: .secondary) { model.openCmux() }
                    NWButton(title: "cmux iPhone docs", kind: .secondary) { model.openPhoneDocs() }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
            }

            HStack {
                Spacer(minLength: 0)
                NWButton(title: "Done", kind: .secondary, shortcut: .cancelAction) { store.closeCmuxSetup() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(n)
                .font(Font.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(P.teal.color)
                .frame(width: 20, height: 20)
                .background(Circle().fill(P.teal.opacity(0.14).color))
            Text(text)
                .font(Font.system(size: 12.5))
                .foregroundColor(P.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
