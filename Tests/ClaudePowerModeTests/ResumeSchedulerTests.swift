import XCTest
@testable import ClaudePowerMode

/// Everything here runs against temp directories and a recording fake for
/// launchctl / sudo pmset — never the real launchd domain or power schedule.
final class ResumeSchedulerTests: XCTestCase {
    private var root: URL!
    private var calls: [[String]] = []
    private var launchctlListOutput = "PID\tStatus\tLabel\n"
    private var bootstrapFailures = 0
    private let lock = NSLock()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        calls = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func dir(_ name: String) -> URL {
        let u = root.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func makeScheduler() -> ResumeScheduler {
        ResumeScheduler(
            scheduledDir: dir("scheduled"),
            resultsDir: dir("results"),
            logsDir: dir("logs"),
            launchAgentsDir: dir("LaunchAgents"),
            sessionsDir: dir("sessions").path,
            launchctlPath: "/usr/bin/true",
            runCommand: { [unowned self] path, args in
                self.lock.lock(); defer { self.lock.unlock() }
                self.calls.append([path] + args)
                let ok = ProcessRunner.Result(status: 0, stdout: "", stderr: "", timedOut: false, launched: true)
                if args.first == "list" {
                    return ProcessRunner.Result(status: 0, stdout: self.launchctlListOutput, stderr: "", timedOut: false, launched: true)
                }
                if args.first == "bootstrap", self.bootstrapFailures > 0 {
                    self.bootstrapFailures -= 1
                    return ProcessRunner.Result(status: 5, stdout: "", stderr: "Bootstrap failed: 5", timedOut: false, launched: true)
                }
                return ok
            })
    }

    /// A fake `claude` that records its argv, one per line.
    private func fakeClaude(exit code: Int = 0) throws -> (bin: String, argsFile: String) {
        let argsFile = root.appendingPathComponent("claude-args").path
        let bin = root.appendingPathComponent("fake-claude").path
        try """
        #!/bin/bash
        printf '%s\\n' "$@" > \(ProcessRunner.shellQuote(argsFile))
        echo "fake claude ran in $(pwd)"
        exit \(code)
        """.write(toFile: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin)
        return (bin, argsFile)
    }

    private func event(reset: Date, sessionId: String = "0a1b2c3d-1111-2222-3333-444455556666",
                       backend: AgentBackendID = .claude, estimated: Bool = false) -> RateLimitEvent {
        let project = dir("project")
        return RateLimitEvent(sessionId: sessionId, cwd: project.path, projectName: "project",
                              eventTime: reset.addingTimeInterval(-3600), resetTime: reset,
                              resetTimeText: "resets soon", transcriptPath: "",
                              backend: backend, resetTimeIsEstimated: estimated)
    }

    // MARK: - Pure helpers

    func testFireDateIsNextWholeMinuteAndNeverTheCurrentOne() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)   // whole minute
        XCTAssertEqual(ResumeScheduler.launchdFireDate(for: base.addingTimeInterval(5), now: base.addingTimeInterval(-3600)),
                       base.addingTimeInterval(60))
        XCTAssertEqual(ResumeScheduler.launchdFireDate(for: base, now: base.addingTimeInterval(-3600)), base)
        XCTAssertEqual(ResumeScheduler.launchdFireDate(for: base.addingTimeInterval(5), now: base.addingTimeInterval(3)),
                       base.addingTimeInterval(60))
        XCTAssertEqual(ResumeScheduler.launchdFireDate(for: base, now: base.addingTimeInterval(-2)),
                       base.addingTimeInterval(60), "too close to bootstrap in time → next minute")
    }

    func testSessionIdValidationAndPromptSanitising() {
        XCTAssertTrue(ResumeScheduler.isSafeSessionId("0a1b2c3d-1111-2222-3333-444455556666"))
        XCTAssertFalse(ResumeScheduler.isSafeSessionId("../etc"))
        XCTAssertFalse(ResumeScheduler.isSafeSessionId("a b"))
        XCTAssertFalse(ResumeScheduler.isSafeSessionId("x'; rm -rf ~"))
        XCTAssertFalse(ResumeScheduler.isSafeSessionId(""))
        XCTAssertEqual(ResumeScheduler.sanitizePrompt("--help"), " --help")
        XCTAssertEqual(ResumeScheduler.sanitizePrompt("!ls"), " !ls")
        XCTAssertEqual(ResumeScheduler.sanitizePrompt("a\u{1B}[2Jb\nc"), "a[2Jb\nc")
    }

    func testLaunchctlListParsing() {
        let out = "PID\tStatus\tLabel\n-\t0\tlocal.ClaudePowerMode.resume.abc\n123\t0\tcom.apple.x\n4242\t0\tlocal.PageAI.resume.def\n"
        let jobs = ResumeScheduler.loadedJobs(fromLaunchctlList: out,
                                              prefixes: [ResumeScheduler.labelPrefix] + ResumeScheduler.legacyLabelPrefixes)
        XCTAssertEqual(jobs.map(\.label), ["local.ClaudePowerMode.resume.abc", "local.PageAI.resume.def"])
        XCTAssertEqual(jobs.map(\.pid), [nil, 4242])
    }

    func testPurgeNeverTouchesARunningJob() throws {
        let claude = try fakeClaude()
        let scheduler = makeScheduler()
        let now = Date()
        let s = try scheduler.schedule(event: event(reset: now.addingTimeInterval(600)), prompt: "x",
                                       claudeBinaryPath: claude.bin, now: now)
        // Long past due (a 20h-late run would have expired itself), but launchd says it's running.
        launchctlListOutput = "PID\tStatus\tLabel\n4242\t0\t\(s.label)\n"
        calls = []
        scheduler.purgeStale(now: now.addingTimeInterval(20 * 3600))
        XCTAssertFalse(calls.contains { $0.dropFirst().first == "bootout" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.plistPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.scriptPath!))

        // A run that's merely in progress (due 30 min ago) isn't stale either.
        launchctlListOutput = "PID\tStatus\tLabel\n-\t0\t\(s.label)\n"
        scheduler.purgeStale(now: now.addingTimeInterval(30 * 60))
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.plistPath))

        // Once it can't possibly be running any more, it goes.
        scheduler.purgeStale(now: now.addingTimeInterval(20 * 3600))
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.plistPath))
    }

    // MARK: - Sidecars

    func testSidecarRoundTripAndLegacyFormats() throws {
        let s = ScheduledResume(sessionId: "abc", cwd: "/p", projectName: "p",
                                resetTime: Date(timeIntervalSince1970: 1_800_000_000), prompt: "carry on",
                                plistPath: "/x.plist", logPath: "/x.log", label: "l",
                                createdAt: Date(timeIntervalSince1970: 1_799_990_000),
                                runAt: Date(timeIntervalSince1970: 1_800_000_060), scriptPath: "/x.sh",
                                transcriptPath: "/t.jsonl", claudePath: "/c", wakeStamp: nil)
        XCTAssertEqual(try ResumeScheduler.decodeSidecar(ResumeScheduler.encodeSidecar(s)), s)

        // Written by the previous build: ISO dates, none of the new fields.
        let legacy = #"{"createdAt":"2026-05-13T08:26:25Z","cwd":"/p","label":"l","logPath":"/l","plistPath":"/x","projectName":"p","prompt":"carry on","resetTime":"2026-05-13T13:00:00Z","sessionId":"abc"}"#
        let old = try ResumeScheduler.decodeSidecar(Data(legacy.utf8))
        XCTAssertNil(old.runAt)
        XCTAssertEqual(old.effectiveRunAt, ISO8601DateFormatter().date(from: "2026-05-13T13:01:00Z"))

        // Foundation's default numeric encoding (seconds since 2001).
        let numeric = #"{"createdAt":800000000,"cwd":"/p","label":"l","logPath":"/l","plistPath":"/x","projectName":"p","prompt":"c","resetTime":800003600.5,"sessionId":"abc"}"#
        XCTAssertEqual(try ResumeScheduler.decodeSidecar(Data(numeric.utf8)).resetTime,
                       Date(timeIntervalSinceReferenceDate: 800_003_600.5))
    }

    // MARK: - schedule / cancel / purge

    func testScheduleWritesSidecarScriptAndPlistThenIsIdempotent() throws {
        let claude = try fakeClaude()
        let scheduler = makeScheduler()
        let now = Date()
        let reset = now.addingTimeInterval(3600)
        let s = try scheduler.schedule(event: event(reset: reset), prompt: "carry on", claudeBinaryPath: claude.bin, now: now)

        XCTAssertEqual(s.claudePath, claude.bin)
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.scriptPath!))
        XCTAssertEqual(scheduler.listScheduled(now: now), [s])

        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: URL(fileURLWithPath: s.plistPath)), format: nil) as! [String: Any]
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/bin/bash", s.scriptPath!])
        let cal = ResumeScheduler.calendar
        let interval = plist["StartCalendarInterval"] as! [String: Int]
        let fire = s.runAt!
        XCTAssertEqual(interval["Minute"], cal.component(.minute, from: fire))
        XCTAssertEqual(interval["Hour"], cal.component(.hour, from: fire))
        XCTAssertEqual(interval["Day"], cal.component(.day, from: fire))
        XCTAssertEqual(interval["Month"], cal.component(.month, from: fire))
        XCTAssertGreaterThanOrEqual(fire, reset.addingTimeInterval(5))
        XCTAssertEqual(fire.timeIntervalSince1970.truncatingRemainder(dividingBy: 60), 0)

        let script = try String(contentsOfFile: s.scriptPath!)
        let check = ProcessRunner.run("/bin/bash", ["-n", s.scriptPath!])
        XCTAssertTrue(check.succeeded, check.stderr)
        XCTAssertFalse(script.contains("set -e"))

        let bootstraps = calls.filter { $0.dropFirst().first == "bootstrap" }.count
        XCTAssertEqual(bootstraps, 1)
        let again = try scheduler.schedule(event: event(reset: reset), prompt: "carry on", claudeBinaryPath: claude.bin, now: now)
        XCTAssertEqual(again, s)
        XCTAssertEqual(calls.filter { $0.dropFirst().first == "bootstrap" }.count, 1, "same reset → no re-bootstrap")

        scheduler.cancel(s)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.plistPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.scriptPath!))
        XCTAssertTrue(scheduler.listScheduled(now: now).isEmpty)
        XCTAssertTrue(calls.contains { $0.last == "gui/\(getuid())/\(s.label)" })
    }

    func testScheduleRetriesBootstrapAndCleansUpOnFailure() throws {
        let claude = try fakeClaude()
        let scheduler = makeScheduler()
        bootstrapFailures = 1
        let now = Date()
        XCTAssertNoThrow(try scheduler.schedule(event: event(reset: now.addingTimeInterval(600)), prompt: "x",
                                                claudeBinaryPath: claude.bin, now: now))
        bootstrapFailures = 10
        let other = event(reset: now.addingTimeInterval(900), sessionId: "ffff0000-1111-2222-3333-444455556666")
        XCTAssertThrowsError(try scheduler.schedule(event: other, prompt: "x", claudeBinaryPath: claude.bin, now: now))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir("scheduled").path).filter { $0.hasPrefix("ffff") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testScheduleRefusals() throws {
        let claude = try fakeClaude()
        let scheduler = makeScheduler()
        let now = Date()
        let reset = now.addingTimeInterval(3600)
        XCTAssertThrowsError(try scheduler.schedule(event: event(reset: reset, backend: .codex), prompt: "x",
                                                    claudeBinaryPath: claude.bin, now: now)) {
            XCTAssertEqual($0 as? ResumeScheduler.ScheduleError, .unsupportedBackend("codex"))
        }
        XCTAssertThrowsError(try scheduler.schedule(event: event(reset: reset, estimated: true), prompt: "x",
                                                    claudeBinaryPath: claude.bin, now: now)) {
            XCTAssertEqual($0 as? ResumeScheduler.ScheduleError, .resetTimeUnknown)
        }
        XCTAssertNoThrow(try scheduler.schedule(event: event(reset: reset, estimated: true), prompt: "x",
                                                claudeBinaryPath: claude.bin, allowEstimatedReset: true, now: now))
        XCTAssertThrowsError(try scheduler.schedule(event: event(reset: now.addingTimeInterval(-60)), prompt: "x",
                                                    claudeBinaryPath: claude.bin, now: now))
        XCTAssertThrowsError(try scheduler.schedule(event: event(reset: reset, sessionId: "codex thread"), prompt: "x",
                                                    claudeBinaryPath: claude.bin, now: now))
    }

    func testPurgeRemovesStaleOrphansAndLeftoverJobs() throws {
        let claude = try fakeClaude()
        let scheduler = makeScheduler()
        let now = Date()
        let live = try scheduler.schedule(event: event(reset: now.addingTimeInterval(3600)), prompt: "x",
                                          claudeBinaryPath: claude.bin, now: now)

        let agents = dir("LaunchAgents")
        let orphan = agents.appendingPathComponent("local.ClaudePowerMode.resume.dead.plist")
        try Data("x".utf8).write(to: orphan)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: orphan.path)
        let fresh = agents.appendingPathComponent("local.ClaudePowerMode.resume.brandnew.plist")
        try Data("x".utf8).write(to: fresh)
        let unrelated = agents.appendingPathComponent("com.example.agent.plist")
        try Data("x".utf8).write(to: unrelated)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: unrelated.path)

        // A stale sidecar from an older build (no runAt, ISO dates).
        let staleJSON = #"{"createdAt":"2026-05-13T08:26:25Z","cwd":"/p","label":"local.ClaudePowerMode.resume.old","logPath":"/l","plistPath":"\#(agents.path)/local.ClaudePowerMode.resume.old.plist","projectName":"p","prompt":"carry on","resetTime":"2026-05-13T13:00:00Z","sessionId":"old"}"#
        try Data(staleJSON.utf8).write(to: dir("scheduled").appendingPathComponent("old.json"))
        try Data("x".utf8).write(to: agents.appendingPathComponent("local.ClaudePowerMode.resume.old.plist"))

        launchctlListOutput = "PID\tStatus\tLabel\n-\t0\t\(live.label)\n-\t0\tlocal.ClaudePowerMode.resume.ghost\n"
        calls = []
        scheduler.purgeStale(now: now)

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: orphan.path))
        XCTAssertTrue(fm.fileExists(atPath: fresh.path), "a plist written seconds ago may be mid-schedule")
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path))
        XCTAssertFalse(fm.fileExists(atPath: agents.appendingPathComponent("local.ClaudePowerMode.resume.old.plist").path))
        XCTAssertFalse(fm.fileExists(atPath: dir("scheduled").appendingPathComponent("old.json").path))
        XCTAssertTrue(fm.fileExists(atPath: live.plistPath))
        let bootedOut = calls.filter { $0.dropFirst().first == "bootout" }.compactMap { $0.last }
        XCTAssertTrue(bootedOut.contains("gui/\(getuid())/local.ClaudePowerMode.resume.ghost"))
        XCTAssertFalse(bootedOut.contains("gui/\(getuid())/\(live.label)"))
        XCTAssertEqual(scheduler.listScheduled(now: now).map(\.label), [live.label])
    }

    // MARK: - The generated job script, executed with fakes

    private func scriptValues(claude: String, prompt: String, targetEpoch: Int, targetYear: Int? = nil) -> ResumeScheduler.ScriptValues {
        let scheduled = dir("scheduled")
        let sid = "0a1b2c3d-1111-2222-3333-444455556666"
        return ResumeScheduler.ScriptValues(
            label: "local.ClaudePowerMode.test.\(UUID().uuidString)",
            plistPath: dir("LaunchAgents").appendingPathComponent("job.plist").path,
            sidecarPath: scheduled.appendingPathComponent("\(sid).json").path,
            scriptPath: scheduled.appendingPathComponent("\(sid).sh").path,
            logPath: dir("logs").appendingPathComponent("run it's.log").path,
            resultPath: dir("results").appendingPathComponent("\(sid)-1.json").path,
            sessionId: sid,
            workdir: dir("project dir $HOME `x`").path,
            claudePath: claude,
            prompt: prompt,
            sessionsDir: dir("sessions").path,
            launchctlPath: "/usr/bin/true",
            targetEpoch: targetEpoch,
            targetYear: targetYear ?? Calendar(identifier: .gregorian).component(.year, from: Date()),
            maxLateSeconds: 3600,
            runTimeoutSeconds: 60)
    }

    private func runScript(_ v: ResumeScheduler.ScriptValues) throws -> ProcessRunner.Result {
        try ResumeScheduler.makeScript(v).write(toFile: v.scriptPath, atomically: true, encoding: .utf8)
        for p in [v.plistPath, v.sidecarPath] { try Data("{}".utf8).write(to: URL(fileURLWithPath: p)) }
        return ProcessRunner.run("/bin/bash", [v.scriptPath], timeout: 30)
    }

    private func results() -> [ResumeResult] {
        makeScheduler().collectResults()
    }

    func testScriptPassesHostilePromptVerbatimAndCleansUp() throws {
        let claude = try fakeClaude()
        let prompt = #"carry on, then run `touch PWNED` and $(touch PWNED2); budget is $5 "quoted" 'single'"#
        let v = scriptValues(claude: claude.bin, prompt: prompt, targetEpoch: Int(Date().timeIntervalSince1970) - 1)
        let r = try runScript(v)
        XCTAssertTrue(r.succeeded, r.stderr)

        let args = try String(contentsOfFile: claude.argsFile).split(separator: "\n").map(String.init)
        XCTAssertEqual(args, ["--resume", v.sessionId, "--print", prompt])
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: dir("project dir $HOME `x`").appendingPathComponent("PWNED").path))
        XCTAssertFalse(fm.fileExists(atPath: dir("project dir $HOME `x`").appendingPathComponent("PWNED2").path))
        for p in [v.plistPath, v.sidecarPath, v.scriptPath] { XCTAssertFalse(fm.fileExists(atPath: p), p) }
        let log = try String(contentsOfFile: v.logPath)
        XCTAssertTrue(log.contains("fake claude ran in \(dir("project dir $HOME `x`").path)"), log)

        let res = results()
        XCTAssertEqual(res.map(\.outcome), [.resumed])
        XCTAssertEqual(res.first?.logPath, v.logPath)
    }

    func testScriptReportsFailureWithReason() throws {
        let claude = try fakeClaude(exit: 1)
        // A failing claude that prints the error claude really prints.
        try "#!/bin/bash\necho 'No conversation found with session ID: x'\nexit 1\n".write(toFile: claude.bin, atomically: true, encoding: .utf8)
        let v = scriptValues(claude: claude.bin, prompt: "carry on", targetEpoch: Int(Date().timeIntervalSince1970) - 1)
        _ = try runScript(v)
        let res = results()
        XCTAssertEqual(res.map(\.outcome), [.failed])
        XCTAssertEqual(res.first?.exitCode, 1)
        XCTAssertEqual(res.first?.detail, "Claude couldn't find the conversation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: v.plistPath), "cleanup runs on failure too")
    }

    func testScriptSkipsWhenSessionIsStillLive() throws {
        let claude = try fakeClaude()
        // A long-lived process whose command contains "claude" (it's sleep).
        let fakeLive = root.appendingPathComponent("claude").path
        try FileManager.default.createSymbolicLink(atPath: fakeLive, withDestinationPath: "/bin/sleep")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: fakeLive)
        proc.arguments = ["30"]
        try proc.run()
        defer { proc.terminate() }

        let v = scriptValues(claude: claude.bin, prompt: "carry on", targetEpoch: Int(Date().timeIntervalSince1970) - 1)
        let sessionFile = URL(fileURLWithPath: v.sessionsDir).appendingPathComponent("\(proc.processIdentifier).json")
        try #"{"pid":\#(proc.processIdentifier),"sessionId":"\#(v.sessionId)","status":"idle"}"#.write(to: sessionFile, atomically: true, encoding: .utf8)

        _ = try runScript(v)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.argsFile), "must not fork a live session")
        XCTAssertEqual(results().map(\.outcome), [.skippedLive])
    }

    func testScriptYearGuardExpires() throws {
        let claude = try fakeClaude()
        let v = scriptValues(claude: claude.bin, prompt: "carry on", targetEpoch: Int(Date().timeIntervalSince1970) - 1, targetYear: 1999)
        _ = try runScript(v)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.argsFile))
        XCTAssertEqual(results().map(\.outcome), [.expired])
        XCTAssertFalse(FileManager.default.fileExists(atPath: v.plistPath))
    }
}
