import XCTest
@testable import ClaudePowerMode

/// The in-app power-helper install. Never runs osascript (that would put an
/// admin prompt on screen); it checks the pure pieces.
final class PowerHelperInstallerTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The app and install.sh must grant exactly the same commands, so either
    /// can install the rule and `--disable-power-helpers` removes both.
    func testRuleLinesMatchInstallScript() throws {
        let script = try String(contentsOf: repoRoot.appendingPathComponent("install.sh"), encoding: .utf8)
        let lines = script.components(separatedBy: "\n")

        let patternLine = try XCTUnwrap(lines.first { $0.hasPrefix("STAMP_PATTERN='") })
        let pattern = String(patternLine.dropFirst("STAMP_PATTERN='".count).dropLast())
        XCTAssertEqual(pattern, PowerHelperInstaller.stampPattern)

        let start = try XCTUnwrap(lines.firstIndex { $0.contains("cat > \"$tmp\" <<EOF") })
        let end = try XCTUnwrap(lines[(start + 1)...].firstIndex { $0 == "EOF" })
        let rules = lines[(start + 1)..<end]
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.replacingOccurrences(of: "$USER_NAME", with: "alex")
                     .replacingOccurrences(of: "$STAMP_PATTERN", with: pattern) }
        XCTAssertEqual(Array(rules), PowerHelperInstaller.ruleLines(user: "alex"))
    }

    func testFragmentPassesVisudo() throws {
        guard FileManager.default.isExecutableFile(atPath: PowerHelperInstaller.visudo) else {
            throw XCTSkip("visudo not available")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("page-sudoers-\(UUID().uuidString)")
        try PowerHelperInstaller.fragment(user: "alex").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let r = ProcessRunner.run(PowerHelperInstaller.visudo, ["-c", "-q", "-f", url.path], timeout: 10)
        XCTAssertTrue(r.succeeded, "visudo: \(r.stderr)")
    }

    func testUserNameValidation() {
        for ok in ["alex", "a.b", "first_last", "user-1"] {
            XCTAssertTrue(PowerHelperInstaller.isValidUserName(ok), ok)
        }
        for bad in ["", "-x", "a b", "a\nALL=(ALL) ALL", "a,b", "a'b", "a\"b", "%admin", "a:b", "ä"] {
            XCTAssertFalse(PowerHelperInstaller.isValidUserName(bad), bad)
        }
    }

    /// The root script installs via a dotted temp name (sudo ignores those),
    /// validates the root-owned copy, and rolls back if sudoers breaks.
    func testRootScriptShape() {
        let s = PowerHelperInstaller.rootScript(user: "alex")
        let lines = s.components(separatedBy: "\n")
        func index(_ needle: String) -> Int? { lines.firstIndex { $0.contains(needle) } }
        let write = index("printf '%s'"), chown = index("chown root:wheel"),
            check = index("-c -q -f '/etc/sudoers.d/claude-power-mode.page-tmp'"),
            move = index("/bin/mv -f"), recheck = lines.lastIndex { $0.contains("-c -q >/dev/null") }
        XCTAssertNotNil(write); XCTAssertNotNil(chown); XCTAssertNotNil(check); XCTAssertNotNil(move); XCTAssertNotNil(recheck)
        if let write, let chown, let check, let move, let recheck {
            XCTAssertTrue(write < chown && chown < check && check < move && move < recheck)
        }
        XCTAssertTrue(lines[recheck ?? 0].contains("rm -f '/etc/sudoers.d/claude-power-mode'"))
        // The fragment is embedded, not read from a user-writable file.
        XCTAssertTrue(s.contains("NOPASSWD: /usr/bin/pmset -a disablesleep 1"))
        XCTAssertFalse(s.contains("/tmp/"))
    }

    /// Runs the root script's shell text through sh -n, and the AppleScript
    /// wrapper through osacompile (compile only — nothing executes).
    func testScriptsParse() throws {
        let sh = ProcessRunner.run("/bin/sh", ["-n", "-c", PowerHelperInstaller.rootScript(user: "alex")])
        XCTAssertTrue(sh.succeeded, sh.stderr)
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/osacompile") else { return }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("page-helper-\(UUID().uuidString).scpt")
        defer { try? FileManager.default.removeItem(at: out) }
        let osa = ProcessRunner.run("/usr/bin/osacompile", ["-o", out.path, "-e", PowerHelperInstaller.appleScript(user: "alex")])
        XCTAssertTrue(osa.succeeded, osa.stderr)
    }

    func testOutcomeMapping() {
        typealias R = ProcessRunner.Result
        XCTAssertEqual(PowerHelperInstaller.outcome(R(status: 0, stdout: "", stderr: "", timedOut: false, launched: true)), .installed)
        XCTAssertEqual(PowerHelperInstaller.outcome(R(status: 1, stdout: "", stderr: "execution error: User canceled. (-128)", timedOut: false, launched: true)), .cancelled)
        XCTAssertEqual(PowerHelperInstaller.outcome(R(status: 1, stdout: "", stderr: "the rule failed validation (3)", timedOut: false, launched: true)),
                       .failed("the rule failed validation (3)"))
        if case .failed = PowerHelperInstaller.outcome(R(status: -1, stdout: "", stderr: "", timedOut: true, launched: true)) {} else { XCTFail("timeout") }
        if case .failed = PowerHelperInstaller.outcome(.notLaunched) {} else { XCTFail("not launched") }
    }
}
