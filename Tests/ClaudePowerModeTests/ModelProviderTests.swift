import XCTest
@testable import ClaudePowerMode

/// Pure provider classification: Claude Code's env / settings, Codex argv
/// and thread metadata, transcript model names, and the settings reader.
final class ModelProviderTests: XCTestCase {
    private typealias C = ModelProviderClassifier

    // MARK: Claude env

    func testOllamaLaunchEnv() {
        let env = ["ANTHROPIC_BASE_URL": "http://127.0.0.1:11434", "ANTHROPIC_AUTH_TOKEN": "ollama"]
        XCTAssertEqual(C.claude(env: env, settingsEnv: [:]), .ollama)
        XCTAssertTrue(ModelProvider.ollama.isLocal)
        XCTAssertFalse(ModelProvider.ollama.isKnownAnthropic)
    }

    func testLMStudioEnv() {
        let env = ["ANTHROPIC_BASE_URL": "http://localhost:1234", "ANTHROPIC_AUTH_TOKEN": "lmstudio"]
        XCTAssertEqual(C.claude(env: env, settingsEnv: [:]), .lmStudio)
        XCTAssertTrue(ModelProvider.lmStudio.isLocal)
    }

    func testPortOrTokenAloneIdentifiesTheServer() {
        XCTAssertEqual(C.claude(env: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:11434"], settingsEnv: [:]), .ollama)
        XCTAssertEqual(C.claude(env: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:9000", "ANTHROPIC_AUTH_TOKEN": "ollama"],
                                settingsEnv: [:]), .ollama)
        XCTAssertEqual(C.claude(env: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:1234"], settingsEnv: [:]), .lmStudio)
        XCTAssertEqual(C.claude(env: ["ANTHROPIC_BASE_URL": "http://[::1]:11434"], settingsEnv: [:]), .ollama)
        XCTAssertEqual(C.claude(env: ["ANTHROPIC_BASE_URL": "localhost:11434"], settingsEnv: [:]), .ollama, "no scheme")
        XCTAssertEqual(C.claude(env: ["ANTHROPIC_BASE_URL": "http://0.0.0.0:1234/"], settingsEnv: [:]), .lmStudio)
        XCTAssertEqual(C.claude(env: ["ANTHROPIC_BASE_URL": "http://LOCALHOST:11434"], settingsEnv: [:]), .ollama)
        XCTAssertEqual(C.claude(env: ["ANTHROPIC_BASE_URL": "http://127.4.5.6:11434"], settingsEnv: [:]), .ollama)
    }

    func testAnthropicDefaults() {
        XCTAssertEqual(C.claude(env: [:], settingsEnv: [:]), .anthropic)
        XCTAssertEqual(C.claude(env: ["ANTHROPIC_BASE_URL": ""], settingsEnv: [:]), .anthropic)
        XCTAssertEqual(C.claude(env: ["ANTHROPIC_BASE_URL": "https://api.anthropic.com"], settingsEnv: [:]), .anthropic)
        XCTAssertEqual(C.claude(env: ["ANTHROPIC_BASE_URL": "https://API.anthropic.com/"], settingsEnv: [:]), .anthropic)
        XCTAssertEqual(C.claude(env: ["CLAUDE_CODE_USE_BEDROCK": "0"], settingsEnv: [:]), .anthropic)
        XCTAssertTrue(ModelProvider.anthropic.isKnownAnthropic)
        XCTAssertFalse(ModelProvider.anthropic.isLocal)
    }

    func testBedrockAndVertex() {
        XCTAssertEqual(C.claude(env: ["CLAUDE_CODE_USE_BEDROCK": "1"], settingsEnv: [:]), .cloudGateway)
        XCTAssertEqual(C.claude(env: ["CLAUDE_CODE_USE_VERTEX": "true"], settingsEnv: [:]), .cloudGateway)
        XCTAssertEqual(C.claude(env: ["CLAUDE_CODE_USE_VERTEX": "YES"], settingsEnv: [:]), .cloudGateway)
        // Claude Code's own truthiness also accepts "on".
        XCTAssertEqual(C.claude(env: ["CLAUDE_CODE_USE_BEDROCK": "on"], settingsEnv: [:]), .cloudGateway)
        XCTAssertEqual(C.claude(env: [:], settingsEnv: ["CLAUDE_CODE_USE_VERTEX": " On "]), .cloudGateway)
        XCTAssertFalse(ModelProvider.cloudGateway.isLocal)
        XCTAssertTrue(ModelProvider.cloudGateway.isKnownNonAnthropic)
    }

    func testOtherPlatformSwitchesAreGateways() {
        for key in ["CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_USE_ANTHROPIC_AWS", "CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD",
                    "CLAUDE_CODE_USE_MANTLE", "CLAUDE_CODE_USE_GATEWAY"] {
            XCTAssertEqual(C.claude(env: [key: "1"], settingsEnv: [:]), .cloudGateway, key)
            XCTAssertEqual(C.claude(env: [:], settingsEnv: [key: "true"]), .cloudGateway, "\(key) in settings")
            XCTAssertTrue(ClaudeSettingsEnv.keys.contains(key), "\(key) is read from settings files")
            XCTAssertTrue(C.claudeProcessEnvKeys.contains(key), "\(key) is read from the process")
        }
        XCTAssertEqual(ClaudeSettingsEnv.parse(Data(#"{"env":{"CLAUDE_CODE_USE_FOUNDRY":true}}"#.utf8)),
                       ["CLAUDE_CODE_USE_FOUNDRY": "true"])
    }

    func testCustomGatewayAndLookalikeHosts() {
        XCTAssertEqual(C.claude(env: ["ANTHROPIC_BASE_URL": "https://llm-gateway.example.com/anthropic"], settingsEnv: [:]),
                       .cloudGateway)
        XCTAssertEqual(C.claude(env: ["ANTHROPIC_BASE_URL": "http://127.0.0.1.evil.example:11434"], settingsEnv: [:]),
                       .cloudGateway)
        XCTAssertEqual(C.claude(env: ["ANTHROPIC_BASE_URL": "http://localhost.evil.example:1234"], settingsEnv: [:]),
                       .cloudGateway)
        XCTAssertEqual(C.claude(env: ["ANTHROPIC_BASE_URL": "http://192.168.1.20:11434"], settingsEnv: [:]),
                       .cloudGateway, "a LAN server is not this Mac")
        XCTAssertEqual(C.claude(env: ["ANTHROPIC_BASE_URL": "::::"], settingsEnv: [:]), .cloudGateway,
                       "unparseable fails closed (non-Anthropic)")
    }

    func testOtherLoopbackIsNotTreatedAsLocal() {
        let p = C.claude(env: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:8080"], settingsEnv: [:])
        XCTAssertEqual(p, .otherLocal)
        XCTAssertFalse(p.isLocal, "may be a proxy to Anthropic")
        XCTAssertTrue(p.isKnownNonAnthropic)
    }

    func testOllamaCloudModelIsNotLocal() {
        let base = ["ANTHROPIC_BASE_URL": "http://127.0.0.1:11434", "ANTHROPIC_AUTH_TOKEN": "ollama"]
        for model in ["glm-4.6:cloud", "gpt-oss:120b-cloud"] {
            for key in C.claudeModelKeys {
                XCTAssertEqual(C.claude(env: base.merging([key: model]) { $1 }, settingsEnv: [:]), .cloudGateway, "\(key)=\(model)")
            }
        }
        XCTAssertEqual(C.claude(env: base.merging(["ANTHROPIC_MODEL": "qwen3-coder:30b"]) { $1 }, settingsEnv: [:]), .ollama)
    }

    func testSettingsOnlyBaseURL() {
        XCTAssertEqual(C.claude(env: [:], settingsEnv: ["ANTHROPIC_BASE_URL": "http://localhost:1234"]), .lmStudio)
        XCTAssertEqual(C.claude(env: ["ANTHROPIC_AUTH_TOKEN": "ollama"],
                                settingsEnv: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:9999"]), .ollama, "merged per key")
    }

    func testProcessAnthropicPlusSettingsOllamaIsOllama() {
        XCTAssertEqual(C.claude(env: ["ANTHROPIC_BASE_URL": "https://api.anthropic.com"],
                                settingsEnv: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:11434"]), .ollama)
        // Either source pointing away from Anthropic wins (fail closed).
        XCTAssertEqual(C.claude(env: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:11434"],
                                settingsEnv: ["ANTHROPIC_BASE_URL": "https://api.anthropic.com"]), .ollama)
    }

    func testTokenNeverAppearsInDescriptions() {
        let secret = "sk-ant-SECRET-token-value"
        let env = ["ANTHROPIC_BASE_URL": "https://gw.example.com", "ANTHROPIC_AUTH_TOKEN": secret]
        let p = C.claude(env: env, settingsEnv: ["ANTHROPIC_AUTH_TOKEN": secret])
        XCTAssertFalse(String(describing: p).contains(secret))
        XCTAssertFalse(String(reflecting: p).contains(secret))
        XCTAssertFalse(p.displayName.contains(secret))
        let data = try? JSONEncoder().encode(p)
        XCTAssertFalse(String(decoding: data ?? Data(), as: UTF8.self).contains(secret))
        let msg = ResumeProviderGate.message(.init(stored: p, lastAssistantModel: nil))
        XCTAssertFalse(msg.contains(secret))
        XCTAssertFalse(msg.contains("gw.example.com"), "no URL either")
    }

    func testLenientDecode() throws {
        let decoded = try JSONDecoder().decode([ModelProvider].self, from: Data(#"["ollama","fromTheFuture"]"#.utf8))
        XCTAssertEqual(decoded, [.ollama, .unknown])
    }

    // MARK: Codex

    func testCodexOss() {
        XCTAssertEqual(C.codex(argv: ["codex", "--oss"], threadModelProvider: nil), .ollama)
        XCTAssertEqual(C.codex(argv: ["codex", "--oss", "--local-provider", "lmstudio"], threadModelProvider: nil), .lmStudio)
        XCTAssertEqual(C.codex(argv: ["codex", "--oss", "--local-provider=ollama"], threadModelProvider: nil), .ollama)
        XCTAssertEqual(C.codex(argv: ["codex", "--oss", "-c", "oss_provider=\"lmstudio\""], threadModelProvider: nil), .lmStudio)
    }

    /// Exactly what `ollama launch codex` passed with Ollama 0.40.11.
    func testRealOllama040LaunchCodexArgv() {
        let argv = ["codex", "--profile", "ollama-launch", "-c", "model_provider=\"ollama-launch\"",
                    "-c", "model_providers.ollama-launch.name=\"Ollama\"",
                    "-c", "model_providers.ollama-launch.base_url=\"http://127.0.0.1:11434/v1/\"",
                    "-c", "model_providers.ollama-launch.wire_api=\"responses\"",
                    "-c", "model_catalog_json=\"/Users/alex/.codex/model.json\"", "-c", "service_tier=\"default\"", "-m", "qwen2.5:0.5b"]
        XCTAssertEqual(C.codex(argv: argv, threadModelProvider: nil), .ollama)
    }

    func testCodexOllamaLaunchProfile() {
        let argv = ["codex", "--profile", "ollama-launch", "-c",
                    "model_providers.ollama-launch.base_url=\"http://127.0.0.1:11434/v1/\"", "-m", "gpt-oss:20b"]
        XCTAssertEqual(C.codex(argv: argv, threadModelProvider: nil), .ollama)
        XCTAssertEqual(C.codex(argv: ["codex", "-p", "ollama-launch"], threadModelProvider: nil), .ollama)
        XCTAssertEqual(C.codex(argv: ["codex", "--profile=ollama-launch"], threadModelProvider: nil), .ollama)
        XCTAssertEqual(C.codex(argv: ["codex", "-c", "model_providers.ollama-launch.base_url=http://127.0.0.1:11434/v1/"],
                               threadModelProvider: nil), .ollama)
        XCTAssertEqual(C.codex(argv: ["codex", "-c", "model_provider=ollama"], threadModelProvider: nil), .ollama)
        XCTAssertEqual(C.codex(argv: ["codex", "-c", "model_provider=\"lmstudio\""], threadModelProvider: nil), .lmStudio)
        XCTAssertEqual(C.codex(argv: ["codex", "--config=model_provider='ollama'"], threadModelProvider: nil), .ollama)
    }

    func testCodexHostedIsUnknown() {
        XCTAssertEqual(C.codex(argv: ["codex"], threadModelProvider: nil), .unknown)
        XCTAssertEqual(C.codex(argv: ["codex", "-m", "gpt-5", "--profile", "work"], threadModelProvider: "openai"), .unknown)
        XCTAssertEqual(C.codex(argv: ["codex", "explain the --oss flag"], threadModelProvider: nil), .unknown,
                       "a prompt mentioning a flag is one argv element")
        XCTAssertEqual(C.codex(argv: ["codex", "--", "--oss"], threadModelProvider: nil), .unknown)
    }

    func testCodexThreadModelProvider() {
        XCTAssertEqual(C.codex(argv: [], threadModelProvider: "ollama"), .ollama)
        XCTAssertEqual(C.codex(argv: [], threadModelProvider: "ollama-launch"), .ollama)
        XCTAssertEqual(C.codex(argv: [], threadModelProvider: "lmstudio"), .lmStudio)
        XCTAssertEqual(C.codex(argv: [], threadModelProvider: "openai"), .unknown)
        XCTAssertEqual(C.codex(argv: ["codex", "--oss"], threadModelProvider: "openai"), .ollama, "argv still counts")
    }

    // MARK: Transcript model

    func testTranscriptModelIsAnthropic() {
        XCTAssertEqual(C.transcriptModelIsAnthropic("claude-sonnet-4-5-20250929"), true)
        XCTAssertEqual(C.transcriptModelIsAnthropic("qwen3-coder:30b"), false)
        XCTAssertEqual(C.transcriptModelIsAnthropic("openai/gpt-oss-20b"), false)
        XCTAssertEqual(C.transcriptModelIsAnthropic("us.anthropic.claude-sonnet-4"), false, "Bedrock id")
        XCTAssertNil(C.transcriptModelIsAnthropic(nil))
        XCTAssertNil(C.transcriptModelIsAnthropic(""))
        XCTAssertNil(C.transcriptModelIsAnthropic("<synthetic>"))
    }

    func testLastAssistantModelSkipsSyntheticErrorsAndSubagents() {
        let lines = [
            #"{"type":"user","message":{"content":"hi"}}"#,
            #"{"type":"assistant","message":{"model":"claude-opus-4-1","content":[]}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-4-5","content":[]}}"#,
            #"{"type":"assistant","message":{"model":"<synthetic>","content":[]}}"#,
            #"{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","message":{"model":"<synthetic>"}}"#,
            "not json",
        ]
        XCTAssertEqual(TranscriptParser.lastAssistantModel(tailLines: lines), "claude-opus-4-1")
        XCTAssertEqual(TranscriptParser.lastAssistantModel(tailLines: [
            #"{"type":"assistant","message":{"model":"claude-opus-4-1"}}"#,
            #"{"type":"assistant","message":{"model":"qwen3:8b"}}"#,
        ]), "qwen3:8b", "the newest real reply wins")
        XCTAssertNil(TranscriptParser.lastAssistantModel(tailLines: [#"{"type":"user"}"#]))
        XCTAssertNil(TranscriptParser.lastAssistantModel(transcript: nil))
    }

    // MARK: Settings env

    func testSettingsEnvReaderMergesAndAllowlists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settingsenv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("proj")
        for dir in [home.appendingPathComponent(".claude"), project.appendingPathComponent(".claude")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try #"{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com","OPENAI_API_KEY":"nope","ANTHROPIC_MODEL":"a"}}"#
            .write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        try #"{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:11434","CLAUDE_CODE_USE_BEDROCK":1}}"#
            .write(to: project.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        try #"{"env":{"ANTHROPIC_MODEL":"qwen3"}"#   // malformed: skipped
            .write(to: project.appendingPathComponent(".claude/settings.local.json"), atomically: true, encoding: .utf8)

        let env = ClaudeSettingsEnv.read(cwd: project.path, home: home.path)
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "http://127.0.0.1:11434", "project overrides user")
        XCTAssertEqual(env["CLAUDE_CODE_USE_BEDROCK"], "1")
        XCTAssertEqual(env["ANTHROPIC_MODEL"], "a")
        XCTAssertNil(env["OPENAI_API_KEY"], "not allowlisted")

        try #"{"env":{"ANTHROPIC_MODEL":"qwen3"}}"#
            .write(to: project.appendingPathComponent(".claude/settings.local.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeSettingsEnv.read(cwd: project.path, home: home.path)["ANTHROPIC_MODEL"], "qwen3", "local wins")
        XCTAssertEqual(ClaudeSettingsEnv.read(cwd: nil, home: home.path)["ANTHROPIC_BASE_URL"], "https://api.anthropic.com")
        XCTAssertEqual(ClaudeSettingsEnv.read(cwd: "/nonexistent-\(UUID().uuidString)", home: "/nonexistent"), [:])
        XCTAssertTrue(ClaudeSettingsEnv.keys.allSatisfy { $0.hasPrefix("ANTHROPIC_") || $0.hasPrefix("CLAUDE_CODE_USE_") })
    }

    // MARK: Live Claude process

    /// The keys beyond `ProcArgs.envAllowlist` come back from a process's
    /// environment block (the shape `claude` processes have).
    func testProcessEnvKeysAreReadFromTheEnvironmentBlock() throws {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(1).littleEndian) { bytes += $0 }
        for s in ["/usr/local/bin/claude", "claude",
                  "CLAUDE_CODE_USE_FOUNDRY=1", "CLAUDE_CONFIG_DIR=/x", "UNRELATED_SECRET=s"] {
            bytes += Array(s.utf8) + [0]
        }
        let info = try XCTUnwrap(ProcArgs.parse(Data(bytes), envKeys: C.claudeProcessEnvKeys))
        XCTAssertEqual(info.env, ["CLAUDE_CODE_USE_FOUNDRY": "1", "CLAUDE_CONFIG_DIR": "/x"])
        XCTAssertEqual(C.claude(env: info.env, settingsEnv: [:]), .cloudGateway)
    }

    /// The same through a real child process. macOS hides the environment
    /// of Apple platform binaries such as /bin/sleep (not of `claude`), so
    /// this skips unless the kernel shows it.
    func testProcessEnvKeysAreReadFromALiveProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        child.environment = ["CLAUDE_CODE_USE_FOUNDRY": "1", "CLAUDE_CONFIG_DIR": "/x", "UNRELATED_SECRET": "s"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        usleep(100_000)
        let info = try XCTUnwrap(ProcArgs.read(pid: child.processIdentifier, envKeys: C.claudeProcessEnvKeys))
        try XCTSkipIf(info.env.isEmpty, "the kernel hides this child's environment (platform binary)")
        XCTAssertEqual(info.env, ["CLAUDE_CODE_USE_FOUNDRY": "1", "CLAUDE_CONFIG_DIR": "/x"])
        XCTAssertEqual(C.claude(env: info.env, settingsEnv: [:]), .cloudGateway)
    }

    /// cmux starts Claude with `--settings '<inline JSON of hooks>'`: no
    /// `env`, so it must not make the session unclassifiable.
    func testInlineHookSettingsKeepTheClassification() {
        let argv = ["claude", "--session-id", "455cd6af-046c-4468-9d9b-5de46c4d8194", "--settings",
                    #"{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"cmux hooks claude stop"}]}]}}"#]
        XCTAssertEqual(C.claudeLive(argv: argv, env: [:], cwd: "/nonexistent-\(UUID().uuidString)", home: "/nonexistent"),
                       .anthropic)
    }

    func testClaudeLiveReadsEverySettingsSourceOrIsUnknown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudelive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let project = root.appendingPathComponent("proj")
        let configDir = root.appendingPathComponent("altconfig")
        for dir in [home.appendingPathComponent(".claude"), project.appendingPathComponent(".claude"), configDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let ollama = #"{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:11434","ANTHROPIC_AUTH_TOKEN":"ollama"}}"#
        func live(_ argv: [String] = ["claude"], env: [String: String] = [:], cwd: String? = nil) -> ModelProvider {
            C.claudeLive(argv: argv, env: env, cwd: cwd ?? project.path, home: home.path)
        }

        XCTAssertEqual(live(), .anthropic)
        XCTAssertEqual(C.claudeLive(argv: ["claude"], env: [:], cwd: nil, home: home.path), .unknown,
                       "no launch directory: the project settings can't be read")
        XCTAssertEqual(C.claudeLive(argv: ["claude"], env: [:], cwd: "", home: home.path), .unknown)

        // CLAUDE_CONFIG_DIR moves the user settings.
        try ollama.write(to: configDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(live(env: ["CLAUDE_CONFIG_DIR": configDir.path]), .ollama)
        XCTAssertEqual(live(), .anthropic, "~/.claude/settings.json is clean")

        // --settings: a file (relative to the launch directory), inline JSON, or unreadable.
        try ollama.write(to: project.appendingPathComponent("extra.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(live(["claude", "--settings", "extra.json"]), .ollama)
        XCTAssertEqual(live(["claude", "--settings=\(project.path)/extra.json"]), .ollama)
        XCTAssertEqual(live(["claude", "--settings", #"{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}"#]), .cloudGateway)
        XCTAssertEqual(live(["claude", "--settings", "missing.json"]), .unknown, "unreadable settings could say anything")
        XCTAssertEqual(live(["claude", "--settings"]), .unknown)
        XCTAssertEqual(live(["claude", "--", "--settings", "extra.json"]), .anthropic, "after -- it's the prompt")
        XCTAssertEqual(ClaudeSettingsEnv.settingsFlag(["claude", "-p", "hi"]), nil)
    }
}
