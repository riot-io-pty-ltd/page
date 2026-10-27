import Foundation

/// Defence in depth for typing into the wrong session. The phone's `input` and
/// `interrupt` commands name a session id, and may also carry the folder and
/// title its room showed (`expectCwd`, `expectTitle`, verbatim from this Mac's
/// own list). If the session behind that id no longer matches, the command is
/// refused instead of typed. Both fields are optional: a command without them
/// (an older phone) is not checked, exactly as before.
///
/// The folder decides when the phone sent one. The title only decides when it
/// did not, because a title can legitimately change while a room is open and a
/// strict title match would refuse good sends. A refusal heals itself: the
/// next list the phone receives carries what the Mac has now.
enum SessionTargetCheck {
    /// The phone stores at most this much of a cwd (and title); compare no more.
    static let cwdLimit = 300
    static let titleLimit = 120

    /// nil when the command may go ahead.
    static func verify(_ cmd: SessionCommand, against s: AgentSession, home: String = NSHomeDirectory()) -> SessionCommandResult? {
        verify(expectCwd: cmd.expectCwd, expectTitle: cmd.expectTitle, cwd: s.cwd,
               title: s.title ?? SessionRemote.folderTitle(s.cwd, home: home) ?? s.backend.rawValue, home: home)
    }

    static func verify(expectCwd: String?, expectTitle: String?, cwd: String?, title: String, home: String = NSHomeDirectory()) -> SessionCommandResult? {
        if let want = expectCwd.map(normalizedCwd), !want.isEmpty {
            let have = cwd.map { normalizedCwd(SessionRemote.homeAbbreviated($0, home: home)) } ?? ""
            if want == have { return nil }
            return mismatch(shown: want, actual: have.isEmpty ? nil : have)
        }
        if let want = expectTitle.map(normalizedTitle), !want.isEmpty {
            if want == normalizedTitle(title) { return nil }
            return mismatch(shown: want, actual: normalizedTitle(title))
        }
        return nil
    }

    static func normalizedCwd(_ s: String) -> String {
        var t = String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(cwdLimit))
        while t.count > 1, t.hasSuffix("/") { t.removeLast() }
        return t
    }

    static func normalizedTitle(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(titleLimit)).lowercased()
    }

    /// Names the two folders (last components only), so the phone can say what changed.
    private static func mismatch(shown: String, actual: String?) -> SessionCommandResult {
        func leaf(_ p: String) -> String { p == "/" || p == "~" ? p : (p as NSString).lastPathComponent }
        let detail: String
        if let actual {
            detail = "Nothing was typed. The room showed \(leaf(shown)), but that session is now in \(leaf(actual)). Close the room and open it again."
        } else {
            detail = "Nothing was typed. The room showed \(leaf(shown)), which doesn't match this session any more. Close the room and open it again."
        }
        return .refused(.targetMismatch, detail)
    }
}
