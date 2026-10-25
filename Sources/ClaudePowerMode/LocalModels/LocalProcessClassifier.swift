import Foundation

/// What discovery knows about one process, for the classifier only.
///
/// Privacy: `argv` and `env` are transient (`ProcArgs` rules) — the
/// classifier derives a kind, a port and a few flags and the facts are
/// dropped. `description` never prints them.
struct ProcessFacts: CustomStringConvertible, CustomDebugStringConvertible {
    let pid: Int32
    let ppid: Int32
    let execPath: String
    /// Empty when discovery decided from the executable alone.
    let argv: [String]
    /// Allowlisted keys only.
    let env: [String: String]
    /// "ttys003" (no /dev/), nil without a controlling terminal.
    let ttyName: String?

    init(pid: Int32, ppid: Int32, execPath: String, argv: [String] = [], env: [String: String] = [:], ttyName: String? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.execPath = execPath
        self.argv = argv
        self.env = env
        self.ttyName = ttyName
    }

    var description: String {
        "ProcessFacts(pid: \(pid), ppid: \(ppid), exec: \(LocalProcessClassifier.basename(execPath)), argc: \(argv.count), tty: \(ttyName ?? "-"))"
    }
    var debugDescription: String { description }
}

/// A classified local-inference process. Holds only derived facts — no
/// argv, no environment values (an API key is reduced to `hasAPIKey`).
struct LocalProcess: Equatable {
    enum Kind: String, Equatable {
        /// `ollama serve` (also what Ollama.app runs).
        case ollamaServe
        /// The model runner `ollama serve` spawns per loaded model.
        case ollamaRunner
        /// A standalone llama.cpp `llama-server` (incl. Jan/Msty-embedded).
        case llamaServer
        /// Any process of LM Studio (app bundle helpers, ~/.lmstudio engines).
        case lmStudio
        /// Apple MLX (`mlx_lm.server`, `mlx_lm.generate`, `mlx_vlm.*`, …).
        case mlx
        /// llama-cli, llama-run, llamafile, koboldcpp …
        case llamaCLI
        /// opencode, aider, goose, `ollama run`, `lms chat`, … in a terminal.
        case terminalAgent
    }

    let kind: Kind
    let pid: Int32
    /// Display name for tools and agents ("llama-cli", "opencode", "ollama run").
    let name: String
    /// From argv `--port` / env LLAMA_ARG_PORT. A hint only: discovery
    /// prefers ports the process actually listens on.
    var declaredPort: Int? = nil
    /// llama-server answers on 127.0.0.1: its `--host` / LLAMA_ARG_HOST is
    /// loopback, unspecified or not given (the default is 127.0.0.1). Only
    /// this verdict is kept, never the host value itself.
    var loopbackHost: Bool = true
    /// llama-server started with an API key: its /slots needs auth, so
    /// Page doesn't probe it (and never learns the key).
    var hasAPIKey: Bool = false
    /// llama-server `--no-slots`: the endpoint is off.
    var noSlots: Bool = false
    var ttyName: String? = nil
}

/// Pure classification of processes into local-inference kinds.
///
/// Names and paths come from the tools' docs and are unverified on this
/// Mac (none of them is installed here): Ollama's runner argv, LM Studio's
/// bundle and `~/.lmstudio` layout, llama.cpp's `--no-slots`/LLAMA_ARG_*.
enum LocalProcessClassifier {
    /// What discovery must read before it can classify a process. Decided
    /// from the executable alone so argv (a sysctl and a large buffer) is
    /// read only for real candidates.
    enum Candidacy: Equatable {
        case none
        /// The path is enough.
        case pathOnly
        /// Needs argv (subcommand, port flags, module name).
        case needsArgv
        /// Needs argv only when the process has a controlling terminal
        /// (interpreters that might be running a terminal agent).
        case needsArgvIfTTY
    }

    /// Terminal agents Page doesn't otherwise know. claude and codex are
    /// covered by their own backends and deliberately absent.
    static let terminalAgentNames: Set<String> = [
        "opencode", "aider", "goose", "crush", "qwen", "cline", "kilo", "kilocode", "droid", "pi",
    ]
    static let llamaCLINames: Set<String> = ["llama-cli", "llama-run", "llama-mtmd-cli", "llamafile"]
    private static let scriptHosts: Set<String> = ["node", "bun", "deno"]
    private static let scriptExtensions = [".js", ".mjs", ".cjs", ".ts", ".py"]

    /// Environment keys discovery asks `ProcArgs` for.
    static let envKeys: Set<String> = ["LLAMA_ARG_PORT", "LLAMA_ARG_HOST", "LLAMA_ARG_API_KEY", "LLAMA_ARG_NO_SLOTS"]

    static func basename(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }

