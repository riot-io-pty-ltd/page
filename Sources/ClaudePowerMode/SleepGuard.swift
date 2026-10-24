import Foundation

/// Lid-closed-on-battery support (opt-in): `sudo -n /usr/bin/pmset -a
/// disablesleep 1` while agents are working, `0` the moment that stops being
/// safe.
///
/// No IOKit assertion keeps a Mac awake with the lid closed on battery —
/// `PreventSystemSleep` is honoured on AC only — so the only lever is the
/// system-wide `disablesleep` flag. That flag outlives the process that set
/// it, which makes it dangerous: left at 1, a closed MacBook in a bag never
/// sleeps and cooks its battery. So:
///
/// - it is only ever set while every condition in `SleepGuardPolicy` holds
///   (an agent mid-turn — not merely a rate-limit, page or prompt hold — on
///   battery, comfortably above the cutoff, not hot, sudo rule installed,
///   watchdog loaded) and cleared as soon as any fails;
/// - a marker file is written *before* setting it and removed only *after*
///   clearing it succeeded, so "Page may have left it on" is always on disk;
///   while the flag is on Page refreshes the marker's mtime on every pass;
/// - it is cleared on quit, on SIGTERM/SIGINT (after which nothing can set
///   it again), and on launch if the marker survived a crash;
/// - a per-user LaunchAgent watchdog (`local.Page.sleepguard`) clears it
///   within a minute if the marker exists and Page isn't running at all, or
///   if Page has stopped refreshing the marker (hung) for 3 minutes.
///
/// The sudoers rule (`./install.sh --enable-power-helpers`) allows exactly
/// `/usr/bin/pmset -a disablesleep 0` and `... 1` — nothing else.
enum SleepGuardPolicy {
    /// Turning the flag on needs the battery this many points above the
    /// low-battery cutoff. Once on, it stays on down to the cutoff, where the
    /// battery pause trips, and through the pause's grace period, so the
    /// agents are asked to pause (and can write their summary) with the lid
    /// closed instead of the Mac dropping asleep mid-turn before the trip.
    static let batteryMargin = 5
    /// Never keep the flag at or below this charge, whatever the phase (the
    /// cutoff can be configured as low as 0%).
    static let hardFloor = 5

    struct Inputs: Equatable {
        var enabled: Bool
        /// Page holds the idle-sleep assertion (false when the battery
        /// policy blocks it).
        var boosting: Bool
        /// Some session is actually mid-turn. Holding for a rate-limit reset,
        /// a pending page or a waiting prompt keeps the assertion (lid open)
        /// but must not keep a closed Mac awake.
        var agentsWorking: Bool
        var power: PowerSnapshot
        var cutoff: Int
        var thermal: ProcessInfo.ThermalState
        var helperAvailable: Bool
        var batteryPhase: BatteryPolicy.Phase
        /// Page currently has the flag on (hysteresis + grace hand-off).
        var currentlyActive: Bool
        /// The watchdog LaunchAgent is loaded: never disable sleep without
        /// the safety net.
        var watchdogLoaded: Bool
    }

    /// Nil when sleep should be disabled; otherwise why not (for the menu
    /// and logs).
    static func blocker(_ i: Inputs) -> String? {
        if !i.enabled { return "option off" }
        if !i.power.hasBattery { return "no battery" }
        if i.power.onAC { return "on AC" }
        if i.thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return "the Mac is running hot" }
        let pct = i.power.percent
        if pct <= hardFloor { return "battery at \(pct)%" }
        switch i.batteryPhase {
        case .drained:
            return "battery at \(pct)% — the low-battery pause is over"
        case .grace:
            // Hand-off to the battery pause: keep a flag that is already on
            // (bounded by the grace period), never turn it on here.
            if !i.currentlyActive { return "battery at \(pct)% — agents are pausing" }
            if !i.boosting { return "agents aren’t working" }
        case .normal:
            if !i.boosting || !i.agentsWorking { return "agents aren’t working" }
            let floor = i.currentlyActive ? i.cutoff : i.cutoff + batteryMargin
            if pct <= floor {
                return "battery at \(pct)% (needs above \(i.cutoff + batteryMargin)%)"
            }
        }
        if !i.watchdogLoaded { return "the sleep watchdog isn’t loaded" }
        if !i.helperAvailable { return "the power helper isn’t installed" }
        return nil
    }

    static func shouldDisableSleep(_ i: Inputs) -> Bool { blocker(i) == nil }
}

