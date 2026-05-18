// Smoke test for TranscriptParser against the historical rate-limit event.
// Usage: swift Tools/TestParser.swift
import Foundation

// We import the parser sources directly since this is a one-off check.
let parserURL = URL(fileURLWithPath: "Sources/ClaudePowerMode/TranscriptParser.swift")
let loggerURL = URL(fileURLWithPath: "Sources/ClaudePowerMode/Logger.swift")
for u in [loggerURL, parserURL] {
    guard FileManager.default.fileExists(atPath: u.path) else {
        print("Missing \(u.path)")
        exit(1)
    }
}

print("Scanning ~/.claude/projects with 90-day lookback for any historical rate-limit events...")
let events = TranscriptParser.findRateLimitEvents(directory: "~/.claude/projects", lookbackHours: 24 * 90)
print("Found \(events.count) total event(s).")
let df = ISO8601DateFormatter()
for (i, e) in events.sorted(by: { $0.eventTime > $1.eventTime }).prefix(5).enumerated() {
    print("--- \(i + 1) ---")
    print("  session:    \(e.sessionId)")
    print("  project:    \(e.projectName) (\(e.cwd))")
    print("  eventTime:  \(df.string(from: e.eventTime))")
    print("  resetTime:  \(df.string(from: e.resetTime))")
    print("  resetText:  \"\(e.resetTimeText)\"")
}
