import Foundation

struct Config: Codable, Equatable {
    var lowBatteryCutoff: Int = 10
    var recoveryThreshold: Int = 25
    var recoveryRequiresAC: Bool = true
    var claudeProcessPattern: String = "claude"
    /// Command-line substrings that disqualify a process from counting as a
    /// Claude session. Our own binary is already excluded by the `claude`
    /// basename check; this list is for hand-tuned edge cases.
    var excludePatterns: [String] = ["ClaudePowerMode"]
    var checkIntervalSeconds: Double = 15
    var requireRecentTranscriptActivity: Bool = true
    var transcriptActivityWindowSeconds: Double = 90
    var transcriptDirectory: String = "~/.claude/projects"
    var rateLimitWatcherEnabled: Bool = true
    var autoResumeEnabled: Bool = false
    var carryOnPrompt: String = "carry on"
    var wakeViaPmsetEnabled: Bool = false
    var holdAssertionUntilReset: Bool = true
    var interventionDetectionEnabled: Bool = true
    var relayEnabled: Bool = false
    /// Base URL of the Cloudflare Worker. Fork-friendly default; override
    /// in Preferences (or config.json) after you deploy your own Worker (see
    /// Cloudflare/README.md). The relay client appends `/ws` for WebSocket
    /// and uses the HTTPS-equivalent paths for REST. The default is a
    /// placeholder that never resolves — `relayBaseURL` treats it as unset.
    var relayURL: String = Config.placeholderRelayURL

    // Codex backend. Off by default.
    var codexBackendEnabled: Bool = false
    /// Absolute path to `codex`. Empty = auto-discover (~/.local/bin,
    /// /opt/homebrew/bin, /usr/local/bin, npm-global, nvm).
    var codexPath: String = ""

    /// Keep the Mac awake while local models generate (Ollama, LM Studio,
    /// llama.cpp, MLX) and while terminal tools on them produce output.
    /// Read-only and loopback-only; idle loaded models never count.
    var localModelsEnabled: Bool = true

    // Paging behaviour (v2).
    /// Idle pages ("Claude finished its turn") are held back while the user
    /// has touched the Mac within this many seconds, and sent once they've
    /// walked away. 0 disables the check. Approvals/questions always page.
    var idlePageOnlyWhenAwaySeconds: Double = 120
    /// How long a session must sit idle (turn finished, nothing typed)
    /// before it pages.
    var idlePageDelaySeconds: Double = 60
    /// Keep the Mac awake while a page is waiting for a reply (so the reply
    /// can still be delivered), but only for this long. 0 = don't hold.
    var holdAwakeForPendingPageMinutes: Double = 60
    /// If the target session's process has exited, deliver a text reply via a
    /// background `claude --resume --print` (output goes to a log file).
    /// Never used while the session is still running.
    var headlessResumeFallbackEnabled: Bool = true
    /// Show live sessions on the paired phone (end-to-end encrypted with
    /// the pairing's session key) and let it type into them or stop them
    /// through the same input gate as replies (SESSIONS-PROTOCOL.md).
    var remoteSessionsEnabled: Bool = true

    // Keeping awake (v3).
    /// While agents are working on AC power, also hold a
    /// `PreventSystemSleep` assertion so the Mac stays awake with the lid
    /// closed. macOS honours that assertion on AC only, so it changes
    /// nothing on battery.
    var keepAwakeLidClosedOnAC: Bool = true
    /// Opt-in: keep working with the lid closed on battery, via
    /// `sudo -n pmset -a disablesleep 1` (needs the power helper, installed
    /// from the app or by `./install.sh --enable-power-helpers`). Only while agents are working, the battery
    /// is comfortably above the cutoff and the Mac isn't hot; a LaunchAgent
    /// watchdog undoes it if Page dies.
    var keepAwakeLidClosedOnBattery: Bool = false

