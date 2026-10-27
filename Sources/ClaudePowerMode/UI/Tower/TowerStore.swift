import Foundation
import Combine

/// Everything the Tower needs from the outside world, as closures. The live
/// window (PreferencesWindowController) fills them in; the render harness
/// leaves them at their defaults, so building a store never reads config.json,
/// ~/.claude, the filesystem or the network and never starts a helper.
struct TowerEnvironment {
    /// The freshest config on disk (nil `config`: the file is unreadable).
    var loadConfig: () -> Config.LoadResult? = { nil }
    /// Page's running config: the fallback when the file can't be read.
    var runningConfig: () -> Config = { Config() }
    var writeConfig: (Config) throws -> Void = { _ in }
    var reloadConfig: () -> Void = {}
    var isExecutable: (String) -> Bool = { _ in false }
    /// `ProcessRunner.findExecutable("codex", configured:)`.
    var findCodex: (String?) -> String? = { _ in nil }
    var checkHelper: (_ refresh: Bool, _ done: @escaping (SleepGuard.HelperStatus) -> Void) -> Void = { _, done in done(.unknown) }
    var installHelper: (_ done: @escaping (PowerHelperInstaller.Outcome, SleepGuard.HelperStatus) -> Void) -> Void = { _ in }
    /// `UsageCapture().state()`.
    var usageCaptureState: () -> UsageCapture.State = { .off }
    /// `UsageCapture().set(_:)`; returns the settings backup's file name.
    var setUsageCapture: (Bool) throws -> String? = { _ in nil }
    var localModelLines: () -> [String] = { [] }
    /// GET `<relay>/health`; calls back on the main queue.
    var probeRelay: (_ base: URL, _ done: @escaping (_ message: String, _ ok: Bool) -> Void) -> Void = { _, _ in }
    var showAlert: (_ title: String, _ text: String) -> Void = { _, _ in }
    /// Asks before replacing an unreadable config.json; true = replace it.
    var confirmReplaceBrokenConfig: (_ info: String) -> Bool = { _ in false }
    var close: () -> Void = {}
    var beep: () -> Void = {}
    var log: (String) -> Void = { _ in }

    // Entry points for other windows and files.
    var pairPhone: () -> Void = {}
    var setUpCmux: () -> Void = {}
    var installHooks: () -> Void = {}
    var copyLocalDiagnostics: () -> Void = {}
    var openConfigFile: () -> Void = {}
    var openLog: () -> Void = {}
    var reloadFromMenu: () -> Void = {}

    // The Terminals page. Defaults touch nothing, so the harness and tests never
    // read kitty.conf, ask macOS or look at a process.
    /// Installed hosts, live sessions per host, setup state. Blocking: the live
    /// window runs it off the main queue and calls back on main; nil = nothing learned.
    var probeTerminals: (_ sessions: [AgentSession], _ done: @escaping (TerminalProbe.Snapshot?) -> Void) -> Void = { _, done in done(nil) }
    var previewKitty: () -> Result<KittyConfigFile.Preview, KittyConfigFile.Failure> = { .failure(.unreadable) }
    var enableKitty: () -> Result<KittyConfigFile.Outcome, KittyConfigFile.Failure> = { .failure(.unreadable) }
    var undoKitty: () -> Bool = { false }
    /// Asks macOS for Automation permission (may show its prompt); calls back on main.
    var requestAutomation: (_ id: TerminalCatalog.ID, _ done: @escaping (TerminalProbe.Automation) -> Void) -> Void = { _, done in done(.unknown) }
    /// An OK / Cancel question; true = OK.
    var confirm: (_ title: String, _ text: String, _ okTitle: String) -> Bool = { _, _, _ in false }
    var openURL: (URL) -> Void = { _ in }
    /// The window is on screen (the Terminals page only refreshes then).
    var windowVisible: () -> Bool = { true }
}

/// The state of the Tower window: the form being edited, what was on screen
/// when it opened, and the live bits (battery, usage, helper) the pages draw.
/// Pure logic lives in TowerModel.swift; this class only holds values and
/// calls the environment.
final class TowerStore: ObservableObject {
    enum RelayTest: Equatable {
        case idle
        case testing(host: String)
        case result(message: String, ok: Bool)
    }

    struct UsageCaptureStatus: Equatable {
        var on = false
        var text = ""
        var failed = false
    }

    // MARK: published state

