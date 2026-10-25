import XCTest
@testable import ClaudePowerMode

final class LocalModelsClassifierTests: XCTestCase {
    private let home = "/Users/alex"

    private func classify(_ path: String, _ argv: [String] = [], env: [String: String] = [:], tty: String? = nil,
                          pid: Int32 = 500, ppid: Int32 = 1, parents: [ProcessFacts] = []) -> LocalProcess? {
        let facts = ProcessFacts(pid: pid, ppid: ppid, execPath: path, argv: argv, env: env, ttyName: tty)
        let byPid = Dictionary(uniqueKeysWithValues: parents.map { ($0.pid, $0) })
        return LocalProcessClassifier.classify(facts, parentOf: { byPid[$0] }, home: home)
    }

    // MARK: Ollama

    func testOllamaServeFromCLIAndApp() {
        XCTAssertEqual(classify("/opt/homebrew/bin/ollama", ["ollama", "serve"])?.kind, .ollamaServe)
        XCTAssertEqual(classify("/Applications/Ollama.app/Contents/Resources/ollama", ["/Applications/Ollama.app/Contents/Resources/ollama", "serve"])?.kind, .ollamaServe)
        // The menu-bar GUI itself and other subcommands aren't inference.
        XCTAssertNil(classify("/Applications/Ollama.app/Contents/MacOS/Ollama", ["/Applications/Ollama.app/Contents/MacOS/Ollama"]))
        XCTAssertNil(classify("/opt/homebrew/bin/ollama", ["ollama", "pull", "qwen3"]))
        XCTAssertNil(classify("/opt/homebrew/bin/ollama", ["ollama", "ps"], tty: "ttys001"))
    }

    func testOllamaRunnerUnderServeParent() {
        let serve = ProcessFacts(pid: 100, ppid: 1, execPath: "/Applications/Ollama.app/Contents/Resources/ollama", argv: ["ollama", "serve"])
        let runner = classify("/Applications/Ollama.app/Contents/Resources/llama-server",
                              ["llama-server", "--model", "/x.gguf", "--port", "54321"], ppid: 100, parents: [serve])
        XCTAssertEqual(runner?.kind, .ollamaRunner)
        XCTAssertEqual(runner?.declaredPort, 54321)

        let goRunner = classify("/opt/homebrew/bin/ollama", ["ollama", "runner", "--ollama-engine", "--port", "60001"], ppid: 100, parents: [serve])
        XCTAssertEqual(goRunner?.kind, .ollamaRunner)
        XCTAssertEqual(goRunner?.declaredPort, 60001)

        let old = classify("/tmp/ollama123/runners/metal/ollama_llama_server", ["ollama_llama_server", "--port", "60002"], ppid: 100, parents: [serve])
        XCTAssertEqual(old?.kind, .ollamaRunner)
        XCTAssertEqual(old?.declaredPort, 60002)
    }

    /// Exactly what Homebrew's Ollama 0.40.11 ran on a real Mac.
    func testRealOllama040RunnerIsSeen() {
        let serve = ProcessFacts(pid: 84609, ppid: 1, execPath: "/opt/homebrew/opt/ollama/bin/ollama", argv: ["/opt/homebrew/opt/ollama/bin/ollama", "serve"])
        let runner = classify("/opt/homebrew/Cellar/ollama/0.40.11/libexec/lib/ollama/llama-server",
                              ["/opt/homebrew/Cellar/ollama/0.40.11/libexec/lib/ollama/llama-server", "--model", "/Users/alex/.ollama/models/blobs/sha256-c539",
                               "--port", "50025", "--host", "127.0.0.1", "--no-webui", "--offline", "-c", "32768", "-np", "1"],
                              pid: 87007, ppid: 84609, parents: [serve])
        XCTAssertEqual(runner?.kind, .ollamaRunner)
        XCTAssertEqual(runner?.declaredPort, 50025)
        XCTAssertTrue(runner.map(LocalProcessClassifier.shouldProbeSlots) ?? false)
    }

    func testOllamaRunIsATerminalAgentOnlyWithTTY() {
        let run = classify("/opt/homebrew/bin/ollama", ["ollama", "run", "qwen3"], tty: "ttys004")
        XCTAssertEqual(run?.kind, .terminalAgent)
        XCTAssertEqual(run?.name, "ollama run")
        XCTAssertEqual(run?.ttyName, "ttys004")
        XCTAssertNil(classify("/opt/homebrew/bin/ollama", ["ollama", "run", "qwen3"]))
    }

