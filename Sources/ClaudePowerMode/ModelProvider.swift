import Foundation

/// Which model backend an agent session talks to: Anthropic's API, a model
/// server on this Mac (Ollama, LM Studio), or something else.
///
/// Derived from the agent's own launch configuration (environment,
/// settings.json `env`, argv) and kept as nothing more than this enum —
/// never a token, never a URL.
enum ModelProvider: String, Codable, Equatable {
    case anthropic
    case ollama
    case lmStudio
    /// A loopback server that isn't recognisably Ollama or LM Studio. Not
    /// treated as local: it may be a proxy that forwards to Anthropic.
    case otherLocal
    /// Bedrock, Vertex, a custom gateway, or an Ollama `:cloud` model.
    case cloudGateway
    case unknown

    /// A model running on this Mac (the battery is paying for inference).
    var isLocal: Bool { self == .ollama || self == .lmStudio }

    var isKnownAnthropic: Bool { self == .anthropic }

    /// Positively known to run somewhere other than Anthropic's API.
    var isKnownNonAnthropic: Bool {
        switch self {
        case .ollama, .lmStudio, .otherLocal, .cloudGateway: return true
        case .anthropic, .unknown: return false
        }
    }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .otherLocal: return "a local server"
        case .cloudGateway: return "a cloud gateway"
        case .unknown: return "unknown"
        }
    }

    /// Lenient: a value written by a newer build decodes as `.unknown`
    /// instead of failing the whole file.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ModelProvider(rawValue: raw) ?? .unknown
    }
}

