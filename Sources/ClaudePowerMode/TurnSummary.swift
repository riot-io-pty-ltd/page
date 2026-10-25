import Foundation

/// "What changed" for a finished turn: a one-line headline on the idle page
/// ("Changed 3 files (+120 −14) · tests passed") and, over the encrypted
/// sessions channel only, the file list and the diff itself (the `diff`
/// kind, SESSIONS-PROTOCOL.md §4).
///
/// The headline carries counts only, never file names or code: page
/// context is stored by the relay and shown by APNs. Files come from the
/// turn's own Edit/Write calls (TurnDigest); line counts and the patch from
/// git when the folder is a repository.
enum TurnSummary {
    struct FileChange: Equatable {
        /// Relative to the repository root (or as the transcript wrote it).
        let path: String
        /// nil when unknown (not a repo, binary, or already committed).
        let added: Int?
        let removed: Int?
        /// "modified", "added" (untracked), or "changed" (no stats).
        let status: String

        var jsonObject: [String: Any] {
            var o: [String: Any] = ["path": path, "status": status]
            if let added { o["added"] = added }
            if let removed { o["removed"] = removed }
            return o
        }
    }

    struct Changes: Equatable {
        var root: String?
        var files: [FileChange]
        var added: Int? { sum(\.added) }
        var removed: Int? { sum(\.removed) }

        private func sum(_ key: KeyPath<FileChange, Int?>) -> Int? {
            let known = files.compactMap { $0[keyPath: key] }
            return known.isEmpty ? nil : known.reduce(0, +)
        }
    }

    static let gitTimeout: TimeInterval = 3
    static let maxPatchBytes = 48 * 1024
    static let maxFiles = 200
    static let maxPlaintextBytes = 64 * 1024

    // MARK: pure

