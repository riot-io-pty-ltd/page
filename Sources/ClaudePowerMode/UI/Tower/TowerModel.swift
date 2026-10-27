import Foundation

// The Tower (settings window): everything that decides what it says, as pure
// values. The views in TowerView / TowerPages only draw these; the store in
// TowerStore only moves them around.

// MARK: - Sections

/// The sidebar sections, in board order (board 41).
enum TowerSection: String, CaseIterable, Identifiable, Equatable {
    case power, budget, macsPhones, attention, agents, terminals, shortcuts, pairing, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .power: return "Power"
        case .budget: return "Budget"
        case .macsPhones: return "Macs & phones"
        case .attention: return "Attention"
        case .agents: return "Agents"
        case .terminals: return "Terminals"
        case .shortcuts: return "Shortcuts"
        case .pairing: return "Pairing & encryption"
        case .about: return "About Page"
        }
    }

    /// The line under the page title.
    var subtitle: String {
        switch self {
        case .power: return "Keep agents running, and stop them gracefully before the battery does."
        case .budget: return "How much of Claude’s limit is left, and what Page does when you hit it."
        case .macsPhones: return "Where Page sends pages, and what your phone may do on this Mac."
        case .attention: return "What is worth interrupting you for, and when."
        case .agents: return "Which agents Page watches, and the tools it works with."
        case .terminals: return "Where Page can reply, approve and stop agents for you, and what each terminal needs."
        case .shortcuts: return "Every key Page answers to. Page only ever approves, denies or sends your own words."
        case .pairing: return "How your phone and this Mac find each other, and who can read what."
        case .about: return "This copy of Page, its files and its defaults."
        }
    }

    /// SF Symbol names that exist on macOS 12.
    var symbol: String {
        switch self {
        case .power: return "battery.100"
        case .budget: return "speedometer"
        case .macsPhones: return "laptopcomputer"
        case .attention: return "bell.badge"
        case .agents: return "terminal"
        case .terminals: return "macwindow"
        case .shortcuts: return "keyboard"
        case .pairing: return "key"
        case .about: return "info.circle"
        }
    }

    /// Pure. The section after a move of `delta` rows, wrapping nowhere (the
    /// sidebar stops at its ends).
    static func moved(from s: TowerSection, by delta: Int) -> TowerSection {
        let all = allCases
        guard let i = all.firstIndex(of: s) else { return s }
        return all[min(all.count - 1, max(0, i + delta))]
    }
}

// MARK: - The Tower card

/// The card at the top of the sidebar: status dot, Mac name, how many agents
/// are working, and the day's three rings.
struct TowerCardModel: Equatable {
    enum Dot: Equatable { case running, paused, starting }

    var title: String
    /// "Studio MBP · 5 working".
    var subtitle: String
    var dot: Dot
    var rings: [RingStat]
    /// The Attention row's badge: items that need you (decisions and looks).
    var attentionBadge: Int

    /// Pure.
    static func build(model: NowModel?, macName: String) -> TowerCardModel {
        guard let m = model else {
            return TowerCardModel(title: "The Tower", subtitle: "\(macName) · starting…", dot: .starting, rings: [], attentionBadge: 0)
        }
        let state: String
        switch m.mood {
        case .dusk: state = "paused for battery"
        default: state = m.workingCount > 0 ? "\(m.workingCount) working" : "all quiet"
        }
        return TowerCardModel(title: "The Tower", subtitle: "\(m.macName) · \(state)",
                              dot: m.mood == .dusk ? .paused : .running,
                              rings: m.rings, attentionBadge: m.attentionCount)
    }
}

// MARK: - Formatting

