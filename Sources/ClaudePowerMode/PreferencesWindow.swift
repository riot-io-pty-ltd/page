import AppKit

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

final class PreferencesWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let coordinator: Coordinator
    /// What the controls showed when the window opened (read back from the
    /// controls, so slider clamping never counts as an edit).
    private var baseline: PreferencesForm?

    private let problemBanner = NSTextField(wrappingLabelWithString: "")

    // Phone & paging
    private let relayToggle = NSButton(checkboxWithTitle: "Send pages to my phone (via your relay)", target: nil, action: nil)
    private let relayURLField = NSTextField(string: "")
    private let relayTestButton = NSButton(title: "Test", target: nil, action: nil)
    private let relayStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let detectionToggle = NSButton(checkboxWithTitle: "Detect sessions that need me (approvals, questions, finished turns)", target: nil, action: nil)
    private let awaySlider = NSSlider()
    private let awayLabel = NSTextField(labelWithString: "")
    private let idleDelaySlider = NSSlider()
    private let idleDelayLabel = NSTextField(labelWithString: "")
    private let holdAwakeSlider = NSSlider()
    private let holdAwakeLabel = NSTextField(labelWithString: "")
    private let headlessToggle = NSButton(checkboxWithTitle: "If the session has exited, deliver text replies with a background “claude --resume”", target: nil, action: nil)
    private let remoteSessionsToggle = NSButton(checkboxWithTitle: "Show my live sessions on my phone, and let it type into them or stop them", target: nil, action: nil)

    // Power
    private let lidACToggle = NSButton(checkboxWithTitle: "Keep the Mac awake with the lid closed while on AC power", target: nil, action: nil)
    private let lidBatteryToggle = NSButton(checkboxWithTitle: "Also with the lid closed on battery (advanced)", target: nil, action: nil)
    private let helperStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let helperInstallButton = NSButton(title: "Install…", target: nil, action: nil)
    private var helperInstalling = false
    private let helperRecheckButton = NSButton(title: "Check again", target: nil, action: nil)
    private var helperStatus: SleepGuard.HelperStatus = .unknown
    private var helperCheckGeneration = 0

    // Battery
    private let actionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let graceSlider = NSSlider()
    private let graceLabel = NSTextField(labelWithString: "")
    private let resumeAfterRecoveryToggle = NSButton(checkboxWithTitle: "When power is back, tell the paused sessions to carry on", target: nil, action: nil)
    private let cutoffSlider = NSSlider()
    private let cutoffLabel = NSTextField(labelWithString: "")
    private let recoverySlider = NSSlider()
    private let recoveryLabel = NSTextField(labelWithString: "")
    private let recoveryACToggle = NSButton(checkboxWithTitle: "Only count it as recovered while plugged in", target: nil, action: nil)
    private let activityToggle = NSButton(checkboxWithTitle: "Only keep awake while Claude is producing output (transcript activity)", target: nil, action: nil)
    private let activityWindowSlider = NSSlider()
    private let activityWindowLabel = NSTextField(labelWithString: "")
    private let intervalSlider = NSSlider()
    private let intervalLabel = NSTextField(labelWithString: "")

    // Agents
    private let codexToggle = NSButton(checkboxWithTitle: "Watch Codex sessions", target: nil, action: nil)
    private let localModelsToggle = NSButton(checkboxWithTitle: "Keep the Mac awake while local models are working (Ollama, LM Studio, llama.cpp, MLX)", target: nil, action: nil)
    private let localModelsStatus = NSTextField(wrappingLabelWithString: "")
    private let codexPathField = NSTextField(string: "")
    private let codexPathStatus = NSTextField(wrappingLabelWithString: "")

    // Rate limits
    private let rateLimitWatcherToggle = NSButton(checkboxWithTitle: "Watch for Claude rate-limit events in transcripts", target: nil, action: nil)
    private let autoResumeToggle = NSButton(checkboxWithTitle: "Auto-schedule a resume at the reset time", target: nil, action: nil)
    private let carryOnField = NSTextField(string: "")
    private let holdAssertionToggle = NSButton(checkboxWithTitle: "Keep the Mac awake through the reset wait", target: nil, action: nil)
    private let wakePmsetToggle = NSButton(checkboxWithTitle: "Schedule a pmset wake before the resume (uses the power helper — Power tab)", target: nil, action: nil)

    // Alerts
    private let stuckToggle = NSButton(checkboxWithTitle: "Page me when an agent looks stuck (a failing command on repeat, no progress, a stalled workflow)", target: nil, action: nil)
    private let stuckSlider = NSSlider()
    private let stuckLabel = NSTextField(labelWithString: "")
    private let turnSummaryToggle = NSButton(checkboxWithTitle: "Start finished-turn pages with what changed (“Changed 3 files (+120 −14) · tests passed”)", target: nil, action: nil)
    private let batteryForecastToggle = NSButton(checkboxWithTitle: "Page me when the battery cutoff is about 15 minutes away while agents work", target: nil, action: nil)
    private let usageForecastToggle = NSButton(checkboxWithTitle: "Page me when I'm about 30 minutes from Claude's 5-hour limit (needs usage below)", target: nil, action: nil)
    private let startSessionsToggle = NSButton(checkboxWithTitle: "Let my phone start new Claude sessions (in cmux, in folders Claude already used)", target: nil, action: nil)
    private let earlyPauseToggle = NSButton(checkboxWithTitle: "Pause early: about 10 minutes before the cutoff, by the drain forecast", target: nil, action: nil)
    private let usageCaptureToggle = NSButton(checkboxWithTitle: "Show my Claude usage (5-hour and 7-day) and forecast the limit", target: nil, action: nil)
    private let usageCaptureStatus = NSTextField(wrappingLabelWithString: "")

    private var relayProbeGeneration = 0

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Page Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: layout

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        problemBanner.textColor = .systemOrange
        problemBanner.font = .systemFont(ofSize: 12)
        problemBanner.preferredMaxLayoutWidth = 580
        problemBanner.isHidden = true
        root.addArrangedSubview(problemBanner)

        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(tab("Phone", phoneTab()))
        tabs.addTabViewItem(tab("Power", powerTab()))
        tabs.addTabViewItem(tab("Battery", batteryTab()))
        tabs.addTabViewItem(tab("Alerts", alertsTab()))
        tabs.addTabViewItem(tab("Agents", agentsTab()))
        tabs.addTabViewItem(tab("Rate limits", rateLimitTab()))
        root.addArrangedSubview(tabs)
        tabs.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        let resetBtn = NSButton(title: "Reset to defaults", target: self, action: #selector(resetDefaults))
        resetBtn.bezelStyle = .rounded
        resetBtn.toolTip = "Resets everything except the relay URL and Codex path."
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        let applyBtn = NSButton(title: "Apply", target: self, action: #selector(apply))
        applyBtn.bezelStyle = .rounded
        applyBtn.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        [resetBtn, spacer, cancelBtn, applyBtn].forEach { buttonRow.addArrangedSubview($0) }
        root.addArrangedSubview(buttonRow)
        buttonRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
    }

    private func tab(_ label: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor)
        ])
        item.view = container
        return item
    }

    private func section() -> NSStackView {
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 10
        s.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        return s
    }

    private func hint(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 540
        return l
    }

    private func phoneTab() -> NSView {
        let s = section()
        relayToggle.target = self
        relayToggle.action = #selector(controlChanged)
        s.addArrangedSubview(relayToggle)

        let urlRow = NSStackView()
        urlRow.orientation = .horizontal
        urlRow.spacing = 8
        let urlTitle = NSTextField(labelWithString: "Relay URL:")
        relayURLField.placeholderString = "https://page-relay.<your-account>.workers.dev"
        relayURLField.delegate = self
        relayURLField.widthAnchor.constraint(equalToConstant: 380).isActive = true
        relayTestButton.target = self
        relayTestButton.action = #selector(testRelay)
        relayTestButton.bezelStyle = .rounded
        [urlTitle, relayURLField, relayTestButton].forEach { urlRow.addArrangedSubview($0) }
        s.addArrangedSubview(urlRow)

        relayStatusLabel.font = .systemFont(ofSize: 11)
        relayStatusLabel.preferredMaxLayoutWidth = 540
        s.addArrangedSubview(relayStatusLabel)
        s.addArrangedSubview(hint("Deploy the relay Worker once (Cloudflare/README.md), paste its URL here, then use “Pair phone…” in the menu."))

        s.addArrangedSubview(separator())
        detectionToggle.target = self
        detectionToggle.action = #selector(controlChanged)
        s.addArrangedSubview(detectionToggle)
        s.addArrangedSubview(sliderRow(
            title: "Page about a finished turn only after I’ve been away from the Mac for:",
            slider: awaySlider, label: awayLabel, min: 0, max: 900))
        s.addArrangedSubview(sliderRow(
            title: "…and the session has been idle for:",
            slider: idleDelaySlider, label: idleDelayLabel, min: 0, max: 900))
        s.addArrangedSubview(hint("Approvals and questions always page right away — they block the agent."))
        s.addArrangedSubview(sliderRow(
            title: "Keep the Mac awake for a waiting page (so the reply can be delivered) for up to:",
            slider: holdAwakeSlider, label: holdAwakeLabel, min: 0, max: 240))
        headlessToggle.target = self
        headlessToggle.action = #selector(controlChanged)
        s.addArrangedSubview(headlessToggle)

        s.addArrangedSubview(separator())
        remoteSessionsToggle.target = self
        remoteSessionsToggle.action = #selector(controlChanged)
        s.addArrangedSubview(remoteSessionsToggle)
        s.addArrangedSubview(hint("End-to-end encrypted with the key in the pairing QR — the relay can’t read it. Phones paired before this need to scan the QR again."))
        startSessionsToggle.target = self
        startSessionsToggle.action = #selector(controlChanged)
        s.addArrangedSubview(startSessionsToggle)
        s.addArrangedSubview(hint("Opens a cmux workspace and runs claude with your prompt. Only folders where Claude sessions already ran in the last 30 days; only from your paired phone."))
        return s
    }

    private func alertsTab() -> NSView {
        let s = section()
        stuckToggle.target = self
        stuckToggle.action = #selector(controlChanged)
        s.addArrangedSubview(stuckToggle)
        s.addArrangedSubview(sliderRow(
            title: "Count it as no progress after:",
            slider: stuckSlider, label: stuckLabel,
            min: Config.Limits.stuckAfterMinutes.lowerBound, max: 120))
        s.addArrangedSubview(hint("A loop is the same call failing 3 times in a row, or 5 times in the last 12 steps. Reply to the page to steer it, or Deny to stop it (Esc)."))
        s.addArrangedSubview(separator())
        turnSummaryToggle.target = self
        turnSummaryToggle.action = #selector(controlChanged)
        s.addArrangedSubview(turnSummaryToggle)
        s.addArrangedSubview(hint("Only counts go in the page. The file list and diff are sent to your phone end-to-end encrypted when you open them."))
        s.addArrangedSubview(separator())
        batteryForecastToggle.target = self
        batteryForecastToggle.action = #selector(controlChanged)
        s.addArrangedSubview(batteryForecastToggle)
        usageForecastToggle.target = self
        usageForecastToggle.action = #selector(controlChanged)
        s.addArrangedSubview(usageForecastToggle)
        return s
    }

    private func powerTab() -> NSView {
        let s = section()
        s.addArrangedSubview(hint("While Claude Code or Codex is working, Page keeps the Mac from idle-sleeping, and lets it sleep again as soon as they stop."))
        lidACToggle.target = self
        lidACToggle.action = #selector(controlChanged)
        s.addArrangedSubview(lidACToggle)
        lidBatteryToggle.target = self
        lidBatteryToggle.action = #selector(lidBatteryChanged)
        s.addArrangedSubview(lidBatteryToggle)
        s.addArrangedSubview(hint("On battery macOS always sleeps when the lid closes, so this uses “pmset disablesleep” — only while an agent is actually mid-turn (not while waiting on a rate-limit reset, a page or a prompt) and the Mac isn’t running hot. It turns on only above your low-battery level + 5%, and stays on down to that level so agents can pause and write their summary with the lid closed; then the Mac sleeps. Risk: a closed MacBook in a bag stays awake and warm. Page turns it off the moment any of that changes, when it quits, and a watchdog turns it off within a minute if Page crashes (a few minutes if it hangs)."))
        helperStatusLabel.font = .systemFont(ofSize: 11)
        helperStatusLabel.preferredMaxLayoutWidth = 360
        helperInstallButton.target = self
        helperInstallButton.action = #selector(installHelper)
        helperInstallButton.bezelStyle = .rounded
        helperRecheckButton.target = self
        helperRecheckButton.action = #selector(recheckHelper)
        helperRecheckButton.bezelStyle = .rounded
        let helperRow = NSStackView(views: [helperStatusLabel, helperInstallButton, helperRecheckButton])
        helperRow.orientation = .horizontal
        helperRow.spacing = 8
        s.addArrangedSubview(helperRow)
        s.addArrangedSubview(separator())
        activityToggle.target = self
        activityToggle.action = #selector(controlChanged)
        s.addArrangedSubview(activityToggle)
        s.addArrangedSubview(sliderRow(
            title: "Consider Claude idle after no transcript writes for:",
            slider: activityWindowSlider, label: activityWindowLabel, min: 15, max: 600))
        s.addArrangedSubview(sliderRow(
            title: "Check every:",
            slider: intervalSlider, label: intervalLabel, min: Config.Limits.checkInterval.lowerBound, max: 120))
        return s
    }

    private func batteryTab() -> NSView {
        let s = section()
        s.addArrangedSubview(sliderRow(
            title: "When the battery reaches this level (on battery power only):",
            slider: cutoffSlider, label: cutoffLabel, min: 0, max: 50, action: #selector(cutoffChanged)))
        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.spacing = 8
        actionPopup.removeAllItems()
        for action in LowBatteryAction.allCases {
            actionPopup.addItem(withTitle: action.menuTitle)
            actionPopup.lastItem?.representedObject = action.rawValue
        }
        actionPopup.target = self
        actionPopup.action = #selector(controlChanged)
        [NSTextField(labelWithString: "…then:"), actionPopup].forEach { actionRow.addArrangedSubview($0) }
        s.addArrangedSubview(actionRow)
        s.addArrangedSubview(sliderRow(
            title: "Keep the Mac awake for their summary, then let it sleep, after:",
            slider: graceSlider, label: graceLabel,
            min: Config.Limits.lowBatteryPauseGrace.lowerBound, max: 300))
        s.addArrangedSubview(hint("Paused sessions get a phone page each (reply to send them instructions) and are listed in Page’s menu. Never triggers while plugged in, or on a Mac without a battery."))
        s.addArrangedSubview(separator())
        s.addArrangedSubview(sliderRow(
            title: "Power counts as back once the battery recovers to:",
            slider: recoverySlider, label: recoveryLabel, min: 5, max: 100, action: #selector(recoveryChanged)))
        recoveryACToggle.target = self
        recoveryACToggle.action = #selector(controlChanged)
        s.addArrangedSubview(recoveryACToggle)
        resumeAfterRecoveryToggle.target = self
        resumeAfterRecoveryToggle.action = #selector(controlChanged)
        s.addArrangedSubview(resumeAfterRecoveryToggle)
        s.addArrangedSubview(separator())
        earlyPauseToggle.target = self
        earlyPauseToggle.action = #selector(controlChanged)
        s.addArrangedSubview(earlyPauseToggle)
        s.addArrangedSubview(hint("Gives agents time to write their summary before the battery is critical. Uses the same pause as above."))
        return s
    }

    private func agentsTab() -> NSView {
        let s = section()
        s.addArrangedSubview(hint("Claude Code sessions are always watched."))
        codexToggle.target = self
        codexToggle.action = #selector(controlChanged)
        s.addArrangedSubview(codexToggle)
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let title = NSTextField(labelWithString: "codex path:")
        codexPathField.placeholderString = "Blank = auto-detect"
        codexPathField.delegate = self
        codexPathField.widthAnchor.constraint(equalToConstant: 380).isActive = true
        [title, codexPathField].forEach { row.addArrangedSubview($0) }
        s.addArrangedSubview(row)
        codexPathStatus.font = .systemFont(ofSize: 11)
        codexPathStatus.preferredMaxLayoutWidth = 540
        s.addArrangedSubview(codexPathStatus)

        let localHeader = NSTextField(labelWithString: "Local models")
        localHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        s.addArrangedSubview(localHeader)
        localModelsToggle.target = self
        localModelsToggle.action = #selector(controlChanged)
        s.addArrangedSubview(localModelsToggle)
        s.addArrangedSubview(hint("Only while a model is actually generating — a loaded but idle model never keeps the Mac awake. Terminal tools (opencode, aider, goose, crush, ollama run, llama-cli…) count while they're producing output. Page only looks: it never starts, stops or unloads models. Claude Code and Codex pointed at Ollama or LM Studio are detected automatically, and Page won't restart them in the background on your Anthropic account."))
        localModelsStatus.font = .systemFont(ofSize: 11)
        localModelsStatus.textColor = .secondaryLabelColor
        localModelsStatus.preferredMaxLayoutWidth = 540
        s.addArrangedSubview(localModelsStatus)
        return s
    }

    private func rateLimitTab() -> NSView {
        let s = section()
        rateLimitWatcherToggle.target = self
        rateLimitWatcherToggle.action = #selector(controlChanged)
        s.addArrangedSubview(rateLimitWatcherToggle)
        autoResumeToggle.target = self
        autoResumeToggle.action = #selector(controlChanged)
        s.addArrangedSubview(autoResumeToggle)
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let lbl = NSTextField(labelWithString: "Resume prompt:")
        carryOnField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        [lbl, carryOnField].forEach { row.addArrangedSubview($0) }
        s.addArrangedSubview(row)
        holdAssertionToggle.target = self
        holdAssertionToggle.action = #selector(controlChanged)
        s.addArrangedSubview(holdAssertionToggle)
        wakePmsetToggle.target = self
        wakePmsetToggle.action = #selector(controlChanged)
        s.addArrangedSubview(wakePmsetToggle)
        s.addArrangedSubview(hint("Auto-resume works for Claude sessions only. On your phone you can also reply to a rate-limit page with a message to send when it resets."))
        s.addArrangedSubview(separator())
        usageCaptureToggle.target = self
        usageCaptureToggle.action = #selector(usageCaptureChanged)
        s.addArrangedSubview(usageCaptureToggle)
        s.addArrangedSubview(hint("Claude Code only gives these numbers to your status line, so Page wraps it: a small script saves them, then runs your own status line unchanged. Changes ~/.claude/settings.json (backed up first); turning this off puts it back."))
        usageCaptureStatus.font = .systemFont(ofSize: 11)
        usageCaptureStatus.preferredMaxLayoutWidth = 540
        s.addArrangedSubview(usageCaptureStatus)
        return s
    }

    /// Applied straight away (not on Save): it edits Claude Code's settings,
    /// not Page's.
    @objc private func usageCaptureChanged() {
        let on = usageCaptureToggle.state == .on
        do {
            let backup = try UsageCapture().set(on)
            usageCaptureStatus.textColor = .secondaryLabelColor
            usageCaptureStatus.stringValue = on
                ? "On — numbers appear after Claude Code next draws its status line." + (backup.map { " Backup: \($0.lastPathComponent)" } ?? "")
                : "Off — your status line is back as it was."
        } catch {
            usageCaptureToggle.state = on ? .off : .on
            usageCaptureStatus.textColor = .systemRed
            usageCaptureStatus.stringValue = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func refreshUsageCaptureStatus() {
        switch UsageCapture().state() {
        case .on: usageCaptureToggle.state = .on
        case .off: usageCaptureToggle.state = .off
        case .unreadable(let why):
            usageCaptureToggle.state = .off
            usageCaptureStatus.textColor = .systemRed
            usageCaptureStatus.stringValue = why
        }
    }

    private func sliderRow(title: String, slider: NSSlider, label: NSTextField,
                           min: Double, max: Double, action: Selector = #selector(controlChanged)) -> NSView {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4

        let titleLbl = NSTextField(labelWithString: title)
        titleLbl.font = .systemFont(ofSize: NSFont.systemFontSize)

        slider.minValue = min
        slider.maxValue = max
        slider.isContinuous = true
        slider.target = self
        slider.action = action
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 420).isActive = true

        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let inner = NSStackView(views: [slider, label])
        inner.orientation = .horizontal
        inner.spacing = 12
        row.addArrangedSubview(titleLbl)
        row.addArrangedSubview(inner)
        return row
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 540).isActive = true
        return line
    }

    // MARK: form <-> controls

    private func populate(from c: Config) {
        let f = PreferencesForm(c)
        relayToggle.state = f.relayEnabled ? .on : .off
        relayURLField.stringValue = f.relayURL
        detectionToggle.state = f.interventionDetectionEnabled ? .on : .off
        awaySlider.doubleValue = f.idlePageOnlyWhenAwaySeconds
        idleDelaySlider.doubleValue = f.idlePageDelaySeconds
        holdAwakeSlider.doubleValue = f.holdAwakeForPendingPageMinutes
        headlessToggle.state = f.headlessResumeFallbackEnabled ? .on : .off
        remoteSessionsToggle.state = f.remoteSessionsEnabled ? .on : .off
        cutoffSlider.doubleValue = Double(f.lowBatteryCutoff)
        recoverySlider.doubleValue = Double(f.recoveryThreshold)
        recoveryACToggle.state = f.recoveryRequiresAC ? .on : .off
        activityToggle.state = f.requireRecentTranscriptActivity ? .on : .off
        activityWindowSlider.doubleValue = f.transcriptActivityWindowSeconds
        intervalSlider.doubleValue = f.checkIntervalSeconds
        lidACToggle.state = f.keepAwakeLidClosedOnAC ? .on : .off
        lidBatteryToggle.state = f.keepAwakeLidClosedOnBattery ? .on : .off
        actionPopup.selectItem(at: LowBatteryAction.allCases.firstIndex(of: f.lowBatteryAction) ?? 0)
        graceSlider.doubleValue = f.lowBatteryPauseGraceSeconds
        resumeAfterRecoveryToggle.state = f.resumeAfterBatteryRecovery ? .on : .off
        codexToggle.state = f.codexBackendEnabled ? .on : .off
        localModelsToggle.state = f.localModelsEnabled ? .on : .off
        codexPathField.stringValue = f.codexPath
        rateLimitWatcherToggle.state = f.rateLimitWatcherEnabled ? .on : .off
        autoResumeToggle.state = f.autoResumeEnabled ? .on : .off
        carryOnField.stringValue = f.carryOnPrompt
        holdAssertionToggle.state = f.holdAssertionUntilReset ? .on : .off
        wakePmsetToggle.state = f.wakeViaPmsetEnabled ? .on : .off
        stuckToggle.state = f.stuckAlertsEnabled ? .on : .off
        stuckSlider.doubleValue = f.stuckAfterMinutes
        turnSummaryToggle.state = f.turnSummaryEnabled ? .on : .off
        startSessionsToggle.state = f.phoneStartSessionsEnabled ? .on : .off
        batteryForecastToggle.state = f.batteryForecastPageEnabled ? .on : .off
        earlyPauseToggle.state = f.earlyBatteryPause ? .on : .off
        usageForecastToggle.state = f.usageForecastPageEnabled ? .on : .off
        refreshUsageCaptureStatus()
        refreshLabels()
    }

    private func readForm() -> PreferencesForm {
        var f = PreferencesForm(Config())
        f.relayEnabled = relayToggle.state == .on
        f.relayURL = relayURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        f.interventionDetectionEnabled = detectionToggle.state == .on
        f.idlePageOnlyWhenAwaySeconds = awaySlider.doubleValue.rounded()
        f.idlePageDelaySeconds = idleDelaySlider.doubleValue.rounded()
        f.holdAwakeForPendingPageMinutes = holdAwakeSlider.doubleValue.rounded()
        f.headlessResumeFallbackEnabled = headlessToggle.state == .on
        f.remoteSessionsEnabled = remoteSessionsToggle.state == .on
        f.lowBatteryCutoff = Int(cutoffSlider.doubleValue.rounded())
        f.recoveryThreshold = Int(recoverySlider.doubleValue.rounded())
        f.recoveryRequiresAC = recoveryACToggle.state == .on
        f.requireRecentTranscriptActivity = activityToggle.state == .on
        f.transcriptActivityWindowSeconds = activityWindowSlider.doubleValue.rounded()
        f.checkIntervalSeconds = intervalSlider.doubleValue.rounded()
        f.keepAwakeLidClosedOnAC = lidACToggle.state == .on
        f.keepAwakeLidClosedOnBattery = lidBatteryToggle.state == .on
        let actionIndex = actionPopup.indexOfSelectedItem
        f.lowBatteryAction = LowBatteryAction.allCases.indices.contains(actionIndex) ? LowBatteryAction.allCases[actionIndex] : .pause
        f.lowBatteryPauseGraceSeconds = graceSlider.doubleValue.rounded()
        f.resumeAfterBatteryRecovery = resumeAfterRecoveryToggle.state == .on
        f.codexBackendEnabled = codexToggle.state == .on
        f.localModelsEnabled = localModelsToggle.state == .on
        f.codexPath = codexPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        f.rateLimitWatcherEnabled = rateLimitWatcherToggle.state == .on
        f.autoResumeEnabled = autoResumeToggle.state == .on
        let prompt = carryOnField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        f.carryOnPrompt = prompt.isEmpty ? Config().carryOnPrompt : prompt
        f.holdAssertionUntilReset = holdAssertionToggle.state == .on
        f.wakeViaPmsetEnabled = wakePmsetToggle.state == .on
        f.stuckAlertsEnabled = stuckToggle.state == .on
        f.stuckAfterMinutes = stuckSlider.doubleValue.rounded()
        f.turnSummaryEnabled = turnSummaryToggle.state == .on
        f.phoneStartSessionsEnabled = startSessionsToggle.state == .on
        f.batteryForecastPageEnabled = batteryForecastToggle.state == .on
        f.earlyBatteryPause = earlyPauseToggle.state == .on
        f.usageForecastPageEnabled = usageForecastToggle.state == .on
        return f
    }

    private static func duration(_ seconds: Double, zero: String = "Off") -> String {
        let s = Int(seconds.rounded())
        if s == 0 { return zero }
        if s < 60 { return "\(s) s" }
        return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60)m \(s % 60)s"
    }

    private func refreshLabels() {
        cutoffLabel.stringValue = "\(Int(cutoffSlider.doubleValue.rounded()))%"
        recoveryLabel.stringValue = "\(Int(recoverySlider.doubleValue.rounded()))%"
        intervalLabel.stringValue = Self.duration(intervalSlider.doubleValue)
        graceLabel.stringValue = Self.duration(graceSlider.doubleValue)
        let pausing = actionPopup.indexOfSelectedItem != LowBatteryAction.allCases.firstIndex(of: .off)
        graceSlider.isEnabled = pausing
        resumeAfterRecoveryToggle.isEnabled = pausing
        refreshHelperLabel()
        refreshLocalModelsStatus()
        activityWindowLabel.stringValue = Self.duration(activityWindowSlider.doubleValue)
        awayLabel.stringValue = Self.duration(awaySlider.doubleValue, zero: "Always")
        idleDelayLabel.stringValue = Self.duration(idleDelaySlider.doubleValue, zero: "Now")
        let minutes = Int(holdAwakeSlider.doubleValue.rounded())
        holdAwakeLabel.stringValue = minutes == 0 ? "Don’t" : (minutes < 60 ? "\(minutes) min" : "\(minutes / 60)h \(minutes % 60)m")
        stuckLabel.stringValue = "\(Int(stuckSlider.doubleValue.rounded())) min"
        stuckSlider.isEnabled = stuckToggle.state == .on
        earlyPauseToggle.isEnabled = pausing

        let relayOn = relayToggle.state == .on
        let url = relayURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty {
            relayStatusLabel.stringValue = relayOn ? "Enter your relay’s URL." : ""
            relayStatusLabel.textColor = relayOn ? .systemRed : .secondaryLabelColor
            relayTestButton.isEnabled = false
        } else {
            switch Config.validatedRelayURL(url) {
            case .success(let base):
                relayStatusLabel.stringValue = "Will connect to \(base.absoluteString)"
                relayStatusLabel.textColor = .secondaryLabelColor
                relayTestButton.isEnabled = true
            case .failure(let problem):
                relayStatusLabel.stringValue = problem.message
                relayStatusLabel.textColor = .systemRed
                relayTestButton.isEnabled = false
            }
        }

        let codexOn = codexToggle.state == .on
        codexPathField.isEnabled = codexOn
        let configured = codexPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !codexOn {
            codexPathStatus.stringValue = ""
        } else if let found = ProcessRunner.findExecutable("codex", configured: configured.isEmpty ? nil : configured) {
            let usingConfigured = !configured.isEmpty && found == (configured as NSString).expandingTildeInPath
            codexPathStatus.stringValue = usingConfigured || configured.isEmpty
                ? "Using \(found)"
                : "Nothing executable at that path — auto-detect would use \(found)"
            codexPathStatus.textColor = usingConfigured || configured.isEmpty ? .secondaryLabelColor : .systemRed
        } else {
            codexPathStatus.stringValue = "codex wasn’t found in the usual places — enter its full path."
            codexPathStatus.textColor = .systemRed
        }
    }

    /// Shows whether the sudo rule for lid-closed-on-battery is installed,
    /// with an Install button (admin prompt) if not.
    private func refreshHelperLabel() {
        let wanted = lidBatteryToggle.state == .on
        helperInstallButton.isEnabled = !helperInstalling
        if helperInstalling {
            helperStatusLabel.stringValue = "Waiting for your password…"
            helperStatusLabel.textColor = .secondaryLabelColor
            helperInstallButton.isHidden = true
            return
        }
        switch helperStatus {
        case .available:
            helperStatusLabel.stringValue = "✓ Power helper installed."
            helperStatusLabel.textColor = .systemGreen
            helperInstallButton.isHidden = true
        case .missing:
            helperStatusLabel.stringValue = "Power helper not installed\(wanted ? " — this option does nothing until it is" : "")."
                + " Click Install and enter your Mac password once."
            helperStatusLabel.textColor = wanted ? .systemRed : .secondaryLabelColor
            helperInstallButton.isHidden = false
        case .unknown:
            helperStatusLabel.stringValue = "Checking the power helper…"
            helperStatusLabel.textColor = .secondaryLabelColor
            helperInstallButton.isHidden = true
        }
    }

    /// What the local-model monitor sees right now (as of opening the
    /// window or touching a control).
    private func refreshLocalModelsStatus() {
        guard localModelsToggle.state == .on else {
            localModelsStatus.stringValue = "Off."
            return
        }
        let lines = LocalActivity.menuLines(coordinator.localActivities)
        localModelsStatus.stringValue = lines.isEmpty ? "No local model servers or tools running right now." : lines.joined(separator: "\n")
    }

    private func checkHelper(refresh: Bool) {
        helperCheckGeneration += 1
        let generation = helperCheckGeneration
        helperStatus = .unknown
        refreshHelperLabel()
        coordinator.checkPowerHelper(refresh: refresh) { [weak self] status in
            guard let self, generation == self.helperCheckGeneration else { return }
            self.helperStatus = status
            self.refreshHelperLabel()
        }
    }

    // MARK: actions

    @objc private func controlChanged() { refreshLabels() }

    @objc private func recheckHelper() { checkHelper(refresh: true) }

    /// Ticking lid-closed-on-battery without the helper goes straight to
    /// the admin prompt; cancelling it unticks the box again.
    @objc private func lidBatteryChanged() {
        refreshLabels()
        guard lidBatteryToggle.state == .on, helperStatus == .missing else { return }
        runHelperInstall(untickOnCancel: true)
    }

    @objc private func installHelper() { runHelperInstall(untickOnCancel: false) }

    private func runHelperInstall(untickOnCancel: Bool) {
        guard !helperInstalling else { return }
        helperInstalling = true
        helperCheckGeneration += 1   // drop any check still in flight
        refreshHelperLabel()
        coordinator.installPowerHelper { [weak self] outcome, status in
            guard let self else { return }
            self.helperInstalling = false
            self.helperStatus = status
            switch outcome {
            case .installed:
                break
            case .cancelled:
                if untickOnCancel { self.lidBatteryToggle.state = .off }
            case .failed(let why):
                if untickOnCancel { self.lidBatteryToggle.state = .off }
                self.showAlert("Couldn’t install the power helper", why)
            }
            self.refreshLabels()
            self.refreshHelperLabel()
        }
    }

    @objc private func cutoffChanged() {
        if recoverySlider.doubleValue < cutoffSlider.doubleValue {
            recoverySlider.doubleValue = min(recoverySlider.maxValue, cutoffSlider.doubleValue + 5)
        }
        refreshLabels()
    }

    @objc private func recoveryChanged() {
        if recoverySlider.doubleValue < cutoffSlider.doubleValue {
            cutoffSlider.doubleValue = max(cutoffSlider.minValue, recoverySlider.doubleValue - 5)
        }
        refreshLabels()
    }

    func controlTextDidChange(_ obj: Notification) { refreshLabels() }

    @objc private func testRelay() {
        let raw = relayURLField.stringValue
        guard let base = try? Config.validatedRelayURL(raw).get() else { return }
        relayProbeGeneration += 1
        let generation = relayProbeGeneration
        relayStatusLabel.stringValue = "Testing \(base.host ?? "")…"
        relayStatusLabel.textColor = .secondaryLabelColor
        var request = URLRequest(url: base.appendingPathComponent("health"), timeoutInterval: 8)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
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
            DispatchQueue.main.async {
                guard let self, generation == self.relayProbeGeneration else { return }
                self.relayStatusLabel.stringValue = message
                self.relayStatusLabel.textColor = ok ? .systemGreen : .systemRed
            }
        }.resume()
    }

    @objc private func resetDefaults() {
        let current = readForm()
        var d = Config()
        // Keep the setup the user can't easily re-type.
        d.relayEnabled = current.relayEnabled
        d.relayURL = current.relayURL.isEmpty ? Config.placeholderRelayURL : current.relayURL
        d.codexPath = current.codexPath
        populate(from: d)
    }

    @objc private func cancel() {
        // Nothing to undo: controls are reloaded from disk on every show.
        window?.close()
    }

    @objc private func apply() {
        let form = readForm()
        if let error = form.validationError() {
            NSSound.beep()
            showAlert("Can’t save these settings", error)
            return
        }

        let loaded = Config.loadResult()
        let base: Config
        if let fresh = loaded.config {
            base = fresh
        } else {
            // The file on disk is unreadable. Saving replaces it, so make
            // that an explicit choice (a copy of it has been kept).
            let alert = NSAlert()
            alert.messageText = "config.json couldn’t be read"
            var info = (loaded.problem ?? "The file is malformed.")
                + "\n\nSaving replaces it with the settings shown here plus Page’s current settings."
            if let backup = loaded.backupURL { info += " The broken file was copied to \(backup.lastPathComponent)." }
            alert.informativeText = info
            alert.addButton(withTitle: "Replace config.json")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            base = coordinator.config
        }

        let merged = form.merged(onto: base, changedFrom: baseline ?? PreferencesForm(base))
        let (valid, _) = merged.validated()
        do {
            try valid.write()
        } catch {
            showAlert("Couldn’t save settings", error.localizedDescription)
            return
        }
        Logger.shared.log("Preferences saved")
        coordinator.reloadConfig()
        window?.close()
    }

    private func showAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// Reloads every control from disk, so Cancel always reverts and edits
    /// made to config.json by hand show up.
    func showAndFocus() {
        let loaded = Config.loadResult()
        populate(from: loaded.config ?? coordinator.config)
        baseline = readForm()
        checkHelper(refresh: true)
        if let problem = loaded.problem {
            problemBanner.stringValue = "⚠ " + problem
            problemBanner.isHidden = false
        } else {
            problemBanner.isHidden = true
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
