import Foundation

enum ActivityMonitor {
    /// Seconds since the most recently modified of `transcripts` was written,
    /// or nil if none exist. Callers pass the transcripts of live sessions
    /// (from ClaudeSessionRegistry), which costs one stat per session instead
    /// of walking every project under ~/.claude/projects each tick.
    static func secondsSinceLastWrite(of transcripts: [URL], now: Date = Date()) -> Double? {
        var newest: Date?
        for url in transcripts {
            guard let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { continue }
            if newest == nil || mtime > newest! { newest = mtime }
        }
        return newest.map { max(0, now.timeIntervalSince($0)) }
    }
}