enum TowerFormat {
    /// Pure. "Off" / "45 s" / "3 min" / "1m 30s": the old Preferences labels.
    static func duration(_ seconds: Double, zero: String = "Off") -> String {
        let s = Int(seconds.rounded())
        if s == 0 { return zero }
        if s < 60 { return "\(s) s" }
        return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60)m \(s % 60)s"
    }

    /// Pure. The slider readout for "keep awake for a waiting page": "Don’t",
    /// "45 min", "2h 30m".
    static func holdAwake(minutes raw: Double) -> String {
        let minutes = Int(raw.rounded())
        return minutes == 0 ? "Don’t" : (minutes < 60 ? "\(minutes) min" : "\(minutes / 60)h \(minutes % 60)m")
    }

    /// Pure. The segment label for a hold time: "Off", "30m", "1h", "1h 30m".
    static func holdSegment(minutes raw: Double) -> String {
        let m = Int(raw.rounded())
        if m <= 0 { return "Off" }
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

    /// Pure. "62%".
    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// Pure. "03:00" today, "Fri 23:00" further out; 24-hour, as the runway shows it.
    static func resetText(_ at: Date, now: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = timeZone
        let sameDay = cal.isDate(at, inSameDayAs: now)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now).map { cal.isDate(at, inSameDayAs: $0) } ?? false
        f.dateFormat = (sameDay || tomorrow || at.timeIntervalSince(now) < 20 * 3600) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: at)
    }
}

// MARK: - Segmented options

/// Segmented controls offer presets, but the config accepts any value in a
/// wider range (and so did the old sliders). A value that is not a preset is
/// shown as its own extra segment, so the control never shows nothing
/// selected, and is only changed by a tap.
enum TowerOptions {
    static let cutoffPresets: [Int] = [5, 10, 15, 20]
    static let holdPresets: [Double] = [0, 30, 60]

    /// Pure. 5% 10% 15% 20%, plus the current value in its place when it is
    /// none of them.
    static func cutoffOptions(current: Int) -> [(value: Int, label: String)] {
        var values = cutoffPresets
        if !values.contains(current) { values.append(current); values.sort() }
        return values.map { ($0, "\($0)%") }
    }

    /// Pure. Off 30m 1h, plus the current value in its place when it is none of them.
    static func holdOptions(current: Double) -> [(value: Double, label: String)] {
        var values = holdPresets
        let cur = current.rounded()
        if !values.contains(cur) { values.append(cur); values.sort() }
        return values.map { ($0, TowerFormat.holdSegment(minutes: $0)) }
    }

    /// Pure. Pause / After step / Off.
    static func actionLabel(_ a: LowBatteryAction) -> String {
        switch a {
        case .pause: return "Pause"
        case .afterTurn: return "After step"
        case .off: return "Off"
        }
    }

    /// Pure. The line under "Agents should".
    static func actionDetail(_ a: LowBatteryAction) -> String {
        switch a {
        case .pause: return "pause now and summarise"
        case .afterTurn: return "finish the step, then summarise"
        case .off: return "left alone · the Mac just sleeps"
        }
    }

    /// Pure. The line under the Card glow control.
    static func cardGlowDetail(_ g: CardGlow) -> String {
        switch g {
        case .off: return "plain glass · no teal along the bottom of cards"
        case .subtle: return "a faint teal light rising from the bottom of cards"
        case .full: return "a stronger teal light rising from the bottom of cards"
        }
    }
}

// MARK: - Coupling and availability

/// Rules between controls, ported from the old Preferences window.
enum TowerRules {
    /// Pure. Moving the cutoff up past the recovery level pulls recovery up to
    /// five points above it (capped at 100).
    static func recovery(afterCutoff cutoff: Int, recovery: Int) -> Int {
        recovery < cutoff ? min(100, cutoff + 5) : recovery
    }

    /// Pure. Moving recovery down below the cutoff pulls the cutoff down to
    /// five points under it (not below 0).
    static func cutoff(afterRecovery recovery: Int, cutoff: Int) -> Int {
        recovery < cutoff ? max(0, recovery - 5) : cutoff
    }

    /// Pure. Anything but "don't message the agents" pauses them, so the
    /// grace period, resume on power and pausing early only mean something then.
    static func pausesAgents(_ a: LowBatteryAction) -> Bool { a != .off }

