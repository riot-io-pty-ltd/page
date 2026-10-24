import Foundation

final class Logger {
    static let shared = Logger()

    static let logURL: URL = {
        let logs = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("ClaudePowerMode.log")
    }()

    /// Roll the log over at this size. One previous file (`.1`) is kept, so
    /// the log can never use more than ~2× this on disk. Before rotation
    /// existed a busy Mac had grown it to 12+ MB of mostly repeated lines.
    static let maxBytes: UInt64 = 5 * 1024 * 1024

    private let queue = DispatchQueue(label: "ClaudePowerMode.logger")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    /// Kept open between writes (confined to `queue`); reopened after rotation.
    private var handle: FileHandle?
    private var bytesWritten: UInt64 = 0
    /// Mirror to stderr only when someone is watching (`swift run` in a
    /// terminal). Under launchd stderr is redirected to Page.stderr.log, and
    /// duplicating every line there just doubled the disk use; real crash
    /// output still lands there.
    private let mirrorToStderr = isatty(STDERR_FILENO) != 0

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(Logger.redact(message))\n"
        queue.async { self.append(line) }
        if mirrorToStderr {
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    // MARK: file handling (on `queue`)

    private func append(_ line: String) {
        let data = Data(line.utf8)
        if handle == nil { openHandle() }
        guard let handle else { return }
        do {
            // The throwing APIs report ENOSPC/EIO as errors; the legacy
            // `write(_:)` raised an Objective-C exception and crashed the app.
            try handle.write(contentsOf: data)
            bytesWritten += UInt64(data.count)
        } catch {
            try? handle.close()
            self.handle = nil
            return
        }
        if bytesWritten >= Logger.maxBytes { rotate() }
    }

    private func openHandle() {
        let url = Logger.logURL
        let fm = FileManager.default
        // Recreated here (not just once at launch) in case ~/Library/Logs
        // was cleaned out while we were running.
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        bytesWritten = (try? h.seekToEnd()) ?? 0
        handle = h
        if bytesWritten >= Logger.maxBytes { rotate() }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let url = Logger.logURL
        let previous = url.appendingPathExtension("1")
        let fm = FileManager.default
        try? fm.removeItem(at: previous)
        try? fm.moveItem(at: url, to: previous)
        fm.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        bytesWritten = 0
    }

    // MARK: hygiene

    /// Masks anything that looks like a bearer credential. Belt and braces:
    /// no code path should log the pairing token, but a stray request dump
    /// or error description must not leak it into a file users attach to
    /// bug reports.
    static func redact(_ message: String) -> String {
        guard message.range(of: "bearer", options: .caseInsensitive) != nil
                || message.range(of: "token", options: .caseInsensitive) != nil else {
            return message
        }
        var out = message
        let patterns = [
            #"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#,
            #"(?i)("?token"?\s*[:=]\s*"?)[A-Za-z0-9._~+/=-]{8,}"#
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            out = re.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1<redacted>"
            )
        }
        return out
    }

    /// Deletes per-reply / per-resume log files older than `maxAgeDays` from
    /// the side directories the injection and resume paths write to. Those
    /// directories only ever hold `.log` files (one per reply), so nothing
    /// else is touched. Call off the main thread.
    static func pruneAuxiliaryLogs(maxAgeDays: Double = 14) {
        let logs = logURL.deletingLastPathComponent()
        let dirs = ["ClaudePowerMode-resumes", "Page-codex-replies"].map {
            logs.appendingPathComponent($0, isDirectory: true)
        }
        let cutoff = Date().addingTimeInterval(-maxAgeDays * 86_400)
        let fm = FileManager.default
        var removed = 0
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
            ) else { continue }
            for file in files where file.pathExtension == "log" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true,
                      let mtime = values?.contentModificationDate, mtime < cutoff else { continue }
                if (try? fm.removeItem(at: file)) != nil { removed += 1 }
            }
        }
        if removed > 0 { shared.log("Pruned \(removed) reply/resume log file(s) older than \(Int(maxAgeDays)) days") }
    }
}
