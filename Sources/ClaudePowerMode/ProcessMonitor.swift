import Foundation

enum ProcessMonitor {
    /// Returns the number of distinct user-launched `claude` processes,
    /// excluding our own helper and any names in `exclude`.
    static func countClaudeRunning(pattern: String, exclude: [String]) -> Int {
        runPgrep(pattern: pattern, exclude: exclude).count
    }

    static func isClaudeRunning(pattern: String, exclude: [String]) -> Bool {
        !runPgrep(pattern: pattern, exclude: exclude).isEmpty
    }

    private static func runPgrep(pattern: String, exclude: [String]) -> [Int32] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-fl", pattern]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            Logger.shared.log("pgrep failed: \(error)")
            return []
        }
        task.waitUntilExit()

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let myPid = ProcessInfo.processInfo.processIdentifier

        var pids: [Int32] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let pidStr = parts.first, let pid = Int32(pidStr), pid != myPid else { continue }
            let cmd = parts.count > 1 ? String(parts[1]) : ""
            if exclude.contains(where: { !$0.isEmpty && cmd.contains($0) }) { continue }
            // Only count processes whose actual executable is `claude` —
            // pgrep -fl matches the whole command line, so /bin/zsh running
            // `tail -F /tmp/claude-XXXX-cwd` or hook scripts under
            // ~/.claude/hooks would otherwise count as "claude sessions."
            let cmdParts = cmd.split(separator: " ", omittingEmptySubsequences: true)
            guard let exe = cmdParts.first else { continue }
            let exeBasename = (String(exe) as NSString).lastPathComponent
            guard exeBasename == "claude" else { continue }
            pids.append(pid)
        }
        return pids
    }
}