    @Published var selection: TowerSection = .power
    /// What the controls show.
    @Published var form: PreferencesForm
    /// What the controls showed when the window opened (or after Apply).
    @Published private(set) var baseline: PreferencesForm
    @Published private(set) var model: NowModel?
    @Published private(set) var snapshot: Coordinator.Snapshot?
    @Published private(set) var helperStatus: SleepGuard.HelperStatus = .unknown
    @Published private(set) var helperInstalling = false
    @Published private(set) var relayTest: RelayTest = .idle
    @Published private(set) var usageCapture = UsageCaptureStatus()
    @Published private(set) var localLines: [String] = []
    /// config.json had a problem when the window opened.
    @Published private(set) var problem: String?
    /// The Terminals page: facts per host (nil until the first probe) and the
    /// line under the card.
    @Published private(set) var terminals: TerminalProbe.Snapshot?
    @Published private(set) var terminalNotice: TowerStatusLine?

    var env: TowerEnvironment
    var macName: String
    /// The clock the pages read, so a render is deterministic.
    var now: () -> Date = Date.init
    var timeZone: TimeZone = .current

    private var helperCheckGeneration = 0
    private var relayProbeGeneration = 0
    private var terminalProbeGeneration = 0
    private var terminalProbesInFlight = 0

    init(config: Config = Config(), macName: String = "this Mac", env: TowerEnvironment = TowerEnvironment()) {
        let f = PreferencesForm(config)
        self.form = f
        self.baseline = f
        self.macName = macName
        self.env = env
    }

    // MARK: live data

    /// A new snapshot and model from the app (each tick).
    func update(snapshot: Coordinator.Snapshot?, model: NowModel?) {
        let before = liveSessionIDs
        if let snapshot { self.snapshot = snapshot }
        if let model, self.model != model { self.model = model }
        // A session that starts or ends changes the Terminals page's counts:
        // look again now, not at the next timer tick.
        if liveSessionIDs != before { refreshTerminalsIfVisible() }
    }

    /// The live sessions, by id: what the Terminals page counts per host.
    private var liveSessionIDs: Set<String> {
        Set((snapshot?.sessions ?? []).filter { $0.state != .offline }.map(\.sessionId))
    }

    var card: TowerCardModel { TowerCardModel.build(model: model, macName: model?.macName ?? macName) }

    var isDirty: Bool { form != baseline }

    /// Sets the live-ish bits directly, for the render harness and tests (the
    /// real window gets them from `load()` and the environment).
    func preview(helper: SleepGuard.HelperStatus? = nil, installing: Bool = false, localLines: [String]? = nil,
                 usageCapture: UsageCaptureStatus? = nil, relayTest: RelayTest? = nil, problem: String? = nil,
                 terminals: TerminalProbe.Snapshot? = nil, terminalsUnprobed: Bool = false, terminalNotice: TowerStatusLine? = nil) {
        if let helper { helperStatus = helper }
        helperInstalling = installing
        if let localLines { self.localLines = localLines }
        if let usageCapture { self.usageCapture = usageCapture }
        if let relayTest { self.relayTest = relayTest }
        if let problem { self.problem = problem }
        if terminalsUnprobed { self.terminals = nil }
        if let terminals { self.terminals = terminals }
        if let terminalNotice { self.terminalNotice = terminalNotice }
    }

    // MARK: opening

    /// Reloads every control from disk (so Cancel always reverts and hand
    /// edits show up), resets the baseline, and checks the power helper.
    func load(section: TowerSection? = nil) {
        let loaded = env.loadConfig()
        let cfg = loaded?.config ?? env.runningConfig()
        let f = PreferencesForm(cfg)
        form = f
        baseline = f
        problem = loaded?.problem
        usageCapture = Self.usageStatus(env.usageCaptureState())
        relayTest = .idle
        refreshLocalModels()
        checkHelper(refresh: true)
        terminalNotice = nil
        if let section { selection = section }
        if selection == .terminals { refreshTerminals() }
    }

    private static func usageStatus(_ s: UsageCapture.State) -> UsageCaptureStatus {
        switch s {
        case .on: return UsageCaptureStatus(on: true)
        case .off: return UsageCaptureStatus(on: false)
        case .unreadable(let why): return UsageCaptureStatus(on: false, text: why, failed: true)
        }
    }

    func refreshLocalModels() { localLines = env.localModelLines() }

    // MARK: terminals

    /// The rows the Terminals page draws.
    var terminalRows: [TerminalCatalog.Row] {
        terminals.map { TerminalCatalog.rows($0.facts, pageAddedKittyLines: $0.pageAddedKittyLines) } ?? []
    }