    /// Pure. Stuck minutes only matter while stuck alerts are on.
    static func stuckMinutesEnabled(_ f: PreferencesForm) -> Bool { f.stuckAlertsEnabled }

    /// Pure. The Codex path field only matters while Codex is watched.
    static func codexPathEnabled(_ f: PreferencesForm) -> Bool { f.codexBackendEnabled }

    /// Pure. What ticking "lid closed on battery" does first: with the power
    /// helper missing it goes straight to the admin prompt (and unticks if
    /// that is cancelled); otherwise it just changes the setting.
    enum LidBatteryStep: Equatable { case set(Bool), installHelperFirst }
    static func lidBattery(turningOn: Bool, helper: SleepGuard.HelperStatus) -> LidBatteryStep {
        turningOn && helper == .missing ? .installHelperFirst : .set(turningOn)
    }

    /// Pure. After the helper install: whether the lid-on-battery box stays ticked.
    static func lidBatteryAfterInstall(_ outcome: PowerHelperInstaller.Outcome) -> Bool {
        if case .installed = outcome { return true }
        return false
    }
}

// MARK: - Relay and Codex status lines

struct TowerStatusLine: Equatable {
    enum Tone: Equatable { case quiet, good, bad }
    var text: String
    var tone: Tone
}

enum TowerLines {
    /// Pure. The line under the relay URL: what is wrong, or where it will connect.
    /// `canTest` says whether the Test button works.
    static func relay(enabled: Bool, url rawURL: String) -> (line: TowerStatusLine, canTest: Bool) {
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty {
            return (TowerStatusLine(text: enabled ? "Enter your relay’s URL." : "", tone: enabled ? .bad : .quiet), false)
        }
        switch Config.validatedRelayURL(url) {
        case .success(let base):
            return (TowerStatusLine(text: "Will connect to \(base.absoluteString)", tone: .quiet), true)
        case .failure(let problem):
            return (TowerStatusLine(text: problem.message, tone: .bad), false)
        }
    }

    /// Pure. The line under the Codex path; `found` is what the lookup finds
    /// for it (nil when Codex isn't anywhere).
    static func codex(enabled: Bool, configured rawConfigured: String, found: String?) -> TowerStatusLine? {
        guard enabled else { return nil }
        let configured = rawConfigured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let found else {
            return TowerStatusLine(text: "codex wasn’t found in the usual places — enter its full path.", tone: .bad)
        }
        let usingConfigured = !configured.isEmpty && found == (configured as NSString).expandingTildeInPath
        if usingConfigured || configured.isEmpty { return TowerStatusLine(text: "Using \(found)", tone: .quiet) }
        return TowerStatusLine(text: "Nothing executable at that path — auto-detect would use \(found)", tone: .bad)
    }

    /// Pure. The local models line: off, nothing running, or one line per tool.
    static func localModels(enabled: Bool, lines: [String]) -> String {
        guard enabled else { return "Off." }
        return lines.isEmpty ? "No local model servers or tools running right now." : lines.joined(separator: "\n")
    }

    /// Pure. The usage-capture status after a toggle (same words as before).
    static func usageCaptured(on: Bool, backupName: String?) -> String {
        on ? "On — numbers appear after Claude Code next draws its status line." + (backupName.map { " Backup: \($0)" } ?? "")
           : "Off — your status line is back as it was."
    }
}

// MARK: - Power page

/// Everything the Power hero needs from the live state and the form.
struct PowerInputs {
    var power: PowerSnapshot
    var forecast: BatteryForecast.Estimate?
    var phase: BatteryPolicy.Phase = .normal
    var awake: AwakeAssertions
    var lidClosedOnBattery = false
    var lidBlocker: String?
    var cutoff: Int
    var recoveryThreshold: Int = 25
    var action: LowBatteryAction = .pause
    var earlyPause = false
    var keepAwakeLidClosedOnAC = true
    var keepAwakeLidClosedOnBattery = false
}

