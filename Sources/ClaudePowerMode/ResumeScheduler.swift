import Foundation

struct ScheduledResume: Codable, Equatable {
    let sessionId: String
    /// The session's launch directory (where `claude --resume` finds it).
    let cwd: String
    let projectName: String
    let resetTime: Date
    let prompt: String
    let plistPath: String
    let logPath: String
    let label: String
    let createdAt: Date
    // Added later; optional so sidecars written by older builds still decode.
    /// When the job actually fires (the next whole minute at/after reset + buffer).
    var runAt: Date? = nil
    var scriptPath: String? = nil
    var transcriptPath: String? = nil
    var claudePath: String? = nil
    /// "MM/dd/yyyy HH:mm:ss" stamp of the pmset wake we scheduled, if any.
    var wakeStamp: String? = nil

    var effectiveRunAt: Date { runAt ?? resetTime.addingTimeInterval(60) }
}

/// Outcome a fired resume job reports back (one JSON file per run in
/// `resultsDir`), so the app can tell the user what happened instead of the
/// result living only in a log file nobody reads.
struct ResumeResult: Codable, Equatable {
    enum Outcome: String, Codable {
        case resumed          // claude --resume --print exited 0
        case failed           // non-zero exit / missing dir / missing claude
        case timedOut = "timed_out"
        case skippedLive = "skipped_live"  // session still open; the app continues those itself
        case expired          // fired far too late (asleep for hours) or in a later year
        case cancelled        // unloaded while running (Cancel in the menu)
    }
    let sessionId: String
    let outcome: Outcome
    let exitCode: Int
    let finishedAt: Date
    let logPath: String
    /// Short human-readable reason ("No conversation found", ...), if any.
    var detail: String? = nil
}

