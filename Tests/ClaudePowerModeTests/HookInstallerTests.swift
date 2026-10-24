import XCTest
@testable import ClaudePowerMode

final class OrderedJSONTests: XCTestCase {
    func testRoundTripPreservesOrderEscapesAndNumbers() throws {
        let text = """
        {
          "$schema": "https://json.schemastore.org/claude-code-settings.json",
          "zeta": 1.50,
          "alpha": [],
          "obj": {},
          "esc": "caf\\u00e9 \\"q\\" \\/ \\n",
          "big": 1e10,
          "neg": -0.5,
          "list": [
            true,
            false,
            null
          ]
        }
        """
        let v = try OrderedJSON.parse(text)
        XCTAssertEqual(v.objectMembers?.map(\.key), ["$schema", "zeta", "alpha", "obj", "esc", "big", "neg", "list"])
        XCTAssertEqual(v["esc"]?.stringValue, "café \"q\" / \n")
        XCTAssertEqual(v.rendered(), text)
    }

    func testCreatedStringsUseStringifyEscaping() {
        XCTAssertEqual(OrderedJSON.quote("a/b \"c\" \\ \n\t\u{01} é"), "\"a/b \\\"c\\\" \\\\ \\n\\t\\u0001 é\"")
        let v = OrderedJSON.object([.init("cmd", .str("'/x y/page-notify.sh' --codex"))])
        XCTAssertEqual(v.rendered(), "{\n  \"cmd\": \"'/x y/page-notify.sh' --codex\"\n}")
    }

    func testRejectsInvalidJSON() {
        for bad in ["", "{", "{\"a\":}", "{\"a\":1,}", "[1 2]", "{} x", "{\"a\":\"\\ud800\"}", "{'a':1}", "{\"a\":01}", "{\"a\":\"\u{01}\"}", "nul"] {
            XCTAssertThrowsError(try OrderedJSON.parse(bad), bad)
        }
    }

    func testUnicodeAndSurrogatePairs() throws {
        let v = try OrderedJSON.parse("{\"e\":\"\\ud83d\\ude00 🙂\"}")
        XCTAssertEqual(v["e"]?.stringValue, "😀 🙂")
    }

    func testSemanticEqualityIgnoresRawForms() throws {
        XCTAssertEqual(try OrderedJSON.parse("{\"a\":\"\\u0041\",\"n\":1.0}"), try OrderedJSON.parse("{\"a\":\"A\",\"n\":1}"))
        XCTAssertNotEqual(try OrderedJSON.parse("{\"a\":1,\"b\":2}"), try OrderedJSON.parse("{\"b\":2,\"a\":1}"))
    }
}