    static func isLMStudioPath(_ execPath: String, home: String) -> Bool {
        if execPath.contains("/LM Studio.app/") { return true }
        let root = (home.hasSuffix("/") ? home : home + "/") + ".lmstudio/"
        return !home.isEmpty && execPath.hasPrefix(root)
    }

    static func candidacy(execPath: String, home: String) -> Candidacy {
        let lower = basename(execPath).lowercased()
        if lower == "lms" { return .needsArgvIfTTY }
        // Same order as `classify`: these are decided by argv wherever they live.
        switch lower {
        case "ollama", "llama-server", "ollama_llama_server": return .needsArgv
        default: break
        }
        if isLMStudioPath(execPath, home: home) { return .pathOnly }
        if lower.hasPrefix("python") { return .needsArgv }
        if isAPELoader(lower) { return .needsArgv }
        if isMLXExecutable(lower) || isLlamaCLI(lower) || terminalAgentNames.contains(lower) { return .pathOnly }
        if scriptHosts.contains(lower) { return .needsArgvIfTTY }
        return .none
    }

    /// `parentOf` resolves a pid to the facts discovery holds for it (nil
    /// when it isn't a candidate or is gone); used to tell an Ollama runner
    /// from a standalone llama-server.
    static func classify(_ p: ProcessFacts, parentOf: (Int32) -> ProcessFacts?, home: String = NSHomeDirectory()) -> LocalProcess? {
        let base = basename(p.execPath)
        let lower = base.lowercased()
        let arg1 = p.argv.count > 1 ? p.argv[1] : nil

        if lower == "ollama" {
            switch arg1 {
            case "serve":
                return LocalProcess(kind: .ollamaServe, pid: p.pid, name: "Ollama")
            case "runner":
                // Unverified: `ollama runner … --port N` per Ollama's source/docs.
                return LocalProcess(kind: .ollamaRunner, pid: p.pid, name: "Ollama", declaredPort: port(flagValue(p.argv, "--port")))
            case "run":
                return p.ttyName == nil ? nil : agent(p, name: "ollama run")
            default:
                return nil
            }
        }
        if lower == "ollama_llama_server" {
            return LocalProcess(kind: .ollamaRunner, pid: p.pid, name: "Ollama", declaredPort: port(flagValue(p.argv, "--port")))
        }
        if lower == "llama-server" {
            if let parent = parentOf(p.ppid), basename(parent.execPath).lowercased() == "ollama" {
                return LocalProcess(kind: .ollamaRunner, pid: p.pid, name: "Ollama", declaredPort: port(flagValue(p.argv, "--port")))
            }
            return llamaServer(p)
        }
        if lower == "lms", arg1 == "chat", p.ttyName != nil {
            return agent(p, name: "lms chat")
        }
        if isLMStudioPath(p.execPath, home: home) {
            return LocalProcess(kind: .lmStudio, pid: p.pid, name: "LM Studio")
        }
        if isMLXExecutable(lower) {
            return LocalProcess(kind: .mlx, pid: p.pid, name: "MLX")
        }
        if lower.hasPrefix("python") {
            if isMLXPython(p.argv) { return LocalProcess(kind: .mlx, pid: p.pid, name: "MLX") }
            if p.ttyName != nil, let script = agentScript(p.argv) { return agent(p, name: script) }
            return nil
        }
        if isLlamaCLI(lower) {
            return LocalProcess(kind: .llamaCLI, pid: p.pid, name: base, ttyName: p.ttyName)
        }
        if isAPELoader(lower) {
            // A llamafile on Apple silicon runs under Cosmopolitan's APE
            // loader (~/.ape-<ver>, or one in $TMPDIR), which execs with the
            // program as an argument — so the executable is the loader and
            // the llamafile shows up in argv (unverified: no llamafile here).
            for arg in p.argv.prefix(3) {
                let name = basename(arg)
                if isLlamaCLI(name.lowercased()) { return LocalProcess(kind: .llamaCLI, pid: p.pid, name: name, ttyName: p.ttyName) }
            }
            return nil
        }
        if terminalAgentNames.contains(lower) {
            return p.ttyName == nil ? nil : agent(p, name: lower)
        }
        if scriptHosts.contains(lower), p.ttyName != nil, let script = agentScript(p.argv) {
            return agent(p, name: script)
        }
        return nil
    }

    // MARK: argv / env parsing

    /// Value of `--flag value` or `--flag=value`; the last occurrence wins
    /// (as with llama.cpp's own parser).
    static func flagValue(_ argv: [String], _ flag: String) -> String? {
        var value: String?
        var i = 1
        while i < argv.count {
            let a = argv[i]
            if a == flag {
                if i + 1 < argv.count { value = argv[i + 1]; i += 1 }
            } else if a.hasPrefix(flag + "=") {
                value = String(a.dropFirst(flag.count + 1))
            }
            i += 1
        }
        return value
    }

