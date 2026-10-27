import Foundation

/// Turns on kitty's remote control for Page, by adding two lines to
/// `kitty.conf` (one click in the Tower's Terminals page):
///
///     allow_remote_control socket-only
///     listen_on unix:/tmp/kitty-{kitty_pid}
///
/// kitty.conf is the user's own file, so the edit is as small as it can be:
/// only lines that are missing are appended, under a comment saying who added
/// them, and every existing byte stays. kitty reads the file top to bottom
/// and the last line wins, so a line that already says something else is not
/// overridden behind the user's back: Page leaves the file alone and names the
/// line to change. A timestamped copy is written first; Undo takes the same
/// lines out again. kitty must be restarted to read the file.
enum KittyConfigFile {
    static let allowKey = "allow_remote_control"
    static let listenKey = "listen_on"
    static let allowLine = "allow_remote_control socket-only"
    static let listenLine = "listen_on unix:/tmp/kitty-{kitty_pid}"
    static let marker = "# Added by Page: lets Page type into kitty windows (restart kitty to apply)"

    /// `allow_remote_control` values that let a local socket in (kitty reads
    /// `y`, `yes` and `true` alike). `password` and `no` do not.
    static let acceptedAllow: Set<String> = ["y", "yes", "true", "socket", "socket-only"]

    // MARK: parsing (pure)

    /// The effective value of each setting (last line wins) and where it was set.
    struct Settings: Equatable {
        var allowRemoteControl: String?
        var allowLineNumber: Int?
        /// "colors.conf line 2": the file and line that set it.
        var allowSource: String?
        var listenOn: String?
        var listenLineNumber: Int?
        var listenSource: String?
    }

    /// One line of a config file, and where it came from.
    struct Line: Equatable {
        let text: String
        let file: String
        let number: Int
    }

    /// Pure. "\r\n" (a Windows file) read as "\n": Swift treats the pair as
    /// one character, so splitting on "\n" would never split such a file.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// Pure. The lines of `text`, numbered from 1, all from `file`.
    static func lines(of text: String, file: String) -> [Line] {
        normalized(text).components(separatedBy: "\n").enumerated().map { Line(text: $0.element, file: file, number: $0.offset + 1) }
    }

    /// Pure. kitty.conf syntax: `key value`, `#` starts a comment line.
    static func parse(_ text: String) -> Settings {
        parse(lines(of: text, file: "kitty.conf"))
    }

    static func parse(_ lines: [Line]) -> Settings {
        var s = Settings()
        for l in lines {
            let line = l.text.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            let source = "\(l.file) line \(l.number)"
            switch key {
            case allowKey: s.allowRemoteControl = value; s.allowLineNumber = l.number; s.allowSource = source
            case listenKey: s.listenOn = value; s.listenLineNumber = l.number; s.listenSource = source
            default: continue
            }
        }
        return s
    }

    enum Plan: Equatable {
        /// Both settings are already right.
        case alreadyDone
        /// The new file text, and the lines added.
        case write(text: String, added: [String])
        /// An existing line says something else: what to change by hand.
        case conflict(String)
    }

    /// Pure. `text`: the file as it is (nil: no file yet). `effective`: the
    /// file with its `include`d files read in, when settings may live there;
    /// `effectiveLines` the same with each line's own file and number, so a
    /// conflict names the right one.
    static func plan(text: String?, effective: String? = nil, effectiveLines: [Line]? = nil) -> Plan {
        let settings = effectiveLines.map(parse(_:)) ?? parse(effective ?? text ?? "")
        var added: [String] = []
        if let allow = settings.allowRemoteControl {
            if !acceptedAllow.contains(allow) {
                return .conflict("\(settings.allowSource ?? "kitty.conf") says “\(allowKey) \(allow)”. Change it to “\(allowLine)”, then restart kitty.")
            }
        } else {
            added.append(allowLine)
        }
        if let listen = settings.listenOn {
            if !KittyBridge.isLocalSocket(listen) {
                return .conflict("\(settings.listenSource ?? "kitty.conf") says “\(listenKey) \(listen)”. Page only uses a local socket: change it to “\(listenLine)”, then restart kitty.")
            }
        } else {
            added.append(listenLine)
        }
        guard !added.isEmpty else { return .alreadyDone }
        var base = text ?? ""
        // utf8, not hasSuffix: Swift reads a final "\r\n" as one character that is not "\n".
        if !base.isEmpty, base.utf8.last != UInt8(ascii: "\n") { base += "\n" }
        let separator = base.isEmpty ? "" : "\n"
        return .write(text: base + separator + marker + "\n" + added.joined(separator: "\n") + "\n", added: added)
    }

    /// Pure. Splits at every "\n" byte, also the one inside "\r\n" (which
    /// Swift's own String splitting treats as part of one character), so
    /// joining with "\n" gives the file back byte for byte.
    private static func utf16Lines(_ text: String) -> [String] {
        (text as NSString).components(separatedBy: "\n")
    }