/// The lid-closed state chip at the right of the hero.
struct LidChip: Equatable {
    enum Tone: Equatable { case active, blocked, idle }
    var text: String
    var tone: Tone
}

/// The battery bar with its cutoff and pause-early markers.
struct BatteryBarModel: Equatable {
    /// 0...1 of the bar that is charge.
    var fill: Double
    /// 0...1 positions of the markers.
    var cutoff: Double
    var pauseEarly: Double?
    var cutoffLabel: String
    var pauseEarlyLabel: String
    /// Pause early is switched off: its marker is drawn dim.
    var pauseEarlyOn: Bool
}

struct PowerHero: Equatable {
    /// "41%", or "AC" on a Mac with no battery.
    var bigText: String
    /// "on battery · cutoff in about 1 h 50 min at this rate".
    var line: String
    var lid: LidChip?
    var bar: BatteryBarModel?
}

enum PowerPage {
    /// Nominal drain (points per hour) used to place the pause-early marker
    /// before there is a forecast to place it by.
    static let nominalDrainPerHour = 30.0

    /// Pure. Minutes to the cutoff at `drainPerHour`, 0 at or below it; nil
    /// when there is no drain to go by.
    static func minutesToCutoff(percent: Int, cutoff: Int, drainPerHour: Double) -> Int? {
        guard drainPerHour > 0 else { return nil }
        let left = Double(percent - cutoff)
        return left <= 0 ? 0 : Int((left / drainPerHour * 60).rounded())
    }

    /// Pure. Where "pause early" fires: the charge at which the forecast says
    /// the cutoff is `BatteryForecast.earlyPauseWithin` minutes away, at least
    /// one point above the cutoff, never above 100.
    static func pauseEarlyPercent(cutoff: Int, drainPerHour: Double?) -> Int {
        let drain = drainPerHour.flatMap { $0 > 0 ? $0 : nil } ?? nominalDrainPerHour
        let points = max(1, Int((drain * Double(BatteryForecast.earlyPauseWithin) / 60).rounded()))
        return min(100, cutoff + points)
    }

    /// Pure. The lid-closed chip, or nil on a Mac that cannot run with the lid closed any differently.
    static func lidChip(_ i: PowerInputs) -> LidChip? {
        if i.lidClosedOnBattery { return LidChip(text: "Lid closed · awake on battery", tone: .active) }
        if !i.power.onAC, i.power.hasBattery, i.keepAwakeLidClosedOnBattery, let why = i.lidBlocker {
            return LidChip(text: why, tone: .blocked)
        }
        let wanted = i.power.onAC || !i.power.hasBattery ? i.keepAwakeLidClosedOnAC : i.keepAwakeLidClosedOnBattery
        return wanted ? LidChip(text: "Lid closed · awake while agents work", tone: .active)
                      : LidChip(text: "Lid closed · the Mac sleeps", tone: .idle)
    }

    /// Pure.
    static func hero(_ i: PowerInputs) -> PowerHero {
        let lid = lidChip(i)
        guard i.power.hasBattery, i.power.percent >= 0 else {
            return PowerHero(bigText: "AC", line: "no battery in this Mac · agents keep it awake until they stop", lid: lid, bar: nil)
        }
        let p = i.power.percent
        let line: String
        if i.phase != .normal {
            line = "paused at the \(i.cutoff)% cutoff · agents resume at \(i.recoveryThreshold)%"
        } else if i.power.onAC {
            line = i.power.isCharging ? "charging · the cutoff only applies on battery" : "on AC · the cutoff only applies on battery"
        } else if !TowerRules.pausesAgents(i.action) {
            line = "on battery · at \(i.cutoff)% the Mac stops being kept awake"
        } else if let f = i.forecast,
                  let m = f.cutoff == i.cutoff ? f.minutesToCutoff
                    : minutesToCutoff(percent: p, cutoff: i.cutoff, drainPerHour: f.drainPerHour) {
            line = m == 0 ? "on battery · at the cutoff now"
                : "on battery · cutoff in about \(BatteryForecast.duration(minutes: m)) at this rate"
        } else {
            line = p <= i.cutoff ? "on battery · at the cutoff now"
                : "on battery · cutoff at \(i.cutoff)% · the forecast needs a few minutes of drain"
        }
        let early = TowerRules.pausesAgents(i.action)
            ? Double(pauseEarlyPercent(cutoff: i.cutoff, drainPerHour: i.forecast?.drainPerHour)) / 100 : nil
        let bar = BatteryBarModel(
            fill: Double(min(100, max(0, p))) / 100, cutoff: Double(min(100, max(0, i.cutoff))) / 100,
            pauseEarly: early, cutoffLabel: "cutoff \(i.cutoff)%", pauseEarlyLabel: "pause early", pauseEarlyOn: i.earlyPause)
        return PowerHero(bigText: "\(p)%", line: line, lid: lid, bar: bar)
    }

