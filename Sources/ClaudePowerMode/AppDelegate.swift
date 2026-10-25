import AppKit
import UserNotifications

/// Round-trips a RateLimitEvent through a notification's userInfo, so the
/// "Auto-resume" action still works after Page restarts (the old in-memory
/// lookup table was empty after a relaunch and the tap silently did nothing).
enum RateLimitUserInfo {
    static func encode(_ e: RateLimitEvent) -> [String: Any] {
        [
            "kind": "rateLimit",
            "sessionId": e.sessionId,
            "cwd": e.cwd,
            "projectName": e.projectName,
            "eventTime": e.eventTime.timeIntervalSince1970,
            "resetTime": e.resetTime.timeIntervalSince1970,
            "resetTimeText": e.resetTimeText,
            "transcriptPath": e.transcriptPath,
            "backend": e.backend.rawValue
        ]
    }

    static func decode(_ info: [AnyHashable: Any]) -> RateLimitEvent? {
        guard info["kind"] as? String == "rateLimit",
              let sessionId = info["sessionId"] as? String,
              let cwd = info["cwd"] as? String,
              let eventTime = (info["eventTime"] as? NSNumber)?.doubleValue,
              let resetTime = (info["resetTime"] as? NSNumber)?.doubleValue else { return nil }
        return RateLimitEvent(
            sessionId: sessionId,
            cwd: cwd,
            projectName: info["projectName"] as? String ?? URL(fileURLWithPath: cwd).lastPathComponent,
            eventTime: Date(timeIntervalSince1970: eventTime),
            resetTime: Date(timeIntervalSince1970: resetTime),
            resetTimeText: info["resetTimeText"] as? String ?? "",
            transcriptPath: info["transcriptPath"] as? String ?? "",
            backend: (info["backend"] as? String).flatMap(AgentBackendID.init(rawValue:)) ?? .claude
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private enum NotificationCategory {
        static let rateLimit = "RATE_LIMIT"          // Claude: Auto-resume / Skip
        static let rateLimitInfo = "RATE_LIMIT_INFO" // informational, no actions
        static let intervention = "INTERVENTION"
    }

    private var statusItem: NSStatusItem!
    /// One persistent menu, filled in `menuNeedsUpdate`. Replacing
    /// `statusItem.menu` on every tick (the old approach) closed or froze a
    /// menu the user had open.
    private let menu = NSMenu()
    private let coordinator = Coordinator()
    private var lastSnapshot: Coordinator.Snapshot?
    private var prefsController: PreferencesWindowController?
    /// True while the power-helper admin prompt is up (menu item disabled).
    private var installingPowerHelper = false
    private let launchedAt = Date()
    /// Ids already bannered this run (bounded). Backends can re-report a
    /// page (e.g. after a config reload); one banner per page is enough.
    private var notifiedInterventionIds: [String] = []
    private var notifiedInterventionSet: Set<String> = []
    /// SIGTERM/SIGINT sources; kept alive for the life of the app.
    private var signalSources: [DispatchSourceSignal] = []

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .short
        return df
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Page")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeft
            button.title = ""
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        coordinator.onStateChange = { [weak self] snap in
            DispatchQueue.main.async { self?.render(snap) }
        }
        coordinator.onNewRateLimit = { [weak self] notice in
            DispatchQueue.main.async { self?.postRateLimitNotification(notice) }
        }
        coordinator.onNewIntervention = { [weak self] event in
            DispatchQueue.main.async { self?.postInterventionNotification(event) }
        }
        coordinator.onResumeResult = { [weak self] result in
            DispatchQueue.main.async { self?.postResumeResultNotification(result) }
        }
        coordinator.onBatteryNotice = { [weak self] notice in
            DispatchQueue.main.async { self?.postSimpleNotification(title: notice.title, body: notice.body) }
        }
        installSignalHandlers()
        setupNotifications()
        coordinator.start()
        // After sleep the relay socket is dead but looks open until the next
        // ping times out (up to ~35 s). Reconnect straight away instead, so
        // pages and replies flow again as soon as the lid opens.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Logger.shared.log("System woke — reconnecting the relay")
            self?.coordinator.nudgeRelay()
        }
        DispatchQueue.global(qos: .background).async { Logger.pruneAuxiliaryLogs() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
    }

    /// `launchctl bootout`, logout and Ctrl-C send SIGTERM/SIGINT, whose
    /// default action kills the app without `applicationWillTerminate` — and
    /// would leave `pmset disablesleep 1` behind. Handle them: clear the
    /// sleep overrides first (directly, without waiting on the tick queue)
    /// and seal them so no tick can set them again, then terminate normally,
    /// with a hard exit as a backstop in case main is stuck (e.g. inside a
    /// modal alert) — which retries the clear once more before exiting.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in
                Logger.shared.log("Received signal \(sig) — clearing sleep overrides and quitting")
                guard let coordinator = self?.coordinator else { exit(0) }
                coordinator.releaseSleepOverrides(reason: "signal \(sig)")
                DispatchQueue.main.async { NSApp.terminate(nil) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    // Sealed, so this only retries a clear that failed above.
                    coordinator.releaseSleepOverrides(reason: "exit backstop")
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: notifications

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
        // setNotificationCategories replaces the whole set, so register all
        // of them in one call.
        center.setNotificationCategories([
            UNNotificationCategory(identifier: NotificationCategory.rateLimit,
                                   actions: [resumeAction, skipAction],
                                   intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: NotificationCategory.rateLimitInfo,
                                   actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationCategory.intervention,
                                   actions: [], intentIdentifiers: [], options: [])
        ])
    }

    private func postInterventionNotification(_ event: InterventionEvent) {
        // Rate limits have their own banner (with the Auto-resume action).
        if event.kind.rawValue == "rate_limit" { return }
        guard !notifiedInterventionSet.contains(event.id) else { return }
        notifiedInterventionSet.insert(event.id)
        notifiedInterventionIds.append(event.id)
        if notifiedInterventionIds.count > 500 {
            let dropped = notifiedInterventionIds.removeFirst()
            notifiedInterventionSet.remove(dropped)
        }
        // Detectors re-discover still-waiting sessions after a relaunch. A
        // page that was already waiting well before this launch was bannered
        // by the previous run; don't re-sound it.
        if event.openedAt < launchedAt.addingTimeInterval(-600) {
            Logger.shared.log("Skipping Mac banner for pre-launch page \(event.id)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "\(Self.agentName(event.backend)) needs you — \(event.projectName)"
        content.subtitle = Self.kindLabel(event)
        content.body = String(event.context.prefix(180))
        content.sound = .default
        content.categoryIdentifier = NotificationCategory.intervention
        content.threadIdentifier = event.sessionId
        content.userInfo = ["kind": "intervention", "interventionId": event.id]
        let req = UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error { Logger.shared.log("Failed to post page banner: \(error)") }
        }
    }

    private func postRateLimitNotification(_ notice: Coordinator.RateLimitNotice) {
        let event = notice.event
        let resetStr = Self.timeFormatter.string(from: event.resetTime)
        let content = UNMutableNotificationContent()
        content.title = "\(Self.agentName(event.backend)) rate limit reached"
        content.subtitle = event.projectName
        if let scheduled = notice.scheduledResume {
            content.body = "Resets at \(resetStr). Page will resume the session at \(Self.timeFormatter.string(from: scheduled.resetTime))."
            content.categoryIdentifier = NotificationCategory.rateLimitInfo
        } else if notice.canResume {
            content.body = "Resets at \(resetStr). Choose Auto-resume to continue the session then."
            content.categoryIdentifier = NotificationCategory.rateLimit
        } else {
            let suffix = event.backend == .codex ? " Codex sessions can’t be auto-resumed yet." : ""
            content.body = "Resets at \(resetStr).\(suffix)"
            content.categoryIdentifier = NotificationCategory.rateLimitInfo
        }
        content.userInfo = RateLimitUserInfo.encode(event)
        let request = UNNotificationRequest(identifier: "ratelimit-\(event.uniqueId)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Logger.shared.log("Failed to post notification: \(error)") }
        }
    }

    private func postResumeResultNotification(_ result: ResumeResult) {
        let session = String(result.sessionId.prefix(8))
        let title: String
        switch result.outcome {
        case .resumed:     title = "Claude session resumed"
        case .failed:      title = "Scheduled resume failed"
        case .timedOut:    title = "Scheduled resume timed out"
        case .expired:     title = "Scheduled resume skipped (too late)"
        case .cancelled:   title = "Scheduled resume cancelled"
        case .skippedLive: return
        }
        let detail = result.detail.map { $0.isEmpty ? "" : " — \($0)" } ?? ""
        postSimpleNotification(title: title, body: "Session \(session)\(detail). Log: \((result.logPath as NSString).lastPathComponent)")
    }

    private func postSimpleNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    static func agentName(_ backend: AgentBackendID) -> String {
        switch backend {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    static func kindLabel(_ event: InterventionEvent) -> String {
        if event.subtype == "plan" { return "Plan approval" }
        switch event.kind.rawValue {
        case "permission": return "Approval needed"
        case "plan": return "Plan approval"
        case "question": return "Question"
        case "idle": return "Finished — waiting for you"
        case "rate_limit": return "Rate limited"
        default: return event.kind.rawValue.capitalized
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
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        DispatchQueue.main.async { [weak self] in
            self?.handleNotificationResponse(info: info, action: action)
            completionHandler()
        }
    }

    private func handleNotificationResponse(info: [AnyHashable: Any], action: String) {
        switch info["kind"] as? String {
        case "rateLimit":
            guard action == "RESUME" else { return }
            guard let event = RateLimitUserInfo.decode(info) else {
                Logger.shared.log("Auto-resume tapped on a notification without event data — ignoring")
                return
            }
            coordinator.scheduleResumeManually(for: event) { [weak self] result in
                switch result {
                case .success(let scheduled):
                    Logger.shared.log("Manual resume scheduled for \(scheduled.projectName) at \(scheduled.resetTime)")
                    self?.postSimpleNotification(
                        title: "Resume scheduled",
                        body: "\(scheduled.projectName) will continue at \(Self.timeFormatter.string(from: scheduled.resetTime)).")
                case .failure(let error):
                    Logger.shared.log("Manual resume schedule failed: \(error)")
                    self?.postSimpleNotification(title: "Couldn’t schedule the resume",
                                                 body: error.localizedDescription)
                }
            }
        case "intervention":
            // Clicking a page banner just shows the menu with the waiting
            // pages. It deliberately doesn't type anything or focus a
            // terminal: replying is an explicit action.
            if action == UNNotificationDefaultActionIdentifier {
                statusItem.button?.performClick(nil)
            }
        default:
            break
        }
    }

    // MARK: status item

    private func render(_ snap: Coordinator.Snapshot) {
        lastSnapshot = snap
        guard let button = statusItem.button else { return }

        let p = snap.power
        let symbolName: String
        if !snap.pendingInterventions.isEmpty {
            symbolName = "person.wave.2.fill"
        } else if snap.tripped {
            symbolName = "exclamationmark.triangle.fill"
        } else if snap.activeRateLimit != nil {
            symbolName = "hourglass"
        } else if snap.boosting {
            symbolName = "bolt.fill"
        } else if !p.hasBattery || p.onAC {
            symbolName = "powerplug.fill"
        } else if p.percent <= 20 {
            symbolName = "battery.25"
        } else if p.percent <= 60 {
            symbolName = "battery.50"
        } else {
            symbolName = "battery.100"
        }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Page — \(snap.statusLine)")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeft
        if !snap.pendingInterventions.isEmpty {
            button.title = " \(snap.pendingInterventions.count)"
        } else if p.hasBattery {
            button.title = " \(p.percent)%"
        } else {
            button.title = ""
        }
        button.toolTip = "Page — \(snap.statusLine)"
        updatePairingStatus()
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let s = lastSnapshot {
            if let problem = s.configProblem {
                let item = addAction(menu, "⚠ Config problem — using safe values. Open config…", #selector(openConfig), key: "")
                item.toolTip = problem
                menu.addItem(.separator())
            }
            addInfo(menu, "Status: \(s.statusLine)")
            addInfo(menu, powerLine(s.power))
            if let e = s.batteryForecast { addInfo(menu, "   " + BatteryForecast.menuLine(e)) }
            for line in s.usageLines { addInfo(menu, line) }
            let cfg = coordinator.config
            for line in Self.awakeLines(s, cutoff: cfg.lowBatteryCutoff) {
                addInfo(menu, line)
            }
            if !s.battery.paused.isEmpty {
                addInfo(menu, "Paused for low battery:")
                for ps in s.battery.paused.sorted(by: { $0.pausedAt > $1.pausedAt }).prefix(6) {
                    let item = NSMenuItem(title: "   • \(ps.projectName) (\(Self.agentName(ps.backend))) — since \(Self.timeFormatter.string(from: ps.pausedAt))",
                                          action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    item.toolTip = ps.detail
                    menu.addItem(item)
                }
                if s.battery.paused.count > 6 { addInfo(menu, "   … and \(s.battery.paused.count - 6) more") }
                addAction(menu, "Resume paused sessions now", #selector(resumePausedSessions), key: "")
            }
            menu.addItem(.separator())

            for b in s.backends where b.enabled {
                addInfo(menu, backendLine(b))
            }
            for line in LocalActivity.menuLines(s.localModels) {
                addInfo(menu, "Local: \(line)")
            }
            if let rl = s.activeRateLimit {
                addInfo(menu, "⏳ \(Self.agentName(rl.backend)) rate-limited (\(rl.projectName)) — resets at \(Self.timeFormatter.string(from: rl.resetTime))")
            }
            if !s.pendingInterventions.isEmpty {
                let n = s.pendingInterventions.count
                addInfo(menu, "\(n) page\(n == 1 ? "" : "s") waiting:")
                for ev in s.pendingInterventions.sorted(by: { $0.openedAt > $1.openedAt }).prefix(5) {
                    addInfo(menu, "   • \(ev.projectName) — \(Self.kindLabel(ev))")
                }
                if n > 5 { addInfo(menu, "   … and \(n - 5) more") }
            }
            menu.addItem(.separator())

            switch s.relayState {
            case .connected:
                addInfo(menu, "Phone relay: connected")
            case .connecting:
                addInfo(menu, "Phone relay: connecting…")
            case .off:
                addAction(menu, "Phone relay: off — set up…", #selector(openPreferences), key: "")
            case .misconfigured(let why):
                let item = addAction(menu, "Phone relay: not set up — fix in Preferences…", #selector(openPreferences), key: "")
                item.toolTip = why
            }

            if !s.scheduledResumes.isEmpty {
                menu.addItem(.separator())
                addInfo(menu, "Scheduled resumes:")
                for sr in s.scheduledResumes.sorted(by: { $0.resetTime < $1.resetTime }) {
                    let item = NSMenuItem(title: "   \(sr.projectName) at \(Self.timeFormatter.string(from: sr.resetTime))",
                                          action: nil, keyEquivalent: "")
                    let sub = NSMenu()
                    sub.autoenablesItems = false
                    let cancel = NSMenuItem(title: "Cancel this resume", action: #selector(cancelScheduledResume(_:)), keyEquivalent: "")
                    cancel.target = self
                    cancel.representedObject = ScheduledResumeBox(sr)
                    sub.addItem(cancel)
                    let log = NSMenuItem(title: "Open resume log", action: #selector(openResumeLog(_:)), keyEquivalent: "")
                    log.target = self
                    log.representedObject = sr.logPath
                    log.isEnabled = FileManager.default.fileExists(atPath: sr.logPath)
                    sub.addItem(log)
                    item.submenu = sub
                    menu.addItem(item)
                }
            }

            if s.power.hasBattery {
                menu.addItem(.separator())
                addInfo(menu, Self.batteryRuleLine(cfg))
                let lid = addAction(menu, "Keep awake with the lid closed on battery", #selector(toggleLidClosedOnBattery), key: "")
                lid.state = cfg.keepAwakeLidClosedOnBattery ? .on : .off
                lid.isEnabled = !installingPowerHelper
            }
            menu.addItem(.separator())
        } else {
            addInfo(menu, "Starting…")
            menu.addItem(.separator())
        }
        addAction(menu, "Pair phone…", #selector(showPairingQR), key: "p")
        let integrations = NSMenuItem(title: "Integrations", action: nil, keyEquivalent: "")
        let integrationsMenu = NSMenu()
        integrationsMenu.autoenablesItems = false
        addAction(integrationsMenu, "Set up cmux…", #selector(openCmuxSetup), key: "")
        addAction(integrationsMenu, "Install agent hooks…", #selector(openHookInstaller), key: "")
        integrationsMenu.addItem(.separator())
        addAction(integrationsMenu, "Copy local-model diagnostics", #selector(copyLocalModelDiagnostics), key: "")
        integrations.submenu = integrationsMenu
        menu.addItem(integrations)
        addAction(menu, "Preferences…", #selector(openPreferences), key: ",")
        addAction(menu, "Open Config File…", #selector(openConfig), key: "")
        addAction(menu, "Open Log", #selector(openLog), key: "l")
        addAction(menu, "Reload Config", #selector(reloadConfig), key: "r")
        menu.addItem(.separator())
        addAction(menu, "Quit Page", #selector(quit), key: "q")
    }

    /// What Page is doing about sleep right now, in the user's terms.
    static func awakeLines(_ s: Coordinator.Snapshot, cutoff: Int) -> [String] {
        // Shown whatever else is going on: the flag outlives Page's checks.
        let warning = s.lidClosedCleanupFailed
            ? ["⚠ Couldn’t turn off pmset disablesleep — the Mac may not sleep with the lid closed. Run: sudo pmset -a disablesleep 0"]
            : []
        return warning + baseAwakeLines(s, cutoff: cutoff)
    }

    private static func baseAwakeLines(_ s: Coordinator.Snapshot, cutoff: Int) -> [String] {
        let p = s.power
        switch s.battery.phase {
        case .grace:
            var line = "Low battery — keeping awake briefly so agents can write a summary"
            if let end = s.battery.graceEndsAt, end > Date() {
                line += " (until \(timeFormatter.string(from: end)))"
            }
            return [line]
        case .drained where !p.onAC:
            return ["Low battery — not keeping the Mac awake (plug in to continue)"]
        default:
            break
        }
        guard s.boosting else { return [] }
        guard p.hasBattery else { return ["Keeping Mac awake"] }
        if p.onAC {
            return [s.awake.preventSystemSleep
                    ? "Keeping Mac awake — lid can be closed (on AC)"
                    : "Keeping Mac awake — keep the lid open"]
        }
        if s.lidClosedOnBattery {
            return ["Keeping Mac awake — lid can be closed (on battery, while agents work, down to \(cutoff)%)"]
        }
        var lines = ["Keeping Mac awake — keep the lid open on battery"]
        if let why = s.lidClosedOnBatteryBlocker {
            lines.append("   Lid-closed on battery is off: \(why)")
        }
        return lines
    }

    static func batteryRuleLine(_ cfg: Config) -> String {
        let action: String
        switch cfg.lowBatteryAction {
        case .pause: action = "ask agents to pause"
        case .afterTurn: action = "ask agents to stop after this step"
        case .off: action = "stop keeping awake"
        }
        let resume = cfg.resumeAfterBatteryRecovery ? "resume" : "recover"
        return "At \(cfg.lowBatteryCutoff)% on battery: \(action) · \(resume) at \(cfg.recoveryThreshold)%\(cfg.recoveryRequiresAC ? " on AC" : "")"
    }

    private func powerLine(_ p: PowerSnapshot) -> String {
        guard p.hasBattery else { return "Power: AC (no battery)" }
        let state: String
        if p.isCharging { state = "charging" }
        else if p.onAC { state = "on AC" }
        else { state = "on battery" }
        return "Battery: \(p.percent)% (\(state))"
    }

    private func backendLine(_ b: Coordinator.BackendInfo) -> String {
        if let problem = b.problem { return "\(b.displayName): \(problem)" }
        guard b.sessionCount > 0 else { return "\(b.displayName): no sessions" }
        var parts = ["\(b.sessionCount) session\(b.sessionCount == 1 ? "" : "s")"]
        if b.activeCount > 0 { parts.append("\(b.activeCount) active") }
        if b.waitingCount > 0 { parts.append("\(b.waitingCount) waiting") }
        return "\(b.displayName): \(parts.joined(separator: " · "))"
    }

    private func addInfo(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @discardableResult
    private func addAction(_ menu: NSMenu, _ title: String, _ selector: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
        return item
    }

    /// NSMenuItem.representedObject wants an object; ScheduledResume is a struct.
    private final class ScheduledResumeBox {
        let value: ScheduledResume
        init(_ value: ScheduledResume) { self.value = value }
    }

    @objc private func cancelScheduledResume(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ScheduledResumeBox else { return }
        coordinator.cancelResume(box.value)
    }

    @objc private func resumePausedSessions() {
        coordinator.resumePausedSessionsNow()
    }

    @objc private func openCmuxSetup() {
        CmuxSetupWindowController.shared.show()
    }

    @objc private func openHookInstaller() {
        HookInstallerWindowController.shared.show()
    }

    /// What Page sees of Ollama / LM Studio / llama.cpp / MLX and terminal
    /// tools, for a bug report. Contains no argv, environment or prompts.
    @objc private func copyLocalModelDiagnostics() {
        let text = coordinator.localModelDiagnostics()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        postSimpleNotification(title: "Local-model diagnostics copied", body: "Paste them into your bug report or message.")
    }

    /// Menu toggle for lid-closed-on-battery. Turning it on explains the
    /// trade-off once, installs the power helper behind the macOS admin
    /// prompt if it's missing, then saves the setting.
    @objc private func toggleLidClosedOnBattery() {
        guard !installingPowerHelper else { return }
        if coordinator.config.keepAwakeLidClosedOnBattery {
            if !coordinator.setLidClosedOnBattery(false) { lidSettingFailed() }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Keep agents running with the lid closed on battery?"
        alert.informativeText = "While an agent is mid-turn, Page will stop the Mac sleeping when you close the lid on battery. "
            + "At your low-battery level it asks the agents to pause, then lets the Mac sleep. "
            + "A closed MacBook in a bag will stay awake and warm while agents work."
            + (coordinator.sleepGuardHelperMissing ? "\n\nmacOS will ask for your password once to allow this." : "")
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        installingPowerHelper = true
        coordinator.checkPowerHelper(refresh: true) { [weak self] status in
            guard let self else { return }
            guard status != .available else {
                self.installingPowerHelper = false
                if !self.coordinator.setLidClosedOnBattery(true) { self.lidSettingFailed() }
                return
            }
            self.coordinator.installPowerHelper { [weak self] outcome, status in
                guard let self else { return }
                self.installingPowerHelper = false
                switch outcome {
                case .installed where status == .available:
                    if !self.coordinator.setLidClosedOnBattery(true) { self.lidSettingFailed() }
                case .cancelled:
                    break
                case .installed:
                    self.showSimpleAlert("Couldn’t turn this on", "The power helper was installed but sudo still doesn’t allow it. Check the log.")
                case .failed(let why):
                    self.showSimpleAlert("Couldn’t install the power helper", why)
                }
            }
        }
    }

    private func lidSettingFailed() {
        showSimpleAlert("Couldn’t save the setting", "config.json couldn’t be read or written. Open Preferences to fix it.")
    }

    private func showSimpleAlert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func openResumeLog(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: windows

    @objc private func openPreferences() {
        if prefsController == nil {
            prefsController = PreferencesWindowController(coordinator: coordinator)
        }
        prefsController?.showAndFocus()
    }

    private var pairingWindow: NSWindow?
    private var pairingPayloadCached: String = ""
    private weak var pairingHealthLabel: NSTextField?
    private weak var pairingMacLabel: NSTextField?
    private var healthProbeGeneration = 0

    @objc private func showPairingQR() {
        if pairingWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            w.title = "Pair your iPhone"
            w.isReleasedWhenClosed = false
            pairingWindow = w
        }
        guard let window = pairingWindow else { return }

        let cfg = coordinator.config
        let stack: NSStackView
        if cfg.relayIsUsable, let base = cfg.relayBaseURL {
            stack = pairingContent(base: base)
        } else {
            // A QR pointing at a disabled relay or the placeholder URL pairs
            // "successfully" and then nothing ever arrives on the phone.
            pairingPayloadCached = ""
            stack = setupNeededContent(cfg)
        }

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor)
        ])
        window.contentView = content
        window.setContentSize(NSSize(width: 440, height: max(260, stack.fittingSize.height)))
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func wrappingLabel(_ text: String, size: CGFloat = 12, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.alignment = .center
        label.textColor = color
        label.preferredMaxLayoutWidth = 380
        return label
    }

    private func setupNeededContent(_ cfg: Config) -> NSStackView {
        let stack = makeStack()
        let icon = NSImageView(image: NSImage(systemSymbolName: "antenna.radiowaves.left.and.right.slash",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 40, weight: .regular)
        let title = NSTextField(labelWithString: "Set up your relay first")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let reason: String
        if !cfg.relayEnabled {
            reason = "Phone paging is turned off. In Preferences → Phone, turn on “Send pages to my phone” and enter your relay’s URL."
        } else {
            reason = (cfg.relayURLProblem?.message ?? "The relay URL isn’t valid.")
                + " Enter your Worker’s URL in Preferences → Phone."
        }
        let detail = wrappingLabel(reason, size: 12, color: .labelColor)
        let hint = wrappingLabel("The relay is a small Cloudflare Worker you deploy once (see Cloudflare/README.md in the Page repository). Pairing needs it so your phone and this Mac can reach each other.")

        let prefsBtn = NSButton(title: "Open Preferences…", target: self, action: #selector(openPreferencesFromPairing))
        prefsBtn.bezelStyle = .rounded
        prefsBtn.keyEquivalent = "\r"

        [icon, title, detail, hint, prefsBtn].forEach { stack.addArrangedSubview($0) }
        return stack
    }

    private func pairingContent(base: URL) -> NSStackView {
        let stack = makeStack()
        let payload = PairingTokenManager.pairingPayloadJSON(relayBaseURL: base,
                                                             sessionKey: PairingTokenManager.currentSessionKey())
        pairingPayloadCached = payload

        if let qr = QRCode.image(from: payload, size: CGSize(width: 300, height: 300)) {
            let qrView = NSImageView(image: qr)
            qrView.imageScaling = NSImageScaling.scaleProportionallyUpOrDown
            qrView.translatesAutoresizingMaskIntoConstraints = false
            qrView.widthAnchor.constraint(equalToConstant: 300).isActive = true
            qrView.heightAnchor.constraint(equalToConstant: 300).isActive = true
            stack.addArrangedSubview(qrView)
        }

        let title = NSTextField(labelWithString: "Scan this QR with Page on your iPhone")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.alignment = .center
        stack.addArrangedSubview(title)

        let relayLabel = wrappingLabel("Relay: \(base.host ?? base.absoluteString)")
        stack.addArrangedSubview(relayLabel)

        let health = wrappingLabel("Checking the relay…")
        stack.addArrangedSubview(health)
        pairingHealthLabel = health

        let mac = wrappingLabel("")
        stack.addArrangedSubview(mac)
        pairingMacLabel = mac
        updatePairingStatus()

        let simHint = wrappingLabel("Simulator can’t use a camera — use Copy pairing JSON and paste it into the app’s manual-pair screen.", size: 11)
        stack.addArrangedSubview(simHint)

        let copyBtn = NSButton(title: "Copy pairing JSON", target: self, action: #selector(copyPairingJSON))
        copyBtn.bezelStyle = .rounded
        copyBtn.keyEquivalent = "c"
        copyBtn.keyEquivalentModifierMask = [.command]

        let regenBtn = NSButton(title: "Regenerate token…", target: self, action: #selector(regenerateToken))
        regenBtn.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [copyBtn, regenBtn])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        stack.addArrangedSubview(buttonRow)

        probeRelayHealth(base: base)
        return stack
    }

    /// GET <relay>/health — proves the URL points at a live Page relay
    /// before the user scans (the endpoint needs no token).
    private func probeRelayHealth(base: URL) {
        healthProbeGeneration += 1
        let generation = healthProbeGeneration
        var request = URLRequest(url: base.appendingPathComponent("health"), timeoutInterval: 8)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let text: String
            let ok: Bool
            if let error {
                text = "✗ Can’t reach the relay: \(error.localizedDescription)"
                ok = false
            } else if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                if json?["ok"] as? Bool == true {
                    text = "✓ Relay is reachable"
                    ok = true
                } else {
                    text = "⚠ Reached \(base.host ?? "the server"), but it doesn’t look like a Page relay"
                    ok = false
                }
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                text = "✗ The relay answered HTTP \(code)"
                ok = false
            }
            DispatchQueue.main.async {
                guard let self, generation == self.healthProbeGeneration else { return }
                self.pairingHealthLabel?.stringValue = text
                self.pairingHealthLabel?.textColor = ok ? .systemGreen : .systemRed
            }
        }.resume()
    }

    private func updatePairingStatus() {
        guard let label = pairingMacLabel else { return }
        switch lastSnapshot?.relayState {
        case .connected?: label.stringValue = "This Mac is connected to the relay."
        case .connecting?: label.stringValue = "This Mac is connecting to the relay…"
        case .off?, .misconfigured?: label.stringValue = "This Mac isn’t using the relay."
        case nil: label.stringValue = ""
        }
    }

    @objc private func openPreferencesFromPairing() {
        pairingWindow?.close()
        openPreferences()
    }

    @objc private func copyPairingJSON() {
        guard !pairingPayloadCached.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(pairingPayloadCached, forType: .string)
        // The payload carries the relay token. These markers (nspasteboard.org
        // convention) ask clipboard managers not to record or sync it.
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    }

    @objc private func regenerateToken() {
        let alert = NSAlert()
        alert.messageText = "Regenerate the pairing token?"
        alert.informativeText = "Phones paired with the current token stop receiving pages until they scan the new QR code. Page asks the relay to retire the old token, so (on an up-to-date relay) those phones are told to re-pair. This Mac reconnects with the new token right away."
        alert.addButton(withTitle: "Regenerate")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        let proceed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            // Posts tokenDidChange; the Coordinator reconnects the relay.
            PairingTokenManager.regenerate()
            self?.showPairingQR()
        }
        if let window = pairingWindow, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: proceed)
        } else {
            proceed(alert.runModal())
        }
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
