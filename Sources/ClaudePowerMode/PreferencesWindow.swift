import AppKit
import SwiftUI

/// Everything the Preferences window edits, as plain values. Pure so the
/// save rules are testable without AppKit.
struct PreferencesForm: Equatable {
    // Phone & paging
    var relayEnabled: Bool
    /// Empty when the config still holds the placeholder.
    var relayURL: String
    var interventionDetectionEnabled: Bool
    var idlePageOnlyWhenAwaySeconds: Double
    var idlePageDelaySeconds: Double
    var holdAwakeForPendingPageMinutes: Double
    var headlessResumeFallbackEnabled: Bool
    var remoteSessionsEnabled: Bool
    // Power
    var lowBatteryCutoff: Int
    var recoveryThreshold: Int
    var recoveryRequiresAC: Bool
    var requireRecentTranscriptActivity: Bool
    var transcriptActivityWindowSeconds: Double
    var checkIntervalSeconds: Double
    var keepAwakeLidClosedOnAC: Bool
    var keepAwakeLidClosedOnBattery: Bool
    var lowBatteryAction: LowBatteryAction
    var lowBatteryPauseGraceSeconds: Double
    var resumeAfterBatteryRecovery: Bool
    // Agents
    var codexBackendEnabled: Bool
    var localModelsEnabled: Bool
    var codexPath: String
    // Rate limits
    var rateLimitWatcherEnabled: Bool
    var autoResumeEnabled: Bool
    var carryOnPrompt: String
    var holdAssertionUntilReset: Bool
    var wakeViaPmsetEnabled: Bool
    // Alerts (v4)
    var stuckAlertsEnabled: Bool
    var stuckAfterMinutes: Double
    var turnSummaryEnabled: Bool
    var phoneStartSessionsEnabled: Bool
    var batteryForecastPageEnabled: Bool
    var earlyBatteryPause: Bool
    var usageForecastPageEnabled: Bool

    init(_ c: Config) {
        relayEnabled = c.relayEnabled
        relayURL = c.isRelayURLPlaceholder ? "" : c.relayURL
        interventionDetectionEnabled = c.interventionDetectionEnabled
        idlePageOnlyWhenAwaySeconds = c.idlePageOnlyWhenAwaySeconds
        idlePageDelaySeconds = c.idlePageDelaySeconds
        holdAwakeForPendingPageMinutes = c.holdAwakeForPendingPageMinutes
        headlessResumeFallbackEnabled = c.headlessResumeFallbackEnabled
        remoteSessionsEnabled = c.remoteSessionsEnabled
        lowBatteryCutoff = c.lowBatteryCutoff
        recoveryThreshold = c.recoveryThreshold
        recoveryRequiresAC = c.recoveryRequiresAC
        requireRecentTranscriptActivity = c.requireRecentTranscriptActivity
        transcriptActivityWindowSeconds = c.transcriptActivityWindowSeconds
        checkIntervalSeconds = c.checkIntervalSeconds
        keepAwakeLidClosedOnAC = c.keepAwakeLidClosedOnAC
        keepAwakeLidClosedOnBattery = c.keepAwakeLidClosedOnBattery
        lowBatteryAction = c.lowBatteryAction
        lowBatteryPauseGraceSeconds = c.lowBatteryPauseGraceSeconds
        resumeAfterBatteryRecovery = c.resumeAfterBatteryRecovery
        codexBackendEnabled = c.codexBackendEnabled
        localModelsEnabled = c.localModelsEnabled
        codexPath = c.codexPath
        rateLimitWatcherEnabled = c.rateLimitWatcherEnabled
        autoResumeEnabled = c.autoResumeEnabled
        carryOnPrompt = c.carryOnPrompt
        holdAssertionUntilReset = c.holdAssertionUntilReset
        wakeViaPmsetEnabled = c.wakeViaPmsetEnabled
        stuckAlertsEnabled = c.stuckAlertsEnabled
        stuckAfterMinutes = c.stuckAfterMinutes
        turnSummaryEnabled = c.turnSummaryEnabled
        phoneStartSessionsEnabled = c.phoneStartSessionsEnabled
        batteryForecastPageEnabled = c.batteryForecastPageEnabled
        earlyBatteryPause = c.earlyBatteryPause
        usageForecastPageEnabled = c.usageForecastPageEnabled
    }

    /// Why this form can't be saved, or nil.
    func validationError(isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        let url = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty {
            if relayEnabled { return "Enter your relay’s URL, or turn off “Send pages to my phone”." }
        } else if case .failure(let problem) = Config.validatedRelayURL(url) {
            return problem.message
        }
        let path = codexPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty && !isExecutable((path as NSString).expandingTildeInPath) {
            return "No executable codex at \(path). Leave the field blank to auto-detect."
        }
        return nil
    }