/// Manages one-shot launchd jobs that "carry on" a rate-limited Claude
/// session after its limit resets.
///
/// Each resume is three files: a sidecar JSON (what the menu lists), a
/// generated bash script, and a LaunchAgent plist that runs the script at a
/// calendar minute. The script — not the app — does the work, so a resume
/// still fires if the app has quit or crashed. When it fires it:
/// - exits without doing anything if the session is still open in a terminal
///   (the Mac app types the prompt into live sessions itself; a headless
///   `--print` run would fork the conversation behind the open TUI's back);
/// - otherwise runs `claude --resume <id> --print <prompt>` from the
///   session's launch directory, with a timeout, logging to
///   ~/Library/Logs/ClaudePowerMode-resumes;
/// - always removes its plist, sidecar and script and unloads itself.
final class ResumeScheduler {
    static let scheduledDir: URL = appSupportSubdir("scheduled")
    static let resultsDir: URL = appSupportSubdir("resume-results")
    static let logsDir: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("ClaudePowerMode-resumes", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    static let launchAgentsDir: URL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LaunchAgents", isDirectory: true)

    private static func appSupportSubdir(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudePowerMode", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static let labelPrefix = "local.ClaudePowerMode.resume."
    /// Resume jobs written under the app's earlier names; swept as orphans.
    static let legacyLabelPrefixes = ["local.Page.resume.", "local.PageAI.resume."]

    /// How late a job may still run (launchd runs missed calendar jobs on
    /// wake). Past this, "carry on" would surprise more than help.
    static let maxLateness: TimeInterval = 12 * 3600
    /// Hard cap on one background `claude --print` run.
    static let runTimeout: TimeInterval = 3600

    enum ScheduleError: Error, LocalizedError, Equatable {
        case resetAlreadyPassed(Date)
        case resetTimeUnknown
        case unsupportedBackend(String)
        case invalidSessionId(String)
        case transcriptMissing(String)
        case projectDirectoryNotFound(String)
        case claudeNotFound
        case launchctlFailed(String)

        var errorDescription: String? {
            switch self {
            case .resetAlreadyPassed(let t): return "Reset time \(t) has already passed — refusing to schedule"
            case .resetTimeUnknown: return "Claude didn't say when this limit resets — not scheduling an automatic resume"
            case .unsupportedBackend(let b): return "Automatic resume isn't supported for \(b) sessions yet"
            case .invalidSessionId(let id): return "Unexpected session id \"\(id.prefix(40))\" — refusing to schedule"
            case .transcriptMissing(let p): return "The session's transcript is gone (\(p))"
            case .projectDirectoryNotFound(let d): return "Couldn't find the folder this session was started in (\(d))"
            case .claudeNotFound: return "Couldn't find the claude command-line tool (looked in ~/.local/bin, Homebrew, npm and nvm)"
            case .launchctlFailed(let msg): return "launchctl couldn't load the resume job: \(msg)"
            }
        }
    }

    /// Runs a helper (launchctl, sudo pmset). Injectable so tests never touch
    /// the real launchd domain or power schedule.
    typealias CommandRunner = (_ path: String, _ args: [String]) -> ProcessRunner.Result

    let scheduledDir: URL
    let resultsDir: URL
    let logsDir: URL
    let launchAgentsDir: URL
    let sessionsDir: String
    private let runCommand: CommandRunner
    private let launchctlPath: String
    private let lock = NSLock()
    /// listScheduled() runs every tick; re-read only when the directory
    /// changed (the job's `rm` and our atomic writes both bump its mtime).
    private var listCache: (mtime: Date, items: [ScheduledResume])?

    init(
        scheduledDir: URL = ResumeScheduler.scheduledDir,
        resultsDir: URL = ResumeScheduler.resultsDir,
        logsDir: URL = ResumeScheduler.logsDir,
        launchAgentsDir: URL = ResumeScheduler.launchAgentsDir,
        sessionsDir: String = NSHomeDirectory() + "/.claude/sessions",
        launchctlPath: String = "/bin/launchctl",
        runCommand: @escaping CommandRunner = { ProcessRunner.run($0, $1, timeout: 15) }
    ) {
        self.scheduledDir = scheduledDir
        self.resultsDir = resultsDir
        self.logsDir = logsDir
        self.launchAgentsDir = launchAgentsDir
        self.sessionsDir = sessionsDir
        self.launchctlPath = launchctlPath
        self.runCommand = runCommand
        for dir in [scheduledDir, resultsDir, logsDir, launchAgentsDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Public API

    /// Schedules (or re-confirms) a resume for `event`. Idempotent per
    /// session: re-scheduling the same reset returns the existing job
    /// untouched; a different reset replaces it.
    @discardableResult
    func schedule(
        event: RateLimitEvent,
        prompt: String,
        bufferSeconds: Int = 5,
        wakeViaPmset: Bool = false,
        pmsetPath: String = "/usr/bin/pmset",
        claudeBinaryPath: String? = nil,
        allowEstimatedReset: Bool = false,
        now: Date = Date()
    ) throws -> ScheduledResume {
        lock.lock()
        defer { lock.unlock() }

        guard event.backend == .claude else {
            throw ScheduleError.unsupportedBackend(event.backend.rawValue)
        }
        guard !event.resetTimeIsEstimated || allowEstimatedReset else {
            throw ScheduleError.resetTimeUnknown
        }
        let sessionId = event.sessionId
        guard Self.isSafeSessionId(sessionId) else { throw ScheduleError.invalidSessionId(sessionId) }

        let runAt = event.resetTime.addingTimeInterval(TimeInterval(bufferSeconds))
        // A moment already in the past would make launchd wait for the
        // calendar to wrap (a year). Better to refuse and let the user decide.
        if runAt < now {
            Logger.shared.log("Refusing to schedule resume for \(sessionId.prefix(8)): reset time \(runAt) already passed")
            throw ScheduleError.resetAlreadyPassed(runAt)
        }
        let fireAt = Self.launchdFireDate(for: runAt, now: now)

        if !event.transcriptPath.isEmpty && !FileManager.default.fileExists(atPath: event.transcriptPath) {
            throw ScheduleError.transcriptMissing(event.transcriptPath)
        }
        guard let workdir = Self.resolveWorkingDirectory(for: event) else {
            throw ScheduleError.projectDirectoryNotFound(event.cwd)
        }
        guard let claude = ProcessRunner.findExecutable("claude", configured: claudeBinaryPath) else {
            throw ScheduleError.claudeNotFound
        }

        let label = Self.labelPrefix + sessionId
        let plistURL = launchAgentsDir.appendingPathComponent("\(label).plist")
        let scriptURL = scriptURL(forSessionId: sessionId)

        let existing = readSidecar(sessionId: sessionId)
        if let existing,
           abs(existing.resetTime.timeIntervalSince(event.resetTime)) < 1,
           existing.prompt == prompt,
           existing.effectiveRunAt > now,
           let script = existing.scriptPath,
           FileManager.default.fileExists(atPath: script),
           FileManager.default.fileExists(atPath: existing.plistPath) {
            return existing
        }
        if let stamp = existing?.wakeStamp { cancelWake(stamp: stamp, pmsetPath: pmsetPath) }

        let logPath = logsDir
            .appendingPathComponent("\(Self.filenameStamp(fireAt))-\(sessionId.prefix(8)).log").path
        var scheduled = ScheduledResume(
            sessionId: sessionId,
            cwd: workdir,
            projectName: URL(fileURLWithPath: workdir).lastPathComponent,
            resetTime: Self.wholeSecond(event.resetTime),
            prompt: prompt,
            plistPath: plistURL.path,
            logPath: logPath,
            label: label,
            createdAt: Self.wholeSecond(now),
            runAt: fireAt,
            scriptPath: scriptURL.path,
            transcriptPath: event.transcriptPath.isEmpty ? nil : event.transcriptPath,
            claudePath: claude
        )

        // Sidecar first: purgeStale treats a resume plist without a sidecar
        // as an orphan, so it must never observe the plist alone.
        try saveSidecar(scheduled)
        do {
            let script = Self.makeScript(Self.ScriptValues(
                label: label,
                plistPath: plistURL.path,
                sidecarPath: sidecarURL(forSessionId: sessionId).path,
                scriptPath: scriptURL.path,
                logPath: logPath,
                resultPath: resultsDir.appendingPathComponent("\(sessionId)-\(Int(fireAt.timeIntervalSince1970)).json").path,
                sessionId: sessionId,
                workdir: workdir,
                claudePath: claude,
                prompt: prompt,
                sessionsDir: sessionsDir,
                launchctlPath: launchctlPath,
                targetEpoch: Int(runAt.timeIntervalSince1970.rounded(.up)),
                targetYear: Self.calendar.component(.year, from: fireAt),
                maxLateSeconds: Int(Self.maxLateness),
                runTimeoutSeconds: Int(Self.runTimeout)
            ))
            try Data(script.utf8).write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            try writePlist(label: label, plistURL: plistURL, scriptPath: scriptURL.path, fireAt: fireAt, logPath: logPath)
            try bootstrap(label: label, plistPath: plistURL.path)
        } catch {
            _ = bootout(label: label)
            for path in [plistURL.path, scriptURL.path, sidecarURL(forSessionId: sessionId).path] {
                try? FileManager.default.removeItem(atPath: path)
            }
            listCache = nil
            throw error
        }

        if wakeViaPmset {
            // Wake a minute early so the system is fully up when the job fires.
            scheduled.wakeStamp = scheduleWake(at: fireAt.addingTimeInterval(-60), pmsetPath: pmsetPath)
            try? saveSidecar(scheduled)
        }
        listCache = nil
        Logger.shared.log("Scheduled resume \(label) for \(fireAt) (reset \(event.resetTime)) → \(workdir)")
        return scheduled
    }

    func cancel(_ scheduled: ScheduledResume) {
        lock.lock()
        defer { lock.unlock() }
        removeArtifacts(of: scheduled)
        if let stamp = scheduled.wakeStamp { cancelWake(stamp: stamp, pmsetPath: "/usr/bin/pmset") }
        Logger.shared.log("Cancelled scheduled resume \(scheduled.label)")
    }

    /// Cancels whatever resume is scheduled for `sessionId` (e.g. the session
    /// replied again, so the limit is over). No-op when there is none.
    func cancel(sessionId: String) {
        guard let s = listScheduled().first(where: { $0.sessionId == sessionId }) else { return }
        cancel(s)
    }

    /// Upcoming (or just-due) resumes, soonest first. Cheap enough to call
    /// every tick: re-reads sidecars only when the directory changed.
    func listScheduled(now: Date = Date()) -> [ScheduledResume] {
        lock.lock()
        defer { lock.unlock() }
        return allSidecars()
            .filter { $0.effectiveRunAt.addingTimeInterval(15 * 60) > now }
            .sorted { $0.effectiveRunAt < $1.effectiveRunAt }
    }

    /// Resumes whose fire time has come. The app should type the prompt into
    /// live sessions itself and then `cancel` them (the job would skip a live
    /// session anyway); for ended sessions the job's background resume runs.
    func dueResumes(now: Date = Date()) -> [ScheduledResume] {
        listScheduled(now: now).filter { $0.effectiveRunAt <= now }
    }

    /// Results reported by fired jobs since the last call (each is returned
    /// once; the files are deleted).
    func collectResults() -> [ResumeResult] {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: resultsDir, includingPropertiesForKeys: nil) else { return [] }
        var out: [ResumeResult] = []
        for url in entries where url.pathExtension == "json" {
            defer { try? fm.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                out.append(try Self.resultDecoder.decode(ResumeResult.self, from: data))
            } catch {
                Logger.shared.log("Ignoring unreadable resume result \(url.lastPathComponent): \(error)")
            }
        }
        return out.sorted { $0.finishedAt < $1.finishedAt }
    }

    /// Removes resumes that are over and anything orphaned: sidecars whose
    /// job can no longer be running (fire time + the script's own lateness
    /// window + run timeout + grace), unreadable sidecars, resume plists
    /// (current and legacy label prefixes) with no live sidecar — including
    /// jobs left loaded by older builds whose scripts booted themselves out
    /// before cleaning up — orphan scripts, and resume logs older than two
    /// weeks. A job launchd reports as running is never touched: an app
    /// restart mid-run must not kill a background resume.
    func purgeStale(graceSeconds: TimeInterval = 600, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        var liveLabels = Set<String>()
        var liveScripts = Set<String>()
        let prefixes = [Self.labelPrefix] + Self.legacyLabelPrefixes
        let listing = runCommand(launchctlPath, ["list"])
        let loaded = listing.succeeded ? Self.loadedJobs(fromLaunchctlList: listing.stdout, prefixes: prefixes) : []
        let running = Set(loaded.filter { $0.pid != nil }.map(\.label))
        let staleAfter = Self.maxLateness + Self.runTimeout + graceSeconds

        // 1. Sidecars.
        let sidecars = (try? fm.contentsOfDirectory(at: scheduledDir, includingPropertiesForKeys: nil)) ?? []
        for url in sidecars where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let s = try? Self.sidecarDecoder.decode(ScheduledResume.self, from: data) else {
                if Self.age(of: url.path, now: now) > 60 {
                    Logger.shared.log("Removing unreadable resume sidecar \(url.lastPathComponent)")
                    try? fm.removeItem(at: url)
                }
                continue
            }
            if s.effectiveRunAt.addingTimeInterval(staleAfter) < now && !running.contains(s.label) {
                Logger.shared.log("Purging stale scheduled resume \(s.label) (was due \(s.effectiveRunAt))")
                removeArtifacts(of: s)
            } else {
                liveLabels.insert(s.label)
                // By name: directory listings may spell the path differently
                // (/var vs /private/var).
                liveScripts.insert(URL(fileURLWithPath: s.scriptPath ?? scriptURL(forSessionId: s.sessionId).path).lastPathComponent)
            }
        }

        // 2. Resume plists without a live sidecar.
        let plists = (try? fm.contentsOfDirectory(at: launchAgentsDir, includingPropertiesForKeys: nil)) ?? []
        for url in plists where url.pathExtension == "plist" {
            let label = url.deletingPathExtension().lastPathComponent
            guard prefixes.contains(where: { label.hasPrefix($0) }),
                  !liveLabels.contains(label), !running.contains(label) else { continue }
            // Mid-schedule from another instance: give it a moment.
            guard Self.age(of: url.path, now: now) > 60 else { continue }
            Logger.shared.log("Removing orphaned resume job \(label)")
            _ = bootout(label: label)
            try? fm.removeItem(at: url)
        }

        // 3. Jobs still loaded in launchd whose plist is already gone.
        for job in loaded where job.pid == nil && !liveLabels.contains(job.label) {
            Logger.shared.log("Unloading leftover resume job \(job.label)")
            _ = bootout(label: job.label)
        }

        // 4. Orphan scripts; 5. old logs and unclaimed results.
        for url in sidecars where url.pathExtension == "sh" && !liveScripts.contains(url.lastPathComponent) {
            if Self.age(of: url.path, now: now) > 60 { try? fm.removeItem(at: url) }
        }
        for (dir, maxAge) in [(logsDir, 14.0 * 86_400), (resultsDir, 7.0 * 86_400)] {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in files where Self.age(of: url.path, now: now) > maxAge {
                try? fm.removeItem(at: url)
            }
        }
        listCache = nil
    }

    // MARK: - Pure helpers (unit-tested)

    /// launchd evaluates StartCalendarInterval in local time; follow the
    /// user's current zone even if it changes while the app runs.
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "en_US_POSIX")
        c.timeZone = .autoupdatingCurrent
        return c
    }

