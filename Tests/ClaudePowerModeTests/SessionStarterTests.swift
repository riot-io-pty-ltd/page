import XCTest
@testable import ClaudePowerMode

final class SessionStarterTests: XCTestCase {
    func testShellQuote() {
        XCTAssertEqual(SessionStarter.shellQuote("plain"), "'plain'")
        XCTAssertEqual(SessionStarter.shellQuote("it's $HOME `x` \"y\""), "'it'\\''s $HOME `x` \"y\"'")
    }

    func testCommand() {
        XCTAssertEqual(SessionStarter.command(prompt: ""), "claude")
        XCTAssertEqual(SessionStarter.command(prompt: "--dangerously-skip-permissions"),
                       "claude -- '--dangerously-skip-permissions'", "a prompt can never become a flag")
        XCTAssertEqual(SessionStarter.command(prompt: "a; rm -rf ~"), "claude -- 'a; rm -rf ~'")
    }

    func testCleanPromptFoldsLinesAndStripsControls() {
        XCTAssertEqual(try SessionStarter.cleanPrompt("one\ntwo\r\nthree").get(), "one two three")
        XCTAssertEqual(try SessionStarter.cleanPrompt("a\u{1B}b\u{07}c").get(), "abc")
        XCTAssertEqual(try SessionStarter.cleanPrompt(nil).get(), "")
        XCTAssertThrowsError(try SessionStarter.cleanPrompt(String(repeating: "x", count: 4001)).get())
    }

    func testAllowedIsExactAfterStandardising() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("starter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let folders = [SessionStarter.Folder(path: dir.path, name: "p", lastUsedAt: nil)]
        XCTAssertNoThrow(try SessionStarter.allowed(dir.path + "/", in: folders).get())
        XCTAssertNoThrow(try SessionStarter.allowed(dir.path + "/sub/..", in: folders).get())
        XCTAssertThrowsError(try SessionStarter.allowed(dir.path + "/sub", in: folders).get())
        XCTAssertThrowsError(try SessionStarter.allowed(nil, in: folders).get())
        let gone = [SessionStarter.Folder(path: dir.path + "-gone", name: "g", lastUsedAt: nil)]
        XCTAssertThrowsError(try SessionStarter.allowed(dir.path + "-gone", in: gone).get())
    }

    func testMerge() {
        let now = Date(timeIntervalSince1970: 100 * 24 * 3600)
        let folders = SessionStarter.merge(
            live: ["/p/live"],
            recent: [("/p/a", now.addingTimeInterval(-3600)), ("/p/a", now.addingTimeInterval(-60)),
                     ("/p/old", now.addingTimeInterval(-40 * 24 * 3600)), ("/", now), (NSHomeDirectory(), now),
                     ("/p/live", now.addingTimeInterval(-10))],
            now: now)
        XCTAssertEqual(folders.map(\.path), ["/p/live", "/p/a"])
        XCTAssertEqual(folders.last?.lastUsedAt, now.addingTimeInterval(-60))
    }

    func testFirstCwd() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("cwd-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: f) }
        try "{\"type\":\"summary\"}\n{\"type\":\"user\",\"cwd\":\"/Users/x/proj\"}\n".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionStarter.firstCwd(f.path), "/Users/x/proj")
    }
}
