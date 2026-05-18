import Foundation

struct Config: Codable {
    var lowBatteryCutoff: Int = 10
    var recoveryThreshold: Int = 25
    var recoveryRequiresAC: Bool = true
    var claudeProcessPattern: String = "claude"
    var excludePatterns: [String] = ["ClaudePowerMode", "mac-on-claude-code"]
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
    /// in config.json after you deploy your own Worker (see
    /// Cloudflare/README.md). The relay client appends `/ws` for WebSocket
    /// and uses the HTTPS-equivalent paths for REST.
    var relayURL: String = "https://your-page-relay.workers.dev"
    var interventionScanIntervalSeconds: Double = 10

    // Codex backend (Phase 2, read-only). Off by default — Phase 2 only
    // wires discovery + logging; nothing user-visible changes when it's on.
    var codexBackendEnabled: Bool = false
    var codexPath: String = "/usr/local/bin/codex"

    init() {}

    enum CodingKeys: String, CodingKey {
        case lowBatteryCutoff, recoveryThreshold, recoveryRequiresAC
        case claudeProcessPattern, excludePatterns, checkIntervalSeconds
        case requireRecentTranscriptActivity, transcriptActivityWindowSeconds, transcriptDirectory
        case rateLimitWatcherEnabled, autoResumeEnabled, carryOnPrompt
        case wakeViaPmsetEnabled, holdAssertionUntilReset
        case interventionDetectionEnabled, relayEnabled, relayURL, interventionScanIntervalSeconds
        case codexBackendEnabled, codexPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        self.lowBatteryCutoff = try c.decodeIfPresent(Int.self, forKey: .lowBatteryCutoff) ?? d.lowBatteryCutoff
        self.recoveryThreshold = try c.decodeIfPresent(Int.self, forKey: .recoveryThreshold) ?? d.recoveryThreshold
        self.recoveryRequiresAC = try c.decodeIfPresent(Bool.self, forKey: .recoveryRequiresAC) ?? d.recoveryRequiresAC
        self.claudeProcessPattern = try c.decodeIfPresent(String.self, forKey: .claudeProcessPattern) ?? d.claudeProcessPattern
        self.excludePatterns = try c.decodeIfPresent([String].self, forKey: .excludePatterns) ?? d.excludePatterns
        self.checkIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .checkIntervalSeconds) ?? d.checkIntervalSeconds
        self.requireRecentTranscriptActivity = try c.decodeIfPresent(Bool.self, forKey: .requireRecentTranscriptActivity) ?? d.requireRecentTranscriptActivity
        self.transcriptActivityWindowSeconds = try c.decodeIfPresent(Double.self, forKey: .transcriptActivityWindowSeconds) ?? d.transcriptActivityWindowSeconds
        self.transcriptDirectory = try c.decodeIfPresent(String.self, forKey: .transcriptDirectory) ?? d.transcriptDirectory
        self.rateLimitWatcherEnabled = try c.decodeIfPresent(Bool.self, forKey: .rateLimitWatcherEnabled) ?? d.rateLimitWatcherEnabled
        self.autoResumeEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoResumeEnabled) ?? d.autoResumeEnabled
        self.carryOnPrompt = try c.decodeIfPresent(String.self, forKey: .carryOnPrompt) ?? d.carryOnPrompt
        self.wakeViaPmsetEnabled = try c.decodeIfPresent(Bool.self, forKey: .wakeViaPmsetEnabled) ?? d.wakeViaPmsetEnabled
        self.holdAssertionUntilReset = try c.decodeIfPresent(Bool.self, forKey: .holdAssertionUntilReset) ?? d.holdAssertionUntilReset
        self.interventionDetectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .interventionDetectionEnabled) ?? d.interventionDetectionEnabled
        self.relayEnabled = try c.decodeIfPresent(Bool.self, forKey: .relayEnabled) ?? d.relayEnabled
        self.relayURL = try c.decodeIfPresent(String.self, forKey: .relayURL) ?? d.relayURL
        self.interventionScanIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .interventionScanIntervalSeconds) ?? d.interventionScanIntervalSeconds
        self.codexBackendEnabled = try c.decodeIfPresent(Bool.self, forKey: .codexBackendEnabled) ?? d.codexBackendEnabled
        self.codexPath = try c.decodeIfPresent(String.self, forKey: .codexPath) ?? d.codexPath
    }

    static var configURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("ClaudePowerMode", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    static func load() -> Config {
        let url = configURL
        if !FileManager.default.fileExists(atPath: url.path) {
            let defaults = Config()
            defaults.save()
            return defaults
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            Logger.shared.log("Failed to load config (\(error)) — using defaults")
            return Config()
        }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            try data.write(to: Config.configURL)
        } catch {
            Logger.shared.log("Failed to save config: \(error)")
        }
    }
}