    // MARK: llama.cpp

    func testStandaloneLlamaServerFlags() throws {
        let p = try XCTUnwrap(classify("/opt/homebrew/bin/llama-server",
                                       ["llama-server", "-m", "m.gguf", "--port", "8081", "--host", "0.0.0.0"], ppid: 77))
        XCTAssertEqual(p.kind, .llamaServer)
        XCTAssertEqual(p.declaredPort, 8081)
        XCTAssertTrue(p.loopbackHost)
        XCTAssertFalse(p.hasAPIKey)
        XCTAssertFalse(p.noSlots)
        XCTAssertTrue(LocalProcessClassifier.shouldProbeSlots(p))
    }

    func testLlamaServerUnderNonOllamaParentIsStandalone() {
        let jan = ProcessFacts(pid: 90, ppid: 1, execPath: "/Applications/Jan.app/Contents/MacOS/Jan")
        let p = classify("/Applications/Jan.app/Contents/Resources/bin/llama-server", ["llama-server", "--port=39291"], ppid: 90, parents: [jan])
        XCTAssertEqual(p?.kind, .llamaServer)
        XCTAssertEqual(p?.declaredPort, 39291)
    }

    func testLlamaServerEnvAndKeyFlags() throws {
        let env = try XCTUnwrap(classify("/usr/local/bin/llama-server", ["llama-server"],
                                         env: ["LLAMA_ARG_PORT": "9000", "LLAMA_ARG_HOST": "192.168.1.5", "LLAMA_ARG_NO_SLOTS": "1"]))
        XCTAssertEqual(env.declaredPort, 9000)
        XCTAssertFalse(env.loopbackHost)
        XCTAssertFalse(String(describing: env).contains("192.168"), "only the verdict is kept")
        XCTAssertTrue(env.noSlots)
        XCTAssertFalse(LocalProcessClassifier.shouldProbeSlots(env))

        let keyed = try XCTUnwrap(classify("/usr/local/bin/llama-server", ["llama-server", "--api-key", "sk-secret"]))
        XCTAssertTrue(keyed.hasAPIKey)
        XCTAssertFalse(LocalProcessClassifier.shouldProbeSlots(keyed))
        XCTAssertFalse(String(describing: keyed).contains("sk-secret"))

        XCTAssertTrue(classify("/usr/local/bin/llama-server", ["llama-server", "--api-key-file=/k"])?.hasAPIKey == true)
        XCTAssertTrue(classify("/usr/local/bin/llama-server", ["llama-server"], env: ["LLAMA_ARG_API_KEY": "x"])?.hasAPIKey == true)
        XCTAssertTrue(classify("/usr/local/bin/llama-server", ["llama-server", "--no-slots"])?.noSlots == true)
        // argv beats env for the port.
        XCTAssertEqual(classify("/usr/local/bin/llama-server", ["llama-server", "--port", "1"], env: ["LLAMA_ARG_PORT": "2"])?.declaredPort, 1)
    }

    func testFlagParsing() {
        XCTAssertEqual(LocalProcessClassifier.flagValue(["x", "--port", "1", "--port=2"], "--port"), "2")
        XCTAssertEqual(LocalProcessClassifier.flagValue(["x", "--port"], "--port"), nil)
        XCTAssertNil(LocalProcessClassifier.flagValue(["--port", "5"], "--port"), "argv[0] is never a flag")
        XCTAssertNil(LocalProcessClassifier.flagValue(["x", "--portal", "5"], "--port"))
        XCTAssertTrue(LocalProcessClassifier.hasFlag(["x", "--no-slots"], "--no-slots"))
        XCTAssertFalse(LocalProcessClassifier.hasFlag(["x", "--no-slotsx"], "--no-slots"))
        XCTAssertNil(LocalProcessClassifier.port("0"))
        XCTAssertNil(LocalProcessClassifier.port("70000"))
        XCTAssertNil(LocalProcessClassifier.port("abc"))
        XCTAssertEqual(LocalProcessClassifier.port(" 8080 "), 8080)
        XCTAssertTrue(LocalProcessClassifier.truthy("TRUE"))
        XCTAssertTrue(LocalProcessClassifier.truthy("on"))
        XCTAssertFalse(LocalProcessClassifier.truthy("0"))
        XCTAssertFalse(LocalProcessClassifier.truthy(nil))
        for h in [nil, "", "127.0.0.1", "127.1.2.3", "localhost", "0.0.0.0", "::", "[::1]", "::1"] {
            XCTAssertTrue(LocalProcessClassifier.isLoopbackOrUnspecified(h), "\(h ?? "nil")")
        }
        for h in ["192.168.1.2", "10.0.0.1", "example.com"] {
            XCTAssertFalse(LocalProcessClassifier.isLoopbackOrUnspecified(h), h)
        }
    }

