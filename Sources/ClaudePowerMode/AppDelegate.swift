import AppKit
import LocalAuthentication
import SystemConfiguration
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
    /// The classic menu, filled in `menuNeedsUpdate`: shown on a right-click
    /// of the status item and from the panel's "…" button, so every item
    /// stays reachable. Replacing `statusItem.menu` on every tick (the old
    /// approach) closed or froze a menu the user had open.
    private let menu = NSMenu()

    // The Night Watch surfaces. The panel replaces the status item's menu as
    // the left-click; none of them hold a Coordinator reference themselves.
    private var nowStore: NowStore!
    private var nowPanel: NowPanelController!
    private var dispatchStore: DispatchStore!
    private var dispatchPanel: DispatchPanelController!
    private let welcomeBack = WelcomeBackController()
    private var hotKey: GlobalHotKey?
    private let glyph = GlyphAnimator()
    private var presenceTimer: Timer?
    private var presence = PresenceTracker(awayAfter: 120)
    private var awayLedger: AwayLedger?
    private var dayLedger = DayLedger(now: Date())
    /// What Page has delivered (or failed to) from the panel, newest last.
    private var receipts: [DeliveryReceipt] = []
    /// Where each pending page's session runs, probed off main.
    private struct RouteInfo { let label: String?; let blocker: String?; let at: Date }
    private var routes: [String: RouteInfo] = [:]
    private var probingRoutes = false
    /// Paused sessions whose transcript shows the summary Page asked for.
    private var summarised: Set<String> = []
    private var summaryCheckedAt: Date = .distantPast
    private let probeQueue = DispatchQueue(label: "ClaudePowerMode.panel.probe", qos: .utility)
    /// "Studio MBP": every action names the Mac it acts on.
    private lazy var macName: String = {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "this Mac"
    }()
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
        menu.delegate = self
        menu.autoenablesItems = false
        setUpNowSurfaces()

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
            // Clicking a page banner just shows the panel with the waiting
            // pages. It deliberately doesn't type anything or focus a
            // terminal: replying is an explicit action.
            if action == UNNotificationDefaultActionIdentifier {
                nowPanel.show()
            }
        default:
            break
        }
    }

    // MARK: status item

    private func render(_ snap: Coordinator.Snapshot) {
        lastSnapshot = snap
        let now = Date()
        let pending = snap.pendingInterventions
        let working = snap.sessions.filter { $0.state == .active }.count + snap.localModels.filter(\.busy).count
        dayLedger.observe(pending: pending, working: working, now: now)
        awayLedger?.observe(pending: pending)
        rebuildModel()
        refreshRoutes(snap)
        refreshSummaryEvidence(snap)
        updatePairingStatus()
    }

    /// Builds the model from the latest snapshot and what Page has delivered,
    /// and hands it to the panel and the status glyph. Called on every
    /// snapshot and after a delivery; the panel updates in place.
    private func rebuildModel() {
        guard let snap = lastSnapshot else { return }
        let cfg = coordinator.config
        NWAppearance.shared.set(cardGlow: cfg.cardGlow)
        let now = Date()
        var inputs = NowInputs(snapshot: snap, now: now, macName: macName)
        inputs.cutoff = cfg.lowBatteryCutoff
        inputs.recoveryThreshold = cfg.recoveryThreshold
        inputs.idleSeconds = UserPresence.secondsSinceLastInput()
        inputs.awayAfter = cfg.idlePageOnlyWhenAwaySeconds
        inputs.usage = snap.usage
        inputs.usageHitAt = snap.usageHitAt
        inputs.receipts = receipts
        inputs.day = dayLedger.stats
        inputs.summarised = summarised
        let routes = self.routes
        inputs.route = { routes[$0.sessionId]?.label }
        inputs.blocker = { routes[$0.sessionId]?.blocker }
        let model = NowModel.build(inputs)
        nowStore.update(model)
        // The Tower's sidebar card, badge and Power page follow the same model while it is open.
        if prefsController?.window?.isVisible == true { prefsController?.store.update(snapshot: snap, model: model) }
        glyph.longestWait = model.rows.map { now.timeIntervalSince($0.waitingSince) }.max() ?? 0
        glyph.state = model.glyph
        if let button = statusItem.button {
            glyph.appearance = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
            // Battery percent stays beside the glyph while on battery.
            let p = snap.power
            button.title = p.hasBattery && !p.onAC ? " \(p.percent)%" : ""
            // The glyph's arc and the count say what matters at a glance; on AC the
            // charge is in the tooltip rather than beside the glyph.
            button.toolTip = "Page — \(snap.statusLine)" + (p.hasBattery && p.onAC ? " · battery \(p.percent)%" : "")
            button.setAccessibilityLabel(model.accessibilityLabel)
        }
    }

    // MARK: the Now panel

    private func setUpNowSurfaces() {
        NWAppearance.shared.set(cardGlow: coordinator.config.cardGlow)
        nowStore = NowStore(model: NowModel.starting(macName: macName))
        nowStore.perform = { [weak self] effect in self?.perform(effect) }
        nowStore.command = { [weak self] command in self?.run(command) }
        nowPanel = NowPanelController(store: nowStore)
        nowPanel.anchorFrame = { [weak self] in
            guard let b = self?.statusItem.button, let w = b.window else { return nil }
            return w.convertToScreen(b.convert(b.bounds, to: nil))
        }
        nowPanel.onVisibilityChange = { [weak self] shown in
            guard shown else { return }
            if let snap = self?.lastSnapshot {
                self?.refreshRoutes(snap, force: true)
                self?.refreshSummaryEvidence(snap, force: true)
            }
            self?.rebuildModel()
        }

        dispatchStore = DispatchStore()
        dispatchPanel = DispatchPanelController(store: dispatchStore)
        dispatchPanel.loadFolders = { [weak self] done in
            let sessions = self?.lastSnapshot?.sessions ?? []
            self?.probeQueue.async {
                let folders = self?.coordinator.knownFolders(sessions: sessions) ?? []
                DispatchQueue.main.async { done(folders) }
            }
        }
        dispatchStore.send = { [weak self] path, prompt in self?.dispatch(folder: path, prompt: prompt) }

        glyph.onImage = { [weak self] image in
            guard let button = self?.statusItem.button else { return }
            button.image = image
            button.imagePosition = .imageLeft
        }
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Page — starting")
        }
        glyph.start()

        // Option-Command-P, from anywhere (no Accessibility permission).
        let key = GlobalHotKey.optionCommandP
        hotKey = GlobalHotKey(keyCode: key.keyCode, modifiers: key.modifiers) { [weak self] in self?.nowPanel.toggle() }
        if hotKey == nil { Logger.shared.log("Option-Command-P is taken by another app — the panel opens from the menu bar only") }

        presenceTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.pollPresence() }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showClassicMenu()
        } else {
            nowPanel.toggle()
        }
    }

    /// The classic menu under the status item (right-click).
    private func showClassicMenu() {
        nowPanel.close(restoreFocus: false)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func run(_ command: NowCommand) {
        switch command {
        case .resumePaused:
            coordinator.resumePausedSessionsNow()
        case .newSession:
            showDispatch()
        case .preferences:
            nowPanel.close(restoreFocus: false)
            openPreferences()
        case .openConfig:
            openConfig()
        case .more:
            // The whole classic menu: nothing in it is lost.
            let anchor = nowPanel.moreMenuAnchor()
            menu.popUp(positioning: nil, at: anchor.point, in: anchor.view)
        }
    }

    // MARK: actions from the panel

    /// Keys and clicks reach here as effects. Replies go through the same
    /// reply path the phone's do (`Coordinator.replyFromMac`); nothing here
    /// types anything itself.
    private func perform(_ effect: NowEffect) {
        switch effect {
        case .none:
            break
        case .close:
            nowPanel.close(restoreFocus: true)
        case .approve(let id):
            reply(rowId: id, action: "approve", text: "")
        case .deny(let id):
            reply(rowId: id, action: "deny", text: "")
        case .send(let id, let text):
            reply(rowId: id, action: "custom", text: text)
        case .approveAfterAuth(let id):
            approveIrreversible(rowId: id)
        case .openTerminal(let id):
            openTerminal(rowId: id)
        case .newSession:
            showDispatch()
        case .preferences:
            run(.preferences)
        case .more:
            run(.more)
        case .stopAll:
            stopAllAgents()
        }
    }

    private func page(forRowId id: String) -> (row: DecideRow, event: InterventionEvent)? {
        guard let row = nowStore.model.rows.first(where: { $0.id == id }),
              let event = lastSnapshot?.pendingInterventions.first(where: { $0.id == id }) else { return nil }
        return (row, event)
    }

    private func reply(rowId: String, action: String, text: String) {
        guard let (row, event) = page(forRowId: rowId) else {
            nowStore.finishSending(rowId: rowId)
            nowStore.notice = NowStore.Notice(text: "That page is gone · Review again", failed: true)
            return
        }
        let route = routes[event.sessionId]?.label
        // The result that arrives after the 25 s wait (a background resume that
        // was queued behind another): it replaces "Didn't confirm in time".
        let late: (ReplyFinished) -> Void = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                self.receipts.append(ReceiptFactory.receipt(action: action, row: row, route: route, finished: finished, at: Date()))
                self.rebuildModel()
            }
        }
        coordinator.replyFromMac(event: event, action: action, text: text, lateResult: late) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                let receipt = ReceiptFactory.receipt(action: action, row: row, route: route, finished: finished, at: Date())
                self.receipts.append(receipt)
                if self.receipts.count > 20 { self.receipts.removeFirst(self.receipts.count - 20) }
                self.nowStore.finishSending(rowId: rowId)
                self.nowStore.notice = nil
                self.rebuildModel()
            }
        }
    }

    /// An Irreversible approval, after the hold: Touch ID (or the login
    /// password where there is none) must pass before option 1 is typed.
    private func approveIrreversible(rowId: String) {
        guard let (row, _) = page(forRowId: rowId) else {
            nowStore.finishSending(rowId: rowId)
            nowStore.notice = NowStore.Notice(text: "That page is gone · Review again", failed: true)
            return
        }
        authenticate(reason: "Approve “\(ReceiptFactory.subject(for: row))” in \(row.projectName)") { [weak self] ok, why in
            guard let self else { return }
            guard ok else {
                self.nowStore.finishSending(rowId: rowId)
                self.nowStore.notice = NowStore.Notice(text: why ?? "Not approved", failed: true)
                return
            }
            self.reply(rowId: rowId, action: "approve", text: "")
        }
    }

    /// Never approves without a passing check: if neither Touch ID nor the
    /// login password can be asked for, the answer is no.
    private func authenticate(reason: String, completion: @escaping (Bool, String?) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(false, "Can't ask for Touch ID or your password · Open on Mac (O)")
            return
        }
        nowPanel.isAuthenticating = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] ok, _ in
            DispatchQueue.main.async {
                self?.nowPanel.isAuthenticating = false
                completion(ok, ok ? nil : "Not approved · cancelled")
            }
        }
    }

    private func openTerminal(rowId: String) {
        // A page row names its session through the event; a rate-limit row has
        // no page, so it goes by the session on the row itself.
        let target: (sessionId: String, backend: AgentBackendID)
        if let (_, event) = page(forRowId: rowId) {
            target = (event.sessionId, event.backend)
        } else if let row = nowStore.model.rows.first(where: { $0.id == rowId }), row.chip == .rateLimited {
            target = (row.sessionId, row.backend)
        } else {
            nowStore.notice = NowStore.Notice(text: "That page is gone · Review again", failed: true)
            return
        }
        nowStore.notice = NowStore.Notice(text: "Finding the terminal…", failed: false)
        probeQueue.async { [weak self] in
            guard let self else { return }
            let outcome = self.coordinator.focusTerminal(sessionId: target.sessionId, backend: target.backend)
            DispatchQueue.main.async {
                self.nowStore.notice = NowStore.Notice(text: outcome.detail, failed: !outcome.ok)
                if outcome.ok { self.nowPanel.close(restoreFocus: false) }
            }
        }
    }

    private func stopAllAgents() {
        nowStore.notice = NowStore.Notice(text: StopScope.describe(working: nowStore.model.stoppableCount) + "…", failed: false)
        coordinator.stopAllAgents { [weak self] result in
            DispatchQueue.main.async {
                let ok = result.code == .delivered || result.code == .queued
                self?.nowStore.notice = NowStore.Notice(text: StopScope.resultLine(detail: result.detail, success: ok), failed: !ok)
            }
        }
    }

    private func toggleNow() { nowPanel.toggle() }

    // MARK: dispatch

    @objc private func showDispatch() {
        nowPanel.close(restoreFocus: false)
        dispatchPanel.show()
    }

    private func dispatch(folder: String, prompt: String) {
        coordinator.dispatchSession(folder: folder, prompt: prompt) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.dispatchStore.finish(result)
                if result.code == .delivered || result.code == .queued {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { self.dispatchPanel.close(restoreFocus: false) }
                }
            }
        }
    }

    // MARK: presence

    /// Welcome back: when you return after being away past the threshold, the
    /// handover drops for a few seconds (amber first when something needs you).
    private func pollPresence() {
        let cfg = coordinator.config
        presence.awayAfter = cfg.idlePageOnlyWhenAwaySeconds > 0 ? cfg.idlePageOnlyWhenAwaySeconds : 120
        let now = Date()
        switch presence.observe(idle: UserPresence.secondsSinceLastInput(), now: now) {
        case .none:
            break
        case .wentAway:
            awayLedger = AwayLedger(phoneRepliesAtStart: coordinator.phoneReplyCount)
            if let snap = lastSnapshot { awayLedger?.observe(pending: snap.pendingInterventions) }
        case .returned(let away):
            defer { awayLedger = nil }
            guard WelcomeBack.isWorthShowing(away: away), let ledger = awayLedger, let snap = lastSnapshot else { return }
            let needYou = snap.pendingInterventions.filter { NowModel.section(of: $0) == .decide }.count
            let model = ledger.welcome(away: away, needYou: needYou, phoneRepliesNow: coordinator.phoneReplyCount,
                                       rings: dayLedger.stats.rings)
            let anchor = nowPanel.anchorFrame()
            welcomeBack.show(model, near: anchor)
        }
    }

    // MARK: probes (off main)

    /// Where each pending page's session runs, so the panel can name the pane
    /// ("cmux › page") and say when Page can't type there. Cached per session
    /// for half a minute; ps, tmux and the cmux socket never run on main.
    private func refreshRoutes(_ snap: Coordinator.Snapshot, force: Bool = false) {
        // Only while the panel is up: nothing here is needed otherwise.
        guard force || nowPanel.isShown else { return }
        let now = Date()
        let wanted = Set(snap.pendingInterventions.map(\.sessionId))
        routes = routes.filter { wanted.contains($0.key) }
        let stale = wanted.filter { id in force || routes[id].map { now.timeIntervalSince($0.at) > 30 } ?? true }
        guard !stale.isEmpty, !probingRoutes else { return }
        let sessions = snap.sessions.filter { stale.contains($0.sessionId) }
        let projects = Dictionary(snap.pendingInterventions.map { ($0.sessionId, $0.projectName) }, uniquingKeysWith: { a, _ in a })
        guard !sessions.isEmpty else { return }
        probingRoutes = true
        probeQueue.async { [weak self] in
            let hosts = self?.coordinator.probeHosts(sessions) ?? [:]
            DispatchQueue.main.async {
                guard let self else { return }
                self.probingRoutes = false
                let at = Date()
                for s in sessions {
                    // Unknown stays unknown for a while (no probe on every tick).
                    guard let info = hosts[s.sessionId] else {
                        self.routes[s.sessionId] = RouteInfo(label: nil, blocker: nil, at: at)
                        continue
                    }
                    self.routes[s.sessionId] = RouteInfo(
                        label: info.canType ? TerminalFocus.routeLabel(host: info.host, project: projects[s.sessionId] ?? "") : nil,
                        blocker: info.canType ? nil : info.typeBlocker, at: at)
                }
                self.rebuildModel()
            }
        }
    }

    /// "summary ✓" at dusk only when a paused session's transcript has an
    /// assistant message written after Page paused it.
    private func refreshSummaryEvidence(_ snap: Coordinator.Snapshot, force: Bool = false) {
        let paused = snap.battery.paused
        guard !paused.isEmpty else {
            if !summarised.isEmpty { summarised = [] }
            return
        }
        guard force || nowPanel.isShown else { return }
        let now = Date()
        guard force || now.timeIntervalSince(summaryCheckedAt) > 20 else { return }
        summaryCheckedAt = now
        probeQueue.async { [weak self] in
            let written = self?.coordinator.summariesWritten(for: paused) ?? []
            DispatchQueue.main.async {
                guard let self, written != self.summarised else { return }
                self.summarised = written
                self.rebuildModel()
            }
        }
    }

    // MARK: NSMenuDelegate

    /// Whatever a menu item opens (a window, an alert) must not sit under the
    /// panel: it closes as the menu does.
    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu, nowPanel.isShown else { return }
        nowPanel.close(restoreFocus: false)
    }

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
                addAction(menu, "Phone relay: off — set up…", #selector(openPreferencesPhone), key: "")
            case .misconfigured(let why):
                let item = addAction(menu, "Phone relay: not set up — fix in Preferences…", #selector(openPreferencesPhone), key: "")
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
        addAction(menu, "New Session…", #selector(showDispatch), key: "n")
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
        showTower(section: nil)
    }

    /// The relay and phone settings: where "Phone relay: off — set up…" and
    /// the pairing window's "Open Preferences…" land.
    @objc private func openPreferencesPhone() {
        showTower(section: .macsPhones)
    }

    private func showTower(section: TowerSection?) {
        if prefsController == nil {
            prefsController = PreferencesWindowController(
                coordinator: coordinator, macName: macName,
                pairPhone: { [weak self] in self?.showPairingQR() },
                copyDiagnostics: { [weak self] in self?.copyLocalModelDiagnostics() })
        }
        prefsController?.store.update(snapshot: lastSnapshot, model: nowStore.model)
        prefsController?.showAndFocus(section: section)
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
            reason = "Phone paging is turned off. In Preferences → Macs & phones, turn on “Send pages to my phone” and enter your relay’s URL."
        } else {
            reason = (cfg.relayURLProblem?.message ?? "The relay URL isn’t valid.")
                + " Enter your Worker’s URL in Preferences → Macs & phones."
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
        openPreferencesPhone()
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