    /// Looks again (installed hosts, sessions per host, setup state) off the
    /// main thread. One probe at a time; a probe that finishes after a newer
    /// one was asked for is dropped.
    func refreshTerminals(force: Bool = false) {
        guard force || terminalProbesInFlight == 0 else { return }
        terminalProbesInFlight += 1
        terminalProbeGeneration += 1
        let generation = terminalProbeGeneration
        let sessions = snapshot?.sessions ?? []
        env.probeTerminals(sessions) { [weak self] result in
            guard let self else { return }
            self.terminalProbesInFlight -= 1
            guard generation == self.terminalProbeGeneration else { return }
            if let result, self.terminals != result { self.terminals = result }
        }
    }

    /// The light timer: only while the page is up and the window is on screen.
    func refreshTerminalsIfVisible() {
        guard selection == .terminals, env.windowVisible() else { return }
        refreshTerminals()
    }

    /// Set up… on a row.
    func setUp(_ id: TerminalCatalog.ID) {
        switch id {
        case .cmux: env.setUpCmux()
        case .kitty: setUpKitty()
        default: break
        }
    }

    /// Shows exactly what will change in kitty.conf, and only then writes it.
    func setUpKitty() {
        switch env.previewKitty() {
        case .failure(let f):
            env.showAlert("Couldn’t set up kitty", f.message)
        case .success(let p):
            switch p.plan {
            case .alreadyDone:
                terminalNotice = TowerStatusLine(text: "kitty already lets Page in. If a session still can’t be typed into, restart kitty.", tone: .good)
            case .conflict(let why):
                env.showAlert("kitty.conf already says something else", why)
            case .write(_, let added):
                let text = TerminalCatalog.kittyConfirmText(path: p.url.path, added: added, creating: p.creating, linkTarget: p.linkTarget?.path)
                guard env.confirm("Turn on kitty remote control?", text, "Add the lines") else { return }
                switch env.enableKitty() {
                case .success(let outcome): terminalNotice = TerminalCatalog.kittyDoneText(outcome)
                case .failure(let f): env.showAlert("Couldn’t set up kitty", f.message)
                }
            }
        }
        refreshTerminals(force: true)
    }

    func undoKitty() {
        terminalNotice = env.undoKitty()
            ? TowerStatusLine(text: "Took Page’s lines out of kitty.conf (a copy was saved first). Restart kitty.", tone: .good)
            : TowerStatusLine(text: "Page found none of its lines in kitty.conf, so it left the file alone.", tone: .bad)
        refreshTerminals(force: true)
    }

    /// Allow… on Terminal or iTerm2: macOS shows its own prompt.
    func allowAutomation(_ id: TerminalCatalog.ID) {
        let name = TerminalCatalog.entry(id).name
        terminalNotice = TowerStatusLine(text: "Asking macOS for permission to control \(name)…", tone: .quiet)
        env.requestAutomation(id) { [weak self] access in
            guard let self else { return }
            self.terminalNotice = TerminalCatalog.automationNotice(access, appName: name)
            if access == .denied { self.env.openURL(TerminalProbe.automationSettingsURL) }
            self.refreshTerminals(force: true)
        }
    }

    /// The row's one button.
    func perform(_ action: TerminalCatalog.Action, on id: TerminalCatalog.ID) {
        switch action {
        case .setUp: setUp(id)
        case .allow: allowAutomation(id)
        case .getIt(let url): env.openURL(url)
        case .undo: undoKitty()
        }
    }

    // MARK: power helper

    func checkHelper(refresh: Bool) {
        helperCheckGeneration += 1
        let generation = helperCheckGeneration
        helperStatus = .unknown
        env.checkHelper(refresh) { [weak self] status in
            guard let self, generation == self.helperCheckGeneration else { return }
            self.helperStatus = status
        }
    }

    /// The lid-closed-on-battery toggle: with the helper missing it goes
    /// straight to the admin prompt and the box ticks only if that succeeds.
    func setLidClosedOnBattery(_ on: Bool) {
        switch TowerRules.lidBattery(turningOn: on, helper: helperStatus) {
        case .set(let v):
            form.keepAwakeLidClosedOnBattery = v
        case .installHelperFirst:
            form.keepAwakeLidClosedOnBattery = true
            installHelper(untickOnFailure: true)
        }
    }

    func installHelper(untickOnFailure: Bool = false) {
        guard !helperInstalling else { return }
        helperInstalling = true
        helperCheckGeneration += 1   // drop any check still in flight
        env.installHelper { [weak self] outcome, status in
            guard let self else { return }
            self.helperInstalling = false
            self.helperStatus = status
            if untickOnFailure, !TowerRules.lidBatteryAfterInstall(outcome) { self.form.keepAwakeLidClosedOnBattery = false }
            if case .failed(let why) = outcome { self.env.showAlert("Couldn’t install the power helper", why) }
        }
    }

    // MARK: coupled sliders

