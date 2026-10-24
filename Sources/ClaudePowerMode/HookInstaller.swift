import Foundation

// MARK: - Order-preserving JSON

/// A JSON value that remembers key order and the literal text of strings and
/// numbers, so a settings file can be edited without reformatting the parts
/// we don't touch. `JSONSerialization` would reorder every object and escape
/// "/" (rewriting the `$schema` URL), turning a three-entry change into a
/// whole-file diff the user can't review.
indirect enum OrderedJSON: Equatable {
    struct Member: Equatable {
        var key: String
        /// The key exactly as written, including quotes.
        var rawKey: String
        var value: OrderedJSON

        init(_ key: String, _ value: OrderedJSON) {
            self.key = key
            self.rawKey = OrderedJSON.quote(key)
            self.value = value
        }

        init(key: String, rawKey: String, value: OrderedJSON) {
            self.key = key
            self.rawKey = rawKey
            self.value = value
        }

        static func == (a: Member, b: Member) -> Bool { a.key == b.key && a.value == b.value }
    }

    case object([Member])
    case array([OrderedJSON])
    /// `raw` is the literal including quotes when parsed from a file; nil for
    /// values we create (printed with standard escaping).
    case string(String, raw: String?)
    /// Kept as its literal text: 1.0 vs 1, exponents etc. survive a round trip.
    case number(String)
    case bool(Bool)
    case null

    static func str(_ s: String) -> OrderedJSON { .string(s, raw: nil) }

    static func == (a: OrderedJSON, b: OrderedJSON) -> Bool {
        switch (a, b) {
        case let (.object(x), .object(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.string(x, _), .string(y, _)): return x == y
        case let (.number(x), .number(y)):
            if x == y { return true }
            if let dx = Double(x), let dy = Double(y) { return dx == dy }
            return false
        case let (.bool(x), .bool(y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    var objectMembers: [Member]? {
        if case .object(let m) = self { return m }
        return nil
    }

    var arrayValue: [OrderedJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var stringValue: String? {
        if case .string(let s, _) = self { return s }
        return nil
    }

    subscript(key: String) -> OrderedJSON? {
        objectMembers?.last(where: { $0.key == key })?.value
    }

    // MARK: printing

    /// Pretty-prints in the style of `JSON.stringify(value, null, indent)`,
    /// which is how Claude Code writes settings.json.
    func rendered(indent: String = "  ") -> String {
        var out = ""
        render(into: &out, indent: indent, level: 0)
        return out
    }

    private func render(into out: inout String, indent: String, level: Int) {
        switch self {
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{\n"
            for (i, m) in members.enumerated() {
                out += String(repeating: indent, count: level + 1) + m.rawKey + ": "
                m.value.render(into: &out, indent: indent, level: level + 1)
                out += i == members.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: indent, count: level) + "}"
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += String(repeating: indent, count: level + 1)
                item.render(into: &out, indent: indent, level: level + 1)
                out += i == items.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: indent, count: level) + "]"
        case .string(let s, let raw):
            out += raw ?? Self.quote(s)
        case .number(let n):
            out += n
        case .bool(let b):
            out += b ? "true" : "false"
        case .null:
            out += "null"
        }
    }

    /// JSON.stringify escaping: quotes, backslash, the short control escapes,
    /// other C0 controls as \u00XX; everything else (including "/" and
    /// non-ASCII) literal.
    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: parsing

    struct ParseError: Error, Equatable, CustomStringConvertible {
        let message: String
        let offset: Int
        var description: String { "\(message) at byte \(offset)" }
    }

    static func parse(_ text: String) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.atEnd else { throw ParseError(message: "Unexpected text after the JSON value", offset: parser.pos) }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var pos = 0
        static let maxDepth = 256

        var atEnd: Bool { pos >= bytes.count }

        mutating func skipWhitespace() {
            while pos < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[pos]) { pos += 1 }
        }

        func fail(_ message: String) -> ParseError { ParseError(message: message, offset: pos) }

        mutating func expect(_ byte: UInt8) throws {
            guard pos < bytes.count, bytes[pos] == byte else {
                throw fail("Expected '\(Character(UnicodeScalar(byte)))'")
            }
            pos += 1
        }

        mutating func parseValue(depth: Int) throws -> OrderedJSON {
            guard depth < Self.maxDepth else { throw fail("Nesting too deep") }
            guard pos < bytes.count else { throw fail("Unexpected end of file") }
            switch bytes[pos] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""):
                let (value, raw) = try parseString()
                return .string(value, raw: raw)
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
            default: throw fail("Unexpected character")
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard pos + w.count <= bytes.count, Array(bytes[pos..<pos + w.count]) == w else {
                throw fail("Invalid literal")
            }
            pos += w.count
        }

        mutating func parseObject(depth: Int) throws -> OrderedJSON {
            try expect(UInt8(ascii: "{"))
            var members: [Member] = []
            skipWhitespace()
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard pos < bytes.count, bytes[pos] == UInt8(ascii: "\"") else { throw fail("Expected a key") }
                let (key, rawKey) = try parseString()
                skipWhitespace()
                try expect(UInt8(ascii: ":"))
                skipWhitespace()
                let value = try parseValue(depth: depth + 1)
                members.append(Member(key: key, rawKey: rawKey, value: value))
                skipWhitespace()
                guard pos < bytes.count else { throw fail("Unterminated object") }
                if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
                if bytes[pos] == UInt8(ascii: "}") { pos += 1; return .object(members) }
                throw fail("Expected ',' or '}'")
            }
        }

        mutating func parseArray(depth: Int) throws -> OrderedJSON {
            try expect(UInt8(ascii: "["))
            var items: [OrderedJSON] = []
            skipWhitespace()
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard pos < bytes.count else { throw fail("Unterminated array") }
                if bytes[pos] == UInt8(ascii: ",") { pos += 1; continue }
                if bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(items) }
                throw fail("Expected ',' or ']'")
            }
        }

        mutating func parseNumber() throws -> OrderedJSON {
            let start = pos
            if bytes[pos] == UInt8(ascii: "-") { pos += 1 }
            func digits() -> Int {
                let s = pos
                while pos < bytes.count, bytes[pos] >= 0x30, bytes[pos] <= 0x39 { pos += 1 }
                return pos - s
            }
            guard pos < bytes.count else { throw fail("Invalid number") }
            if bytes[pos] == UInt8(ascii: "0") { pos += 1 } else if digits() == 0 { throw fail("Invalid number") }
            if pos < bytes.count, bytes[pos] == UInt8(ascii: ".") {
                pos += 1
                guard digits() > 0 else { throw fail("Invalid number") }
            }
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "e") || bytes[pos] == UInt8(ascii: "E") {
                pos += 1
                if pos < bytes.count, bytes[pos] == UInt8(ascii: "+") || bytes[pos] == UInt8(ascii: "-") { pos += 1 }
                guard digits() > 0 else { throw fail("Invalid number") }
            }
            return .number(String(decoding: bytes[start..<pos], as: UTF8.self))
        }

        /// Returns the decoded value and the raw literal (with quotes).
        mutating func parseString() throws -> (String, String) {
            let start = pos
            try expect(UInt8(ascii: "\""))
            var scalars = String.UnicodeScalarView()
            var chunkStart = pos
            func flushChunk(_ end: Int) throws {
                guard end > chunkStart else { return }
                guard let s = String(bytes: bytes[chunkStart..<end], encoding: .utf8) else {
                    throw fail("Invalid UTF-8 in string")
                }
                scalars.append(contentsOf: s.unicodeScalars)
            }
            while true {
                guard pos < bytes.count else { throw fail("Unterminated string") }
                let b = bytes[pos]
                if b == UInt8(ascii: "\"") {
                    try flushChunk(pos)
                    pos += 1
                    break
                }
                if b < 0x20 { throw fail("Control character in string") }
                if b == UInt8(ascii: "\\") {
                    try flushChunk(pos)
                    pos += 1
                    guard pos < bytes.count else { throw fail("Unterminated escape") }
                    let e = bytes[pos]
                    pos += 1
                    switch e {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        let hi = try hex4()
                        if (0xD800...0xDBFF).contains(hi) {
                            // Must be followed by a low surrogate; a lone one
                            // can't be represented in a Swift String, and
                            // silently replacing it would change the file.
                            guard pos + 1 < bytes.count, bytes[pos] == UInt8(ascii: "\\"),
                                  bytes[pos + 1] == UInt8(ascii: "u") else { throw fail("Lone surrogate escape") }
                            pos += 2
                            let lo = try hex4()
                            guard (0xDC00...0xDFFF).contains(lo) else { throw fail("Invalid surrogate pair") }
                            let cp = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                            guard let u = UnicodeScalar(cp) else { throw fail("Invalid code point") }
                            scalars.append(u)
                        } else {
                            guard let u = UnicodeScalar(hi) else { throw fail("Lone surrogate escape") }
                            scalars.append(u)
                        }
                    default:
                        throw fail("Invalid escape")
                    }
                    chunkStart = pos
                    continue
                }
                pos += 1
            }
            let raw = String(decoding: bytes[start..<pos], as: UTF8.self)
            return (String(scalars), raw)
        }

        mutating func hex4() throws -> UInt32 {
            guard pos + 4 <= bytes.count else { throw fail("Invalid \\u escape") }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[pos]
                let d: UInt32
                switch c {
                case 0x30...0x39: d = UInt32(c - 0x30)
                case 0x41...0x46: d = UInt32(c - 0x41 + 10)
                case 0x61...0x66: d = UInt32(c - 0x61 + 10)
                default: throw fail("Invalid \\u escape")
                }
                v = v * 16 + d
                pos += 1
            }
            return v
        }
    }
}