    /// Pure. The line under "Resume on power".
    static func resumeDetail(recoveryThreshold: Int, requiresAC: Bool) -> String {
        requiresAC ? "when back on AC at \(recoveryThreshold)%" : "when back at \(recoveryThreshold)%"
    }
}

// MARK: - Budget page

/// One usage ring: "5-hour 62% · resets 03:00".
struct BudgetRing: Equatable, Identifiable {
    enum Kind: String, Equatable { case fiveHour = "5-hour", sevenDay = "7-day" }
    let kind: Kind
    /// 0...1.
    let progress: Double
    let percentText: String
    /// "resets 03:00"; "no reset time" when Claude Code did not say.
    let resetText: String
    var id: String { kind.rawValue }
    /// Close to the limit: drawn amber (never red: red is for irreversible things).
    var isHigh: Bool { progress >= 0.8 }
}

struct BudgetModel: Equatable {
    var rings: [BudgetRing]
    /// "At this pace you'll hit the 5-hour limit around 02:40"; nil without a forecast.
    var forecastLine: String?
    /// When the numbers were captured: "updated 1 min ago".
    var updatedLine: String?

    /// Pure.
    static func build(usage: UsageSnapshot?, hitAt: Date?, now: Date, timeZone: TimeZone = .current) -> BudgetModel {
        guard let u = usage else { return BudgetModel(rings: [], forecastLine: nil, updatedLine: nil) }
        func ring(_ kind: BudgetRing.Kind, _ w: UsageSnapshot.Window?) -> BudgetRing? {
            guard let w else { return nil }
            let reset = w.resetsAt.map { "resets " + TowerFormat.resetText($0, now: now, timeZone: timeZone) } ?? "no reset time"
            return BudgetRing(kind: kind, progress: min(1, max(0, w.pct / 100)), percentText: TowerFormat.percent(w.pct), resetText: reset)
        }
        let forecast = hitAt.map { "At this pace you’ll hit the 5-hour limit around " + TowerFormat.resetText($0, now: now, timeZone: timeZone) }
        let age = max(0, now.timeIntervalSince(u.updatedAt))
        let updated = age < 90 ? "updated just now" : "updated \(NowModel.duration(seconds: age)) ago"
        return BudgetModel(rings: [ring(.fiveHour, u.fiveHour), ring(.sevenDay, u.sevenDay)].compactMap { $0 },
                           forecastLine: forecast, updatedLine: updated)
    }
}

// MARK: - Shortcuts

/// One line on the Shortcuts page.
struct TowerShortcut: Equatable, Identifiable {
    var keys: [String]
    var title: String
    var detail: String
    var id: String { keys.joined(separator: "+") + title }
}

struct TowerShortcutGroup: Equatable, Identifiable {
    var title: String
    var items: [TowerShortcut]
    var id: String { title }
}

