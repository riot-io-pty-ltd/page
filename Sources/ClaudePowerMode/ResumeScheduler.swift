import Foundation

struct ScheduledResume: Codable, Equatable {
    let sessionId: String
    let cwd: String
    let projectName: String
    let resetTime: Date
    let prompt: String
    let plistPath: String
    let logPath: String
    let label: String
    let createdAt: Date
}

/// Manages launchd plists for one-shot "carry on" resumes at a target time.
final class ResumeScheduler {
    static let scheduledDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudePowerMode", isDirectory: true)
            .appendingPathComponent("scheduled", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
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

    /// Schedules a resume. Returns the ScheduledResume on success.
    enum ScheduleError: Error, LocalizedError {
        case resetAlreadyPassed(Date)
        var errorDescription: String? {
            switch self {
            case .resetAlreadyPassed(let t): return "Reset time \(t) has already passed — refusing to schedule"
            }
        }
    }

    @discardableResult
    func schedule(
        event: RateLimitEvent,
        prompt: String,
        bufferSeconds: Int = 5,
        wakeViaPmset: Bool = false,
        pmsetPath: String = "/usr/bin/pmset",
        claudeBinaryPath: String? = nil
    ) throws -> ScheduledResume {
        let runAt = event.resetTime.addingTimeInterval(TimeInterval(bufferSeconds))
        // launchd's StartCalendarInterval will fire at the NEXT matching time. If we set a
        // moment that's already in the past today, the job sits idle until the calendar
        // wraps (potentially a year). Better to refuse and let the user decide.
        if runAt < Date() {
            Logger.shared.log("Refusing to schedule resume for \(event.sessionId.prefix(8)): reset time \(runAt) already passed")
            throw ScheduleError.resetAlreadyPassed(runAt)
        }
        let label = "local.ClaudePowerMode.resume.\(event.sessionId)"
        let plistPath = Self.launchAgentsDir.appendingPathComponent("\(label).plist").path
        let logFilename = "\(timestampForFilename(runAt))-\(event.sessionId.prefix(8)).log"
        let logPath = Self.logsDir.appendingPathComponent(logFilename).path

        try writePlist(
            label: label,
            plistPath: plistPath,
            runAt: runAt,
            cwd: event.cwd,
            sessionId: event.sessionId,
            prompt: prompt,
            logPath: logPath,
            claudeBinaryPath: claudeBinaryPath ?? discoverClaudeBinary()
        )

        // Reload launchd so the new plist is picked up
        try bootstrap(label: label, plistPath: plistPath)

        // Optional: schedule a system wake via pmset (requires sudoers permission)
        if wakeViaPmset {
            scheduleWake(at: runAt, pmsetPath: pmsetPath)
        }

        let scheduled = ScheduledResume(
            sessionId: event.sessionId,
            cwd: event.cwd,
            projectName: event.projectName,
            resetTime: event.resetTime,
            prompt: prompt,
            plistPath: plistPath,
            logPath: logPath,
            label: label,
            createdAt: Date()
        )
        try saveSidecar(scheduled)

        Logger.shared.log("Scheduled resume \(label) for \(runAt) → \(event.cwd)")
        return scheduled
    }

    func cancel(_ scheduled: ScheduledResume) {
        _ = bootout(label: scheduled.label)
        try? FileManager.default.removeItem(atPath: scheduled.plistPath)
        try? FileManager.default.removeItem(at: sidecarURL(forSessionId: scheduled.sessionId))
        Logger.shared.log("Cancelled scheduled resume \(scheduled.label)")
    }

    func listScheduled() -> [ScheduledResume] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: Self.scheduledDir,
            includingPropertiesForKeys: nil
        ) else { return [] }
        var out: [ScheduledResume] = []
        for url in entries where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let s = try? JSONDecoder().decode(ScheduledResume.self, from: data) {
                out.append(s)
            }
        }
        return out.sorted { $0.resetTime < $1.resetTime }
    }

    /// Removes sidecar records for resumes that have already fired (resetTime + grace in the past).
    func purgeStale(graceSeconds: TimeInterval = 600) {
        let now = Date()
        for s in listScheduled() where s.resetTime.addingTimeInterval(graceSeconds) < now {
            _ = bootout(label: s.label)
            try? FileManager.default.removeItem(atPath: s.plistPath)
            try? FileManager.default.removeItem(at: sidecarURL(forSessionId: s.sessionId))
        }
    }

    // MARK: - launchd plist construction

    private func writePlist(
        label: String,
        plistPath: String,
        runAt: Date,
        cwd: String,
        sessionId: String,
        prompt: String,
        logPath: String,
        claudeBinaryPath: String
    ) throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: runAt)
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0

        // Embed the year as a guard inside the bash so we don't accidentally fire on
        // the same day-of-year next year if the plist is somehow not cleaned up.
        let yearGuard = comps.year ?? 1970
        let escapedPrompt = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let scriptLines = [
            "set -e",
            "currentYear=$(date +%Y)",
            "[[ \"$currentYear\" == \"\(yearGuard)\" ]] || { echo \"[$(date)] year mismatch (\\\"$currentYear\\\" != \\\"\(yearGuard)\\\") — refusing to fire\" >> \"\(logPath)\"; exit 0; }",
            "echo \"[$(date)] Resuming session \(sessionId) in \(cwd) with prompt: \(escapedPrompt)\" >> \"\(logPath)\"",
            "cd \"\(cwd)\" || { echo \"cd failed\" >> \"\(logPath)\"; exit 1; }",
            "\"\(claudeBinaryPath)\" --resume \"\(sessionId)\" --print \"\(escapedPrompt)\" >> \"\(logPath)\" 2>&1",
            "echo \"[$(date)] Resume run complete (exit $?)\" >> \"\(logPath)\"",
            "launchctl bootout \"gui/$(id -u)/\(label)\" 2>/dev/null || true",
            "rm -f \"\(plistPath)\"",
            "rm -f \"\(sidecarURL(forSessionId: sessionId).path)\""
        ]
        let script = scriptLines.joined(separator: "\n") + "\n"

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/bash", "-lc", script],
            "RunAtLoad": false,
            "StartCalendarInterval": [
                "Month": month,
                "Day": day,
                "Hour": hour,
                "Minute": minute
            ],
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            "LimitLoadToSessionType": "Aqua",
            "EnvironmentVariables": [
                "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: plistPath))
    }

    // MARK: - launchctl

    private func bootstrap(label: String, plistPath: String) throws {
        // bootout first in case a stale plist with this label is loaded
        _ = bootout(label: label)
        let uid = getuid()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["bootstrap", "gui/\(uid)", plistPath]
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw NSError(domain: "ClaudePowerMode", code: Int(proc.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed"])
        }
    }

    @discardableResult
    private func bootout(label: String) -> Bool {
        let uid = getuid()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["bootout", "gui/\(uid)/\(label)"]
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    // MARK: - pmset wake schedule

    private func scheduleWake(at runAt: Date, pmsetPath: String) {
        // pmset expects "MM/dd/yyyy HH:mm:ss". This requires sudoers permission.
        let df = DateFormatter()
        df.dateFormat = "MM/dd/yyyy HH:mm:ss"
        df.timeZone = .current
        // Wake 30 seconds before reset so the system is fully up by then.
        let wakeAt = runAt.addingTimeInterval(-30)
        let stamp = df.string(from: wakeAt)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proc.arguments = ["-n", pmsetPath, "schedule", "wake", stamp]
        let outPipe = Pipe()
        proc.standardError = outPipe
        proc.standardOutput = outPipe
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                Logger.shared.log("pmset schedule wake \(stamp) — OK")
            } else {
                let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                Logger.shared.log("pmset schedule wake failed (\(proc.terminationStatus)). Output: \(output.trimmingCharacters(in: .whitespacesAndNewlines)). Hint: run `./install.sh --enable-wake` to allow passwordless pmset.")
            }
        } catch {
            Logger.shared.log("pmset schedule wake threw: \(error)")
        }
    }

    // MARK: - helpers

    private func saveSidecar(_ scheduled: ScheduledResume) throws {
        let url = sidecarURL(forSessionId: scheduled.sessionId)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(scheduled)
        try data.write(to: url)
    }

    private func sidecarURL(forSessionId id: String) -> URL {
        Self.scheduledDir.appendingPathComponent("\(id).json")
    }

    private func timestampForFilename(_ d: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        return df.string(from: d)
    }

    private func discoverClaudeBinary() -> String {
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.npm-global/bin/claude",
            "\(NSHomeDirectory())/.nvm/versions/node/bin/claude"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        // Last resort: rely on PATH at runtime via /usr/bin/env.
        return "/usr/bin/env claude"
    }
}