// MARK: - Installer

/// Which agent's hook configuration we manage.
enum HookAgent: String, CaseIterable {
    case claude, codex

    var displayName: String { self == .claude ? "Claude Code" : "Codex" }
}

enum HookInstallerError: Error, LocalizedError, Equatable {
    case agentNotInstalled(HookAgent)
    case unreadable(String)
    case invalidJSON(String)
    case notAnObject
    case hooksNotAnObject
    case eventNotAList(String)
    case changedSincePreview
    case writeFailed(String)
    case scriptUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .agentNotInstalled(let a):
            return a == .claude
                ? "~/.claude doesn't exist — run Claude Code once first."
                : "~/.codex doesn't exist — run Codex once first."
        case .unreadable(let m): return "Couldn't read the file: \(m)"
        case .invalidJSON(let m): return "The file isn't valid JSON (\(m)). Page won't touch it; fix it by hand first."
        case .notAnObject: return "The file's top level isn't a JSON object. Page won't touch it."
        case .hooksNotAnObject: return "\"hooks\" in the file isn't an object. Page won't touch it."
        case .eventNotAList(let e): return "\"hooks.\(e)\" isn't a list. Page won't touch it."
        case .changedSincePreview: return "The file changed since the preview was made. Review the new preview and try again."
        case .writeFailed(let m): return "Couldn't write the file: \(m)"
        case .scriptUnavailable(let m): return m
        }
    }
}