/// Generates the watchdog LaunchAgent. Pure, so tests can write the files
/// into a temp directory and lint them without loading anything.
enum SleepGuardWatchdog {
    static let label = "local.Page.sleepguard"
    static let interval = 60

    /// Page refreshes the marker's mtime on every power pass (at least every
    /// 15 s) while the flag is on; a marker older than this means Page is
    /// alive but hung, and the watchdog clears the flag anyway.
    static let staleMarkerMinutes = 3

    /// /bin/sh script: if the marker exists and either no Page process of
    /// this user is running or the marker hasn't been refreshed for
    /// `staleMarkerMinutes` (Page hung), clear disablesleep and remove the
    /// marker.
    ///
    /// Page is matched by its bundle executable path (`…/Contents/MacOS/Page`)
    /// rather than `pgrep -x Page`, which would also match the iOS Page app
    /// running in the Simulator and leave the flag on. `ClaudePowerMode` is
    /// the `swift run` / legacy binary name.
    static func script(markerPath: String) -> String {
        """
        #!/bin/sh
        # Generated by Page (\(label)). Safety net for the "keep working with the
        # lid closed on battery" option: if Page is gone (crash, force quit) or
        # hung, but left `pmset disablesleep 1` behind, undo it.
        # Removed automatically when the option is turned off.
        MARKER=\(ProcessRunner.shellQuote(markerPath))
        [ -f "$MARKER" ] || exit 0
        WHY="Page was not running"
        if [ -n "$(/usr/bin/find "$MARKER" -mmin +\(staleMarkerMinutes) 2>/dev/null)" ]; then
            WHY="Page stopped refreshing its marker for \(staleMarkerMinutes) minutes (hung?)"
        else
            ME="$(/usr/bin/id -u)"
            if /usr/bin/pgrep -U "$ME" -f '/Contents/MacOS/Page( |$)' >/dev/null 2>&1; then exit 0; fi
            if /usr/bin/pgrep -U "$ME" -x ClaudePowerMode >/dev/null 2>&1; then exit 0; fi
        fi
        if /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0; then
            /bin/rm -f "$MARKER"
            echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') $WHY — cleared disablesleep"
        else
            echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') $WHY but disablesleep could not be cleared (sudo rule missing?)" >&2
        fi
        exit 0

        """
    }

    static func plist(scriptPath: String, logPath: String) throws -> Data {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/sh", scriptPath],
            "StartInterval": interval,
            "RunAtLoad": true,
            "ProcessType": "Background",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath
        ]
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }
}

final class SleepGuard {
    typealias Runner = (_ path: String, _ args: [String], _ timeout: TimeInterval) -> ProcessRunner.Result

    enum HelperStatus: Equatable {
        case unknown
        case available
        case missing
    }

    struct Paths {
        let marker: URL
        let script: URL
        let launchAgent: URL
        let log: URL

        static var live: Paths {
            let support = Config.configURL.deletingLastPathComponent()
            let home = FileManager.default.homeDirectoryForCurrentUser
            return Paths(
                marker: support.appendingPathComponent("disablesleep.active"),
                script: support.appendingPathComponent("sleepguard.sh"),
                launchAgent: home.appendingPathComponent("Library/LaunchAgents/\(SleepGuardWatchdog.label).plist"),
                log: home.appendingPathComponent("Library/Logs/Page.sleepguard.log")
            )
        }
    }

    static let sudo = "/usr/bin/sudo"
    static let pmset = "/usr/bin/pmset"
    static let launchctl = "/bin/launchctl"
    static let installCommand = "./install.sh --enable-power-helpers"
    /// How long a helper check is trusted. The rule only changes when the
    /// user runs install.sh, so re-asking sudo every tick would be waste.
    static let helperCacheSeconds: TimeInterval = 300

    /// While the helper is missing, a failing clear is retried at most this
    /// often instead of on every 15 s pass (quit and launch always try).
    static let missingHelperRetrySeconds: TimeInterval = 60