    // MARK: LM Studio / MLX

    func testLMStudioPaths() {
        XCTAssertEqual(classify("/Applications/LM Studio.app/Contents/Frameworks/LM Studio Helper.app/Contents/MacOS/LM Studio Helper")?.kind, .lmStudio)
        XCTAssertEqual(classify("/Applications/LM Studio.app/Contents/MacOS/LM Studio")?.kind, .lmStudio)
        XCTAssertEqual(classify("/Users/alex/.lmstudio/llmster/0.0.1/llmster")?.kind, .lmStudio)
        XCTAssertEqual(LocalProcessClassifier.candidacy(execPath: "/Users/alex/.lmstudio/llmster/llmster", home: home), .pathOnly)
        XCTAssertNil(classify("/Users/bob/.lmstudio/llmster/llmster"), "another user's dir isn't ours")
    }

    func testLMSChatIsAnAgentButOtherLMSIsLMStudio() {
        let chat = classify("/Users/alex/.lmstudio/bin/lms", ["lms", "chat"], tty: "ttys002")
        XCTAssertEqual(chat?.kind, .terminalAgent)
        XCTAssertEqual(chat?.name, "lms chat")
        XCTAssertEqual(classify("/Users/alex/.lmstudio/bin/lms", ["lms", "server", "start"], tty: "ttys002")?.kind, .lmStudio)
        XCTAssertEqual(LocalProcessClassifier.candidacy(execPath: "/Users/alex/.lmstudio/bin/lms", home: home), .needsArgvIfTTY)
    }

    func testMLXPython() {
        XCTAssertEqual(classify("/opt/homebrew/bin/python3.12", ["python3", "-m", "mlx_lm.server", "--model", "x"])?.kind, .mlx)
        XCTAssertEqual(classify("/Library/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python",
                                ["Python", "-m", "mlx_lm", "generate"])?.kind, .mlx)
        XCTAssertEqual(classify("/usr/bin/python3", ["python3", "-m", "mlx_vlm.generate"])?.kind, .mlx)
        XCTAssertEqual(classify("/opt/homebrew/bin/python3", ["python3", "/Users/alex/.venv/bin/mlx_lm.chat"])?.kind, .mlx)
        XCTAssertEqual(classify("/Users/alex/.venv/bin/mlx_lm.server")?.kind, .mlx)
        XCTAssertEqual(classify("/opt/homebrew/bin/python3", ["python3", "-m", "mlx_lm.server"])?.name, "MLX")
    }

    func testUnrelatedPythonIgnored() {
        XCTAssertNil(classify("/opt/homebrew/bin/python3", ["python3", "-m", "http.server"]))
        XCTAssertNil(classify("/opt/homebrew/bin/python3", ["python3", "manage.py", "runserver"], tty: "ttys001"))
        XCTAssertNil(classify("/usr/bin/python3", []))
        XCTAssertNil(classify("/usr/bin/vim", ["vim"], tty: "ttys001"))
        XCTAssertEqual(LocalProcessClassifier.candidacy(execPath: "/usr/bin/vim", home: home), .none)
    }

    // MARK: CLIs and agents

    func testLlamaCLIs() {
        for path in ["/opt/homebrew/bin/llama-cli", "/x/llama-run", "/x/llama-mtmd-cli", "/x/llamafile",
                     "/Users/alex/Mistral-7B.llamafile", "/x/koboldcpp-mac-arm64"] {
            XCTAssertEqual(classify(path)?.kind, .llamaCLI, path)
        }
        XCTAssertEqual(classify("/opt/homebrew/bin/llama-cli", tty: "ttys009")?.ttyName, "ttys009")
        XCTAssertEqual(classify("/opt/homebrew/bin/llama-cli")?.name, "llama-cli")
    }