/// The shortcut list, from the spec's keyboard section and the menu. Page
/// sends option 1 to approve, Esc to deny, and your own words; there is no
/// key for "always allow" and none that approves or denies by itself.
enum ShortcutCatalog {
    static let groups: [TowerShortcutGroup] = [
        TowerShortcutGroup(title: "ANYWHERE", items: [
            TowerShortcut(keys: ["⌥", "⌘", "P"], title: "Open or close the Now panel", detail: "From any app, no Accessibility permission needed"),
            TowerShortcut(keys: ["⌘", "N"], title: "New session", detail: "Opens Dispatch: pick a folder, write the prompt")
        ]),
        TowerShortcutGroup(title: "IN THE NOW PANEL", items: [
            TowerShortcut(keys: ["↑", "↓"], title: "Move between pages", detail: "Selects a row; nothing is sent by moving"),
            TowerShortcut(keys: ["1"], title: "Approve", detail: "Types option 1 into the session. On an irreversible item, hold it, then Touch ID (or your password)"),
            TowerShortcut(keys: ["↵"], title: "Approve an undoable item", detail: "Does nothing on irreversible ones, where it opens the terminal instead"),
            TowerShortcut(keys: ["esc"], title: "Deny", detail: "Presses Esc in the session. With nothing selected it closes the panel"),
            TowerShortcut(keys: ["T"], title: "Tell it instead", detail: "Esc first, then your text, then Return"),
            TowerShortcut(keys: ["O"], title: "Open the session’s terminal", detail: "Claude: the session’s own Terminal, iTerm2, cmux or tmux pane. Codex: brings your terminal forward. Never types"),
            TowerShortcut(keys: ["hold", "⌘", "."], title: "Stop all agents", detail: "Hold for a moment; sends Esc to every busy session"),
            TowerShortcut(keys: ["M"], title: "More…", detail: "The classic menu: Pair phone, Open Log, Reload Config, Quit"),
            TowerShortcut(keys: ["tab"], title: "Move between the buttons", detail: "With Full Keyboard Access on; space presses the focused one")
        ]),
        TowerShortcutGroup(title: "IN THE MENU", items: [
            TowerShortcut(keys: ["⌘", "P"], title: "Pair phone…", detail: "Right-click the menu bar icon for the classic menu"),
            TowerShortcut(keys: ["⌘", ","], title: "Preferences…", detail: "This window. Also works in the Now panel"),
            TowerShortcut(keys: ["⌘", "L"], title: "Open Log", detail: "Everything Page did, in one file"),
            TowerShortcut(keys: ["⌘", "R"], title: "Reload Config", detail: "Re-reads config.json"),
            TowerShortcut(keys: ["⌘", "Q"], title: "Quit Page", detail: "")
        ])
    ]
}

// MARK: - Where every old control went

/// One old Preferences control and its new home. The list is the checklist
/// that proves no setting was lost: every `PreferencesForm` field appears
/// exactly once.
struct TowerControlHome: Equatable {
    /// The `PreferencesForm` property, or an "action: …" for a button.
    let old: String
    let oldTab: String
    let section: TowerSection
    let newControl: String
}

