import Foundation

/// Starts a new Claude Code session from the phone (`start` op,
/// SESSIONS-PROTOCOL.md §5): a new cmux workspace in one of the folders
/// Claude has already worked in, running `claude` with the phone's prompt.
///
/// This is remote command execution, so it is fenced in:
/// - off unless the user turns on "Let my phone start sessions";
/// - only from an authenticated `sessions.command` (the pairing's key);
/// - only in a folder from `knownFolders` (where Claude sessions already
///   ran), compared exactly after standardising;
/// - the command is fixed (`claude`); the prompt is one shell-quoted
///   argument after `--`, control characters stripped, newlines folded;
/// - cmux only, through the same socket gate as typing.
enum SessionStarter {
    struct Folder: Equatable {
        let path: String
        let name: String
        let lastUsedAt: Date?

        var jsonObject: [String: Any] {
            var o: [String: Any] = ["path": path, "name": name]
            if let lastUsedAt { o["lastUsedAt"] = Int64((lastUsedAt.timeIntervalSince1970 * 1000).rounded()) }
            return o
        }
    }

    static let maxFolders = 40
    static let maxAge: TimeInterval = 30 * 24 * 3600
    static let maxPromptLength = 4000
    static let disabledMessage = "Starting sessions from the phone is off — turn it on in Page on your Mac (Preferences → Macs & phones)"
    static let unknownFolderMessage = "Page only starts sessions in folders Claude has already worked in"

    // MARK: pure

    /// One POSIX shell word.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The prompt as one line of plain text, or a refusal. Empty is fine
    /// (just opens Claude).
    static func cleanPrompt(_ raw: String?) -> Result<String, SessionCommandResult> {
        let folded = (raw ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: " ")
        let clean = InjectionExecutor.sanitize(folded).trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count > maxPromptLength {
            return .failure(.refused(.error, "The prompt is too long (\(maxPromptLength) characters at most)"))
        }
        return .success(clean)
    }

    /// The exact shell command typed into the new workspace.
    ///
    /// Claude Code's argument parser matches its first operand against
    /// subcommand names even after `--`, and some are destructive (`purge`
    /// deletes a project's Claude state). A prompt with a space can never
    /// equal a command name; a one-word prompt gets a full stop so it can't
    /// either ("purge" → "purge.").
    static func command(prompt: String) -> String {
        guard !prompt.isEmpty else { return "claude" }
        let arg = prompt.contains(where: \.isWhitespace) ? prompt : prompt + "."
        return "claude -- " + shellQuote(arg)
    }

    /// The folder if it's on the list (exact match after standardising).
    static func allowed(_ folder: String?, in folders: [Folder]) -> Result<Folder, SessionCommandResult> {
        guard let folder, !folder.isEmpty else { return .failure(.refused(.error, "Pick a folder")) }
        let wanted = (folder as NSString).standardizingPath
        guard let match = folders.first(where: { ($0.path as NSString).standardizingPath == wanted }) else {
            return .failure(.refused(.notFound, unknownFolderMessage))
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: match.path, isDirectory: &isDir), isDir.boolValue else {
            return .failure(.refused(.notFound, "That folder no longer exists"))
        }
        return .success(match)
    }

    /// Newest first, one entry per folder, at most `maxFolders`, nothing
    /// older than `maxAge` (live sessions' folders always count).
    static func merge(live: [String], recent: [(path: String, at: Date)], now: Date) -> [Folder] {
        var best: [String: Date?] = [:]
        for p in live where !p.isEmpty { best[p] = now }
        for r in recent where now.timeIntervalSince(r.at) <= maxAge && !r.path.isEmpty {
            if let existing = best[r.path], let e = existing, e >= r.at { continue }
            best[r.path] = r.at
        }
        return best.map { Folder(path: $0.key, name: InterventionDetector.projectName(forCwd: $0.key), lastUsedAt: $0.value) }
            .filter { $0.path != "/" && $0.path != NSHomeDirectory() }
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
            .prefix(maxFolders).map { $0 }
    }

    // MARK: IO

    private static let cacheLock = NSLock()
    private static var cache: (at: Date, recent: [(path: String, at: Date)])?

    /// Folders of transcripts written in the last `maxAge`: the `cwd` in the
    /// first records of each project's newest transcripts. Cached a minute.
    static func recentFolders(projectsDirectory: String, now: Date = Date()) -> [(path: String, at: Date)] {
        cacheLock.lock()
        if let c = cache, now.timeIntervalSince(c.at) < 60 { cacheLock.unlock(); return c.recent }
        cacheLock.unlock()
        let fm = FileManager.default
        let root = (projectsDirectory as NSString).expandingTildeInPath
        var out: [(path: String, at: Date)] = []
        for dir in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let base = root + "/" + dir
            var newest: [(String, Date)] = []
            for f in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where f.hasSuffix(".jsonl") {
                if let m = (try? fm.attributesOfItem(atPath: base + "/" + f))?[.modificationDate] as? Date,
                   now.timeIntervalSince(m) <= maxAge { newest.append((base + "/" + f, m)) }
            }
            // A project folder can hold sessions from several cwds (subdirs).
            var seen = Set<String>()
            for (path, at) in newest.sorted(by: { $0.1 > $1.1 }).prefix(5) {
                guard let cwd = firstCwd(path), seen.insert(cwd).inserted else { continue }
                out.append((cwd, at))
            }
        }
        cacheLock.lock(); cache = (now, out); cacheLock.unlock()
        return out
    }

    static func firstCwd(_ transcript: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: transcript) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024) else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(50) {
            guard line.contains("\"cwd\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let cwd = obj["cwd"] as? String, cwd.hasPrefix("/") else { continue }
            return cwd
        }
        return nil
    }

    /// Opens a cmux workspace running `command(prompt:)` in `folder`.
    /// Blocking (the cmux CLI).
    static func start(folder: Folder, prompt: String, runner: @escaping CmuxBridge.Runner = CmuxBridge.defaultRunner) -> SessionCommandResult {
        guard let cli = CmuxBridge.cliPath(forBundlePath: nil) else {
            return .refused(.notTypable, "Starting a session needs cmux, and it isn't installed on your Mac")
        }
        let client: CmuxBridge.Client
        switch CmuxBridge.connect(cliPath: cli, runner: runner) {
        case .success(let c): client = c
        case .failure(let f): return .refused(.notTypable, f.detail)
        }
        let args = ["new-workspace", "--name", String(folder.name.prefix(60)), "--cwd", folder.path,
                    "--command", command(prompt: prompt), "--focus", "false"]
        switch client.run(args, timeout: 8, fallback: "cmux didn't open the workspace") {
        case .success:
            Logger.shared.log("Sessions: started a Claude session in \(folder.name) (\(prompt.count) chars)")
            return SessionCommandResult(code: .delivered, reason: nil, detail: "Started Claude in \(folder.name)")
        case .failure(let f):
            Logger.shared.log("Sessions: couldn't start a session in \(folder.name): \(f.output)")
            return .failed(f.detail)
        }
    }
}
