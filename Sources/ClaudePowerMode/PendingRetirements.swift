import Foundation

/// Pairing tokens that were replaced on this Mac but that the Worker hasn't
/// yet confirmed as retired.
///
/// Regenerating the token retires the old one on the Worker (`relay.retire`)
/// so phones still paired with it are told to re-pair. That first attempt
/// happens immediately, but it can't be trusted on its own: the Mac may be
/// offline, the socket may be half-dead after wake (a socket `send` that
/// completes proves nothing), or the user may regenerate twice in a row. A
/// token that's never retired leaves its phones on a healthy-looking socket
/// to an orphaned inbox — no pages ever again, and no re-pair prompt.
///
/// So every replaced token is written here first (0600, next to the token
/// file) and retried with `POST /intervention {type: relay.retire}` until
/// the Worker answers 2xx or 410 (already retired). Entries give up after
/// `maxAge`; a Worker too old to know the frame answers 400 and is retried
/// with backoff until then.
enum PendingRetirements {
    struct Entry: Codable, Equatable {
        let token: String
        /// The relay's WebSocket URL when the token was replaced.
        let wsURL: URL
        let since: Date
        var attempts: Int = 0
        var nextAttemptAt: Date = .distantPast
    }

    static let maxAge: TimeInterval = 30 * 24 * 3600
    static let maxEntries = 20

    private static let lock = NSLock()
    /// Tests point this at a temp directory.
    static var fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("ClaudePowerMode/retire-pending.json")
    }()

    static func add(token: String, wsURL: URL, now: Date = Date()) {
        guard !token.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var entries = loadLocked().filter { $0.token != token }
        entries.append(Entry(token: token, wsURL: wsURL, since: now))
        saveLocked(Array(entries.suffix(maxEntries)))
    }

    static func remove(token: String) {
        lock.lock(); defer { lock.unlock() }
        let entries = loadLocked()
        let kept = entries.filter { $0.token != token }
        if kept.count != entries.count { saveLocked(kept) }
    }

    static func all() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    /// Pure: entries to try now (never the token in use), after dropping
    /// expired ones. Returns the pruned list too, so the caller can save it.
    static func due(_ entries: [Entry], currentToken: String, now: Date) -> (due: [Entry], kept: [Entry]) {
        let kept = entries.filter { now.timeIntervalSince($0.since) < maxAge && $0.token != currentToken }
        return (kept.filter { $0.nextAttemptAt <= now }, kept)
    }

    /// Pure: backoff after a failed attempt — 1, 2, 4 … minutes, capped at an hour.
    static func backoff(attempts: Int) -> TimeInterval {
        min(3600, 60 * pow(2, Double(max(0, min(attempts, 10) - 1))))
    }

    /// Marks attempts started (so overlapping passes don't double-POST) and
    /// returns the entries to POST. Thread-safe.
    static func claimDue(currentToken: String, now: Date = Date()) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        let stored = loadLocked()
        let (due, kept) = Self.due(stored, currentToken: currentToken, now: now)
        guard !due.isEmpty || kept.count != stored.count else { return [] }
        let dueTokens = Set(due.map(\.token))
        let updated = kept.map { e -> Entry in
            guard dueTokens.contains(e.token) else { return e }
            var e = e
            e.attempts += 1
            e.nextAttemptAt = now.addingTimeInterval(backoff(attempts: e.attempts))
            return e
        }
        saveLocked(updated)
        return due
    }

    // MARK: storage (lock held)

    private static func loadLocked() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    private static func saveLocked(_ entries: [Entry]) {
        let fm = FileManager.default
        if entries.isEmpty {
            try? fm.removeItem(at: fileURL)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(entries) else { return }
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Holds relay tokens: create owner-only, then atomically replace.
        let tmp = fileURL.appendingPathExtension("tmp")
        fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        if (try? fm.replaceItemAt(fileURL, withItemAt: tmp)) == nil {
            try? fm.removeItem(at: fileURL)
            try? fm.moveItem(at: tmp, to: fileURL)
        }
    }
}