/// Whether Page's hooks are present in an agent's config file.
enum HookInstallState: Equatable {
    case notInstalled
    /// Exactly the entries Page would write today.
    case installed
    /// Page entries exist but differ (older path, missing event, other timeout…).
    case needsUpdate
    case agentMissing
    case unreadable(String)
}

struct HookStatus: Equatable {
    var state: HookInstallState
    /// Page hook commands found in the file (to show what an update replaces).
    var pageCommands: [String] = []
    /// Codex only: the opt-in Stop continuation is installed.
    var codexStopEnabled = false
}

/// A computed change to one file. `apply` writes it only if the file still
/// holds exactly `originalData` (what the user reviewed).
struct HookChangePlan {
    enum Action: String { case install, uninstall }
    let agent: HookAgent
    let action: Action
    /// The path the agent reads (may be a symlink).
    let fileURL: URL
    /// The file actually written (symlinks resolved, so a dotfile manager's
    /// link isn't replaced by a regular file).
    let writeURL: URL
    /// nil when the file doesn't exist yet.
    let originalData: Data?
    let originalText: String
    let newText: String
    var changed: Bool { originalText != newText }
}

/// cmux's own PermissionRequest hook (it injects per-session settings with
/// `--settings`, not via ~/.claude/settings.json). Informational only.
struct CmuxHookInfo: Equatable {
    var settingsFiles = 0
    var withPermissionRequestHook = 0
}

/// Codex config.toml facts that affect hooks.json (read-only, line-based).
struct CodexConfigInfo: Equatable {
    var hooksFeatureDisabled = false
    var hasInlineHooks = false
}

/// Computes and applies Page's hook entries in ~/.claude/settings.json and
/// ~/.codex/hooks.json. Pure logic over files under `homeDirectory`, so tests
/// run against a temp directory. Never writes without an explicit `apply`.
///
/// Page's entries are recognised by their command naming `page-notify.sh`,
/// wherever it lives — including an older manual install such as
/// ~/.claude/hooks/page-notify.sh, which an install migrates (otherwise the
/// Notification page would fire twice). Other tools' hooks are never removed
/// or edited: Page only adds its own matcher groups, and on uninstall removes
/// handlers that are its own (whole groups only when every handler in them is).
struct HookInstaller {
    static let scriptName = "page-notify.sh"
    /// Blocking hooks wait this long for the phone (PAGE_HOOK_TIMEOUT default
    /// in the script) …
    static let hookWaitSeconds = 540
    /// … and the agent's timeout must exceed it so the hook gives up cleanly.
    static let blockingTimeout = hookWaitSeconds + 30
    static let notificationTimeout = 30
    static let questionMatcher = "AskUserQuestion|ExitPlanMode"
    static let blockingStatusMessage = "Page: asking your phone (only when you're away)"

    let homeDirectory: URL
    let scriptPath: String
    var fileManager: FileManager = .default