    /// Pure. The file with the lines Page added taken out again (the marker
    /// and the Page lines right after it), or nil when Page never added any.
    /// A blank line Page put before the marker goes too.
    static func removingPageLines(from text: String) -> String? {
        var lines = utf16Lines(text)
        guard let at = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == marker }) else { return nil }
        var end = at + 1
        while end < lines.count {
            let t = lines[end].trimmingCharacters(in: .whitespacesAndNewlines)
            if t == allowLine || t == listenLine { end += 1 } else { break }
        }
        lines.removeSubrange(at..<end)
        if at > 0, lines[at - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.remove(at: at - 1) }
        return lines.joined(separator: "\n")
    }

    /// Pure. Whether Page's lines are in the file.
    static func hasPageLines(_ text: String) -> Bool {
        utf16Lines(text).contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == marker }
    }

    /// Pure. Where a running kitty with this `listen_on` keeps its socket
    /// (`{kitty_pid}` filled in); nil for anything else (abstract sockets, a
    /// path with other placeholders), where Page can't tell.
    static func socketPath(listenOn: String, pid: Int32) -> String? {
        guard listenOn.hasPrefix("unix:") else { return nil }
        let path = String(listenOn.dropFirst("unix:".count)).replacingOccurrences(of: "{kitty_pid}", with: String(pid))
        guard path.hasPrefix("/"), !path.contains("{") else { return nil }
        return path
    }

    /// The effective `listen_on` of the file at `url` (its includes read in).
    static func listenOn(url: URL = defaultURL) -> String? {
        effectiveLines(at: url).flatMap { parse($0).listenOn }
    }

    // MARK: where the file is (pure given its inputs)

    /// kitty's own search order, for the file that exists; else where kitty
    /// would read one (so the new file is found): `KITTY_CONFIG_DIRECTORY`,
    /// `$XDG_CONFIG_HOME/kitty`, `~/.config/kitty`, `~/Library/Preferences/kitty`.
    static func configURL(env: [String: String], home: String, exists: (String) -> Bool) -> URL {
        var dirs: [String] = []
        if let d = env["KITTY_CONFIG_DIRECTORY"], !d.isEmpty { dirs.append(d) }
        if let x = env["XDG_CONFIG_HOME"], !x.isEmpty { dirs.append(x + "/kitty") }
        dirs.append(home + "/.config/kitty")
        dirs.append(home + "/Library/Preferences/kitty")
        let chosen = dirs.first { exists($0 + "/kitty.conf") } ?? dirs[0]
        return URL(fileURLWithPath: chosen + "/kitty.conf")
    }

    /// Pure. `include` targets in a file (plain paths only; globs and
    /// environment includes are left to kitty). Relative paths are relative
    /// to the file's folder.
    static func includePaths(in text: String, baseDirectory: String) -> [String] {
        var out: [String] = []
        for raw in normalized(text).split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("include") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, parts[0] == "include" else { continue }
            let p = (parts[1].trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            out.append(p.hasPrefix("/") ? p : baseDirectory + "/" + p)
        }
        return out
    }

    // MARK: files (I/O)

    static var defaultURL: URL {
        configURL(env: ProcessInfo.processInfo.environment, home: NSHomeDirectory(),
                  exists: { FileManager.default.fileExists(atPath: $0) })
    }

    struct Outcome: Equatable {
        let url: URL
        /// nil when there was no kitty.conf before.
        let backup: URL?
        let added: [String]
    }

    enum Failure: Error, Equatable {
        case conflict(String)
        case unreadable
        case symlink
        case writeFailed

        var message: String {
            switch self {
            case .conflict(let s): return s
            case .unreadable: return "Page couldn't read kitty.conf."
            case .symlink: return "kitty.conf is a link to a file that isn’t there, so Page left it alone."
            case .writeFailed: return "Page couldn't write kitty.conf."
            }
        }
    }

    /// What Set up… is about to do, for the confirmation (nothing is written).
    struct Preview: Equatable {
        let url: URL
        let plan: Plan
        let creating: Bool
        /// When kitty.conf is a link (a dotfiles repo, say): the file it
        /// points at, which is the one Page would edit.
        var linkTarget: URL?
    }

    /// kitty.conf with its plain `include`s read in (at most 3 deep), line by
    /// line with each line's own file and number, so settings kept in another
    /// file count and a conflict there names that file.
    static func effectiveLines(at url: URL, depth: Int = 0) -> [Line]? {
        guard let data = BoundedFileRead.read(url.path, maxBytes: 1 << 20),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let own = lines(of: text, file: url.lastPathComponent)
        guard depth < 3 else { return own }
        let base = url.deletingLastPathComponent().path
        var out: [Line] = []
        for line in own {
            out.append(line)
            for inc in includePaths(in: line.text, baseDirectory: base) {
                if let nested = effectiveLines(at: URL(fileURLWithPath: inc), depth: depth + 1) { out += nested }
            }
        }
        return out
    }

    /// The file with its `include`s read in, as one text.
    static func effectiveText(at url: URL, depth: Int = 0) -> String? {
        effectiveLines(at: url, depth: depth).map { $0.map(\.text).joined(separator: "\n") + "\n" }
    }

    /// The file Page would write for `url`: itself, or what a link points at.
    /// nil for a link that leads nowhere.
    private static func writableTarget(_ url: URL) -> URL? {
        let fm = FileManager.default
        guard let type = try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType,
              type == .typeSymbolicLink else { return url }
        let real = url.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: real.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return real
    }

    static func preview(url: URL = defaultURL) -> Result<Preview, Failure> {
        let fm = FileManager.default
        guard let target = writableTarget(url) else { return .failure(.symlink) }
        let exists = fm.fileExists(atPath: url.path)
        var existing: String?
        var effective: [Line]?
        if exists {
            guard let data = BoundedFileRead.read(url.path, maxBytes: 1 << 20),
                  let s = String(data: data, encoding: .utf8) else { return .failure(.unreadable) }
            existing = s
            effective = effectiveLines(at: url)
        }
        return .success(Preview(url: url, plan: plan(text: existing, effectiveLines: effective), creating: !exists,
                                linkTarget: target == url ? nil : target))
    }

    /// `<name>.bak-page-<stamp>` beside the file, or the same with `-2`, `-3`…
    /// when that name is taken: a second action in the same second must not
    /// overwrite the copy the first one made.
    private static func backupURL(for url: URL, now: Date) -> URL {
        let dir = url.deletingLastPathComponent()
        let base = "\(url.lastPathComponent).bak-page-\(stamp(now))"
        var candidate = dir.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
            candidate = dir.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        return candidate
    }

    /// Backs up, plans and writes (through a link, to the file it points at).
    /// The backup is `kitty.conf.bak-page-<stamp>` beside the file.
    static func enable(url: URL = defaultURL, now: Date = Date()) -> Result<Outcome, Failure> {
        let fm = FileManager.default
        switch preview(url: url) {
        case .failure(let f): return .failure(f)
        case .success(let p):
            let file = p.linkTarget ?? url
            switch p.plan {
            case .conflict(let why): return .failure(.conflict(why))
            case .alreadyDone: return .success(Outcome(url: file, backup: nil, added: []))
            case .write(let text, let added):
                var backup: URL?
                if !p.creating, let data = try? Data(contentsOf: file) {
                    let b = backupURL(for: file, now: now)
                    guard writeAtomically(data, to: b, like: file) else { return .failure(.writeFailed) }
                    backup = b
                } else {
                    try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                }
                guard writeAtomically(Data(text.utf8), to: file, like: file) else { return .failure(.writeFailed) }
                return .success(Outcome(url: file, backup: backup, added: added))
            }
        }
    }

    /// Takes Page's lines out (after a fresh backup). False when there was
    /// nothing of Page's to remove or the write failed.
    @discardableResult
    static func undo(url: URL = defaultURL, now: Date = Date()) -> Bool {
        guard let file = writableTarget(url) else { return false }
        guard let data = BoundedFileRead.read(file.path, maxBytes: 1 << 20),
              let text = String(data: data, encoding: .utf8),
              let cleaned = removingPageLines(from: text) else { return false }
        let b = backupURL(for: file, now: now)
        guard writeAtomically(data, to: b, like: file) else { return false }
        return writeAtomically(Data(cleaned.utf8), to: file, like: file)
    }

    /// Whether the file at `url` holds lines Page added.
    static func hasPageLines(at url: URL = defaultURL) -> Bool {
        guard let data = BoundedFileRead.read(url.path, maxBytes: 1 << 20),
              let text = String(data: data, encoding: .utf8) else { return false }
        return hasPageLines(text)
    }

    /// The setup state for the Terminals page: the file's effective settings.
    static func setupState(url: URL = defaultURL) -> TerminalCatalog.SetupState {
        guard case .success(let p) = preview(url: url) else {
            return .needed("Page can't read kitty.conf, so it can't tell whether kitty's remote control is on")
        }
        switch p.plan {
        case .alreadyDone: return .done
        case .write: return .needed("Remote control is off in kitty. Page adds two lines to kitty.conf; restart kitty after.")
        case .conflict(let why): return .needed(why)
        }
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// Temp file + rename, keeping the original file's permissions (a user's
    /// kitty.conf is usually 0644, not 0600).
    private static func writeAtomically(_ data: Data, to url: URL, like original: URL) -> Bool {
        let mode = (try? FileManager.default.attributesOfItem(atPath: original.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).page-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: mode]) else { return false }
        guard rename(tmp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        return true
    }
}
