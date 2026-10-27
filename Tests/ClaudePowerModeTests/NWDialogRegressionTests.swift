import XCTest
@testable import ClaudePowerMode

/// The regression guard for the frozen dialog. Dialogs used to block in a
/// nested modal loop (`runModal`) started from inside a SwiftUI button action,
/// and their own buttons went dead. Nothing under Sources/ClaudePowerMode may
/// call `runModal` again, and `NWDialog.run` is gone for good.
///
/// The scan reads the source files from the package directory (found through
/// #filePath, so it works from any checkout) and ignores comments, which
/// explain the rule in NWDialog.swift and must not trip it. No window server.
final class NWDialogRegressionTests: XCTestCase {
    /// `Tests/ClaudePowerModeTests/<this file>` up three levels: the package root.
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static var sourceRoot: URL {
        packageRoot.appendingPathComponent("Sources/ClaudePowerMode", isDirectory: true)
    }

    /// Pure. The text with comments and the contents of string literals
    /// removed, line breaks kept, so that a match is code and never prose. A
    /// `//` or `/*` inside a string does not start a comment.
    static func codeOnly(_ text: String) -> String {
        var out = ""
        var inString = false
        var inBlock = false
        var inLine = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if inLine {
                if c == "\n" { inLine = false; out.append(c) }
            } else if inBlock {
                if c == "*", next == "/" { inBlock = false; i += 2; continue }
                if c == "\n" { out.append(c) }
            } else if inString {
                if c == "\\" { i += 2; continue }
                if c == "\"" { inString = false }
                if c == "\n" { out.append(c) }
            } else if c == "/", next == "/" {
                inLine = true
                i += 2
                continue
            } else if c == "/", next == "*" {
                inBlock = true
                i += 2
                continue
            } else {
                if c == "\"" { inString = true }
                out.append(c)
            }
            i += 1
        }
        return out
    }

    /// Pure. The 1-based line numbers whose code (not comments) mentions `runModal`
    /// (which also covers `runModalSession` and `NSApp.runModal(for:)`).
    static func runModalLines(in text: String) -> [Int] {
        codeOnly(text).components(separatedBy: "\n").enumerated().compactMap { index, line in
            line.contains("runModal") ? index + 1 : nil
        }
    }

    private func swiftFiles(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    // MARK: the guard

    func testNoSourceFileUnderSourcesCallsRunModal() throws {
        let files = swiftFiles(under: Self.sourceRoot)
        XCTAssertGreaterThan(files.count, 50, "the scan found the package's sources under \(Self.sourceRoot.path)")
        XCTAssertTrue(files.contains { $0.lastPathComponent == "NWDialog.swift" }, "the scan includes the dialog itself")

        var hits: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in Self.runModalLines(in: text) {
                hits.append("\(file.path):\(line)")
            }
        }
        XCTAssertEqual(hits, [], "runModal blocks in a nested run loop and freezes dialogs clicked from SwiftUI actions; use NWDialog.present")
    }

    func testTheRemovedBlockingEntryPointDoesNotComeBack() throws {
        for file in swiftFiles(under: Self.sourceRoot) {
            let code = Self.codeOnly(try String(contentsOf: file, encoding: .utf8))
            XCTAssertFalse(code.contains("NWDialog.run("), "\(file.lastPathComponent) calls the removed blocking NWDialog.run")
        }
    }

    // MARK: the scanner itself (a guard that cannot see is no guard)

    func testTheScannerFlagsARealRunModalCall() {
        XCTAssertEqual(Self.runModalLines(in: "let answer = NSApp.runModal(for: window)\n"), [1])
        XCTAssertEqual(Self.runModalLines(in: "a\n    let r = alert.runModal()\n"), [2])
        XCTAssertEqual(Self.runModalLines(in: "_ = NSApp.runModalSession(s)"), [1])
    }

    func testTheScannerIgnoresCommentsAndStrings() {
        XCTAssertEqual(Self.runModalLines(in: "// there is no `runModal` here\n"), [])
        XCTAssertEqual(Self.runModalLines(in: "/// a `runModal` note\nlet x = 1\n"), [])
        XCTAssertEqual(Self.runModalLines(in: "/* runModal\n   runModal */ let y = 2\n"), [])
        XCTAssertEqual(Self.runModalLines(in: "let s = \"runModal\"\n"), [])
        XCTAssertEqual(Self.runModalLines(in: "let u = \"https://x.example\"; NSApp.runModal(for: w)\n"), [1],
                       "a // inside a string does not hide the call after it")
    }

    func testTheRealDialogFileIsCleanEvenThoughItsCommentsMentionTheRule() throws {
        let file = Self.sourceRoot.appendingPathComponent("UI/NWDialog.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("runModal"), "the comment that explains the rule is still there")
        XCTAssertEqual(Self.runModalLines(in: text), [])
    }
}