    func testTerminalAgents() {
        XCTAssertEqual(classify("/opt/homebrew/bin/opencode", tty: "ttys001")?.kind, .terminalAgent)
        XCTAssertNil(classify("/opt/homebrew/bin/opencode"), "needs a controlling terminal")
        for name in ["aider", "goose", "crush", "qwen", "cline", "kilo", "kilocode", "droid", "pi"] {
            XCTAssertEqual(classify("/usr/local/bin/\(name)", tty: "ttys001")?.name, name)
        }
        // claude and codex have their own backends.
        XCTAssertNil(classify("/usr/local/bin/claude", ["claude"], tty: "ttys001"))
        XCTAssertNil(classify("/opt/homebrew/bin/codex", ["codex"], tty: "ttys001"))
    }

    func testNodeScriptAgent() {
        let p = classify("/opt/homebrew/bin/node", ["node", "/opt/homebrew/lib/node_modules/opencode-ai/bin/opencode"], tty: "ttys003")
        XCTAssertEqual(p?.kind, .terminalAgent)
        XCTAssertEqual(p?.name, "opencode")
        XCTAssertEqual(classify("/opt/homebrew/bin/node", ["node", "--no-warnings", "/x/bin/qwen.js"], tty: "ttys003")?.name, "qwen")
        XCTAssertEqual(classify("/opt/homebrew/bin/bun", ["bun", "/x/bin/kilo"], tty: "ttys003")?.name, "kilo")
        XCTAssertEqual(classify("/opt/homebrew/bin/python3", ["python3", "-m", "aider"], tty: "ttys003")?.name, "aider")
        XCTAssertNil(classify("/opt/homebrew/bin/node", ["node", "/x/bin/opencode"]), "no tty")
        XCTAssertNil(classify("/opt/homebrew/bin/node", ["node", "/x/server.js"], tty: "ttys003"))
        XCTAssertEqual(LocalProcessClassifier.candidacy(execPath: "/opt/homebrew/bin/node", home: home), .needsArgvIfTTY)
    }

    func testFactsDescriptionHidesArgvAndEnv() {
        let f = ProcessFacts(pid: 1, ppid: 0, execPath: "/x/llama-server", argv: ["llama-server", "--api-key", "sk-xyz"],
                             env: ["LLAMA_ARG_API_KEY": "sk-env"], ttyName: nil)
        let text = String(describing: f) + String(reflecting: f) + "\(f)"
        XCTAssertFalse(text.contains("sk-xyz"))
        XCTAssertFalse(text.contains("sk-env"))
        XCTAssertFalse(text.contains("--api-key"))
    }

    func testCandidacyDecidesArgvReads() {
        XCTAssertEqual(LocalProcessClassifier.candidacy(execPath: "/opt/homebrew/bin/ollama", home: home), .needsArgv)
        XCTAssertEqual(LocalProcessClassifier.candidacy(execPath: "/opt/homebrew/bin/llama-server", home: home), .needsArgv)
        XCTAssertEqual(LocalProcessClassifier.candidacy(execPath: "/usr/bin/python3", home: home), .needsArgv)
        XCTAssertEqual(LocalProcessClassifier.candidacy(execPath: "/opt/homebrew/bin/llama-cli", home: home), .pathOnly)
        XCTAssertEqual(LocalProcessClassifier.candidacy(execPath: "/opt/homebrew/bin/aider", home: home), .pathOnly)
        XCTAssertEqual(LocalProcessClassifier.candidacy(execPath: "/Applications/LM Studio.app/Contents/MacOS/LM Studio", home: home), .pathOnly)
        // A llama-server inside LM Studio's dirs still needs its argv (port, flags).
        XCTAssertEqual(LocalProcessClassifier.candidacy(execPath: home + "/.lmstudio/bin/llama-server", home: home), .needsArgv)
        XCTAssertEqual(LocalProcessClassifier.candidacy(execPath: "/Applications/LM Studio.app/Contents/Resources/ollama", home: home), .needsArgv)
    }
}
