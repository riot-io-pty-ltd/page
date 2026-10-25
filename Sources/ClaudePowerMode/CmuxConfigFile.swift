import Foundation

/// Switches cmux's socket to Password mode by editing
/// `~/.config/cmux/cmux.json`, for the one-click "Let Page type into cmux"
/// button in Set up cmux….
///
/// cmux.json is JSONC (comments, trailing commas) and the user's own file,
/// so the edit is as small as possible: one `"automation"` member inserted
/// right after the root `{`, every existing byte kept. If the file already
/// sets `automation` (uncommented), Page doesn't touch it and the user
/// follows the manual steps instead. A timestamped backup is written
/// first, and the file is written 0600 (it now holds a secret).
///
/// cmux watches the file and applies a mode change within about a second,
/// without `cmux reload-config` (which Page couldn't call anyway: in the
/// default mode cmux refuses Page). Processes started inside cmux, such as
/// cmux's own Claude Code hooks, keep connecting in Password mode; only
/// apps launched outside cmux need the password.
enum CmuxConfigFile {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/cmux/cmux.json")
    }

    enum Plan: Equatable {
        /// The new file text.
        case write(String)
        /// The file sets `automation` itself: leave it to the user.
        case alreadyHasAutomation
        /// Not a JSON(C) object Page can safely edit.
        case unreadable
    }

    /// Pure. `text` nil means the file doesn't exist yet.
    static func plan(text: String?, password: String) -> Plan {
        let member = """
          "automation": {
            "socketControlMode": "password",
            "socketPassword": \(jsonString(password))
          }
        """
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .write("{\n\(member)\n}\n")
        }
        guard let data = stripped(text).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let brace = rootBraceIndex(text) else { return .unreadable }
        if root["automation"] != nil { return .alreadyHasAutomation }
        let after = text.index(after: brace)
        let insertion = "\n" + member + (root.isEmpty ? "\n" : ",")
        return .write(String(text[..<after]) + insertion + String(text[after...]))
    }

    /// Backs up, plans and writes. Returns the backup's URL (nil when there
    /// was no file before), or a short reason.
    static func enablePasswordMode(password: String, url: URL = defaultURL,
                                   now: Date = Date()) -> Result<URL?, CmuxConfigError> {
        let fm = FileManager.default
        // A symlinked cmux.json (a dotfiles repo) would be replaced by a
        // plain file: leave those to the user.
        if let type = try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType, type == .typeSymbolicLink {
            return .failure(.unreadable)
        }
        let existing: String?
        if fm.fileExists(atPath: url.path) {
            guard let data = BoundedFileRead.read(url.path, maxBytes: 1 << 20),
                  let s = String(data: data, encoding: .utf8) else { return .failure(.unreadable) }
            existing = s
        } else {
            existing = nil
        }
        let newText: String
        switch plan(text: existing, password: password) {
        case .write(let t): newText = t
        case .alreadyHasAutomation: return .failure(.alreadyHasAutomation)
        case .unreadable: return .failure(.unreadable)
        }
        var backup: URL?
        if let existing {
            let stamp = backupStamp(now)
            let b = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).bak-page-\(stamp)")
            guard writeAtomically(existing, to: b) else { return .failure(.writeFailed) }
            backup = b
        } else {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        guard writeAtomically(newText, to: url) else { return .failure(.writeFailed) }
        return .success(backup)
    }

    /// Puts the backup back (or removes a file Page created).
    @discardableResult
    static func restore(backup: URL?, url: URL = defaultURL) -> Bool {
        guard let backup else { return (try? FileManager.default.removeItem(at: url)) != nil }
        guard let data = try? Data(contentsOf: backup), let s = String(data: data, encoding: .utf8) else { return false }
        return writeAtomically(s, to: url)
    }

    // MARK: JSONC

    /// Comments removed (strings respected) and trailing commas dropped,
    /// so JSONSerialization can check the structure. Only for reading:
    /// the file itself is edited as text.
    static func stripped(_ text: String) -> String {
        var out = ""
        var it = Array(text.unicodeScalars)[...]
        var inString = false
        while let c = it.first {
            it = it.dropFirst()
            if inString {
                out.unicodeScalars.append(c)
                if c == "\\", let next = it.first { out.unicodeScalars.append(next); it = it.dropFirst() }
                else if c == "\"" { inString = false }
                continue
            }
            if c == "\"" { inString = true; out.unicodeScalars.append(c); continue }
            if c == "/", it.first == "/" {
                while let n = it.first, n != "\n" { it = it.dropFirst() }
                continue
            }
            if c == "/", it.first == "*" {
                it = it.dropFirst()
                while let n = it.first {
                    it = it.dropFirst()
                    if n == "*", it.first == "/" { it = it.dropFirst(); break }
                }
                out.unicodeScalars.append(" ")
                continue
            }
            out.unicodeScalars.append(c)
        }
        // Trailing commas: `, }` / `, ]` (outside strings, which a comma
        // followed only by whitespace and a closer can't be part of here).
        return out.replacingOccurrences(of: #",(\s*[}\]])"#, with: "$1", options: .regularExpression)
    }

    /// The root object's `{`: the first character that isn't whitespace or
    /// inside a comment.
    static func rootBraceIndex(_ text: String) -> String.Index? {
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c.isWhitespace { i = text.index(after: i); continue }
            let rest = text[i...]
            if rest.hasPrefix("//") {
                guard let nl = rest.firstIndex(of: "\n") else { return nil }
                i = text.index(after: nl)
                continue
            }
            if rest.hasPrefix("/*") {
                guard let end = rest.range(of: "*/") else { return nil }
                i = end.upperBound
                continue
            }
            return c == "{" ? i : nil
        }
        return nil
    }

    // MARK: helpers

    private static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    private static func backupStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// Temp file (0600) + rename: never a half-written cmux.json.
    private static func writeAtomically(_ text: String, to url: URL) -> Bool {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).page-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tmp.path, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o600]) else { return false }
        guard rename(tmp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        return true
    }
}

enum CmuxConfigError: Error, Equatable {
    case alreadyHasAutomation, unreadable, writeFailed

    var message: String {
        switch self {
        case .alreadyHasAutomation:
            return "Your cmux.json already sets automation options, so Page left it alone. Use the steps below instead."
        case .unreadable:
            return "Page couldn't read ~/.config/cmux/cmux.json safely, so it left it alone. Use the steps below instead."
        case .writeFailed:
            return "Page couldn't write ~/.config/cmux/cmux.json. Nothing was changed."
        }
    }
}