final class HookInstallerTests: XCTestCase {
    var home: URL!
    let script = "/Applications/Page.app/Contents/Resources/hooks/page-notify.sh"
    var installer: HookInstaller { HookInstaller(homeDirectory: home, scriptPath: script) }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("hookinst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    private var settings: URL { home.appendingPathComponent(".claude/settings.json") }
    private func write(_ text: String, to url: URL? = nil) throws { try Data(text.utf8).write(to: url ?? settings) }
    private func read(_ url: URL? = nil) throws -> String { try String(contentsOf: url ?? settings, encoding: .utf8) }
    private func backups(in dir: URL? = nil) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: (dir ?? home.appendingPathComponent(".claude")).path)
            .filter { $0.contains(".page-backup-") }
    }

    /// A realistic user file: other settings, the legacy manual Notification
    /// install, and someone else's hooks (including a group we must not split).
    let userFile = """
    {
      "$schema": "https://json.schemastore.org/claude-code-settings.json",
      "permissions": {
        "allow": [
          "Bash(git status)"
        ]
      },
      "hooks": {
        "Notification": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "/Users/me/.claude/hooks/page-notify.sh",
                "timeout": 30
              }
            ]
          }
        ],
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              {
                "type": "command",
                "command": "/usr/local/bin/other-guard"
              }
            ]
          }
        ]
      },
      "statusLine": {
        "type": "command",
        "command": "~/bin/status"
      }
    }

    """

    func testInstallMergesMigratesAndPreservesEverythingElse() throws {
        try write(userFile)
        XCTAssertEqual(installer.status(.claude).state, .needsUpdate)
        let plan = try installer.planInstall(.claude)
        XCTAssertTrue(plan.changed)
        let backup = try XCTUnwrap(try installer.apply(plan, now: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), userFile)

        let out = try OrderedJSON.parse(try read())
        // Top-level order and untouched values survive.
        XCTAssertEqual(out.objectMembers?.map(\.key), ["$schema", "permissions", "hooks", "statusLine"])
        XCTAssertEqual(out["permissions"], try OrderedJSON.parse(userFile)["permissions"])
        XCTAssertEqual(out["statusLine"]?["command"]?.stringValue, "~/bin/status")
        // Events: existing order kept, new one appended.
        XCTAssertEqual(out["hooks"]?.objectMembers?.map(\.key), ["Notification", "PreToolUse", "PermissionRequest"])
        // The other tool's PreToolUse group is untouched and stays first.
        let pre = try XCTUnwrap(out["hooks"]?["PreToolUse"]?.arrayValue)
        XCTAssertEqual(pre.count, 2)
        XCTAssertEqual(pre[0]["hooks"]?.arrayValue?.first?["command"]?.stringValue, "/usr/local/bin/other-guard")
        XCTAssertEqual(pre[1]["matcher"]?.stringValue, "AskUserQuestion|ExitPlanMode")
        // Legacy path migrated: exactly one Notification entry, pointing at the bundle.
        let notif = try XCTUnwrap(out["hooks"]?["Notification"]?.arrayValue)
        XCTAssertEqual(notif.count, 1)
        XCTAssertEqual(notif[0]["hooks"]?.arrayValue?.first?["command"]?.stringValue, "'\(script)'")
        let pr = try XCTUnwrap(out["hooks"]?["PermissionRequest"]?.arrayValue?.first?["hooks"]?.arrayValue?.first)
        XCTAssertEqual(pr["timeout"], .number(String(HookInstaller.blockingTimeout)))
        XCTAssertGreaterThan(HookInstaller.blockingTimeout, HookInstaller.hookWaitSeconds)
        XCTAssertNil(pr["onFailure"], "a failing hook must never deny")
        XCTAssertEqual(installer.status(.claude).state, .installed)
        XCTAssertTrue(try read().hasSuffix("}\n"))
    }

    /// The script caps its wait by the agent's timeout, which only the
    /// installer knows: blocking handlers pass it, the Notification one
    /// doesn't block. Entries from before (no argument) are still Page's:
    /// shown as needing an update, and removed by uninstall.
    func testBlockingHandlersPassTheAgentTimeout() throws {
        try write("{}\n")
        try installer.apply(try installer.planInstall(.claude))
        let out = try OrderedJSON.parse(try read())
        for event in ["PermissionRequest", "PreToolUse"] {
            let h = try XCTUnwrap(out["hooks"]?[event]?.arrayValue?.first?["hooks"]?.arrayValue?.first)
            XCTAssertEqual(h["command"]?.stringValue, "'\(script)' --agent-timeout \(HookInstaller.blockingTimeout)", event)
            XCTAssertEqual(h["timeout"], .number(String(HookInstaller.blockingTimeout)), event)
        }
        let n = try XCTUnwrap(out["hooks"]?["Notification"]?.arrayValue?.first?["hooks"]?.arrayValue?.first)
        XCTAssertEqual(n["command"]?.stringValue, "'\(script)'")

        let old = try read().replacingOccurrences(of: " --agent-timeout \(HookInstaller.blockingTimeout)", with: "")
        try write(old)
        XCTAssertEqual(installer.status(.claude).state, .needsUpdate)
        XCTAssertEqual(installer.status(.claude).pageCommands.count, 3)
        try installer.apply(try installer.planUninstall(.claude))
        XCTAssertEqual(installer.status(.claude).state, .notInstalled)
    }

    func testInstallIsIdempotent() throws {
        try write(userFile)
        try installer.apply(try installer.planInstall(.claude))
        let once = try read()
        let again = try installer.planInstall(.claude)
        XCTAssertFalse(again.changed)
        XCTAssertNil(try installer.apply(again))
        XCTAssertEqual(try read(), once)
        XCTAssertEqual(try backups().count, 1, "no backup when nothing changes")
    }

    func testIdempotentEvenWhenOthersAddedHooksAfterOurs() throws {
        try write("{}\n")
        try installer.apply(try installer.planInstall(.claude))
        // Another tool appends its own PermissionRequest group after ours.
        var text = try read()
        text = text.replacingOccurrences(of: "\"PermissionRequest\": [\n", with: "\"PermissionRequest\": [\n      {\"hooks\": [{\"type\": \"command\", \"command\": \"other\"}]},\n")
        try write(text)
        XCTAssertEqual(installer.status(.claude).state, .installed)
        XCTAssertFalse(try installer.planInstall(.claude).changed)
    }

    func testUninstallRemovesExactlyOurs() throws {
        try write(userFile)
        try installer.apply(try installer.planInstall(.claude))
        try installer.apply(try installer.planUninstall(.claude))
        let out = try OrderedJSON.parse(try read())
        XCTAssertEqual(out["hooks"]?.objectMembers?.map(\.key), ["PreToolUse"])
        XCTAssertEqual(out["hooks"]?["PreToolUse"]?.arrayValue?.count, 1)
        XCTAssertEqual(out["hooks"]?["PreToolUse"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["command"]?.stringValue,
                       "/usr/local/bin/other-guard")
        XCTAssertEqual(installer.status(.claude).state, .notInstalled)
        XCTAssertFalse(try installer.planUninstall(.claude).changed)
    }

    func testUninstallFromFreshFileLeavesNoEmptyHooks() throws {
        try write("{\n  \"model\": \"opus\"\n}\n")
        try installer.apply(try installer.planInstall(.claude))
        try installer.apply(try installer.planUninstall(.claude))
        XCTAssertEqual(try read(), "{\n  \"model\": \"opus\"\n}\n")
    }

    func testSharedGroupLosesOnlyOurHandler() throws {
        try write("""
        {"hooks":{"Notification":[{"hooks":[{"type":"command","command":"say hi"},{"type":"command","command":"~/.claude/hooks/page-notify.sh"}]}]}}
        """)
        XCTAssertEqual(installer.status(.claude).state, .needsUpdate)
        try installer.apply(try installer.planUninstall(.claude))
        let out = try OrderedJSON.parse(try read())
        let handlers = try XCTUnwrap(out["hooks"]?["Notification"]?.arrayValue?.first?["hooks"]?.arrayValue)
        XCTAssertEqual(handlers.map { $0["command"]?.stringValue }, ["say hi"])
    }

    func testCreatesMissingFileWithoutBackup() throws {
        let plan = try installer.planInstall(.claude)
        XCTAssertNil(plan.originalData)
        XCTAssertNil(try installer.apply(plan))
        let out = try OrderedJSON.parse(try read())
        XCTAssertEqual(out["hooks"]?.objectMembers?.map(\.key), ["PermissionRequest", "PreToolUse", "Notification"])
        let perms = try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
    }

    func testKeepsPermissionsAndWritesThroughSymlink() throws {
        let real = home.appendingPathComponent("dotfiles-settings.json")
        try write("{}\n", to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: real)
        try installer.apply(try installer.planInstall(.claude))
        let attrs = try FileManager.default.attributesOfItem(atPath: settings.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink, "the user's symlink must survive")
        XCTAssertTrue(try read(real).contains("PermissionRequest"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber)?.intValue, 0o644)
        XCTAssertEqual(try backups(in: home).count, 1)
    }

    func testRefusesWhenFileChangedSincePreview() throws {
        try write(userFile)
        let plan = try installer.planInstall(.claude)
        try write(userFile + " ")
        XCTAssertThrowsError(try installer.apply(plan)) { XCTAssertEqual($0 as? HookInstallerError, .changedSincePreview) }
        XCTAssertEqual(try read(), userFile + " ")
        XCTAssertEqual(try backups().count, 0)
    }

    func testRefusesInvalidOrUnexpectedFiles() throws {
        try write("{ \"hooks\": { // comment\n } }")
        XCTAssertThrowsError(try installer.planInstall(.claude))
        if case .unreadable = installer.status(.claude).state {} else { XCTFail("expected unreadable") }
        try write("[]")
        XCTAssertThrowsError(try installer.planInstall(.claude)) { XCTAssertEqual($0 as? HookInstallerError, .notAnObject) }
        try write("{\"hooks\": []}")
        XCTAssertThrowsError(try installer.planInstall(.claude)) { XCTAssertEqual($0 as? HookInstallerError, .hooksNotAnObject) }
        try write("{\"hooks\": {\"PreToolUse\": {}}}")
        XCTAssertThrowsError(try installer.planInstall(.claude)) { XCTAssertEqual($0 as? HookInstallerError, .eventNotAList("PreToolUse")) }
        // None of that was written over.
        XCTAssertEqual(try read(), "{\"hooks\": {\"PreToolUse\": {}}}")
    }

    func testRefusesTranslocatedScriptPath() {
        let bad = HookInstaller(homeDirectory: home, scriptPath: "/private/var/folders/x/AppTranslocation/ABC/d/Page.app/Contents/Resources/hooks/page-notify.sh")
        XCTAssertThrowsError(try bad.planInstall(.claude))
    }

    func testAgentMissing() throws {
        XCTAssertEqual(installer.status(.codex).state, .agentMissing)
        XCTAssertThrowsError(try installer.planInstall(.codex)) { XCTAssertEqual($0 as? HookInstallerError, .agentNotInstalled(.codex)) }
    }

    func testIndentAndTrailingNewlineFollowOriginal() throws {
        try write("{\n    \"a\": 1\n}")
        try installer.apply(try installer.planInstall(.claude))
        let text = try read()
        XCTAssertTrue(text.hasPrefix("{\n    \"a\": 1,\n    \"hooks\": {\n        \"PermissionRequest\""))
        XCTAssertFalse(text.hasSuffix("\n"))
    }

    func testCommandQuotingHandlesSpacesAndQuotes() {
        XCTAssertEqual(HookInstaller.shellQuote("/a b/it's/page-notify.sh"), "'/a b/it'\\''s/page-notify.sh'")
        let i = HookInstaller(homeDirectory: home, scriptPath: "/x y/page-notify.sh")
        XCTAssertEqual(i.command(for: .codex), "'/x y/page-notify.sh' --codex")
    }

    // MARK: Codex

    private var codexHooks: URL { home.appendingPathComponent(".codex/hooks.json") }

    func testCodexInstallWithAndWithoutStop() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try write("{\n  \"description\": \"mine\",\n  \"hooks\": {\n    \"SessionStart\": []\n  }\n}\n", to: codexHooks)
        try installer.apply(try installer.planInstall(.codex))
        var out = try OrderedJSON.parse(try read(codexHooks))
        XCTAssertEqual(out.objectMembers?.map(\.key), ["description", "hooks"])
        XCTAssertEqual(out["hooks"]?.objectMembers?.map(\.key), ["SessionStart", "PermissionRequest"])
        let h = try XCTUnwrap(out["hooks"]?["PermissionRequest"]?.arrayValue?.first?["hooks"]?.arrayValue?.first)
        XCTAssertEqual(h["command"]?.stringValue, "'\(script)' --codex --agent-timeout \(HookInstaller.blockingTimeout)")
        var st = installer.status(.codex)
        XCTAssertEqual(st.state, .installed)
        XCTAssertFalse(st.codexStopEnabled)

        // Opt in to the Stop continuation.
        let withStop = try installer.planInstall(.codex, codexStop: true)
        XCTAssertTrue(withStop.changed)
        try installer.apply(withStop)
        out = try OrderedJSON.parse(try read(codexHooks))
        XCTAssertEqual(out["hooks"]?.objectMembers?.map(\.key), ["SessionStart", "PermissionRequest", "Stop"])
        st = installer.status(.codex)
        XCTAssertEqual(st.state, .installed)
        XCTAssertTrue(st.codexStopEnabled)
        XCTAssertFalse(try installer.planInstall(.codex, codexStop: true).changed)

        // Uninstall leaves the user's empty SessionStart list alone.
        try installer.apply(try installer.planUninstall(.codex))
        XCTAssertEqual(try read(codexHooks), "{\n  \"description\": \"mine\",\n  \"hooks\": {\n    \"SessionStart\": []\n  }\n}\n")
    }

    func testCodexOptOutOfStopRemovesTheEvent() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try installer.apply(try installer.planInstall(.codex, codexStop: true))
        try installer.apply(try installer.planInstall(.codex, codexStop: false))
        let out = try OrderedJSON.parse(try read(codexHooks))
        XCTAssertEqual(out["hooks"]?.objectMembers?.map(\.key), ["PermissionRequest"])
        XCTAssertFalse(installer.status(.codex).codexStopEnabled)
    }

    func testCodexConfigParsing() {
        XCTAssertTrue(HookInstaller.parseCodexConfig("[features]\nhooks = false\n").hooksFeatureDisabled)
        XCTAssertTrue(HookInstaller.parseCodexConfig("[features]\ncodex_hooks = false # old\n").hooksFeatureDisabled)
        XCTAssertTrue(HookInstaller.parseCodexConfig("features.hooks = false\n").hooksFeatureDisabled)
        XCTAssertFalse(HookInstaller.parseCodexConfig("[features]\nhooks = true\n[other]\nhooks = false\n").hooksFeatureDisabled)
        XCTAssertTrue(HookInstaller.parseCodexConfig("[[hooks.PreToolUse]]\nmatcher = \"Bash\"\n").hasInlineHooks)
        XCTAssertFalse(HookInstaller.parseCodexConfig("model = \"gpt-5\"\nnotify = [\"x\"]\n").hasInlineHooks)
    }

    // MARK: cmux, diff, script lookup

    func testCmuxInfo() throws {
        let dir = home.appendingPathComponent(".cmuxterm/claude-settings")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write("{\"hooks\":{\"PermissionRequest\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"cmux hooks feed\"}]}]}}", to: dir.appendingPathComponent("a.json"))
        try write("{\"hooks\":{\"Stop\":[]}}", to: dir.appendingPathComponent("b.json"))
        try write("not json", to: dir.appendingPathComponent("c.json"))
        XCTAssertEqual(installer.cmuxHookInfo(), CmuxHookInfo(settingsFiles: 3, withPermissionRequestHook: 1))
    }

    func testUnifiedDiff() {
        let old = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n"
        let new = "a\nb\nc\nd\nE\nf\ng\nh\ni\nj\nk\n"
        let d = HookInstaller.unifiedDiff(old: old, new: new, oldLabel: "x", newLabel: "y")
        XCTAssertTrue(d.hasPrefix("--- x\n+++ y\n@@ -2,9 +2,10 @@\n"), d)
        XCTAssertTrue(d.contains("\n-e\n+E\n"), d)
        XCTAssertTrue(d.contains("\n+k\n"), d)
        XCTAssertEqual(HookInstaller.unifiedDiff(old: old, new: old, oldLabel: "x", newLabel: "y"), "")
        let created = HookInstaller.unifiedDiff(old: "", new: "{}\n", oldLabel: "x", newLabel: "y")
        XCTAssertTrue(created.contains("@@ -0,0 +1,1 @@\n+{}\n"), created)
    }

    func testLocateScriptFallsBackToRepo() throws {
        // The test bundle has no hooks/ resource; the #filePath fallback finds the repo copy.
        let path = try XCTUnwrap(HookInstaller.locateScript(bundle: Bundle(for: Self.self)))
        XCTAssertTrue(path.hasSuffix("/hooks/page-notify.sh"))
        XCTAssertNil(HookInstaller.locateScript(bundle: Bundle(for: Self.self), sourceFile: "/nonexistent/a/b/c.swift").flatMap { $0.contains("/nonexistent/") ? $0 : nil })
    }
}