    /// launchd's StartCalendarInterval has minute granularity, fires at
    /// second 0, and never matches the minute it's evaluated in. So: the
    /// first whole minute at/after `runAt`, at least a few seconds out so
    /// bootstrap latency can't push us into a year-long wait.
    static func launchdFireDate(for runAt: Date, now: Date) -> Date {
        var fire = Date(timeIntervalSince1970: (runAt.timeIntervalSince1970 / 60).rounded(.up) * 60)
        while fire.timeIntervalSince(now) < 5 { fire.addTimeInterval(60) }
        return fire
    }

    /// Session ids go into labels, file names and the script; Claude's are
    /// UUIDs. Anything else is refused rather than escaped.
    static func isSafeSessionId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128, !id.hasPrefix("."), !id.hasPrefix("-") else { return false }
        return id.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    /// The directory `claude --resume` must run in: the session's launch
    /// directory verified against its transcript's project folder. Falls
    /// back to the event's cwd (with a log line) only when it exists but
    /// can't be verified, e.g. transcripts kept outside ~/.claude/projects.
    static func resolveWorkingDirectory(for event: RateLimitEvent) -> String? {
        if !event.transcriptPath.isEmpty,
           let dir = TranscriptParser.launchDirectory(transcriptPath: event.transcriptPath, hintCwd: event.cwd) {
            return dir
        }
        guard !event.cwd.isEmpty, TranscriptParser.directoryExists(event.cwd) else { return nil }
        if !event.transcriptPath.isEmpty {
            Logger.shared.log("Resume for \(event.sessionId.prefix(8)): couldn't verify launch directory; using \(event.cwd)")
        }
        return event.cwd
    }