    var claudeDirectory: URL { homeDirectory.appendingPathComponent(".claude", isDirectory: true) }
    var codexDirectory: URL { homeDirectory.appendingPathComponent(".codex", isDirectory: true) }
    var claudeSettingsURL: URL { claudeDirectory.appendingPathComponent("settings.json") }
    var codexHooksURL: URL { codexDirectory.appendingPathComponent("hooks.json") }
    var codexConfigURL: URL { codexDirectory.appendingPathComponent("config.toml") }

    func fileURL(for agent: HookAgent) -> URL { agent == .claude ? claudeSettingsURL : codexHooksURL }
    func agentDirectory(for agent: HookAgent) -> URL { agent == .claude ? claudeDirectory : codexDirectory }

    // MARK: script location

    /// The hook script to reference: inside the app bundle, else (dev builds
    /// run from the repo) the repo's hooks/ folder. nil if none is usable.
    static func locateScript(bundle: Bundle = .main, fileManager: FileManager = .default,
                             sourceFile: String = #filePath) -> String? {
        var candidates: [URL] = []
        if let res = bundle.resourceURL {
            candidates.append(res.appendingPathComponent("hooks/\(scriptName)"))
        }
        if let exe = bundle.executableURL?.resolvingSymlinksInPath() {
            var dir = exe.deletingLastPathComponent()
            for _ in 0..<6 {
                candidates.append(dir.appendingPathComponent("hooks/\(scriptName)"))
                dir = dir.deletingLastPathComponent()
            }
        }
        // Sources/ClaudePowerMode/HookInstaller.swift -> <repo>/hooks/
        candidates.append(URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("hooks/\(scriptName)"))
        for url in candidates {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
               fileManager.isExecutableFile(atPath: url.path) {
                return url.standardizedFileURL.path
            }
        }
        return nil
    }

    /// Paths that would break later: a translocated copy (Gatekeeper runs
    /// apps from a random read-only mount until they're moved) or a disk
    /// image. Returns a reason, or nil when the path is fine to persist.
    static func unsuitableScriptReason(_ path: String) -> String? {
        if path.contains("/AppTranslocation/") {
            return "Page is running from a temporary location. Move Page.app to Applications, reopen it, then install the hooks."
        }
        if path.hasPrefix("/Volumes/") {
            return "Page is running from a disk image. Copy Page.app to Applications first."
        }
        return nil
    }

    // MARK: canonical entries