    /// Writes only the fields that differ from `baseline` (what the window
    /// showed when it opened) onto `base` (the freshest config on disk).
    /// A value hand-edited in config.json while the window was open — or
    /// one no control exposes — is never overwritten by a stale control.
    func merged(onto base: Config, changedFrom baseline: PreferencesForm) -> Config {
        var c = base
        if relayEnabled != baseline.relayEnabled { c.relayEnabled = relayEnabled }
        if relayURL != baseline.relayURL {
            let trimmed = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalized = try? Config.validatedRelayURL(trimmed).get() {
                c.relayURL = normalized.absoluteString
            } else {
                c.relayURL = trimmed
            }
        }
        if interventionDetectionEnabled != baseline.interventionDetectionEnabled { c.interventionDetectionEnabled = interventionDetectionEnabled }
        if idlePageOnlyWhenAwaySeconds != baseline.idlePageOnlyWhenAwaySeconds { c.idlePageOnlyWhenAwaySeconds = idlePageOnlyWhenAwaySeconds }
        if idlePageDelaySeconds != baseline.idlePageDelaySeconds { c.idlePageDelaySeconds = idlePageDelaySeconds }
        if holdAwakeForPendingPageMinutes != baseline.holdAwakeForPendingPageMinutes { c.holdAwakeForPendingPageMinutes = holdAwakeForPendingPageMinutes }
        if headlessResumeFallbackEnabled != baseline.headlessResumeFallbackEnabled { c.headlessResumeFallbackEnabled = headlessResumeFallbackEnabled }
        if remoteSessionsEnabled != baseline.remoteSessionsEnabled { c.remoteSessionsEnabled = remoteSessionsEnabled }
        if lowBatteryCutoff != baseline.lowBatteryCutoff { c.lowBatteryCutoff = lowBatteryCutoff }
        if recoveryThreshold != baseline.recoveryThreshold { c.recoveryThreshold = recoveryThreshold }
        if recoveryRequiresAC != baseline.recoveryRequiresAC { c.recoveryRequiresAC = recoveryRequiresAC }
        if requireRecentTranscriptActivity != baseline.requireRecentTranscriptActivity { c.requireRecentTranscriptActivity = requireRecentTranscriptActivity }
        if transcriptActivityWindowSeconds != baseline.transcriptActivityWindowSeconds { c.transcriptActivityWindowSeconds = transcriptActivityWindowSeconds }
        if checkIntervalSeconds != baseline.checkIntervalSeconds { c.checkIntervalSeconds = checkIntervalSeconds }
        if keepAwakeLidClosedOnAC != baseline.keepAwakeLidClosedOnAC { c.keepAwakeLidClosedOnAC = keepAwakeLidClosedOnAC }
        if keepAwakeLidClosedOnBattery != baseline.keepAwakeLidClosedOnBattery { c.keepAwakeLidClosedOnBattery = keepAwakeLidClosedOnBattery }
        if lowBatteryAction != baseline.lowBatteryAction { c.lowBatteryAction = lowBatteryAction }
        if lowBatteryPauseGraceSeconds != baseline.lowBatteryPauseGraceSeconds { c.lowBatteryPauseGraceSeconds = lowBatteryPauseGraceSeconds }
        if resumeAfterBatteryRecovery != baseline.resumeAfterBatteryRecovery { c.resumeAfterBatteryRecovery = resumeAfterBatteryRecovery }
        if codexBackendEnabled != baseline.codexBackendEnabled { c.codexBackendEnabled = codexBackendEnabled }
        if localModelsEnabled != baseline.localModelsEnabled { c.localModelsEnabled = localModelsEnabled }
        if codexPath != baseline.codexPath { c.codexPath = codexPath.trimmingCharacters(in: .whitespacesAndNewlines) }
        if rateLimitWatcherEnabled != baseline.rateLimitWatcherEnabled { c.rateLimitWatcherEnabled = rateLimitWatcherEnabled }
        if autoResumeEnabled != baseline.autoResumeEnabled { c.autoResumeEnabled = autoResumeEnabled }
        if carryOnPrompt != baseline.carryOnPrompt { c.carryOnPrompt = carryOnPrompt }
        if holdAssertionUntilReset != baseline.holdAssertionUntilReset { c.holdAssertionUntilReset = holdAssertionUntilReset }
        if wakeViaPmsetEnabled != baseline.wakeViaPmsetEnabled { c.wakeViaPmsetEnabled = wakeViaPmsetEnabled }
        if stuckAlertsEnabled != baseline.stuckAlertsEnabled { c.stuckAlertsEnabled = stuckAlertsEnabled }
        if stuckAfterMinutes != baseline.stuckAfterMinutes { c.stuckAfterMinutes = stuckAfterMinutes }
        if turnSummaryEnabled != baseline.turnSummaryEnabled { c.turnSummaryEnabled = turnSummaryEnabled }
        if phoneStartSessionsEnabled != baseline.phoneStartSessionsEnabled { c.phoneStartSessionsEnabled = phoneStartSessionsEnabled }
        if batteryForecastPageEnabled != baseline.batteryForecastPageEnabled { c.batteryForecastPageEnabled = batteryForecastPageEnabled }
        if earlyBatteryPause != baseline.earlyBatteryPause { c.earlyBatteryPause = earlyBatteryPause }
        if usageForecastPageEnabled != baseline.usageForecastPageEnabled { c.usageForecastPageEnabled = usageForecastPageEnabled }
        return c
    }
}

