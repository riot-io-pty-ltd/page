import Foundation

/// Periodically scans Claude transcripts for rate-limit events. Emits `onNewEvent`
/// for events it hasn't reported before in the current process lifetime.
final class RateLimitWatcher {
    var onNewEvent: ((RateLimitEvent) -> Void)?

    private var seen: Set<String> = []
    private let queue = DispatchQueue(label: "ClaudePowerMode.RateLimitWatcher")

    func scan(transcriptDirectory: String, lookbackHours: Double = 6) -> [RateLimitEvent] {
        let events = TranscriptParser.findRateLimitEvents(
            directory: transcriptDirectory,
            lookbackHours: lookbackHours
        )

        var newEvents: [RateLimitEvent] = []
        queue.sync {
            for e in events where !seen.contains(e.uniqueId) {
                seen.insert(e.uniqueId)
                newEvents.append(e)
            }
        }
        for e in newEvents { onNewEvent?(e) }
        return events
    }

    /// Bulk-mark events as already-seen so we don't re-fire on first launch.
    func primeWithExistingEvents(transcriptDirectory: String, lookbackHours: Double = 6) {
        let events = TranscriptParser.findRateLimitEvents(
            directory: transcriptDirectory,
            lookbackHours: lookbackHours
        )
        queue.sync {
            for e in events { seen.insert(e.uniqueId) }
        }
        Logger.shared.log("RateLimitWatcher primed with \(events.count) pre-existing event(s)")
    }
}