    static func pmsetArgs(_ on: Bool) -> [String] { ["-n", pmset, "-a", "disablesleep", on ? "1" : "0"] }

    /// Whether `pmset -g` output shows `disablesleep` off. macOS lists a
    /// `SleepDisabled` line only while it is on; output that doesn't look
    /// like `pmset -g` at all, or any non-zero value, counts as "not off"
    /// (fail closed).
    static func sleepDisabledIsOff(pmsetOutput out: String) -> Bool {
        guard out.contains("System-wide power settings:") || out.contains("Currently in use:") else { return false }
        for line in out.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let i = fields.firstIndex(where: { $0.caseInsensitiveCompare("SleepDisabled") == .orderedSame }) else { continue }
            guard i + 1 < fields.count, fields[i + 1] == "0" else { return false }
        }
        return true
    }

    let paths: Paths
    private let runner: Runner
    private let uid: uid_t
    private let now: () -> Date
    private let sleeper: (TimeInterval) -> Void

    private let lock = NSLock()
    /// `pmset disablesleep 1` succeeded and no clear has succeeded since.
    private var _flagOn = false
    /// A clear failed (or a leftover marker couldn't be cleared): the flag
    /// may be on, nobody can vouch for it, and every pass retries.
    private var _cleanupPending = false
    /// One-way: set on quit / SIGTERM / SIGINT. After it nothing may set the
    /// flag again (a tick racing the shutdown would otherwise re-enable it).
    private var sealed = false
    private var _watchdogLoaded = false
    private var lastClearAttemptAt: Date = .distantPast
    private var helper: HelperStatus = .unknown
    private var helperCheckedAt: Date = .distantPast
    private var lastFailureLogAt: Date = .distantPast

    init(paths: Paths = .live,
         uid: uid_t = getuid(),
         now: @escaping () -> Date = Date.init,
         sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         runner: @escaping Runner = { ProcessRunner.run($0, $1, timeout: $2) }) {
        self.paths = paths
        self.uid = uid
        self.now = now
        self.sleeper = sleeper
        self.runner = runner
    }

    /// True while Page has `disablesleep 1` in force and knows it (the menu
    /// may say "lid can be closed"). False while a clear is failing, even if
    /// the flag might still be on — see `cleanupPending`.
    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return _flagOn && !_cleanupPending
    }

    /// Clearing the flag failed and is being retried: the Mac may not sleep
    /// with the lid closed, and Page can't vouch for its battery checks.
    var cleanupPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cleanupPending
    }

    /// The watchdog LaunchAgent was loaded by the last install/sync.
    var watchdogLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return _watchdogLoaded
    }

    // MARK: helper (sudo rule)

    /// Whether `sudo -n` may run both pmset commands. Cached; pass
    /// `refresh: true` after the user may have run install.sh. Blocking
    /// (runs sudo -l) — call off the main thread.
    func helperStatus(refresh: Bool = false) -> HelperStatus {
        lock.lock(); defer { lock.unlock() }
        return helperStatusLocked(refresh: refresh)
    }

    /// The cached answer only; never spawns anything (for the UI thread).
    var cachedHelperStatus: HelperStatus {
        lock.lock(); defer { lock.unlock() }
        return helper
    }

    private func helperStatusLocked(refresh: Bool) -> HelperStatus {
        if !refresh, helper != .unknown, now().timeIntervalSince(helperCheckedAt) < Self.helperCacheSeconds {
            return helper
        }
        // `sudo -n -l <command>` exits 0 only if that exact command is
        // permitted without a password. Never prompts.
        let ok = [false, true].allSatisfy { on in
            runner(Self.sudo, ["-n", "-l", Self.pmset, "-a", "disablesleep", on ? "1" : "0"], 5).succeeded
        }
        helper = ok ? .available : .missing
        helperCheckedAt = now()
        return helper
    }

    // MARK: disablesleep

    /// Idempotent; call every pass with the policy's answer.
    func update(shouldDisableSleep wantIn: Bool, reason: String) {
        lock.lock(); defer { lock.unlock() }
        let want = wantIn && !sealed
        let markerExists = FileManager.default.fileExists(atPath: paths.marker.path)
        if _cleanupPending, flagReadsOffLocked() {
            // Cleared by hand (the menu's fix) or by the watchdog/installer:
            // nothing left to retry, and the warning can go.
            try? FileManager.default.removeItem(at: paths.marker)
            _cleanupPending = false
            _flagOn = false
            Logger.shared.log("pmset disablesleep is off (pmset -g) — stopped retrying the clear")
        }
        if _cleanupPending {
            // Never re-enable over a clear that keeps failing; keep retrying
            // it (backed off while the sudo rule is known to be gone).
            if helperStatusLocked(refresh: false) == .missing,
               now().timeIntervalSince(lastClearAttemptAt) < Self.missingHelperRetrySeconds {
                return
            }
            _ = disableLocked(reason: reason)
            return
        }
        if _flagOn && !markerExists {
            // Someone else cleared it and removed the marker (the watchdog
            // after a hang, install.sh): the flag is off now.
            _flagOn = false
            Logger.shared.log("Lid-closed-on-battery: the marker was removed outside Page — treating disablesleep as off")
        }
        if want && !_flagOn {
            enableLocked(reason: reason)
        } else if want && _flagOn {
            // Heartbeat for the watchdog's hung-Page check.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: paths.marker.path)
        } else if !want && _flagOn {
            _ = disableLocked(reason: reason)
        }
    }

    /// Clears disablesleep if Page set it (or a marker says a previous run
    /// did). Safe from any thread, including a signal handler's queue; never
    /// touches the Coordinator's queues. Does not prevent a later `update`
    /// from enabling again (used at launch) — see `sealAndDisable`.
    @discardableResult
    func forceDisable(reason: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return forceDisableLocked(reason: reason)
    }

    /// Quit / signal path: clears the flag like `forceDisable` and, in the
    /// same locked step, makes every later `update` unable to set it again.
    /// One-way — only for a process that is going away.
    @discardableResult
    func sealAndDisable(reason: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        sealed = true
        return forceDisableLocked(reason: reason)
    }

    var isSealed: Bool {
        lock.lock(); defer { lock.unlock() }
        return sealed
    }

    /// Reads the real flag without sudo. Only a clear "off" counts.
    private func flagReadsOffLocked() -> Bool {
        let r = runner(Self.pmset, ["-g"], 5)
        return r.succeeded && Self.sleepDisabledIsOff(pmsetOutput: r.stdout)
    }

    private func forceDisableLocked(reason: String) -> Bool {
        guard _flagOn || _cleanupPending || FileManager.default.fileExists(atPath: paths.marker.path) else { return true }
        return disableLocked(reason: reason)
    }

    private func enableLocked(reason: String) {
        // Marker first: if Page dies between here and the pmset call, the
        // watchdog / next launch still knows to clear the flag.
        do {
            try FileManager.default.createDirectory(at: paths.marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: now())
            try Data("pid \(getpid()) at \(stamp)\n".utf8).write(to: paths.marker, options: .atomic)
        } catch {
            Logger.shared.log("Lid-closed-on-battery: couldn't write \(paths.marker.lastPathComponent) (\(error.localizedDescription)) — not disabling sleep")
            return
        }
        let r = runner(Self.sudo, Self.pmsetArgs(true), 10)
        if r.succeeded {
            _flagOn = true
            Logger.shared.log("Lid-closed-on-battery ON (pmset disablesleep 1) — \(reason)")
            return
        }
        Logger.shared.log("Lid-closed-on-battery: pmset disablesleep 1 failed (status \(r.status)\(r.timedOut ? ", timed out" : "")) — is the power helper installed? (\(Self.installCommand))")
        // Assume the rule is gone so we don't retry every tick, and make
        // sure a half-applied (e.g. timed-out) call didn't leave the flag
        // on. Page never knew the flag to be on, so `_flagOn` stays false;
        // if the clear fails too, `cleanupPending` keeps it retried.
        helper = .missing
        helperCheckedAt = now()
        _cleanupPending = true
        _ = disableLocked(reason: "enable failed")
    }

    private func disableLocked(reason: String) -> Bool {
        lastClearAttemptAt = now()
        let r = runner(Self.sudo, Self.pmsetArgs(false), 10)
        if r.succeeded {
            try? FileManager.default.removeItem(at: paths.marker)
            if _flagOn {
                Logger.shared.log("Lid-closed-on-battery OFF (pmset disablesleep 0) — \(reason)")
            } else {
                Logger.shared.log("Cleared pmset disablesleep left on by an earlier Page run — \(reason)")
            }
            _flagOn = false
            _cleanupPending = false
            return true
        }
        // Keep the marker and mark the clear as pending — the flag may well
        // be on (e.g. a leftover found at launch) — so every pass retries;
        // the watchdog retries too once Page is gone.
        _cleanupPending = true
        if now().timeIntervalSince(lastFailureLogAt) > 300 {
            lastFailureLogAt = now()
            Logger.shared.log("⚠ pmset disablesleep 0 FAILED (status \(r.status)\(r.timedOut ? ", timed out" : "")) — the Mac may not sleep with the lid closed. Will retry. Fix by hand: sudo pmset -a disablesleep 0")
        }
        return false
    }

    // MARK: watchdog LaunchAgent

    /// Installs (option on) or removes (option off) the watchdog. Idempotent
    /// and cheap when nothing changes. Blocking (launchctl).
    func syncWatchdog(enabled: Bool) {
        if enabled {
            do { try installWatchdog() } catch {
                setWatchdogLoaded(false)
                Logger.shared.log("Couldn't install the sleep watchdog: \(error.localizedDescription)")
            }
        } else if FileManager.default.fileExists(atPath: paths.marker.path) {
            // The flag may still be on (clearing it failed): keep the safety
            // net until it's really off; a later sync removes it.
            return
        } else {
            uninstallWatchdog()
        }
    }

    private var domain: String { "gui/\(uid)" }
    private var service: String { "\(domain)/\(SleepGuardWatchdog.label)" }

    private func setWatchdogLoaded(_ loaded: Bool) {
        lock.lock(); _watchdogLoaded = loaded; lock.unlock()
    }

    func installWatchdog() throws {
        let fm = FileManager.default
        let script = Data(SleepGuardWatchdog.script(markerPath: paths.marker.path).utf8)
        let plist = try SleepGuardWatchdog.plist(scriptPath: paths.script.path, logPath: paths.log.path)

        let unchanged = (try? Data(contentsOf: paths.script)) == script
            && (try? Data(contentsOf: paths.launchAgent)) == plist
        if unchanged && runner(Self.launchctl, ["print", service], 5).succeeded {
            setWatchdogLoaded(true)
            return
        }

        try fm.createDirectory(at: paths.script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: paths.script, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.script.path)
        try plist.write(to: paths.launchAgent, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.launchAgent.path)

        // Reload so launchd picks up a changed plist. bootout of a service
        // that isn't loaded fails harmlessly. A bootstrap straight after a
        // bootout can fail ("Bootstrap failed: 5") while launchd is still
        // tearing the job down, so wait until it's really gone, then retry.
        _ = runner(Self.launchctl, ["bootout", service], 10)
        for _ in 0..<10 {
            if !runner(Self.launchctl, ["print", service], 5).succeeded { break }
            sleeper(0.5)
        }
        var r = runner(Self.launchctl, ["bootstrap", domain, paths.launchAgent.path], 10)
        for _ in 0..<2 where !r.succeeded {
            sleeper(1)
            r = runner(Self.launchctl, ["bootstrap", domain, paths.launchAgent.path], 10)
        }
        setWatchdogLoaded(r.succeeded)
        if r.succeeded {
            Logger.shared.log("Installed the sleep watchdog (\(SleepGuardWatchdog.label))")
        } else {
            Logger.shared.log("launchctl bootstrap of the sleep watchdog failed (status \(r.status)): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) — lid-closed-on-battery stays off until it loads")
        }
    }

    func uninstallWatchdog() {
        setWatchdogLoaded(false)
        let fm = FileManager.default
        let present = fm.fileExists(atPath: paths.launchAgent.path) || fm.fileExists(atPath: paths.script.path)
        guard present else { return }
        _ = runner(Self.launchctl, ["bootout", service], 10)
        try? fm.removeItem(at: paths.launchAgent)
        try? fm.removeItem(at: paths.script)
        Logger.shared.log("Removed the sleep watchdog (\(SleepGuardWatchdog.label))")
    }
}