enum TowerControlMap {
    static let entries: [TowerControlHome] = [
        // Phone & paging
        .init(old: "relayEnabled", oldTab: "Phone", section: .macsPhones, newControl: "Send pages to my phone toggle"),
        .init(old: "relayURL", oldTab: "Phone", section: .macsPhones, newControl: "Relay URL field, Test button, status line"),
        .init(old: "interventionDetectionEnabled", oldTab: "Phone", section: .attention, newControl: "Detect sessions that need me toggle"),
        .init(old: "idlePageOnlyWhenAwaySeconds", oldTab: "Phone", section: .attention, newControl: "Away-for slider"),
        .init(old: "idlePageDelaySeconds", oldTab: "Phone", section: .attention, newControl: "Idle-for slider"),
        .init(old: "holdAwakeForPendingPageMinutes", oldTab: "Phone", section: .power, newControl: "Hold for a waiting page segments + fine slider"),
        .init(old: "headlessResumeFallbackEnabled", oldTab: "Phone", section: .macsPhones, newControl: "Background claude --resume toggle"),
        .init(old: "remoteSessionsEnabled", oldTab: "Phone", section: .macsPhones, newControl: "Show my live sessions on my phone toggle"),
        .init(old: "phoneStartSessionsEnabled", oldTab: "Alerts", section: .macsPhones, newControl: "Let my phone start sessions toggle"),
        // Power
        .init(old: "keepAwakeLidClosedOnAC", oldTab: "Power", section: .power, newControl: "Lid closed on AC toggle"),
        .init(old: "keepAwakeLidClosedOnBattery", oldTab: "Power", section: .power, newControl: "Lid closed on battery toggle + power helper row"),
        .init(old: "requireRecentTranscriptActivity", oldTab: "Power", section: .power, newControl: "Only while Claude is producing output toggle"),
        .init(old: "transcriptActivityWindowSeconds", oldTab: "Power", section: .power, newControl: "Idle after no transcript writes slider"),
        .init(old: "checkIntervalSeconds", oldTab: "Power", section: .power, newControl: "Check every slider"),
        // Battery
        .init(old: "lowBatteryCutoff", oldTab: "Battery", section: .power, newControl: "Cutoff segments + fine slider"),
        .init(old: "lowBatteryAction", oldTab: "Battery", section: .power, newControl: "Agents should segments"),
        .init(old: "lowBatteryPauseGraceSeconds", oldTab: "Battery", section: .power, newControl: "Summary grace slider"),
        .init(old: "recoveryThreshold", oldTab: "Battery", section: .power, newControl: "Power is back at slider"),
        .init(old: "recoveryRequiresAC", oldTab: "Battery", section: .power, newControl: "Only count recovery while plugged in toggle"),
        .init(old: "resumeAfterBatteryRecovery", oldTab: "Battery", section: .power, newControl: "Resume on power toggle"),
        .init(old: "earlyBatteryPause", oldTab: "Alerts", section: .power, newControl: "Pause early toggle"),
        // Agents
        .init(old: "codexBackendEnabled", oldTab: "Agents", section: .agents, newControl: "Watch Codex sessions toggle"),
        .init(old: "codexPath", oldTab: "Agents", section: .agents, newControl: "codex path field + status line"),
        .init(old: "localModelsEnabled", oldTab: "Agents", section: .agents, newControl: "Local models toggle + status"),
        // Rate limits
        .init(old: "rateLimitWatcherEnabled", oldTab: "Rate limits", section: .budget, newControl: "Watch for rate-limit events toggle"),
        .init(old: "autoResumeEnabled", oldTab: "Rate limits", section: .budget, newControl: "Auto-schedule a resume toggle"),
        .init(old: "carryOnPrompt", oldTab: "Rate limits", section: .budget, newControl: "Resume prompt field"),
        .init(old: "holdAssertionUntilReset", oldTab: "Rate limits", section: .budget, newControl: "Keep awake through the reset wait toggle"),
        .init(old: "wakeViaPmsetEnabled", oldTab: "Rate limits", section: .budget, newControl: "pmset wake before the resume toggle"),
        // Alerts
        .init(old: "stuckAlertsEnabled", oldTab: "Alerts", section: .attention, newControl: "Page me when an agent looks stuck toggle"),
        .init(old: "stuckAfterMinutes", oldTab: "Alerts", section: .attention, newControl: "No progress after slider"),
        .init(old: "turnSummaryEnabled", oldTab: "Alerts", section: .attention, newControl: "Start finished-turn pages with what changed toggle"),
        .init(old: "batteryForecastPageEnabled", oldTab: "Alerts", section: .attention, newControl: "Page me before the battery cutoff toggle"),
        .init(old: "usageForecastPageEnabled", oldTab: "Alerts", section: .attention, newControl: "Page me before the 5-hour limit toggle"),
        // Appearance
        .init(old: "cardGlow", oldTab: "(new)", section: .about, newControl: "Card glow segments (Appearance)"),
        // Not form fields
        .init(old: "action: usage capture toggle", oldTab: "Rate limits", section: .budget, newControl: "Show my Claude usage toggle (applies at once)"),
        .init(old: "action: power helper Install / Check again", oldTab: "Power", section: .power, newControl: "Power helper row"),
        .init(old: "action: Reset to defaults", oldTab: "window", section: .about, newControl: "Reset to defaults (footer)"),
        .init(old: "action: Cancel / Apply", oldTab: "window", section: .about, newControl: "Cancel and Apply (footer)"),
        .init(old: "action: Set up cmux…", oldTab: "menu", section: .agents, newControl: "Set up cmux… button (also on the Terminals page)"),
        .init(old: "action: Terminals list", oldTab: "(new)", section: .terminals, newControl: "Terminals page: every supported terminal, its status chip and one action"),
        .init(old: "action: Set up kitty remote control", oldTab: "(new)", section: .terminals, newControl: "kitty row: Set up… adds two lines to kitty.conf (backed up), Undo"),
        .init(old: "action: Allow Terminal / iTerm2 automation", oldTab: "(new)", section: .terminals, newControl: "Terminal and iTerm2 rows: Allow… asks macOS for Automation permission"),
        .init(old: "action: Get a terminal", oldTab: "(new)", section: .terminals, newControl: "Not-installed rows: Get it ↗ opens the official site"),
        .init(old: "action: Install agent hooks…", oldTab: "menu", section: .agents, newControl: "Install agent hooks… button"),
        .init(old: "action: Copy local-model diagnostics", oldTab: "menu", section: .agents, newControl: "Copy local-model diagnostics button"),
        .init(old: "action: Pair phone…", oldTab: "menu", section: .pairing, newControl: "Pair phone… button"),
        .init(old: "action: Open Config File…", oldTab: "menu", section: .about, newControl: "Open Config File… button"),
        .init(old: "action: Open Log", oldTab: "menu", section: .about, newControl: "Open Log button"),
        .init(old: "action: Reload Config", oldTab: "menu", section: .about, newControl: "Reload Config button"),
        .init(old: "action: menu key equivalents (⌘P ⌘, ⌘L ⌘R ⌘Q)", oldTab: "menu", section: .shortcuts, newControl: "Shortcuts page, In the menu")
    ]

