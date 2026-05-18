import AppKit

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let coordinator: Coordinator
    private var working: Config

    private let cutoffSlider = NSSlider()
    private let cutoffLabel = NSTextField(labelWithString: "")
    private let recoverySlider = NSSlider()
    private let recoveryLabel = NSTextField(labelWithString: "")
    private let intervalSlider = NSSlider()
    private let intervalLabel = NSTextField(labelWithString: "")
    private let activityWindowSlider = NSSlider()
    private let activityWindowLabel = NSTextField(labelWithString: "")
    private let recoveryACToggle = NSButton(checkboxWithTitle: "Require AC reconnect to recover from lockout", target: nil, action: nil)
    private let activityToggle = NSButton(checkboxWithTitle: "Only boost while Claude is producing output (transcript activity)", target: nil, action: nil)
    private let patternField = NSTextField(string: "")
    private let rateLimitWatcherToggle = NSButton(checkboxWithTitle: "Watch for Claude rate-limit events in transcripts", target: nil, action: nil)
    private let autoResumeToggle = NSButton(checkboxWithTitle: "Auto-schedule resume at reset time", target: nil, action: nil)
    private let holdAssertionToggle = NSButton(checkboxWithTitle: "Hold system awake through the reset wait (no deep sleep)", target: nil, action: nil)
    private let wakePmsetToggle = NSButton(checkboxWithTitle: "Schedule pmset wake (needs ./install.sh --enable-wake)", target: nil, action: nil)
    private let carryOnField = NSTextField(string: "carry on")

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        self.working = coordinator.config

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Claude Power Mode — Preferences"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        refreshLabels()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        stack.addArrangedSubview(sliderRow(
            title: "Stop boosting when battery drops below:",
            slider: cutoffSlider, label: cutoffLabel,
            min: 1, max: 50, value: Double(working.lowBatteryCutoff),
            action: #selector(cutoffChanged)
        ))
        stack.addArrangedSubview(sliderRow(
            title: "Resume boosting once battery recovers to:",
            slider: recoverySlider, label: recoveryLabel,
            min: 5, max: 95, value: Double(working.recoveryThreshold),
            action: #selector(recoveryChanged)
        ))

        recoveryACToggle.target = self
        recoveryACToggle.action = #selector(toggleRecoveryAC)
        recoveryACToggle.state = working.recoveryRequiresAC ? .on : .off
        stack.addArrangedSubview(recoveryACToggle)

        stack.addArrangedSubview(separator())

        activityToggle.target = self
        activityToggle.action = #selector(toggleActivity)
        activityToggle.state = working.requireRecentTranscriptActivity ? .on : .off
        stack.addArrangedSubview(activityToggle)

        stack.addArrangedSubview(sliderRow(
            title: "Consider Claude “idle” after no transcript writes for:",
            slider: activityWindowSlider, label: activityWindowLabel,
            min: 15, max: 600, value: working.transcriptActivityWindowSeconds,
            action: #selector(activityWindowChanged)
        ))

        stack.addArrangedSubview(separator())

        stack.addArrangedSubview(sliderRow(
            title: "Check interval (seconds):",
            slider: intervalSlider, label: intervalLabel,
            min: 5, max: 120, value: working.checkIntervalSeconds,
            action: #selector(intervalChanged)
        ))

        let patternStack = NSStackView()
        patternStack.orientation = .horizontal
        patternStack.spacing = 8
        let patternTitle = NSTextField(labelWithString: "Process pattern (pgrep -f):")
        patternField.stringValue = working.claudeProcessPattern
        patternField.target = self
        patternField.action = #selector(patternChanged)
        patternField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        patternStack.addArrangedSubview(patternTitle)
        patternStack.addArrangedSubview(patternField)
        stack.addArrangedSubview(patternStack)

        stack.addArrangedSubview(separator())

        let header = NSTextField(labelWithString: "Rate-limit handling")
        header.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        stack.addArrangedSubview(header)

        rateLimitWatcherToggle.target = self
        rateLimitWatcherToggle.action = #selector(noOp)
        rateLimitWatcherToggle.state = working.rateLimitWatcherEnabled ? .on : .off
        stack.addArrangedSubview(rateLimitWatcherToggle)

        autoResumeToggle.target = self
        autoResumeToggle.action = #selector(noOp)
        autoResumeToggle.state = working.autoResumeEnabled ? .on : .off
        stack.addArrangedSubview(autoResumeToggle)

        let carryOnRow = NSStackView()
        carryOnRow.orientation = .horizontal
        carryOnRow.spacing = 8
        let carryOnLbl = NSTextField(labelWithString: "Resume prompt:")
        carryOnField.stringValue = working.carryOnPrompt
        carryOnField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        carryOnRow.addArrangedSubview(carryOnLbl)
        carryOnRow.addArrangedSubview(carryOnField)
        stack.addArrangedSubview(carryOnRow)

        holdAssertionToggle.target = self
        holdAssertionToggle.action = #selector(noOp)
        holdAssertionToggle.state = working.holdAssertionUntilReset ? .on : .off
        stack.addArrangedSubview(holdAssertionToggle)

        wakePmsetToggle.target = self
        wakePmsetToggle.action = #selector(noOp)
        wakePmsetToggle.state = working.wakeViaPmsetEnabled ? .on : .off
        stack.addArrangedSubview(wakePmsetToggle)

        stack.addArrangedSubview(separator())

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        let resetBtn = NSButton(title: "Reset to defaults", target: self, action: #selector(resetDefaults))
        resetBtn.bezelStyle = .rounded
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelBtn.bezelStyle = .rounded
        let applyBtn = NSButton(title: "Apply", target: self, action: #selector(apply))
        applyBtn.bezelStyle = .rounded
        applyBtn.keyEquivalent = "\r"
        buttonRow.addArrangedSubview(resetBtn)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(cancelBtn)
        buttonRow.addArrangedSubview(applyBtn)
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(buttonRow)
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
    }

    private func sliderRow(title: String, slider: NSSlider, label: NSTextField,
                           min: Double, max: Double, value: Double, action: Selector) -> NSView {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false

        let titleLbl = NSTextField(labelWithString: title)
        titleLbl.font = .systemFont(ofSize: NSFont.systemFontSize)

        slider.minValue = min
        slider.maxValue = max
        slider.doubleValue = value
        slider.isContinuous = true
        slider.target = self
        slider.action = action
        slider.translatesAutoresizingMaskIntoConstraints = false

        let inner = NSStackView()
        inner.orientation = .horizontal
        inner.spacing = 12
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.addArrangedSubview(slider)
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 60).isActive = true
        inner.addArrangedSubview(label)
        slider.widthAnchor.constraint(equalToConstant: 340).isActive = true

        row.addArrangedSubview(titleLbl)
        row.addArrangedSubview(inner)
        return row
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        line.widthAnchor.constraint(equalToConstant: 440).isActive = true
        return line
    }

    private func refreshLabels() {
        cutoffLabel.stringValue = "\(Int(cutoffSlider.doubleValue))%"
        recoveryLabel.stringValue = "\(Int(recoverySlider.doubleValue))%"
        intervalLabel.stringValue = "\(Int(intervalSlider.doubleValue)) s"
        let secs = Int(activityWindowSlider.doubleValue)
        activityWindowLabel.stringValue = secs >= 60 ? "\(secs / 60)m \(secs % 60)s" : "\(secs) s"
    }

    @objc private func cutoffChanged() {
        if cutoffSlider.doubleValue >= recoverySlider.doubleValue {
            recoverySlider.doubleValue = min(recoverySlider.maxValue, cutoffSlider.doubleValue + 5)
        }
        refreshLabels()
    }
    @objc private func recoveryChanged() {
        if recoverySlider.doubleValue <= cutoffSlider.doubleValue {
            cutoffSlider.doubleValue = max(cutoffSlider.minValue, recoverySlider.doubleValue - 5)
        }
        refreshLabels()
    }
    @objc private func intervalChanged() { refreshLabels() }
    @objc private func activityWindowChanged() { refreshLabels() }
    @objc private func toggleRecoveryAC() { /* read on apply */ }
    @objc private func toggleActivity() { /* read on apply */ }
    @objc private func patternChanged() { /* read on apply */ }
    @objc private func noOp() { /* read on apply */ }

    @objc private func resetDefaults() {
        let defaults = Config()
        cutoffSlider.doubleValue = Double(defaults.lowBatteryCutoff)
        recoverySlider.doubleValue = Double(defaults.recoveryThreshold)
        intervalSlider.doubleValue = defaults.checkIntervalSeconds
        activityWindowSlider.doubleValue = defaults.transcriptActivityWindowSeconds
        recoveryACToggle.state = defaults.recoveryRequiresAC ? .on : .off
        activityToggle.state = defaults.requireRecentTranscriptActivity ? .on : .off
        patternField.stringValue = defaults.claudeProcessPattern
        rateLimitWatcherToggle.state = defaults.rateLimitWatcherEnabled ? .on : .off
        autoResumeToggle.state = defaults.autoResumeEnabled ? .on : .off
        holdAssertionToggle.state = defaults.holdAssertionUntilReset ? .on : .off
        wakePmsetToggle.state = defaults.wakeViaPmsetEnabled ? .on : .off
        carryOnField.stringValue = defaults.carryOnPrompt
        refreshLabels()
    }

    @objc private func cancel() {
        window?.close()
    }

    @objc private func apply() {
        var cfg = coordinator.config
        cfg.lowBatteryCutoff = Int(cutoffSlider.doubleValue)
        cfg.recoveryThreshold = Int(recoverySlider.doubleValue)
        cfg.recoveryRequiresAC = (recoveryACToggle.state == .on)
        cfg.requireRecentTranscriptActivity = (activityToggle.state == .on)
        cfg.transcriptActivityWindowSeconds = activityWindowSlider.doubleValue
        cfg.checkIntervalSeconds = intervalSlider.doubleValue
        cfg.rateLimitWatcherEnabled = (rateLimitWatcherToggle.state == .on)
        cfg.autoResumeEnabled = (autoResumeToggle.state == .on)
        cfg.holdAssertionUntilReset = (holdAssertionToggle.state == .on)
        cfg.wakeViaPmsetEnabled = (wakePmsetToggle.state == .on)
        let trimmedPrompt = carryOnField.stringValue.trimmingCharacters(in: .whitespaces)
        if !trimmedPrompt.isEmpty { cfg.carryOnPrompt = trimmedPrompt }
        let trimmedPattern = patternField.stringValue.trimmingCharacters(in: .whitespaces)
        if !trimmedPattern.isEmpty { cfg.claudeProcessPattern = trimmedPattern }
        cfg.save()
        coordinator.reloadConfig()
        window?.close()
    }

    func showAndFocus() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