    /// `--flag` alone or as `--flag=…`.
    static func hasFlag(_ argv: [String], _ flag: String) -> Bool {
        argv.dropFirst().contains { $0 == flag || $0.hasPrefix(flag + "=") }
    }

    static func port(_ s: String?) -> Int? {
        guard let s, let n = Int(s.trimmingCharacters(in: .whitespaces)), (1...65535).contains(n) else { return nil }
        return n
    }

    static func truthy(_ s: String?) -> Bool {
        guard let s else { return false }
        return ["1", "true", "yes", "on"].contains(s.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Hosts whose server answers on 127.0.0.1 (nil = llama-server's
    /// default, 127.0.0.1).
    static func isLoopbackOrUnspecified(_ host: String?) -> Bool {
        guard let raw = host?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return true }
        let h = raw.hasPrefix("[") && raw.hasSuffix("]") ? String(raw.dropFirst().dropLast()) : raw
        return h == "localhost" || h == "0.0.0.0" || h == "::" || h == "::1" || h.hasPrefix("127.")
    }

    /// Whether Page may GET this llama-server's /slots: it must answer on
    /// loopback, need no key and have the endpoint on. Ollama runners are
    /// always tried: Ollama 0.40's llama-server child answers /slots (seen
    /// on a real install); the Go `ollama runner` may not, and a 404/501
    /// there just falls back to the runner's GPU signal.
    static func shouldProbeSlots(_ p: LocalProcess) -> Bool {
        switch p.kind {
        case .ollamaRunner: return true
        case .llamaServer: return p.loopbackHost && !p.hasAPIKey && !p.noSlots
        default: return false
        }
    }

    // MARK: private

    private static func llamaServer(_ p: ProcessFacts) -> LocalProcess {
        let apiKeyEnv = p.env["LLAMA_ARG_API_KEY"].map { !$0.isEmpty } ?? false
        return LocalProcess(
            kind: .llamaServer, pid: p.pid, name: "llama.cpp server",
            declaredPort: port(flagValue(p.argv, "--port")) ?? port(p.env["LLAMA_ARG_PORT"]),
            loopbackHost: isLoopbackOrUnspecified(flagValue(p.argv, "--host") ?? p.env["LLAMA_ARG_HOST"]),
            hasAPIKey: hasFlag(p.argv, "--api-key") || hasFlag(p.argv, "--api-key-file") || apiKeyEnv,
            noSlots: hasFlag(p.argv, "--no-slots") || truthy(p.env["LLAMA_ARG_NO_SLOTS"]))
    }

    private static func agent(_ p: ProcessFacts, name: String) -> LocalProcess {
        LocalProcess(kind: .terminalAgent, pid: p.pid, name: name, ttyName: p.ttyName)
    }

    /// Cosmopolitan's APE loader: ".ape", ".ape-1.10", "ape", "ape-arm64.elf".
    private static func isAPELoader(_ lower: String) -> Bool {
        lower == "ape" || lower == ".ape" || lower.hasPrefix(".ape-") || lower.hasPrefix("ape-")
    }

    private static func isLlamaCLI(_ lower: String) -> Bool {
        llamaCLINames.contains(lower) || lower.hasSuffix(".llamafile") || lower.hasPrefix("koboldcpp")
    }

    private static func isMLXModule(_ m: String) -> Bool {
        m == "mlx_lm" || m == "mlx_vlm" || m.hasPrefix("mlx_lm.") || m.hasPrefix("mlx_vlm.")
    }

    private static func isMLXExecutable(_ lower: String) -> Bool {
        lower.hasPrefix("mlx_lm.") || lower.hasPrefix("mlx_vlm.")
    }

    /// `python -m mlx_lm.server …`, or python running an `mlx_lm.*` entry
    /// point script.
    private static func isMLXPython(_ argv: [String]) -> Bool {
        if let m = flagValue(argv, "-m"), isMLXModule(m) { return true }
        return argv.dropFirst().prefix(2).contains { isMLXExecutable(basename($0).lowercased()) }
    }

    /// For interpreters: the terminal-agent script among argv[1...2]
    /// (`node /opt/homebrew/bin/opencode`, `python -m aider`).
    private static func agentScript(_ argv: [String]) -> String? {
        for a in argv.dropFirst().prefix(2) where !a.hasPrefix("-") {
            var comp = basename(a).lowercased()
            for ext in scriptExtensions where comp.hasSuffix(ext) {
                comp = String(comp.dropLast(ext.count))
            }
            if terminalAgentNames.contains(comp) { return comp }
        }
        return nil
    }
}