    /// Pure. Entries whose `old` is a form field (not an action).
    static var fieldNames: [String] { entries.map(\.old).filter { !$0.hasPrefix("action:") } }
}

// MARK: - Agents and phones

enum TowerAgents {
    /// Pure. "7 sessions · 5 active · 1 waiting", or the backend's problem.
    static func backendLine(_ info: Coordinator.BackendInfo?, fallback: String) -> String {
        guard let info else { return fallback }
        if let problem = info.problem { return problem }
        if !info.enabled { return "off" }
        var parts = ["\(info.sessionCount) session\(info.sessionCount == 1 ? "" : "s")"]
        if info.activeCount > 0 { parts.append("\(info.activeCount) active") }
        if info.waitingCount > 0 { parts.append("\(info.waitingCount) waiting") }
        return parts.joined(separator: " · ")
    }
}

enum TowerPhone {
    struct RelayChip: Equatable {
        enum Tone: Equatable { case good, working, quiet, bad }
        var text: String
        var tone: Tone
    }

    /// Pure. The relay state as a chip: connected, connecting, off, or what is misconfigured.
    static func relayChip(_ s: Coordinator.RelayState?) -> RelayChip {
        switch s {
        case .connected?: return RelayChip(text: "Relay connected", tone: .good)
        case .connecting?: return RelayChip(text: "Connecting to the relay…", tone: .working)
        case .off?, nil: return RelayChip(text: "Phone relay off", tone: .quiet)
        case .misconfigured(let why)?: return RelayChip(text: "Relay not set up · " + why, tone: .bad)
        }
    }
}
