import Foundation

enum ActivityMonitor {
    /// Returns the number of seconds since the most recent .jsonl transcript was modified
    /// inside `directory` (recursively). Returns nil if no transcript exists.
    static func secondsSinceLastTranscriptWrite(directory: String) -> Double? {
        let expanded = (directory as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: Date?
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let mtime = values?.contentModificationDate else { continue }
            if newest == nil || mtime > newest! { newest = mtime }
        }
        guard let n = newest else { return nil }
        return Date().timeIntervalSince(n)
    }
}