    // Low battery (v3).
    /// What Page does when the battery reaches `lowBatteryCutoff` on battery
    /// power: ask busy agents to stop now and summarise ("pause"), to finish
    /// the current step first ("afterTurn"), or only stop keeping the Mac
    /// awake ("off").
    var lowBatteryAction: LowBatteryAction = .pause
    /// After asking the agents to pause, keep the Mac awake this long so
    /// they can write their summary, then let it sleep.
    var lowBatteryPauseGraceSeconds: Double = 90
    /// When power comes back (see `recoveryThreshold` / `recoveryRequiresAC`),
    /// tell the sessions Page paused to carry on.
    var resumeAfterBatteryRecovery: Bool = true

    init() {}

    // `interventionScanIntervalSeconds` used to live here but nothing ever
    // read it (interventions are scanned on every tick). Old files that
    // still carry the key decode fine — unknown keys are ignored.
    enum CodingKeys: String, CodingKey {
        case lowBatteryCutoff, recoveryThreshold, recoveryRequiresAC
        case claudeProcessPattern, excludePatterns, checkIntervalSeconds
        case requireRecentTranscriptActivity, transcriptActivityWindowSeconds, transcriptDirectory
        case rateLimitWatcherEnabled, autoResumeEnabled, carryOnPrompt
        case wakeViaPmsetEnabled, holdAssertionUntilReset
        case interventionDetectionEnabled, relayEnabled, relayURL
        case codexBackendEnabled, codexPath
        case localModelsEnabled
        case idlePageOnlyWhenAwaySeconds, idlePageDelaySeconds
        case holdAwakeForPendingPageMinutes, headlessResumeFallbackEnabled
        case remoteSessionsEnabled
        case keepAwakeLidClosedOnAC, keepAwakeLidClosedOnBattery
        case lowBatteryAction, lowBatteryPauseGraceSeconds, resumeAfterBatteryRecovery
    }

    /// Collects per-key decode problems. Passed through `decoder.userInfo`
    /// because `init(from:)` has nowhere else to report them.
    final class DecodeIssues {
        var messages: [String] = []
    }
    static let decodeIssuesKey = CodingUserInfoKey(rawValue: "page.config.decodeIssues")!

    /// Every key is decoded on its own: config.json is hand-edited (it used to
    /// be the only way to set the relay up), and one mistyped value — say
    /// `"relayEnabled": "true"` — must not throw away the whole file and
    /// silently turn paging off. A bad key falls back to its default and is
    /// reported through `DecodeIssues`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let issues = decoder.userInfo[Config.decodeIssuesKey] as? DecodeIssues
        let d = Config()