    /// The prompt as passed to `--print`: control characters (except \n and
    /// \t) stripped, and a leading "-" or "!" padded with a space so it can't
    /// be read as a flag or Claude's bash mode.
    static func sanitizePrompt(_ prompt: String) -> String {
        var s = String(String.UnicodeScalarView(prompt.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
        }))
        if s.hasPrefix("-") || s.hasPrefix("!") { s = " " + s }
        return s.isEmpty ? "carry on" : s
    }

    /// Resume jobs in `launchctl list` output ("PID\tStatus\tLabel"); `pid`
    /// is non-nil while the job is running.
    static func loadedJobs(fromLaunchctlList output: String, prefixes: [String]) -> [(label: String, pid: Int32?)] {
        output.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 3, let label = cols.last,
                  prefixes.contains(where: { label.hasPrefix($0) }) else { return nil }
            return (label, Int32(cols[0]))
        }
    }

    struct ScriptValues {
        var label: String
        var plistPath: String
        var sidecarPath: String
        var scriptPath: String
        var logPath: String
        var resultPath: String
        var sessionId: String
        var workdir: String
        var claudePath: String
        var prompt: String
        var sessionsDir: String
        var launchctlPath: String
        var targetEpoch: Int
        var targetYear: Int
        var maxLateSeconds: Int
        var runTimeoutSeconds: Int
    }

    /// The job script. Every value is a single-quoted shell literal assigned
    /// once at the top; nothing else is interpolated, so prompts with `$`,
    /// backticks or quotes reach claude verbatim and odd paths can't break
    /// out. No `set -e`: an EXIT trap guarantees cleanup on every path.
    static func makeScript(_ v: ScriptValues) -> String {
        let q = ProcessRunner.shellQuote
        let logJSON = jsonStringLiteral(v.logPath)
        return """
        #!/bin/bash
        # Page scheduled resume — generated by ResumeScheduler.swift; do not edit.
        # One-shot: carries on Claude Code session \(v.sessionId) after its rate
        # limit resets, then removes its LaunchAgent, sidecar and this script.
        set -u

        LABEL=\(q(v.label))
        PLIST=\(q(v.plistPath))
        SIDECAR=\(q(v.sidecarPath))
        SCRIPT=\(q(v.scriptPath))
        LOG=\(q(v.logPath))
        RESULT=\(q(v.resultPath))
        RESULT_LOG_JSON=\(q(logJSON))
        SESSION_ID=\(q(v.sessionId))
        WORKDIR=\(q(v.workdir))
        CLAUDE=\(q(v.claudePath))
        PROMPT=\(q(sanitizePrompt(v.prompt)))
        SESSIONS_DIR=\(q(v.sessionsDir))
        LAUNCHCTL=\(q(v.launchctlPath))
        TARGET_EPOCH=\(v.targetEpoch)
        TARGET_YEAR=\(v.targetYear)
        MAX_LATE_SECONDS=\(v.maxLateSeconds)
        RUN_TIMEOUT_SECONDS=\(v.runTimeoutSeconds)

        outcome="failed"
        rc=1
        detail=""
        keep_job=0

        log() { printf '[%s] %s\\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S %z')" "$*" >> "$LOG"; }

        finish() {
            trap - EXIT
            [ "$keep_job" = 1 ] && return
            # detail is one of our fixed phrases (no quotes/backslashes).
            printf '{"sessionId":"%s","outcome":"%s","exitCode":%d,"finishedAt":%d,"logPath":%s,"detail":"%s"}\\n' \\
                "$SESSION_ID" "$outcome" "$rc" "$(/bin/date +%s)" "$RESULT_LOG_JSON" "$detail" > "$RESULT.tmp" \\
                && /bin/mv -f "$RESULT.tmp" "$RESULT"
            /bin/rm -f "$PLIST" "$SIDECAR" "$SCRIPT"
            # Unload ourselves LAST: bootout SIGTERMs this job, so nothing
            # after it is guaranteed to run.
            "$LAUNCHCTL" bootout "gui/$(/usr/bin/id -u)/$LABEL" >/dev/null 2>&1
        }
        trap finish EXIT
        # Unloaded mid-run (the app's Cancel boots the job out): report that,
        # not a failure. finish() clears its own trap first, so the TERM from
        # our self-bootout at the very end doesn't rewrite the result.
        trap 'outcome="cancelled"; detail="Cancelled"; exit 143' TERM

        session_is_live() {
            local f sid pid cmd
            for f in "$SESSIONS_DIR"/*.json; do
                [ -f "$f" ] || continue
                sid=$(/usr/bin/plutil -extract sessionId raw -o - "$f" 2>/dev/null) || continue
                [ "$sid" = "$SESSION_ID" ] || continue
                pid=$(/usr/bin/plutil -extract pid raw -o - "$f" 2>/dev/null) || pid=$(/usr/bin/basename "$f" .json)
                case "$pid" in ''|*[!0-9]*) continue ;; esac
                /bin/kill -0 "$pid" 2>/dev/null || continue
                cmd=$(/bin/ps -p "$pid" -o command= 2>/dev/null) || continue
                case "$cmd" in *claude*) return 0 ;; esac
            done
            # A claude started with this id on its command line (e.g. the
            # app's own `claude --resume <id>`) whose sessions file is missing.
            /bin/ps -axww -o pid=,command= 2>/dev/null | ME="$$" SID="$SESSION_ID" SELF="$SCRIPT" /usr/bin/awk '
                $1 != ENVIRON["ME"] && index($0, ENVIRON["SID"]) && index($0, "claude") && !index($0, ENVIRON["SELF"]) { found = 1 }
                END { exit !found }'
        }

        now=$(/bin/date +%s)
        if [ "$(/bin/date +%Y)" != "$TARGET_YEAR" ] || [ "$now" -gt $((TARGET_EPOCH + MAX_LATE_SECONDS)) ]; then
            outcome="expired"; rc=0; detail="Fired too late to carry on"
            log "Not resuming session $SESSION_ID: fired at $(/bin/date) — too long after the reset. Cleaning up."
            exit 0
        fi
        if [ "$now" -lt "$TARGET_EPOCH" ]; then
            wait_s=$((TARGET_EPOCH - now))
            if [ "$wait_s" -gt 7200 ]; then
                # Matching Month/Day/Hour/Minute can't be this early unless the
                # clock jumped; leave the job armed for the real time.
                keep_job=1
                log "Fired ${wait_s}s before the reset (clock change?) — leaving the resume scheduled."
                exit 0
            fi
            /bin/sleep "$wait_s"
        fi

        if session_is_live; then
            outcome="skipped_live"; rc=0; detail="Session is still open in a terminal"
            log "Session $SESSION_ID is still open in a terminal — Page continues live sessions itself, so no background resume was started."
            exit 0
        fi

        if ! cd "$WORKDIR" 2>/dev/null; then
            detail="Project folder no longer exists"
            log "Can't resume $SESSION_ID: project folder $WORKDIR no longer exists."
            exit 1
        fi
        if [ ! -x "$CLAUDE" ]; then
            CLAUDE=$(command -v claude 2>/dev/null || true)
            if [ -z "$CLAUDE" ]; then
                detail="claude command not found"
                log "Can't resume $SESSION_ID: the claude command-line tool is no longer installed where it was."
                exit 1
            fi
        fi

        log "Resuming session $SESSION_ID in $WORKDIR with $CLAUDE (background --print run: tools that need approval will be denied)"
        "$CLAUDE" --resume "$SESSION_ID" --print "$PROMPT" >> "$LOG" 2>&1 < /dev/null &
        child=$!
        waited=0
        timed_out=0
        while /bin/kill -0 "$child" 2>/dev/null; do
            if [ "$waited" -ge "$RUN_TIMEOUT_SECONDS" ]; then
                timed_out=1
                /bin/kill -TERM "$child" 2>/dev/null
                break
            fi
            /bin/sleep 1
            waited=$((waited + 1))
        done
        wait "$child"
        rc=$?

        if [ "$timed_out" = 1 ]; then
            outcome="timed_out"; detail="Background resume ran too long and was stopped"
        elif [ "$rc" -eq 0 ]; then
            outcome="resumed"; detail="Sent via background resume"
        elif /usr/bin/grep -q "No conversation found" "$LOG" 2>/dev/null; then
            detail="Claude couldn't find the conversation"
        elif /usr/bin/grep -q "Prompt is too long" "$LOG" 2>/dev/null; then
            detail="The conversation is too long to resume"
        else
            detail="claude exited with an error"
        fi
        log "Resume run complete (exit $rc, $outcome)"
        exit 0

        """
    }

    // MARK: - Files

    /// Whole-second ISO 8601; `schedule` stores whole-second dates so a
    /// sidecar read back compares equal to the ScheduledResume it returned.
    private static let sidecarEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Reads ISO 8601 with or without fractional seconds (older builds wrote
    /// plain `.iso8601` but decoded with the numeric default, which is why
    /// listing and purging never worked) and bare numbers, so no sidecar from
    /// any build is unreadable.
    static let sidecarDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Double.self) {
                // Foundation's default (.deferredToDate) is seconds since 2001;
                // anything that large is a Unix epoch.
                return n > 1_000_000_000 ? Date(timeIntervalSince1970: n) : Date(timeIntervalSinceReferenceDate: n)
            }
            let s = try c.decode(String.self)
            if let date = TranscriptParser.parseTimestamp(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised date \(s)")
        }
        return d
    }()

    private static let resultDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    static func encodeSidecar(_ s: ScheduledResume) throws -> Data { try sidecarEncoder.encode(s) }
    static func decodeSidecar(_ data: Data) throws -> ScheduledResume { try sidecarDecoder.decode(ScheduledResume.self, from: data) }

    private func saveSidecar(_ scheduled: ScheduledResume) throws {
        try Self.encodeSidecar(scheduled).write(to: sidecarURL(forSessionId: scheduled.sessionId), options: .atomic)
        listCache = nil
    }

    private func readSidecar(sessionId: String) -> ScheduledResume? {
        guard let data = try? Data(contentsOf: sidecarURL(forSessionId: sessionId)) else { return nil }
        return try? Self.decodeSidecar(data)
    }

    /// All decodable sidecars, cached by directory mtime. Caller holds `lock`.
    private func allSidecars() -> [ScheduledResume] {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: scheduledDir.path))?[.modificationDate] as? Date
        if let mtime, let cache = listCache, cache.mtime == mtime { return cache.items }
        let entries = (try? FileManager.default.contentsOfDirectory(at: scheduledDir, includingPropertiesForKeys: nil)) ?? []
        var out: [ScheduledResume] = []
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                out.append(try Self.decodeSidecar(data))
            } catch {
                Logger.shared.log("Unreadable resume sidecar \(url.lastPathComponent): \(error)")
            }
        }
        if let mtime { listCache = (mtime, out) }
        return out
    }

    private func removeArtifacts(of s: ScheduledResume) {
        _ = bootout(label: s.label)
        let fm = FileManager.default
        try? fm.removeItem(atPath: s.plistPath)
        try? fm.removeItem(atPath: s.scriptPath ?? scriptURL(forSessionId: s.sessionId).path)
        try? fm.removeItem(at: sidecarURL(forSessionId: s.sessionId))
        listCache = nil
    }

    private func sidecarURL(forSessionId id: String) -> URL {
        scheduledDir.appendingPathComponent("\(id).json")
    }

    private func scriptURL(forSessionId id: String) -> URL {
        scheduledDir.appendingPathComponent("\(id).sh")
    }

    private static func wholeSecond(_ d: Date) -> Date {
        Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down))
    }

    private static func age(of path: String, now: Date) -> TimeInterval {
        guard let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return 0 }
        return now.timeIntervalSince(m)
    }

    private static func jsonStringLiteral(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s), let str = String(data: data, encoding: .utf8) else { return "\"\"" }
        return str
    }

    private static let filenameFormatter: DateFormatter = posixFormatter("yyyyMMdd-HHmmss")
    /// pmset reads local wall-clock time in exactly this shape; install.sh's
    /// sudoers rule only permits this shape too.
    static let pmsetFormatter: DateFormatter = posixFormatter("MM/dd/yyyy HH:mm:ss")

    /// Fixed-format formatters must be en_US_POSIX + Gregorian, or a Thai /
    /// Japanese calendar or non-Latin digits leak into the output (QA1480).
    private static func posixFormatter(_ format: String) -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.timeZone = .autoupdatingCurrent
        df.dateFormat = format
        return df
    }

    private static func filenameStamp(_ d: Date) -> String { filenameFormatter.string(from: d) }

    // MARK: - launchd

    private func writePlist(label: String, plistURL: URL, scriptPath: String, fireAt: Date, logPath: String) throws {
        let comps = Self.calendar.dateComponents([.month, .day, .hour, .minute], from: fireAt)
        var seen = Set<String>()
        let path = (ProcessRunner.developerBinDirectories + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/bash", scriptPath],
            "RunAtLoad": false,
            // No Year key exists; the script's year guard covers re-firing a
            // year later if cleanup ever failed.
            "StartCalendarInterval": [
                "Month": comps.month ?? 1,
                "Day": comps.day ?? 1,
                "Hour": comps.hour ?? 0,
                "Minute": comps.minute ?? 0
            ],
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            "LimitLoadToSessionType": "Aqua",
            // Node-based installs need `node` on PATH even when claude is
            // launched by absolute path.
            "EnvironmentVariables": ["PATH": path]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    private func bootstrap(label: String, plistPath: String) throws {
        // Bootout first in case a stale job with this label is loaded; the
        // unload completes asynchronously, so retry "already loaded" errors.
        _ = bootout(label: label)
        var last = ProcessRunner.Result.notLaunched
        for attempt in 0..<4 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.3) }
            last = runCommand(launchctlPath, ["bootstrap", "gui/\(getuid())", plistPath])
            if last.succeeded { return }
            if !last.launched { break }
        }
        let msg = (last.stderr + last.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        throw ScheduleError.launchctlFailed(msg.isEmpty ? "exit \(last.status)" : String(msg.prefix(200)))
    }

    @discardableResult
    private func bootout(label: String) -> Bool {
        runCommand(launchctlPath, ["bootout", "gui/\(getuid())/\(label)"]).succeeded
    }

    // MARK: - pmset wake (needs `./install.sh --enable-power-helpers`)

    /// Returns the stamp on success so `cancel` can remove exactly this wake.
    private func scheduleWake(at wakeAt: Date, pmsetPath: String) -> String? {
        let stamp = Self.pmsetFormatter.string(from: wakeAt)
        let r = runCommand("/usr/bin/sudo", ["-n", pmsetPath, "schedule", "wake", stamp])
        if r.succeeded {
            Logger.shared.log("pmset schedule wake \(stamp) — OK")
            return stamp
        }
        let output = (r.stderr + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        Logger.shared.log("pmset schedule wake failed (\(r.status)). Output: \(output). Hint: install the power helper (Preferences ▸ Power ▸ Install…) to allow passwordless pmset.")
        return nil
    }

    private func cancelWake(stamp: String, pmsetPath: String) {
        // Best effort: a leftover wake only wakes the Mac briefly.
        let r = runCommand("/usr/bin/sudo", ["-n", pmsetPath, "schedule", "cancel", "wake", stamp])
        if !r.succeeded {
            Logger.shared.log("pmset schedule cancel wake \(stamp) failed (\(r.status)) — the Mac may wake once unnecessarily")
        }
    }
}
