import XCTest
@testable import ClaudePowerMode

/// The one-click "Let Page type into cmux" edit of cmux.json: smallest
/// possible change, comments kept, never over the user's own automation
/// settings, backed up and restorable. Temp files only.
final class CmuxConfigFileTests: XCTestCase {
    private let template = """
    {
      "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json",
      "schemaVersion": 1,

      // This file uses JSON with comments (JSONC).
      // "automation" : {
      //   "socketControlMode" : "cmuxOnly",
      // },
      /* a block { comment } */
      "app": { "url": "https://example.com/a//b", },
    }
    """

    private func parsed(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(CmuxConfigFile.stripped(text).utf8)) as? [String: Any]
    }

    func testInsertsAutomationKeepingEverythingElse() throws {
        guard case .write(let out) = CmuxConfigFile.plan(text: template) else { return XCTFail() }
        let obj = try XCTUnwrap(parsed(out))
        let automation = try XCTUnwrap(obj["automation"] as? [String: Any])
        XCTAssertEqual(automation["socketControlMode"] as? String, "automation")
        XCTAssertNil(automation["socketPassword"], "no password in Automation mode")
        XCTAssertEqual((obj["app"] as? [String: Any])?["url"] as? String, "https://example.com/a//b", "// inside a string isn't a comment")
        XCTAssertEqual(obj["schemaVersion"] as? Int, 1)
        // Every original byte is still there, in order.
        XCTAssertEqual(out.replacingOccurrences(of: "\n  \"automation\": {\n    \"socketControlMode\": \"automation\"\n  },", with: ""), template)
    }

    func testLeavesTheUsersOwnAutomationAlone() {
        let own = "{\n  // mine\n  \"automation\": { \"socketControlMode\": \"password\" }\n}"
        XCTAssertEqual(CmuxConfigFile.plan(text: own), .alreadyHasAutomation)
    }

    func testEmptyMissingAndBrokenFiles() throws {
        guard case .write(let fresh) = CmuxConfigFile.plan(text: nil) else { return XCTFail() }
        XCTAssertEqual((parsed(fresh)?["automation"] as? [String: Any])?["socketControlMode"] as? String, "automation")
        guard case .write(let empty) = CmuxConfigFile.plan(text: "// only a comment\n{ }\n") else { return XCTFail() }
        XCTAssertNotNil(parsed(empty)?["automation"], "an empty root object gets no trailing comma")
        XCTAssertEqual(CmuxConfigFile.plan(text: "[1, 2]"), .unreadable)
        XCTAssertEqual(CmuxConfigFile.plan(text: "{ \"a\": "), .unreadable)
        XCTAssertEqual(CmuxConfigFile.plan(text: "/* unterminated"), .unreadable)
    }

    func testWriteBackupAndRestore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmuxcfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cmux.json")
        try template.write(to: url, atomically: true, encoding: .utf8)

        let backup = try XCTUnwrap(try CmuxConfigFile.enableAutomationMode(url: url).get())
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), template)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertNotNil(parsed(try String(contentsOf: url, encoding: .utf8))?["automation"])
        XCTAssertEqual(CmuxConfigFile.enableAutomationMode(url: url), .failure(.alreadyHasAutomation),
                       "a second click never stacks a second block")

        XCTAssertTrue(CmuxConfigFile.restore(backup: backup, url: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), template)

        // No file before: created, and restore removes it.
        let fresh = dir.appendingPathComponent("sub/cmux.json")
        XCTAssertNil(try CmuxConfigFile.enableAutomationMode(url: fresh).get())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(CmuxConfigFile.restore(backup: nil, url: fresh))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testSymlinkedConfigIsLeftAlone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmuxcfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("dotfiles-cmux.json")
        try "{}".write(to: real, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("cmux.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(CmuxConfigFile.enableAutomationMode(url: link), .failure(.unreadable))
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "{}")
    }

    /// A cmux session Page can't reach is listed as such, with the fix.
    func testBlockedCmuxIsNotTypable() {
        let target = CmuxBridge.Target(surfaceId: "S", workspaceId: nil, cliPath: "/x/cmux", source: "environment")
        let open = LiveSessionBackends.claudeHostInfo(.cmux(target), provider: .anthropic)
        XCTAssertTrue(open.canType)
        let blocked = LiveSessionBackends.claudeHostInfo(.cmux(target), provider: .anthropic,
                                                         cmuxBlocker: { _ in LiveSessionBackends.cmuxBlockerText(CmuxBridge.blockedDetail) })
        XCTAssertFalse(blocked.canType)
        XCTAssertFalse(blocked.canInterrupt)
        XCTAssertEqual(blocked.host, "cmux")
        XCTAssertTrue(blocked.typeBlocker?.contains("Let Page type into cmux") ?? false)
    }
}