/// Pure classification of an agent's provider from its configuration.
///
/// Token-like values (ANTHROPIC_AUTH_TOKEN) are only ever compared for
/// equality with the fixed literals Ollama and LM Studio document
/// ("ollama", "lmstudio"); they are never stored, returned or logged.
enum ModelProviderClassifier {
    /// Keys whose model names are checked for Ollama's `:cloud` suffix.
    static let claudeModelKeys = [
        "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    ]

    /// Claude Code's provider from its process environment and the merged
    /// settings.json `env`. Settings override the process per key (Claude
    /// Code applies them on top of its environment), and the result fails
    /// closed: if either source on its own points away from Anthropic, so
    /// does the result.
    static func claude(env: [String: String], settingsEnv: [String: String]) -> ModelProvider {
        var merged = env
        for (k, v) in settingsEnv { merged[k] = v }
        for candidate in [classifyClaudeEnv(merged), classifyClaudeEnv(env), classifyClaudeEnv(settingsEnv)]
        where !candidate.isKnownAnthropic {
            return candidate
        }
        return .anthropic
    }

    /// One environment, on its own. Never returns `.unknown`.
    static func classifyClaudeEnv(_ env: [String: String]) -> ModelProvider {
        if isTruthy(env["CLAUDE_CODE_USE_BEDROCK"]) || isTruthy(env["CLAUDE_CODE_USE_VERTEX"]) {
            return .cloudGateway
        }
        // Ollama's cloud models run on Ollama's servers, whatever the base
        // URL says (docs; unverified on a real install).
        if claudeModelKeys.contains(where: { isOllamaCloudModel(env[$0]) }) {
            return .cloudGateway
        }
        let base = (env["ANTHROPIC_BASE_URL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return .anthropic }
        guard let (host, port) = hostAndPort(base) else { return .cloudGateway }
        if host == "api.anthropic.com" { return .anthropic }
        guard isLoopbackHost(host) else { return .cloudGateway }
        let token = env["ANTHROPIC_AUTH_TOKEN"]
        // Ports and tokens are what `ollama launch claude` and LM Studio's
        // Claude Code guide set (docs; unverified on a real install).
        if port == 11434 || token == "ollama" { return .ollama }
        if port == 1234 || token == "lmstudio" { return .lmStudio }
        return .otherLocal
    }

    /// Codex's provider, when it is a local one. Hosted Codex returns
    /// `.unknown`: the Anthropic notion doesn't apply to it, and only
    /// "local or not" matters for Codex.
    static func codex(argv: [String], threadModelProvider: String?) -> ModelProvider {
        switch threadModelProvider?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "ollama", "ollama-launch": return .ollama
        case "lmstudio": return .lmStudio
        default: break
        }
        return codexArgvProvider(argv) ?? .unknown
    }

    /// Local provider named by Codex flags, or nil:
    /// `--oss` (Codex's default local provider is Ollama — docs, unverified),
    /// `--local-provider ollama|lmstudio` (or `=`), `--profile ollama-launch`
    /// (what `ollama launch codex` passes), and `-c` overrides of
    /// `model_providers.ollama-launch…`, `model_provider`, `oss_provider`.
    static func codexArgvProvider(_ argv: [String]) -> ModelProvider? {
        var oss = false
        var ossProvider: ModelProvider?
        var explicit: ModelProvider?

        func named(_ raw: String) -> ModelProvider? {
            switch unquote(raw).lowercased() {
            case "ollama", "ollama-launch": return .ollama
            case "lmstudio": return .lmStudio
            default: return nil
            }
        }
        func config(_ raw: String) {
            guard let eq = raw.firstIndex(of: "=") else { return }
            let key = raw[..<eq].trimmingCharacters(in: .whitespaces)
            let value = String(raw[raw.index(after: eq)...])
            if key.hasPrefix("model_providers.ollama-launch") {
                explicit = explicit ?? .ollama
            } else if key == "model_provider" || key == "profile" {
                if let p = named(value) { explicit = explicit ?? p }
            } else if key == "oss_provider" {
                ossProvider = named(value)
            }
        }

        var i = 0
        while i < argv.count {
            let tok = argv[i]
            if tok == "--" { break }
            let next: String? = i + 1 < argv.count ? argv[i + 1] : nil
            switch tok {
            case "--oss":
                oss = true
            case "--local-provider":
                if let next { ossProvider = named(next) ?? ossProvider; oss = true; i += 1 }
            case "--profile", "-p":
                if let next { if unquote(next) == "ollama-launch" { explicit = explicit ?? .ollama }; i += 1 }
            case "-c", "--config":
                if let next { config(next); i += 1 }
            default:
                if tok.hasPrefix("--local-provider=") {
                    ossProvider = named(String(tok.dropFirst("--local-provider=".count))) ?? ossProvider
                    oss = true
                } else if tok.hasPrefix("--profile=") {
                    if unquote(String(tok.dropFirst("--profile=".count))) == "ollama-launch" { explicit = explicit ?? .ollama }
                } else if tok.hasPrefix("--config=") {
                    config(String(tok.dropFirst("--config=".count)))
                }
            }
            i += 1
        }
        if let explicit { return explicit }
        if oss { return ossProvider ?? .ollama }
        return nil
    }

    /// Whether a transcript's `message.model` names a Claude model: true
    /// for "claude-…", false for anything else, nil when there's nothing
    /// to go on (no model, or Claude Code's locally generated "<synthetic>").
    static func transcriptModelIsAnthropic(_ model: String?) -> Bool? {
        guard let m = model?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty, m != "<synthetic>" else {
            return nil
        }
        return m.lowercased().hasPrefix("claude-")
    }

    // MARK: helpers

    /// An Ollama cloud model name: tag `cloud` ("glm-4.6:cloud") or a tag
    /// ending in "-cloud" ("gpt-oss:120b-cloud").
    static func isOllamaCloudModel(_ model: String?) -> Bool {
        guard let m = model?.trimmingCharacters(in: .whitespaces).lowercased(),
              let colon = m.lastIndex(of: ":") else { return false }
        let tag = m[m.index(after: colon)...]
        return tag == "cloud" || tag.hasSuffix("-cloud")
    }

    static func isTruthy(_ value: String?) -> Bool {
        guard let v = value?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return v == "1" || v == "true" || v == "yes"
    }

    /// Lower-cased host (IPv6 brackets stripped) and port (scheme default
    /// when absent). A URL without a scheme ("localhost:11434") is read as
    /// http.
    static func hostAndPort(_ url: String) -> (host: String, port: Int?)? {
        let full = url.contains("://") ? url : "http://" + url
        guard let comps = URLComponents(string: full), var host = comps.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let port = comps.port ?? {
            switch comps.scheme?.lowercased() {
            case "http": return 80
            case "https": return 443
            default: return nil
            }
        }()
        return (host, port)
    }

    /// 127.0.0.0/8, localhost, ::1 and 0.0.0.0.
    static func isLoopbackHost(_ raw: String) -> Bool {
        var host = raw.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host == "::1" || host == "0.0.0.0" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { p in
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCII), let n = Int(p) else { return false }
            return (0...255).contains(n)
        }
    }

    private static func unquote(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.count >= 2, let f = s.first, let l = s.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }
}

/// The `env` objects of Claude Code's settings files, reduced to the
/// provider-relevant keys (ANTHROPIC_* / CLAUDE_CODE_USE_* from
/// `ProcArgs.envAllowlist`). Everything else is dropped on read.
enum ClaudeSettingsEnv {
    static let keys: Set<String> = ProcArgs.envAllowlist.filter {
        $0.hasPrefix("ANTHROPIC_") || $0.hasPrefix("CLAUDE_CODE_USE_")
    }