    /// Single-quoted for the shell the agent runs the command in.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func command(for agent: HookAgent) -> String {
        agent == .claude ? Self.shellQuote(scriptPath) : Self.shellQuote(scriptPath) + " --codex"
    }

    /// The command for a blocking handler: also tells the script the agent's
    /// timeout, so its wait (whatever PAGE_HOOK_TIMEOUT says) always ends
    /// early enough to print the decision — the agent kills a hook at its
    /// timeout and discards what it printed.
    func blockingCommand(for agent: HookAgent, timeout: Int) -> String {
        command(for: agent) + " --agent-timeout \(timeout)"
    }

    private func handler(_ agent: HookAgent, timeout: Int, statusMessage: String?, blocking: Bool = true) -> OrderedJSON {
        var members: [OrderedJSON.Member] = [
            .init("type", .str("command")),
            .init("command", .str(blocking ? blockingCommand(for: agent, timeout: timeout) : command(for: agent))),
            .init("timeout", .number(String(timeout)))
        ]
        if let statusMessage { members.append(.init("statusMessage", .str(statusMessage))) }
        return .object(members)
    }

    private func group(matcher: String?, _ handler: OrderedJSON) -> OrderedJSON {
        var members: [OrderedJSON.Member] = []
        if let matcher { members.append(.init("matcher", .str(matcher))) }
        members.append(.init("hooks", .array([handler])))
        return .object(members)
    }

    /// (event, matcher group) pairs Page installs, in file order.
    func canonicalEntries(for agent: HookAgent, codexStop: Bool = false) -> [(event: String, group: OrderedJSON)] {
        switch agent {
        case .claude:
            return [
                ("PermissionRequest", group(matcher: nil, handler(.claude, timeout: Self.blockingTimeout,
                                                                  statusMessage: Self.blockingStatusMessage))),
                ("PreToolUse", group(matcher: Self.questionMatcher,
                                     handler(.claude, timeout: Self.blockingTimeout,
                                             statusMessage: Self.blockingStatusMessage))),
                ("Notification", group(matcher: nil, handler(.claude, timeout: Self.notificationTimeout,
                                                             statusMessage: nil, blocking: false)))
            ]
        case .codex:
            var entries: [(event: String, group: OrderedJSON)] = [
                ("PermissionRequest", group(matcher: nil, handler(.codex, timeout: Self.blockingTimeout,
                                                                  statusMessage: Self.blockingStatusMessage)))
            ]
            if codexStop {
                entries.append(("Stop", group(matcher: nil, handler(.codex, timeout: Self.blockingTimeout,
                                                                    statusMessage: "Page: waiting for your reply (only when you're away)"))))
            }
            return entries
        }
    }

    // MARK: recognising Page's entries

    static func isPageHandler(_ v: OrderedJSON) -> Bool {
        guard let cmd = v["command"]?.stringValue else { return false }
        return cmd.contains(scriptName)
    }

    /// Page handler commands in a parsed file, in order.
    static func pageCommands(in root: OrderedJSON) -> [String] {
        guard let hooks = root["hooks"]?.objectMembers else { return [] }
        var out: [String] = []
        for event in hooks {
            for g in event.value.arrayValue ?? [] {
                for h in g["hooks"]?.arrayValue ?? [] where isPageHandler(h) {
                    if let c = h["command"]?.stringValue { out.append(c) }
                }
            }
        }
        return out
    }

    /// Page's groups per event. `mixed` is set when a Page handler shares a
    /// group with someone else's (never what Page writes).
    static func pageGroups(in root: OrderedJSON) -> (groups: [String: [OrderedJSON]], mixed: Bool) {
        var out: [String: [OrderedJSON]] = [:]
        var mixed = false
        guard let hooks = root["hooks"]?.objectMembers else { return (out, false) }
        for event in hooks {
            for g in event.value.arrayValue ?? [] {
                let handlers = g["hooks"]?.arrayValue ?? []
                let ours = handlers.filter(isPageHandler)
                guard !ours.isEmpty else { continue }
                if ours.count != handlers.count { mixed = true }
                out[event.key, default: []].append(g)
            }
        }
        return (out, mixed)
    }

    /// Removes every Page handler. Returns the new root and whether anything
    /// was removed. Containers Page emptied are dropped (unless
    /// `keepEmptiedEvents`, used by install so a migrated entry keeps its
    /// event's position); containers that were already empty are left alone.
    static func removingPageHandlers(from root: OrderedJSON, keepEmptiedEvents: Bool = false) throws -> (OrderedJSON, Bool) {
        guard var rootMembers = root.objectMembers else { throw HookInstallerError.notAnObject }
        guard let hooksIndex = rootMembers.lastIndex(where: { $0.key == "hooks" }) else { return (root, false) }
        guard var events = rootMembers[hooksIndex].value.objectMembers else { throw HookInstallerError.hooksNotAnObject }

        var removedAny = false
        var newEvents: [OrderedJSON.Member] = []
        for var event in events {
            guard let groups = event.value.arrayValue else { newEvents.append(event); continue }
            var removedHere = false
            var newGroups: [OrderedJSON] = []
            for g in groups {
                guard var gm = g.objectMembers, let hi = gm.lastIndex(where: { $0.key == "hooks" }),
                      let handlers = gm[hi].value.arrayValue else { newGroups.append(g); continue }
                let kept = handlers.filter { !isPageHandler($0) }
                if kept.count == handlers.count { newGroups.append(g); continue }
                removedHere = true
                if kept.isEmpty { continue }           // the whole group was Page's
                gm[hi].value = .array(kept)            // shared group: only our handler goes
                newGroups.append(.object(gm))
            }
            if removedHere {
                removedAny = true
                if newGroups.isEmpty && !keepEmptiedEvents { continue }   // Page emptied this event
                event.value = .array(newGroups)
            }
            newEvents.append(event)
        }
        events = newEvents
        guard removedAny else { return (root, false) }
        if events.isEmpty && !keepEmptiedEvents {
            rootMembers.remove(at: hooksIndex)
        } else {
            rootMembers[hooksIndex].value = .object(events)
        }
        return (.object(rootMembers), true)
    }

    /// Removes the named events when their list is empty.
    static func droppingEmptyEvents(_ names: Set<String>, from root: OrderedJSON) -> OrderedJSON {
        guard !names.isEmpty, var rootMembers = root.objectMembers,
              let hi = rootMembers.lastIndex(where: { $0.key == "hooks" }),
              let events = rootMembers[hi].value.objectMembers else { return root }
        rootMembers[hi].value = .object(events.filter { !(names.contains($0.key) && $0.value.arrayValue?.isEmpty == true) })
        return .object(rootMembers)
    }

    /// Appends Page's groups (each event's list gets our group at the end;
    /// missing events and a missing "hooks" object are added at the end).
    static func addingEntries(_ entries: [(event: String, group: OrderedJSON)], to root: OrderedJSON) throws -> OrderedJSON {
        guard var rootMembers = root.objectMembers else { throw HookInstallerError.notAnObject }
        var hooksIndex = rootMembers.lastIndex(where: { $0.key == "hooks" })
        if hooksIndex == nil {
            rootMembers.append(.init("hooks", .object([])))
            hooksIndex = rootMembers.count - 1
        }
        guard let hi = hooksIndex, var events = rootMembers[hi].value.objectMembers else {
            throw HookInstallerError.hooksNotAnObject
        }
        for (event, group) in entries {
            if let ei = events.lastIndex(where: { $0.key == event }) {
                guard var list = events[ei].value.arrayValue else { throw HookInstallerError.eventNotAList(event) }
                list.append(group)
                events[ei].value = .array(list)
            } else {
                events.append(.init(event, .array([group])))
            }
        }
        rootMembers[hi].value = .object(events)
        return .object(rootMembers)
    }

    // MARK: reading

    private struct Loaded {
        let writeURL: URL
        let data: Data?
        let text: String
        let root: OrderedJSON
    }

    private func load(_ agent: HookAgent) throws -> Loaded {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: agentDirectory(for: agent).path, isDirectory: &isDir), isDir.boolValue else {
            throw HookInstallerError.agentNotInstalled(agent)
        }
        let url = fileURL(for: agent)
        let writeURL = url.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: writeURL.path) else {
            return Loaded(writeURL: writeURL, data: nil, text: "", root: .object([]))
        }
        let data: Data
        do { data = try Data(contentsOf: writeURL) } catch { throw HookInstallerError.unreadable(error.localizedDescription) }
        guard let text = String(data: data, encoding: .utf8) else { throw HookInstallerError.invalidJSON("not UTF-8") }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Loaded(writeURL: writeURL, data: data, text: text, root: .object([]))
        }
        if text.hasPrefix("\u{FEFF}") { throw HookInstallerError.invalidJSON("starts with a byte-order mark") }
        let root: OrderedJSON
        do { root = try OrderedJSON.parse(text) } catch { throw HookInstallerError.invalidJSON(String(describing: error)) }
        guard root.objectMembers != nil else { throw HookInstallerError.notAnObject }
        if let hooks = root["hooks"], hooks.objectMembers == nil { throw HookInstallerError.hooksNotAnObject }
        return Loaded(writeURL: writeURL, data: data, text: text, root: root)
    }

    /// Indentation used by the existing file (first indented line), else two
    /// spaces like Claude Code's own writes.
    static func detectIndent(_ text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst() {
            let lead = line.prefix(while: { $0 == " " || $0 == "\t" })
            if lead.isEmpty { continue }
            if lead.first == "\t" { return "\t" }
            return String(repeating: " ", count: min(max(lead.count, 1), 8))
        }
        return "  "
    }

    private func render(_ root: OrderedJSON, like original: String) -> String {
        let body = root.rendered(indent: Self.detectIndent(original))
        // Keep the original's trailing-newline convention; new files get one.
        return original.isEmpty || original.hasSuffix("\n") ? body + "\n" : body
    }

    // MARK: status & plans

    func status(_ agent: HookAgent) -> HookStatus {
        let loaded: Loaded
        do { loaded = try load(agent) } catch HookInstallerError.agentNotInstalled {
            return HookStatus(state: .agentMissing)
        } catch {
            return HookStatus(state: .unreadable((error as? LocalizedError)?.errorDescription ?? "\(error)"))
        }
        let commands = Self.pageCommands(in: loaded.root)
        let (groups, mixed) = Self.pageGroups(in: loaded.root)
        let stop = agent == .codex && groups["Stop"] != nil
        guard !commands.isEmpty else { return HookStatus(state: .notInstalled) }
        let state: HookInstallState = !mixed && groupsMatchCanonical(groups, agent: agent, codexStop: stop)
            ? .installed : .needsUpdate
        return HookStatus(state: state, pageCommands: commands, codexStopEnabled: stop)
    }

    private func groupsMatchCanonical(_ groups: [String: [OrderedJSON]], agent: HookAgent, codexStop: Bool) -> Bool {
        var want: [String: [OrderedJSON]] = [:]
        for (event, group) in canonicalEntries(for: agent, codexStop: codexStop) { want[event, default: []].append(group) }
        return want == groups
    }

    /// The change an install would make. Unchanged when Page's entries are
    /// already exactly current (re-running install is a no-op).
    func planInstall(_ agent: HookAgent, codexStop: Bool = false) throws -> HookChangePlan {
        if let reason = Self.unsuitableScriptReason(scriptPath) { throw HookInstallerError.scriptUnavailable(reason) }
        let loaded = try load(agent)
        let (groups, mixed) = Self.pageGroups(in: loaded.root)
        let newText: String
        if !mixed, groupsMatchCanonical(groups, agent: agent, codexStop: codexStop) {
            newText = loaded.text
        } else {
            // Strip our old entries but keep their (now empty) event lists
            // in place, so a migrated entry stays where it was…
            let (stripped, _) = try Self.removingPageHandlers(from: loaded.root, keepEmptiedEvents: true)
            let added = try Self.addingEntries(canonicalEntries(for: agent, codexStop: codexStop), to: stripped)
            // …then drop lists we emptied that got nothing back (e.g. Codex
            // Stop after opting out). Lists that were empty before stay.
            let emptiedByUs = Self.pageGroups(in: loaded.root).groups.keys.filter { event in
                (loaded.root["hooks"]?[event]?.arrayValue ?? []).allSatisfy { g in
                    (g["hooks"]?.arrayValue ?? []).allSatisfy(Self.isPageHandler)
                }
            }
            newText = render(Self.droppingEmptyEvents(Set(emptiedByUs), from: added), like: loaded.text)
        }
        return HookChangePlan(agent: agent, action: .install, fileURL: fileURL(for: agent), writeURL: loaded.writeURL,
                              originalData: loaded.data, originalText: loaded.text, newText: newText)
    }

    /// The change an uninstall would make (removes only Page's handlers).
    func planUninstall(_ agent: HookAgent) throws -> HookChangePlan {
        let loaded = try load(agent)
        let (stripped, removed) = try Self.removingPageHandlers(from: loaded.root)
        let newText = removed ? render(stripped, like: loaded.text) : loaded.text
        return HookChangePlan(agent: agent, action: .uninstall, fileURL: fileURL(for: agent), writeURL: loaded.writeURL,
                              originalData: loaded.data, originalText: loaded.text, newText: newText)
    }

    // MARK: applying

    static let backupDateFormat = "yyyyMMdd-HHmmss"

    /// Writes the plan. Refuses if the file changed since the plan was made
    /// (the agent writes this file too). Backs the original up next to it as
    /// `<name>.page-backup-<timestamp>` and replaces the file atomically,
    /// keeping its permissions. Returns the backup's URL (nil if there was no
    /// original or nothing changed).
    @discardableResult
    func apply(_ plan: HookChangePlan, now: Date = Date()) throws -> URL? {
        guard plan.changed else { return nil }
        let target = plan.writeURL
        let current: Data? = fileManager.fileExists(atPath: target.path) ? (try? Data(contentsOf: target)) : nil
        guard current == plan.originalData else { throw HookInstallerError.changedSincePreview }
        guard let newData = plan.newText.data(using: .utf8) else { throw HookInstallerError.writeFailed("encoding") }

        let dir = target.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw HookInstallerError.agentNotInstalled(plan.agent)
        }

        var permissions: NSNumber = 0o600
        var backupURL: URL?
        if let original = plan.originalData {
            if let p = (try? fileManager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber {
                permissions = p
            }
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = Self.backupDateFormat
            let base = target.lastPathComponent + ".page-backup-" + df.string(from: now)
            var candidate = dir.appendingPathComponent(base)
            var n = 2
            while fileManager.fileExists(atPath: candidate.path) {
                candidate = dir.appendingPathComponent("\(base)-\(n)")
                n += 1
            }
            do {
                try original.write(to: candidate, options: [.withoutOverwriting])
                try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: candidate.path)
            } catch {
                throw HookInstallerError.writeFailed("backup failed: \(error.localizedDescription)")
            }
            backupURL = candidate
        }

        // Atomic replace: write a sibling temp file, then rename(2) over the
        // target, so the agent never reads a half-written settings file.
        let tmp = dir.appendingPathComponent(".\(target.lastPathComponent).page-tmp-\(UUID().uuidString)")
        do {
            try newData.write(to: tmp, options: [.withoutOverwriting])
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: tmp.path)
            guard rename(tmp.path, target.path) == 0 else {
                throw HookInstallerError.writeFailed(String(cString: strerror(errno)))
            }
        } catch {
            try? fileManager.removeItem(at: tmp)
            if let e = error as? HookInstallerError { throw e }
            throw HookInstallerError.writeFailed(error.localizedDescription)
        }
        Logger.shared.log("HookInstaller: \(plan.action.rawValue) \(plan.agent.rawValue) hooks → \(target.path)\(backupURL.map { " (backup \($0.lastPathComponent))" } ?? "")")
        return backupURL
    }

    // MARK: informational

    /// Counts cmux's per-session Claude settings that carry a
    /// PermissionRequest hook (cmux's "Feed"). Both hooks then run for those
    /// sessions; when both decide, deny wins.
    func cmuxHookInfo() -> CmuxHookInfo {
        let dir = homeDirectory.appendingPathComponent(".cmuxterm/claude-settings", isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return CmuxHookInfo() }
        var info = CmuxHookInfo()
        for name in names.sorted().prefix(500) where name.hasSuffix(".json") {
            info.settingsFiles += 1
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), data.count < 2_000_000,
                  let text = String(data: data, encoding: .utf8),
                  let root = try? OrderedJSON.parse(text) else { continue }
            if let list = root["hooks"]?["PermissionRequest"]?.arrayValue, !list.isEmpty {
                info.withPermissionRequestHook += 1
            }
        }
        return info
    }

    /// Reads ~/.codex/config.toml just enough to warn about hooks being
    /// switched off, or about inline [hooks] tables living alongside
    /// hooks.json (Codex merges both and warns at startup).
    func codexConfigInfo() -> CodexConfigInfo {
        guard let text = try? String(contentsOf: codexConfigURL, encoding: .utf8) else { return CodexConfigInfo() }
        return Self.parseCodexConfig(text)
    }

    static func parseCodexConfig(_ text: String) -> CodexConfigInfo {
        var info = CodexConfigInfo()
        var section = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]).trimmingCharacters(in: .whitespaces) }
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                if section == "hooks" || section.hasPrefix("hooks.") { info.hasInlineHooks = true }
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let (key, value) = (parts[0], parts[1])
            if section == "features", key == "hooks" || key == "codex_hooks", value == "false" {
                info.hooksFeatureDisabled = true
            }
            if section.isEmpty, key == "features.hooks" || key == "features.codex_hooks", value == "false" {
                info.hooksFeatureDisabled = true
            }
            if section.isEmpty, key == "hooks" { info.hasInlineHooks = true }
        }
        return info
    }

    // MARK: diff

    /// Unified diff (3 lines of context) between two texts, for the preview.
    static func unifiedDiff(old: String, new: String, oldLabel: String, newLabel: String, context: Int = 3) -> String {
        if old == new { return "" }
        func lines(_ s: String) -> [String] {
            var l = s.components(separatedBy: "\n")
            if l.last == "" { l.removeLast() }   // the final newline isn't a line
            return l
        }
        let a = lines(old), b = lines(new)
        let ops = diffOps(a, b)

        var out = "--- \(oldLabel)\n+++ \(newLabel)\n"
        // Group changes into hunks with `context` lines around each.
        var i = 0
        while i < ops.count {
            guard let firstChange = ops[i...].firstIndex(where: { $0.kind != .same }) else { break }
            let start = max(firstChange - context, i)
            var end = firstChange
            var lastChange = firstChange
            while end < ops.count {
                if ops[end].kind != .same { lastChange = end }
                if end - lastChange > 2 * context { break }
                end += 1
            }
            let hunkEnd = min(lastChange + context + 1, ops.count)
            let slice = ops[start..<hunkEnd]
            let oldStart = (slice.first?.oldIndex ?? 0) + 1
            let newStart = (slice.first?.newIndex ?? 0) + 1
            let oldCount = slice.filter { $0.kind != .insert }.count
            let newCount = slice.filter { $0.kind != .delete }.count
            out += "@@ -\(oldCount == 0 ? oldStart - 1 : oldStart),\(oldCount) +\(newCount == 0 ? newStart - 1 : newStart),\(newCount) @@\n"
            for op in slice {
                switch op.kind {
                case .same: out += " " + op.text + "\n"
                case .delete: out += "-" + op.text + "\n"
                case .insert: out += "+" + op.text + "\n"
                }
            }
            i = hunkEnd
        }
        return out
    }

    struct DiffOp: Equatable {
        enum Kind { case same, delete, insert }
        let kind: Kind
        let text: String
        /// Position in the old / new file at this op (for hunk headers).
        let oldIndex: Int
        let newIndex: Int
    }

    /// LCS line diff. Settings files are small; past ~4M cells it degrades to
    /// "delete everything, insert everything" rather than allocating.
    static func diffOps(_ a: [String], _ b: [String]) -> [DiffOp] {
        let n = a.count, m = b.count
        if n * m > 4_000_000 {
            return a.enumerated().map { DiffOp(kind: .delete, text: $1, oldIndex: $0, newIndex: 0) }
                + b.enumerated().map { DiffOp(kind: .insert, text: $1, oldIndex: n, newIndex: $0) }
        }
        var lcs = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var ops: [DiffOp] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                ops.append(DiffOp(kind: .same, text: a[i], oldIndex: i, newIndex: j)); i += 1; j += 1
            } else if i < n, j == m || lcs[i + 1][j] >= lcs[i][j + 1] {
                // Deletions first on a tie, so a changed line reads "-old +new".
                ops.append(DiffOp(kind: .delete, text: a[i], oldIndex: i, newIndex: j)); i += 1
            } else {
                ops.append(DiffOp(kind: .insert, text: b[j], oldIndex: i, newIndex: j)); j += 1
            }
        }
        return ops
    }
}