extension PreferencesForm {
    /// Pure. The form as it is saved: relay URL and Codex path trimmed, and an
    /// empty resume prompt turned back into the default.
    func normalisedForSave() -> PreferencesForm {
        var f = self
        f.relayURL = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        f.codexPath = codexPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = carryOnPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        f.carryOnPrompt = prompt.isEmpty ? Config().carryOnPrompt : prompt
        return f
    }

    /// Pure. Every setting back to its default, except the setup that is hard
    /// to re-type: whether the relay is on, its URL and the Codex path.
    func resetToDefaults() -> PreferencesForm {
        var d = PreferencesForm(Config())
        d.relayEnabled = relayEnabled
        d.relayURL = relayURL
        d.codexPath = codexPath
        return d
    }
}

/// The Tower: Page's settings window. A SwiftUI view (UI/Tower) in a dark,
/// full-size-content window. The entry points the rest of the app uses are
/// unchanged: `init(coordinator:)` and `showAndFocus()`.
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let coordinator: Coordinator
    let store: TowerStore

    /// `pairPhone` and `copyDiagnostics` live in AppDelegate (the pairing
    /// window and a notification); the cmux and hook windows are singletons.
    init(coordinator: Coordinator, macName: String = "this Mac",
         pairPhone: @escaping () -> Void = {}, copyDiagnostics: @escaping () -> Void = {}) {
        self.coordinator = coordinator
        self.store = TowerStore(config: coordinator.config, macName: macName)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Page Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NightWatch.Palette.background.nsColor
        window.minSize = NSSize(width: 960, height: 640)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: NWTowerView(store: store))
        store.env = makeEnvironment(pairPhone: pairPhone, copyDiagnostics: copyDiagnostics)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeEnvironment(pairPhone: @escaping () -> Void, copyDiagnostics: @escaping () -> Void) -> TowerEnvironment {
        var env = TowerEnvironment()
        let coordinator = self.coordinator
        env.loadConfig = { Config.loadResult() }
        env.runningConfig = { coordinator.config }
        env.writeConfig = { try $0.write() }
        env.reloadConfig = { coordinator.reloadConfig() }
        env.isExecutable = { FileManager.default.isExecutableFile(atPath: $0) }
        env.findCodex = { ProcessRunner.findExecutable("codex", configured: $0) }
        env.checkHelper = { refresh, done in coordinator.checkPowerHelper(refresh: refresh, completion: done) }
        env.installHelper = { done in coordinator.installPowerHelper(completion: done) }
        env.usageCaptureState = { UsageCapture().state() }
        env.setUsageCapture = { on in try UsageCapture().set(on)?.lastPathComponent }
        env.localModelLines = { LocalActivity.menuLines(coordinator.localActivities) }
        env.probeRelay = { base, done in Self.probeRelay(base, done) }
        env.showAlert = { [weak self] title, text in self?.showAlert(title, text) }
        env.confirmReplaceBrokenConfig = { info in
            let alert = NSAlert()
            alert.messageText = "config.json couldn’t be read"
            alert.informativeText = info
            alert.addButton(withTitle: "Replace config.json")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            return alert.runModal() == .alertFirstButtonReturn
        }
        env.close = { [weak self] in self?.window?.close() }
        env.beep = { NSSound.beep() }
        env.log = { Logger.shared.log($0) }
        env.pairPhone = pairPhone
        env.setUpCmux = { CmuxSetupWindowController.shared.show() }
        env.installHooks = { HookInstallerWindowController.shared.show() }
        env.copyLocalDiagnostics = copyDiagnostics
        env.openConfigFile = { NSWorkspace.shared.open(Config.configURL) }
        env.openLog = { NSWorkspace.shared.open(Logger.logURL) }
        env.reloadFromMenu = { coordinator.reloadConfig() }
        return env
    }

    /// GET `<relay>/health`: a Page relay answers `{"ok": true}`. Only runs
    /// when the user clicks Test.
    private static func probeRelay(_ base: URL, _ done: @escaping (String, Bool) -> Void) {
        var request = URLRequest(url: base.appendingPathComponent("health"), timeoutInterval: 8)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        URLSession.shared.dataTask(with: request) { data, response, error in
            let message: String
            let ok: Bool
            if let error {
                message = "✗ Can’t reach it: \(error.localizedDescription)"
                ok = false
            } else if (response as? HTTPURLResponse)?.statusCode == 200,
                      let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["ok"] as? Bool == true {
                message = "✓ Page relay is reachable"
                ok = true
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                message = "✗ That server answered (HTTP \(code)) but isn’t a Page relay"
                ok = false
            }
            DispatchQueue.main.async { done(message, ok) }
        }.resume()
    }

    private func showAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// Reloads every control from disk, so Cancel always reverts and edits
    /// made to config.json by hand show up. `section` picks the page.
    func showAndFocus(section: TowerSection? = nil) {
        store.load(section: section)
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