        func field<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            do {
                return try c.decodeIfPresent(T.self, forKey: key) ?? fallback
            } catch {
                issues?.messages.append("“\(key.stringValue)” has the wrong type — using the default")
                return fallback
            }
        }

        lowBatteryCutoff = field(.lowBatteryCutoff, d.lowBatteryCutoff)
        recoveryThreshold = field(.recoveryThreshold, d.recoveryThreshold)
        recoveryRequiresAC = field(.recoveryRequiresAC, d.recoveryRequiresAC)
        claudeProcessPattern = field(.claudeProcessPattern, d.claudeProcessPattern)
        excludePatterns = field(.excludePatterns, d.excludePatterns)
        checkIntervalSeconds = field(.checkIntervalSeconds, d.checkIntervalSeconds)
        requireRecentTranscriptActivity = field(.requireRecentTranscriptActivity, d.requireRecentTranscriptActivity)
        transcriptActivityWindowSeconds = field(.transcriptActivityWindowSeconds, d.transcriptActivityWindowSeconds)
        transcriptDirectory = field(.transcriptDirectory, d.transcriptDirectory)
        rateLimitWatcherEnabled = field(.rateLimitWatcherEnabled, d.rateLimitWatcherEnabled)
        autoResumeEnabled = field(.autoResumeEnabled, d.autoResumeEnabled)
        carryOnPrompt = field(.carryOnPrompt, d.carryOnPrompt)
        wakeViaPmsetEnabled = field(.wakeViaPmsetEnabled, d.wakeViaPmsetEnabled)
        holdAssertionUntilReset = field(.holdAssertionUntilReset, d.holdAssertionUntilReset)
        interventionDetectionEnabled = field(.interventionDetectionEnabled, d.interventionDetectionEnabled)
        relayEnabled = field(.relayEnabled, d.relayEnabled)
        relayURL = field(.relayURL, d.relayURL)
        codexBackendEnabled = field(.codexBackendEnabled, d.codexBackendEnabled)
        codexPath = field(.codexPath, d.codexPath)
        localModelsEnabled = field(.localModelsEnabled, d.localModelsEnabled)
        idlePageOnlyWhenAwaySeconds = field(.idlePageOnlyWhenAwaySeconds, d.idlePageOnlyWhenAwaySeconds)
        idlePageDelaySeconds = field(.idlePageDelaySeconds, d.idlePageDelaySeconds)
        holdAwakeForPendingPageMinutes = field(.holdAwakeForPendingPageMinutes, d.holdAwakeForPendingPageMinutes)
        headlessResumeFallbackEnabled = field(.headlessResumeFallbackEnabled, d.headlessResumeFallbackEnabled)
        remoteSessionsEnabled = field(.remoteSessionsEnabled, d.remoteSessionsEnabled)
        keepAwakeLidClosedOnAC = field(.keepAwakeLidClosedOnAC, d.keepAwakeLidClosedOnAC)
        keepAwakeLidClosedOnBattery = field(.keepAwakeLidClosedOnBattery, d.keepAwakeLidClosedOnBattery)
        lowBatteryAction = field(.lowBatteryAction, d.lowBatteryAction)
        lowBatteryPauseGraceSeconds = field(.lowBatteryPauseGraceSeconds, d.lowBatteryPauseGraceSeconds)
        resumeAfterBatteryRecovery = field(.resumeAfterBatteryRecovery, d.resumeAfterBatteryRecovery)
    }

    // MARK: validation

    /// Allowed ranges. Shared with the Preferences sliders so the UI can
    /// never produce a value `validated()` would rewrite.
    enum Limits {
        static let checkInterval: ClosedRange<Double> = 2...600
        static let batteryPercent: ClosedRange<Int> = 0...100
        static let transcriptActivityWindow: ClosedRange<Double> = 5...3600
        static let idlePageAway: ClosedRange<Double> = 0...3600
        static let idlePageDelay: ClosedRange<Double> = 0...3600
        static let holdAwakeMinutes: ClosedRange<Double> = 0...1440
        /// Long enough for a two-line summary even on a slow turn; short
        /// enough that a 10% battery isn't drained waiting.
        static let lowBatteryPauseGrace: ClosedRange<Double> = 15...600
    }

    /// Returns a copy with every value forced into a range the rest of the
    /// app can rely on, plus a human-readable note for each change.
    ///
    /// Why this matters: `checkIntervalSeconds: 0` became a 0.0001 s timer
    /// that spawned pgrep in a tight loop, and `recoveryThreshold` below
    /// `lowBatteryCutoff` made the lockout trip and clear on every tick.
    func validated() -> (config: Config, adjustments: [String]) {
        var c = self
        var notes: [String] = []
        let d = Config()

        func clamp<T: Comparable>(_ value: inout T, _ range: ClosedRange<T>, _ name: String) {
            let clamped = Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
            if clamped != value {
                notes.append("\(name) \(value) is outside \(range.lowerBound)…\(range.upperBound) — using \(clamped)")
                value = clamped
            }
        }
        func finite(_ value: inout Double, _ fallback: Double, _ name: String) {
            if !value.isFinite {
                notes.append("\(name) is not a number — using \(fallback)")
                value = fallback
            }
        }
        func nonEmpty(_ value: inout String, _ fallback: String, _ name: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                notes.append("\(name) is empty — using “\(fallback)”")
                value = fallback
            } else {
                value = trimmed
            }
        }

        finite(&c.checkIntervalSeconds, d.checkIntervalSeconds, "checkIntervalSeconds")
        clamp(&c.checkIntervalSeconds, Limits.checkInterval, "checkIntervalSeconds")
        finite(&c.transcriptActivityWindowSeconds, d.transcriptActivityWindowSeconds, "transcriptActivityWindowSeconds")
        clamp(&c.transcriptActivityWindowSeconds, Limits.transcriptActivityWindow, "transcriptActivityWindowSeconds")
        finite(&c.idlePageOnlyWhenAwaySeconds, d.idlePageOnlyWhenAwaySeconds, "idlePageOnlyWhenAwaySeconds")
        clamp(&c.idlePageOnlyWhenAwaySeconds, Limits.idlePageAway, "idlePageOnlyWhenAwaySeconds")
        finite(&c.idlePageDelaySeconds, d.idlePageDelaySeconds, "idlePageDelaySeconds")
        clamp(&c.idlePageDelaySeconds, Limits.idlePageDelay, "idlePageDelaySeconds")
        finite(&c.holdAwakeForPendingPageMinutes, d.holdAwakeForPendingPageMinutes, "holdAwakeForPendingPageMinutes")
        clamp(&c.holdAwakeForPendingPageMinutes, Limits.holdAwakeMinutes, "holdAwakeForPendingPageMinutes")
        finite(&c.lowBatteryPauseGraceSeconds, d.lowBatteryPauseGraceSeconds, "lowBatteryPauseGraceSeconds")
        clamp(&c.lowBatteryPauseGraceSeconds, Limits.lowBatteryPauseGrace, "lowBatteryPauseGraceSeconds")

        clamp(&c.lowBatteryCutoff, Limits.batteryPercent, "lowBatteryCutoff")
        clamp(&c.recoveryThreshold, Limits.batteryPercent, "recoveryThreshold")
        // Recovery below the cutoff would clear and re-trip the lockout in
        // the same tick forever — and every trip messages the agents. Equal
        // is fine while recovery requires AC: trip needs battery power, so
        // the two can never both hold. Without the AC requirement, trip is
        // `<= cutoff` and recovery `>= recovery`, so recovery must be at
        // least one point higher. (BatteryPolicy guards this too.)
        if c.recoveryThreshold < c.lowBatteryCutoff {
            notes.append("recoveryThreshold \(c.recoveryThreshold) is below lowBatteryCutoff \(c.lowBatteryCutoff) — using \(c.lowBatteryCutoff)")
            c.recoveryThreshold = c.lowBatteryCutoff
        }
        if !c.recoveryRequiresAC && c.recoveryThreshold <= c.lowBatteryCutoff && c.lowBatteryCutoff < 100 {
            let fixed = c.lowBatteryCutoff + 1
            notes.append("recoveryThreshold \(c.recoveryThreshold) must be above lowBatteryCutoff \(c.lowBatteryCutoff) when recovery doesn’t require AC — using \(fixed)")
            c.recoveryThreshold = fixed
        }

        nonEmpty(&c.claudeProcessPattern, d.claudeProcessPattern, "claudeProcessPattern")
        nonEmpty(&c.transcriptDirectory, d.transcriptDirectory, "transcriptDirectory")
        nonEmpty(&c.carryOnPrompt, d.carryOnPrompt, "carryOnPrompt")
        c.excludePatterns = c.excludePatterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        c.relayURL = c.relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        c.codexPath = c.codexPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return (c, notes)
    }

    // MARK: relay URL

    static let placeholderRelayHost = "your-page-relay.workers.dev"
    static let placeholderRelayURL = "https://\(placeholderRelayHost)"

    enum RelayURLProblem: Error, Equatable {
        case empty
        case placeholder
        case invalid
        /// Plain http would send the bearer token in the clear. Allowed
        /// only for a local `wrangler dev`.
        case insecure

        var message: String {
            switch self {
            case .empty: return "No relay URL set."
            case .placeholder: return "The relay URL is still the example placeholder — paste your Worker’s URL."
            case .invalid: return "That doesn’t look like a URL (expected https://<name>.<account>.workers.dev)."
            case .insecure: return "Use https:// — plain http would send your pairing token unencrypted."
            }
        }
    }

    /// Normalises whatever the user typed into the relay's https base URL:
    /// adds a missing scheme, maps ws(s) to http(s), drops a trailing `/ws`,
    /// slashes, query and fragment. Pure; used by the relay client, the
    /// pairing QR and Preferences so all three agree on what's valid.
    static func validatedRelayURL(_ raw: String) -> Result<URL, RelayURLProblem> {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .failure(.empty) }
        if !text.contains("://") { text = "https://" + text }
        guard var comps = URLComponents(string: text),
              let host = comps.host?.lowercased(), !host.isEmpty,
              !host.contains(" ") else {
            return .failure(.invalid)
        }
        let isLocal = host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
        switch comps.scheme?.lowercased() {
        case "https", "wss": comps.scheme = "https"
        case "http", "ws":
            guard isLocal else { return .failure(.insecure) }
            comps.scheme = "http"
        default:
            return .failure(.invalid)
        }
        if !isLocal && !host.contains(".") { return .failure(.invalid) }
        if host == placeholderRelayHost { return .failure(.placeholder) }

        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/ws") { path.removeLast(3) }
        while path.hasSuffix("/") { path.removeLast() }
        comps.path = path
        comps.host = host
        comps.query = nil
        comps.fragment = nil
        comps.user = nil
        comps.password = nil
        guard let url = comps.url else { return .failure(.invalid) }
        return .success(url)
    }

    /// The relay's https base URL, or nil when unset / placeholder / invalid.
    var relayBaseURL: URL? { try? Config.validatedRelayURL(relayURL).get() }

    var isRelayURLPlaceholder: Bool {
        Config.validatedRelayURL(relayURL) == .failure(.placeholder)
    }

    /// The problem with the configured relay URL, if any.
    var relayURLProblem: RelayURLProblem? {
        if case .failure(let p) = Config.validatedRelayURL(relayURL) { return p }
        return nil
    }

    /// Relay switched on AND pointing somewhere real.
    var relayIsUsable: Bool { relayEnabled && relayBaseURL != nil }

    // MARK: persistence

    static var configURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("ClaudePowerMode", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    /// Result of reading config.json.
    struct LoadResult {
        /// The parsed (and validated) config, or nil if the file couldn't
        /// be parsed at all. Callers decide what to fall back to: the
        /// Coordinator keeps its last good config, a first launch uses
        /// defaults.
        let config: Config?
        /// User-facing description of what went wrong (nil = all good).
        /// Set for unparseable files and for keys that were defaulted or
        /// clamped. The menu shows it.
        let problem: String?
        /// Where the unreadable file was copied before anything else touched it.
        let backupURL: URL?

        /// True when the file is unusable as a base for saving.
        var isUnreadable: Bool { config == nil }
    }

    /// Reads config.json without ever overwriting it (except to create it
    /// on first launch). A malformed file is copied to
    /// `config.json.bad-<timestamp>` so the user's hand edits survive even
    /// if something later saves over it.
    static func loadResult(from url: URL = Config.configURL) -> LoadResult {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            let defaults = Config()
            do { try defaults.write(to: url) } catch {
                Logger.shared.log("Couldn't create default config at \(url.path): \(error)")
            }
            return LoadResult(config: defaults, problem: nil, backupURL: nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Logger.shared.log("Couldn't read config (\(error.localizedDescription))")
            return LoadResult(config: nil, problem: "config.json can’t be read: \(error.localizedDescription)", backupURL: nil)
        }
        let issues = DecodeIssues()
        let decoder = JSONDecoder()
        decoder.userInfo[decodeIssuesKey] = issues
        do {
            let parsed = try decoder.decode(Config.self, from: data)
            let (valid, adjustments) = parsed.validated()
            let notes = issues.messages + adjustments
            if !notes.isEmpty {
                Logger.shared.log("Config loaded with \(notes.count) adjustment(s): \(notes.joined(separator: "; "))")
            }
            let problem = notes.isEmpty ? nil : "config.json: " + notes.joined(separator: "; ")
            return LoadResult(config: valid, problem: problem, backupURL: nil)
        } catch {
            let summary = describe(decodingError: error)
            let backup = backUpUnreadable(data: data, next: url)
            Logger.shared.log("Config is malformed (\(summary)) — not using it; backup at \(backup?.path ?? "n/a")")
            var problem = "config.json has an error (\(summary))"
            if let backup { problem += " — a copy was saved as \(backup.lastPathComponent)" }
            return LoadResult(config: nil, problem: problem, backupURL: backup)
        }
    }

    /// Convenience for callers that just need *a* config (backend default
    /// arguments, tests): the parsed file, or defaults if it's unreadable.
    static func load() -> Config {
        loadResult().config ?? Config()
    }

    /// Atomically replaces config.json (temp file + rename), so a crash
    /// mid-write can never leave a truncated file behind.
    func write(to url: URL = Config.configURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Logging wrapper around `write()` for callers with no UI to report to.
    @discardableResult
    func save() -> Bool {
        do {
            try write()
            return true
        } catch {
            Logger.shared.log("Failed to save config: \(error)")
            return false
        }
    }

    // MARK: helpers

    private static let backupLock = NSLock()
    private static var backedUpHashes: Set<Int> = []

    /// Copies an unparseable file aside once per distinct content per
    /// process (load() runs from several places at launch).
    private static func backUpUnreadable(data: Data, next url: URL) -> URL? {
        backupLock.lock()
        defer { backupLock.unlock() }
        let hash = data.hashValue
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            return f.string(from: Date())
        }()
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).bad-\(stamp)")
        if backedUpHashes.contains(hash) {
            // Already copied this exact content; point at the newest copy.
            let dir = url.deletingLastPathComponent()
            let prefix = url.lastPathComponent + ".bad-"
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                .filter { $0.hasPrefix(prefix) }.sorted().last
            return existing.map { dir.appendingPathComponent($0) }
        }
        do {
            try data.write(to: backup, options: .atomic)
            backedUpHashes.insert(hash)
            return backup
        } catch {
            Logger.shared.log("Couldn't back up malformed config: \(error)")
            return nil
        }
    }

    /// One-line, user-readable reason a decode failed.
    static func describe(decodingError error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let ctx):
            if let underlying = ctx.underlyingError as NSError?,
               let detail = underlying.userInfo[NSDebugDescriptionErrorKey] as? String {
                return "invalid JSON: \(detail)"
            }
            return "invalid JSON"
        case DecodingError.typeMismatch(_, let ctx), DecodingError.valueNotFound(_, let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "the top level must be a JSON object" : "“\(path)”: \(ctx.debugDescription)"
        default:
            return error.localizedDescription
        }
    }
}

/// `lowBatteryAction` in config.json. An unknown string falls back to the
/// default (`pause`) and is reported like any other mistyped key.
enum LowBatteryAction: String, Codable, CaseIterable, Equatable {
    /// Ask busy agents to stop now and write a two-line summary.
    case pause
    /// Ask busy agents to finish the step they're on, then stop and
    /// summarise. Backends queue this message instead of interrupting.
    case afterTurn
    /// Don't message the agents; just stop keeping the Mac awake.
    case off

    var menuTitle: String {
        switch self {
        case .pause: return "Ask agents to pause now"
        case .afterTurn: return "Ask agents to stop after the current step"
        case .off: return "Don’t message agents — just let the Mac sleep"
        }
    }
}
