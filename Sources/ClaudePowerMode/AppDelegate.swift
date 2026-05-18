import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let coordinator = Coordinator()
    private var lastSnapshot: Coordinator.Snapshot?
    private var prefsController: PreferencesWindowController?
    private var pendingRateLimits: [String: RateLimitEvent] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Claude Power Mode")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeft
            button.title = ""
        }
        rebuildMenu()

        coordinator.onStateChange = { [weak self] snap in
            DispatchQueue.main.async { self?.render(snap) }
        }
        coordinator.onNewRateLimit = { [weak self] event in
            DispatchQueue.main.async { self?.handleRateLimitNotification(event) }
        }
        coordinator.onNewIntervention = { [weak self] event in
            DispatchQueue.main.async { self?.handleInterventionNotification(event) }
        }
        setupNotifications()
        coordinator.start()
    }

    private func handleInterventionNotification(_ event: InterventionEvent) {
        let content = UNMutableNotificationContent()
        content.title = "Page needs you — \(event.projectName)"
        content.subtitle = event.kind.rawValue.capitalized
        content.body = String(event.context.prefix(180))
        content.userInfo = ["interventionId": event.id]
        let req = UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                Logger.shared.log("Notification authorization error: \(error)")
            } else {
                Logger.shared.log("Notifications authorized: \(granted)")
            }
        }
        let resumeAction = UNNotificationAction(identifier: "RESUME", title: "Auto-resume", options: [])
        let skipAction = UNNotificationAction(identifier: "SKIP", title: "Skip", options: [])
        let category = UNNotificationCategory(
            identifier: "RATE_LIMIT",
            actions: [resumeAction, skipAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    private func handleRateLimitNotification(_ event: RateLimitEvent) {
        pendingRateLimits[event.uniqueId] = event
        let resetStr: String = {
            let df = DateFormatter()
            df.dateStyle = .none
            df.timeStyle = .short
            return df.string(from: event.resetTime)
        }()

        let content = UNMutableNotificationContent()
        content.title = "Claude rate limit reached"
        content.subtitle = event.projectName
        content.body = "Session was cut off. Resets at \(resetStr). Auto-resume scheduled? \(coordinator.config.autoResumeEnabled ? "Yes" : "No")"
        content.categoryIdentifier = "RATE_LIMIT"
        content.userInfo = ["eventId": event.uniqueId]
        let request = UNNotificationRequest(identifier: event.uniqueId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { Logger.shared.log("Failed to post notification: \(error)") }
        }
    }

    // MARK: UNUserNotificationCenterDelegate
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let eventId = response.notification.request.identifier
        guard let event = pendingRateLimits[eventId] else { completionHandler(); return }
        switch response.actionIdentifier {
        case "RESUME":
            do {
                _ = try coordinator.scheduleResumeManually(for: event)
            } catch {
                Logger.shared.log("Manual resume schedule failed: \(error)")
            }
        case "SKIP", UNNotificationDismissActionIdentifier:
            break
        default:
            break
        }
        pendingRateLimits.removeValue(forKey: eventId)
        completionHandler()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
    }

    private func render(_ snap: Coordinator.Snapshot) {
        lastSnapshot = snap
        guard let button = statusItem.button else { return }

        let symbolName: String
        if !snap.pendingInterventions.isEmpty {
            symbolName = "person.wave.2.fill"
        } else if snap.tripped {
            symbolName = "exclamationmark.triangle.fill"
        } else if snap.activeRateLimit != nil {
            symbolName = "hourglass"
        } else if snap.boosting {
            symbolName = "bolt.fill"
        } else if snap.onAC {
            symbolName = "powerplug.fill"
        } else if snap.battery <= 20 {
            symbolName = "battery.25"
        } else if snap.battery <= 60 {
            symbolName = "battery.50"
        } else {
            symbolName = "battery.100"
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: snap.statusLine)
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeft
        button.title = " \(snap.battery)%"
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        if let s = lastSnapshot {
            addInfo(menu, "Status: \(s.statusLine)")
            addInfo(menu, "Battery: \(s.battery)% \(s.onAC ? "(charging)" : "(on battery)")")
            let claudeLine: String = {
                if !s.claudeRunning { return "Claude: not running" }
                if !s.claudeActive { return "Claude: running but idle (stale transcript)" }
                if let secs = s.secondsSinceTranscript {
                    return "Claude: active (\(Int(secs))s since last output)"
                }
                return "Claude: active"
            }()
            addInfo(menu, claudeLine)
            if coordinator.config.codexBackendEnabled {
                addInfo(menu, codexLine(for: s))
            }
            addInfo(menu, "Lockout: \(s.tripped ? "ON" : "off")")
            menu.addItem(.separator())
            if let rl = s.activeRateLimit {
                let df = DateFormatter()
                df.dateStyle = .none
                df.timeStyle = .short
                addInfo(menu, "⚠ Rate-limited (\(rl.projectName))")
                addInfo(menu, "   Resets at \(df.string(from: rl.resetTime))")
                menu.addItem(.separator())
            }
            if !s.pendingInterventions.isEmpty {
                addInfo(menu, "👤 \(s.pendingInterventions.count) page(s) waiting:")
                for ev in s.pendingInterventions.prefix(3) {
                    addInfo(menu, "   • \(ev.projectName) — \(ev.kind.rawValue)")
                }
                menu.addItem(.separator())
            }
            addInfo(menu, "Relay: \(s.relayConnected ? "connected" : (coordinator.config.relayEnabled ? "disconnected" : "off"))")
            menu.addItem(.separator())
            if !s.scheduledResumes.isEmpty {
                let df = DateFormatter()
                df.dateStyle = .none
                df.timeStyle = .short
                addInfo(menu, "Scheduled resumes:")
                for sr in s.scheduledResumes.prefix(3) {
                    addInfo(menu, "   • \(sr.projectName) at \(df.string(from: sr.resetTime))")
                }
                menu.addItem(.separator())
            }
            let cfg = coordinator.config
            addInfo(menu, "Cutoff: <\(cfg.lowBatteryCutoff)% · Recovery: ≥\(cfg.recoveryThreshold)%\(cfg.recoveryRequiresAC ? " on AC" : "")")
            menu.addItem(.separator())
        }
        addAction(menu, "Pair phone…", #selector(showPairingQR), key: "p")
        addAction(menu, "Preferences…", #selector(openPreferences), key: ",")
        addAction(menu, "Open Config File…", #selector(openConfig), key: "")
        addAction(menu, "Open Log…", #selector(openLog), key: "l")
        addAction(menu, "Reload Config", #selector(reloadConfig), key: "r")
        menu.addItem(.separator())
        addAction(menu, "Quit", #selector(quit), key: "q")
        statusItem.menu = menu
    }

    private func codexLine(for s: Coordinator.Snapshot) -> String {
        let codex = s.sessions.filter { $0.backend == .codex }
        if codex.isEmpty { return "Codex: no live threads" }
        let active = codex.filter { $0.state == .active }.count
        let waiting = codex.filter { $0.state == .waitingOnUser || $0.state == .waitingOnApproval }.count
        var parts: [String] = ["\(codex.count) thread\(codex.count == 1 ? "" : "s")"]
        if active > 0 { parts.append("\(active) active") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return "Codex: \(parts.joined(separator: ", "))"
    }

    private func addInfo(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addAction(_ menu: NSMenu, _ title: String, _ selector: Selector, key: String) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func openPreferences() {
        if prefsController == nil {
            prefsController = PreferencesWindowController(coordinator: coordinator)
        }
        prefsController?.showAndFocus()
    }

    private var pairingWindow: NSWindow?

    private var pairingPayloadCached: String = ""

    @objc private func showPairingQR() {
        let payload = PairingTokenManager.pairingPayloadJSON(relayURL: coordinator.config.relayURL)
        pairingPayloadCached = payload
        guard let qr = QRCode.image(from: payload, size: CGSize(width: 320, height: 320)) else { return }

        if pairingWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            w.title = "Pair your iPhone"
            w.isReleasedWhenClosed = false
            pairingWindow = w
        }
        guard let window = pairingWindow else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let qrView = NSImageView(image: qr)
        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.translatesAutoresizingMaskIntoConstraints = false
        qrView.widthAnchor.constraint(equalToConstant: 320).isActive = true
        qrView.heightAnchor.constraint(equalToConstant: 320).isActive = true

        let title = NSTextField(labelWithString: "Scan this QR with Page on your iPhone")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.alignment = .center

        let simHint = NSTextField(labelWithString: "Simulator can't use a camera — use Copy JSON + paste into the app's manual-pair screen.")
        simHint.font = .systemFont(ofSize: 11)
        simHint.alignment = .center
        simHint.textColor = .secondaryLabelColor
        simHint.maximumNumberOfLines = 2
        simHint.lineBreakMode = .byWordWrapping
        simHint.preferredMaxLayoutWidth = 360

        let copyBtn = NSButton(title: "Copy pairing JSON", target: self, action: #selector(copyPairingJSON))
        copyBtn.bezelStyle = .rounded
        copyBtn.keyEquivalent = "c"
        copyBtn.keyEquivalentModifierMask = [.command]

        let regenBtn = NSButton(title: "Regenerate token", target: self, action: #selector(regenerateToken))
        regenBtn.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [copyBtn, regenBtn])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12

        stack.addArrangedSubview(qrView)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(simHint)
        stack.addArrangedSubview(buttonRow)

        window.contentView = NSView()
        window.contentView?.addSubview(stack)
        if let cv = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
                stack.topAnchor.constraint(equalTo: cv.topAnchor),
                stack.bottomAnchor.constraint(equalTo: cv.bottomAnchor)
            ])
        }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func copyPairingJSON() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(pairingPayloadCached, forType: .string)
    }

    @objc private func regenerateToken() {
        _ = PairingTokenManager.regenerate()
        showPairingQR()  // refresh window
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(Config.configURL)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Logger.logURL)
    }

    @objc private func reloadConfig() {
        coordinator.reloadConfig()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