    /// nil when the turn changed nothing and ran no tests.
    static func headline(fileCount: Int, added: Int?, removed: Int?, test: (passed: Bool, label: String)?) -> String? {
        var parts: [String] = []
        if fileCount > 0 {
            var s = "Changed \(fileCount) file\(fileCount == 1 ? "" : "s")"
            if let added, let removed { s += " (+\(added) −\(removed))" }
            parts.append(s)
        }
        if let test { parts.append(test.passed ? "tests passed" : "tests failed") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The idle page's context with the headline on top, clipped as the
    /// detector clips (keeping the end of the reply, where the ask is).
    static func context(headline: String?, reply: String, limit: Int = InterventionDetector.contextLimit) -> String {
        guard let headline else { return reply }
        let budget = limit - headline.count - 2
        guard budget > 40 else { return InterventionDetector.clip(headline, limit) }
        return headline + "\n\n" + InterventionDetector.clipKeepingEnd(reply, budget)
    }

    /// `git diff --numstat -z --no-renames` → path: (added, removed);
    /// binary files ("-") have nil counts.
    static func parseNumstat(_ out: String) -> [String: (Int?, Int?)] {
        var map: [String: (Int?, Int?)] = [:]
        for record in out.split(separator: "\0") {
            let f = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard f.count == 3 else { continue }
            map[String(f[2])] = (Int(f[0]), Int(f[1]))
        }
        return map
    }

    /// Path relative to `root`, or nil if it's outside it.
    static func relative(_ path: String, to root: String) -> String? {
        let r = root.hasSuffix("/") ? root : root + "/"
        let p = (path as NSString).standardizingPath
        return p.hasPrefix(r) ? String(p.dropFirst(r.count)) : nil
    }

    /// Cuts a patch to `maxBytes` at a line boundary.
    static func capped(_ patch: String, maxBytes: Int) -> (String, Bool) {
        guard patch.utf8.count > maxBytes else { return (patch, false) }
        var cut = String(decoding: patch.utf8.prefix(maxBytes), as: UTF8.self)
        if let nl = cut.lastIndex(of: "\n") { cut = String(cut[...nl]) }
        return (cut, true)
    }

    // MARK: git (blocking)

    static var git: String { ProcessRunner.findExecutable("git") ?? "/usr/bin/git" }

    static func repoRoot(cwd: String) -> String? {
        let r = ProcessRunner.run(git, ["-C", cwd, "rev-parse", "--show-toplevel"], timeout: gitTimeout)
        let root = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.succeeded && !root.isEmpty ? (root as NSString).resolvingSymlinksInPath : nil
    }

    /// Stats for `files` (absolute paths). Outside a repository, each file
    /// is listed without counts.
    static func changes(cwd: String?, files: [String]) -> Changes {
        let files = Array(files.prefix(maxFiles))
        guard let cwd, !files.isEmpty, let root = repoRoot(cwd: cwd) else {
            return Changes(root: nil, files: files.map {
                FileChange(path: ($0 as NSString).lastPathComponent, added: nil, removed: nil, status: "changed")
            })
        }
        let resolved = files.map { (($0 as NSString).resolvingSymlinksInPath) }
        let inRepo = resolved.compactMap { relative($0, to: root) }
        var stats: [String: (Int?, Int?)] = [:]
        var untracked = Set<String>()
        if !inRepo.isEmpty {
            let num = ProcessRunner.run(git, ["-C", root, "diff", "--numstat", "-z", "--no-renames", "HEAD", "--"] + inRepo,
                                        timeout: gitTimeout)
            if num.succeeded { stats = parseNumstat(num.stdout) }
            let others = ProcessRunner.run(git, ["-C", root, "ls-files", "--others", "--exclude-standard", "-z", "--"] + inRepo,
                                           timeout: gitTimeout)
            if others.succeeded { untracked = Set(others.stdout.split(separator: "\0").map(String.init)) }
        }
        var out: [FileChange] = []
        for (abs, rel) in zip(resolved, resolved.map { relative($0, to: root) }) {
            guard let rel else {
                out.append(FileChange(path: (abs as NSString).lastPathComponent, added: nil, removed: nil, status: "changed"))
                continue
            }
            if let s = stats[rel] {
                out.append(FileChange(path: rel, added: s.0, removed: s.1, status: "modified"))
            } else if untracked.contains(rel) {
                out.append(FileChange(path: rel, added: lineCount(rel, root: root), removed: 0, status: "added"))
            } else {
                // Edited, then committed (or reverted): no diff against HEAD.
                out.append(FileChange(path: rel, added: nil, removed: nil, status: "changed"))
            }
        }
        return Changes(root: root, files: out)
    }

    /// Uncommitted changes in the whole repository (when the turn itself
    /// edited nothing): tracked changes plus untracked files.
    static func uncommitted(cwd: String?) -> Changes? {
        guard let cwd, let root = repoRoot(cwd: cwd) else { return nil }
        let num = ProcessRunner.run(git, ["-C", root, "diff", "--numstat", "-z", "--no-renames", "HEAD"], timeout: gitTimeout)
        guard num.succeeded else { return nil }
        var files = parseNumstat(num.stdout).sorted { $0.key < $1.key }
            .map { FileChange(path: $0.key, added: $0.value.0, removed: $0.value.1, status: "modified") }
        let others = ProcessRunner.run(git, ["-C", root, "ls-files", "--others", "--exclude-standard", "-z"], timeout: gitTimeout)
        if others.succeeded {
            for rel in others.stdout.split(separator: "\0").map(String.init).sorted() {
                files.append(FileChange(path: rel, added: lineCount(rel, root: root), removed: 0, status: "added"))
            }
        }
        return Changes(root: root, files: Array(files.prefix(maxFiles)))
    }

    /// The unified diff of `changes` against HEAD (untracked files as new
    /// files), redacted and capped.
    static func patch(_ changes: Changes, maxBytes: Int = maxPatchBytes) -> (text: String, truncated: Bool) {
        guard let root = changes.root else { return ("", false) }
        let tracked = changes.files.filter { $0.status == "modified" }.map(\.path)
        var text = ""
        if !tracked.isEmpty {
            let r = ProcessRunner.run(git, ["-C", root, "diff", "--no-color", "--no-renames", "--no-ext-diff", "HEAD", "--"] + tracked,
                                      timeout: gitTimeout)
            if r.succeeded { text = r.stdout }
        }
        for f in changes.files where f.status == "added" {
            guard text.utf8.count < maxBytes else { break }
            text += newFilePatch(path: f.path, root: root, maxBytes: maxBytes - text.utf8.count)
        }
        let (cut, truncated) = capped(text, maxBytes: maxBytes)
        return (ContextRedactor.redact(cut), truncated)
    }

    /// A file inside the repository that may be read: not a symlink (an
    /// untracked link could point at ~/.ssh), and resolving under `root`.
    static func readablePath(_ rel: String, root: String) -> String? {
        let path = root + "/" + rel
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular else { return nil }
        let resolved = (path as NSString).resolvingSymlinksInPath
        return relative(resolved, to: (root as NSString).resolvingSymlinksInPath) != nil ? path : nil
    }

    /// A new file as a unified diff ("+" on every line), text files only.
    static func newFilePatch(path: String, root: String, maxBytes: Int) -> String {
        guard let file = readablePath(path, root: root),
              let data = BoundedFileRead.read(file, maxBytes: max(0, maxBytes)),
              !data.contains(0) else { return "" }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        let body = (lines.last?.isEmpty == true ? lines.dropLast() : lines[...]).map { "+" + $0 }
        return "diff --git a/\(path) b/\(path)\nnew file\n--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1,\(body.count) @@\n"
            + body.joined(separator: "\n") + "\n"
    }

    private static func lineCount(_ rel: String, root: String) -> Int? {
        guard let path = readablePath(rel, root: root),
              let data = BoundedFileRead.read(path, maxBytes: 4 << 20), !data.contains(0) else { return nil }
        return data.reduce(0) { $1 == 10 ? $0 + 1 : $0 } + (data.last.map { $0 == 10 ? 0 : 1 } ?? 0)
    }

    // MARK: wiring

    /// The idle page headline for a session's transcript (blocking: one
    /// tail read and up to three git calls).
    static func headline(transcript: URL?, cwd: String?) -> String? {
        guard let transcript, let tail = InterventionDetector.readTail(of: transcript, maxBytes: 512 * 1024) else { return nil }
        let digest = TurnDigest.parse(tail.text)
        let files = digest.filesTouched
        let changes = files.isEmpty ? Changes(root: nil, files: []) : changes(cwd: cwd, files: files)
        return headline(fileCount: files.count, added: changes.added, removed: changes.removed, test: digest.lastTestRun)
    }

    /// The `diff` fields (everything but the header): this turn's files,
    /// else the repository's uncommitted changes. Files and patch shrink
    /// until the whole plaintext fits, leaving `headerRoom` for the header.
    static func diffFields(transcript: String?, cwd: String?, headerRoom: Int = 1024) -> [String: Any] {
        var obj: [String: Any] = [:]
        var changes: Changes?
        var scope = "turn"
        if let transcript, let tail = InterventionDetector.readTail(of: URL(fileURLWithPath: transcript), maxBytes: 512 * 1024) {
            let files = TurnDigest.parse(tail.text).filesTouched
            if !files.isEmpty { changes = Self.changes(cwd: cwd, files: files) }
        }
        if changes == nil {
            scope = "uncommitted"
            changes = uncommitted(cwd: cwd)
        }
        obj["scope"] = scope
        guard let changes else {
            obj["files"] = [Any]()
            obj["patch"] = ""
            obj["note"] = cwd == nil ? "Page doesn't know this session's folder." : "This folder isn't a git repository."
            return obj
        }
        if let root = changes.root { obj["repo"] = (root as NSString).lastPathComponent }
        var budget = maxPatchBytes
        var files = changes.files
        while true {
            let (patch, truncated) = Self.patch(Changes(root: changes.root, files: files), maxBytes: budget)
            obj["files"] = files.map(\.jsonObject)
            obj["patch"] = patch
            obj["truncated"] = truncated || files.count < changes.files.count
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
               data.count <= maxPlaintextBytes - headerRoom { return obj }
            if budget > 4096 { budget /= 2 } else if files.count > 1 { files.removeLast(files.count / 2) } else {
                obj["patch"] = ""
                return obj
            }
        }
    }
}