    func setCutoff(_ value: Int) {
        form.lowBatteryCutoff = value
        form.recoveryThreshold = TowerRules.recovery(afterCutoff: value, recovery: form.recoveryThreshold)
    }

    func setRecovery(_ value: Int) {
        form.recoveryThreshold = value
        form.lowBatteryCutoff = TowerRules.cutoff(afterRecovery: value, cutoff: form.lowBatteryCutoff)
    }

    // MARK: relay

    func testRelay() {
        guard let base = try? Config.validatedRelayURL(form.relayURL).get() else { return }
        relayProbeGeneration += 1
        let generation = relayProbeGeneration
        relayTest = .testing(host: base.host ?? "")
        env.probeRelay(base) { [weak self] message, ok in
            guard let self, generation == self.relayProbeGeneration else { return }
            self.relayTest = .result(message: message, ok: ok)
        }
    }

    /// Editing the URL or toggling the relay makes an earlier test result stale.
    func relayEdited() {
        if relayTest != .idle { relayTest = .idle }
        relayProbeGeneration += 1
    }

    /// The relay status line: the test result when there is one, else the validation line.
    var relayLine: (line: TowerStatusLine, canTest: Bool) {
        let base = TowerLines.relay(enabled: form.relayEnabled, url: form.relayURL)
        switch relayTest {
        case .idle: return base
        case .testing(let host): return (TowerStatusLine(text: "Testing \(host)…", tone: .quiet), false)
        case .result(let message, let ok): return (TowerStatusLine(text: message, tone: ok ? .good : .bad), base.canTest)
        }
    }

    var codexLine: TowerStatusLine? {
        let configured = form.codexPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = form.codexBackendEnabled ? env.findCodex(configured.isEmpty ? nil : configured) : nil
        return TowerLines.codex(enabled: form.codexBackendEnabled, configured: form.codexPath, found: found)
    }

    var localModelsText: String { TowerLines.localModels(enabled: form.localModelsEnabled, lines: localLines) }

    // MARK: usage capture (applied at once)

    /// Edits Claude Code's settings, not Page's, so it is not part of Apply.
    func setUsageCapture(_ on: Bool) {
        do {
            let backup = try env.setUsageCapture(on)
            usageCapture = UsageCaptureStatus(on: on, text: TowerLines.usageCaptured(on: on, backupName: backup), failed: false)
        } catch {
            usageCapture = UsageCaptureStatus(on: !on, text: (error as? LocalizedError)?.errorDescription ?? "\(error)", failed: true)
        }
    }

    // MARK: apply, cancel, reset

    /// Validates, merges onto the freshest config on disk (only the fields
    /// this window changed), writes it and reloads. True when it saved.
    @discardableResult
    func apply() -> Bool {
        let f = form.normalisedForSave()
        if let error = f.validationError(isExecutable: env.isExecutable) {
            env.beep()
            env.showAlert("Can’t save these settings", error)
            return false
        }
        let loaded = env.loadConfig()
        let base: Config
        if let fresh = loaded?.config {
            base = fresh
        } else {
            // The file on disk is unreadable. Saving replaces it, so make
            // that an explicit choice (a copy of it has been kept).
            let info = TowerApply.replaceWarning(problem: loaded?.problem, backupName: loaded?.backupURL?.lastPathComponent)
            guard env.confirmReplaceBrokenConfig(info) else { return false }
            base = env.runningConfig()
        }
        let config = TowerApply.config(form: f, baseline: baseline, base: base)
        do {
            try env.writeConfig(config)
        } catch {
            env.showAlert("Couldn’t save settings", error.localizedDescription)
            return false
        }
        env.log("Preferences saved")
        env.reloadConfig()
        baseline = f
        form = f
        env.close()
        return true
    }

    func cancel() { env.close() }

    /// Everything back to defaults except the setup that is hard to re-type
    /// (relay on/off and URL, Codex path). Applies on Apply, like any edit.
    func resetToDefaults() { form = form.resetToDefaults() }
}

// MARK: - Apply, pure

enum TowerApply {
    /// Pure. The config to write: the form's changes onto the freshest config
    /// on disk, then forced into range.
    static func config(form: PreferencesForm, baseline: PreferencesForm?, base: Config) -> Config {
        let merged = form.merged(onto: base, changedFrom: baseline ?? PreferencesForm(base))
        return merged.validated().config
    }

    /// Pure. What the "config.json couldn’t be read" alert says.
    static func replaceWarning(problem: String?, backupName: String?) -> String {
        var info = (problem ?? "The file is malformed.")
            + "\n\nSaving replaces it with the settings shown here plus Page’s current settings."
        if let backupName { info += " The broken file was copied to \(backupName)." }
        return info
    }
}
