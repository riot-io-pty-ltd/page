import Foundation

enum ProcessMonitor {
    /// User-launched `claude` processes in one process-table snapshot,
    /// excluding our own helpers and anything matching `exclude`.
    ///
    /// Works on a `ProcessRunner.processTable()` snapshot the caller already
    /// took for the tick, instead of spawning `pgrep -fl` (whose output on a
    /// busy Mac is ~45 KB and used to be read only after waitUntilExit — a
    /// pipe-buffer deadlock that wedged the tick queue).
    static func claudeProcesses(in table: [ProcessRunner.ProcessInfoRow],
                                pattern: String,
                                exclude: [String]) -> [ProcessRunner.ProcessInfoRow] {
        let myPid = ProcessInfo.processInfo.processIdentifier
        let regex = try? NSRegularExpression(pattern: pattern)
        return table.filter { row in
            guard row.pid != myPid else { return false }
            let cmd = row.command
            // `claudeProcessPattern` keeps its pgrep -f meaning: a regex
            // matched against the full command line.
            if let regex {
                let range = NSRange(location: 0, length: (cmd as NSString).length)
                guard regex.firstMatch(in: cmd, range: range) != nil else { return false }
            } else if !cmd.contains(pattern) {
                return false
            }
            if exclude.contains(where: { !$0.isEmpty && cmd.contains($0) }) { return false }
            // Only count processes whose actual executable is `claude` — the
            // pattern matches the whole command line, so /bin/zsh running
            // `tail -F /tmp/claude-XXXX-cwd` or hook scripts under
            // ~/.claude/hooks would otherwise count as "claude sessions."
            return ClaudeSessionRegistry.isClaudeExecutable(cmd)
        }
    }

    /// Convenience for callers without a snapshot (takes one).
    static func countClaudeRunning(pattern: String, exclude: [String]) -> Int {
        claudeProcesses(in: ProcessRunner.processTable(), pattern: pattern, exclude: exclude).count
    }
}