    /// `~/.claude/settings.json`, then (with a cwd) the project's
    /// `.claude/settings.json` and `.claude/settings.local.json`; later
    /// files override earlier ones. Missing or malformed files are skipped.
    /// Managed (enterprise) settings are not read.
    static func read(cwd: String?, home: String = NSHomeDirectory()) -> [String: String] {
        var paths = [(home as NSString).appendingPathComponent(".claude/settings.json")]
        if let cwd, !cwd.isEmpty {
            paths.append((cwd as NSString).appendingPathComponent(".claude/settings.json"))
            paths.append((cwd as NSString).appendingPathComponent(".claude/settings.local.json"))
        }
        var env: [String: String] = [:]
        for path in paths {
            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber,
               size.intValue > 1 << 20 { continue }
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            for (k, v) in parse(data) { env[k] = v }
        }
        return env
    }

    /// Pure. Allowlisted string (or number / boolean) values of `env`.
    static func parse(_ data: Data) -> [String: String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["env"] as? [String: Any] else { return [:] }
        var env: [String: String] = [:]
        for key in keys {
            switch raw[key] {
            case let s as String: env[key] = s
            case let n as NSNumber: env[key] = CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
            default: break
            }
        }
        return env
    }
}

/// Whether Page may restart a Claude session in the background
/// (`claude --resume … --print`, from a phone reply or a scheduled resume).
/// Those runs don't carry the session's environment, so they always go to
/// the user's Anthropic account — for a session that ran on a local model
/// or a gateway, that silently switches provider. Requires POSITIVE
/// evidence the session ran on Anthropic.
enum ResumeProviderGate {
    struct Evidence: Equatable {
        /// What `SessionProviderStore` recorded while the session was live.
        let stored: ModelProvider?
        /// The transcript's newest real assistant `message.model`.
        let lastAssistantModel: String?
    }

    /// Pure. nil when allowed: the store says `.anthropic`, or the store
    /// has nothing and the transcript's last model is "claude-…".
    static func refusal(_ e: Evidence) -> String? {
        if e.stored == .anthropic { return nil }
        if e.stored == nil, ModelProviderClassifier.transcriptModelIsAnthropic(e.lastAssistantModel) == true { return nil }
        return message(e)
    }

    static func message(_ e: Evidence) -> String {
        var parts: [String] = []
        if let p = e.stored, p.isKnownNonAnthropic { parts.append(p.displayName) }
        if let m = e.lastAssistantModel, ModelProviderClassifier.transcriptModelIsAnthropic(m) == false {
            parts.append(String(m.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.prefix(60).map(Character.init)))
        }
        let label = parts.isEmpty ? "model unknown" : parts.joined(separator: " / ")
        return "This session ran on a non-Anthropic model (\(label)). Page can't restart it in the background — "
            + "that would run on your Anthropic account. Reply at the Mac."
    }

    /// Reads the evidence: the provider store and the transcript tail.
    static func evidence(sessionId: String, transcript: URL?,
                         stored: (String) -> ModelProvider? = { SessionProviderStore.provider(for: $0) }) -> Evidence {
        Evidence(stored: stored(sessionId), lastAssistantModel: TranscriptParser.lastAssistantModel(transcript: transcript))
    }

    /// For a rate-limit event (scheduled resume): nil when allowed.
    static func refusal(for event: RateLimitEvent) -> String? {
        let transcript = event.transcriptPath.isEmpty ? nil : URL(fileURLWithPath: event.transcriptPath)
        return refusal(evidence(sessionId: event.sessionId, transcript: transcript))
    }
}

extension BatteryPauseSupport {
    /// Pure. `PausedSession.detail` for a session on a local model, which
    /// only gets Esc: a summary generated by a local model is the most
    /// expensive thing Page could ask for at the battery cutoff.
    static func localModelPauseDetail(stopped: Bool) -> String {
        stopped
            ? "Interrupted (local model — no summary requested, to save battery)"
            : "Pressed Esc but couldn't confirm it stopped (local model — no summary requested, to save battery)"
    }
}
