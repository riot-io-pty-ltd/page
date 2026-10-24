import Foundation

/// The model provider each Claude session was last seen running on,
/// remembered after the process exits.
///
/// A background resume (`claude --resume … --print`) only happens once the
/// session's process is gone, and by then its environment — the only place
/// `ANTHROPIC_BASE_URL` lives — can't be read any more. So whenever a live
/// session is seen, its provider is written here (0600, atomic) and the
/// resume paths ask `ResumeProviderGate` before restarting it.
///
/// Holds only `sessionId → (provider, seenAt)`: never a URL, a token or any
/// other environment value. Entries expire after `maxAge`; at most
/// `maxEntries` (the newest) are kept.
enum SessionProviderStore {
    struct Entry: Codable, Equatable {
        let provider: ModelProvider
        let seenAt: Date
    }

    static let maxAge: TimeInterval = 30 * 24 * 3600
    static let maxEntries = 500
    /// An unchanged entry is rewritten only this often (to keep it from
    /// expiring), not every time the session is seen.
    static let refreshInterval: TimeInterval = 24 * 3600

    private static let lock = NSLock()
    /// Tests point this at a temp directory. Under XCTest the default is a
    /// per-process temp file, so a test that drives a real registry never
    /// writes the user's Application Support.
    static var fileURL: URL = {
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("ClaudePowerMode-tests-\(getpid())", isDirectory: true)
                .appendingPathComponent("session-providers.json")
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("ClaudePowerMode/session-providers.json")
    }()

    /// Records that `sessionId` is running on `provider`. `.unknown` is
    /// never stored (it carries no evidence either way), but it removes an
    /// existing entry: the session is now running somewhere Page couldn't
    /// classify, so an older `.anthropic` must not vouch for it. Thread-safe.
    static func record(sessionId: String, provider: ModelProvider, now: Date = Date()) {
        guard ClaudeSessionRegistry.isValidSessionId(sessionId) else { return }
        let key = sessionId.lowercased()
        lock.lock(); defer { lock.unlock() }
        let stored = loadLocked()
        var entries = pruned(stored, now: now)
        if provider == .unknown {
            guard entries.removeValue(forKey: key) != nil || entries.count != stored.count else { return }
            saveLocked(entries)
            return
        }
        guard needsWrite(existing: entries[key], provider: provider, now: now) || entries.count != stored.count else { return }
        entries[key] = Entry(provider: provider, seenAt: now)
        saveLocked(pruned(entries, now: now))
    }

    /// The provider last recorded for `sessionId`, or nil (never seen, or
    /// expired). Thread-safe.
    static func provider(for sessionId: String, now: Date = Date()) -> ModelProvider? {
        lock.lock(); defer { lock.unlock() }
        guard let e = loadLocked()[sessionId.lowercased()], now.timeIntervalSince(e.seenAt) < maxAge else { return nil }
        return e.provider
    }

    static func all() -> [String: Entry] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    /// Pure: drops expired entries, then keeps the newest `maxEntries`.
    static func pruned(_ entries: [String: Entry], now: Date) -> [String: Entry] {
        let fresh = entries.filter { now.timeIntervalSince($0.value.seenAt) < maxAge }
        guard fresh.count > maxEntries else { return fresh }
        let newest = fresh.sorted { $0.value.seenAt > $1.value.seenAt }.prefix(maxEntries)
        return Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }

    /// Pure: a new or changed provider is written at once; an unchanged one
    /// only once `refreshInterval` has passed.
    static func needsWrite(existing: Entry?, provider: ModelProvider, now: Date) -> Bool {
        guard let existing else { return true }
        return existing.provider != provider || now.timeIntervalSince(existing.seenAt) >= refreshInterval
    }

    // MARK: storage (lock held)

    private static func loadLocked() -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([String: Entry].self, from: data)) ?? [:]
    }

    private static func saveLocked(_ entries: [String: Entry]) {
        let fm = FileManager.default
        if entries.isEmpty {
            try? fm.removeItem(at: fileURL)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(entries) else { return }
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Create owner-only, then atomically replace.
        let tmp = fileURL.appendingPathExtension("tmp")
        fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        if (try? fm.replaceItemAt(fileURL, withItemAt: tmp)) == nil {
            try? fm.removeItem(at: fileURL)
            try? fm.moveItem(at: tmp, to: fileURL)
        }
    }
}
