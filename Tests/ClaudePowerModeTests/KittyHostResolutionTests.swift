import XCTest
@testable import ClaudePowerMode

/// kitty on macOS starts each window's shell as `login -f -l -p user …/kitty.app/Contents/MacOS/kitten
/// run-shell …`. That row mentions the app but is not it; the host must be the kitty process itself.
final class KittyHostResolutionTests: XCTestCase {
    private func row(_ pid: Int32, _ ppid: Int32, _ command: String) -> ProcessRunner.ProcessInfoRow {
        ProcessRunner.ProcessInfoRow(pid: pid, ppid: ppid, tty: pid == 10 ? "??" : "ttys008", command: command)
    }

    func testHostIsTheKittyProcessNotTheLoginRowAroundItsKitten() {
        let app = "/Applications/kitty.app"
        let table = [
            row(10, 1, "\(app)/Contents/MacOS/kitty"),
            row(11, 10, "/usr/bin/login -f -l -p me \(app)/Contents/MacOS/kitten run-shell --shell /bin/zsh -lc claude"),
            row(12, 11, "-zsh -lc claude"),
            row(13, 12, "claude --session-id x"),
        ]
        let cmd = InjectionExecutor.hostAppCommand(forPid: 13, processTable: table)
        XCTAssertEqual(cmd, "\(app)/Contents/MacOS/kitty")
        XCTAssertEqual(InjectionExecutor.bundlePath(fromAppCommand: cmd!), app)
        XCTAssertEqual(InjectionExecutor.appName(forCommand: cmd!), "kitty")
    }

    func testLoginRowWithoutAnAppIsStillSkipped() {
        let table = [
            row(10, 1, "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
            row(11, 10, "/usr/bin/login -fp me"),
            row(12, 11, "-zsh"),
            row(13, 12, "claude"),
        ]
        XCTAssertEqual(InjectionExecutor.hostAppCommand(forPid: 13, processTable: table), "/Applications/iTerm.app/Contents/MacOS/iTerm2")
    }

    func testDetachedITermSessionServerStillResolvesFromItsLoginRow() {
        // After iTerm2 restores sessions its session server can be reparented away from the app:
        // the login row is then the only one that names iTerm.
        let table = [
            row(10, 1, "/Users/me/Library/Application Support/iTerm2/iTermServer-3.7.6 /Users/me/Library/Application Support/iTerm2/iterm2-daemon-1.socket"),
            row(11, 10, "/usr/bin/login -fpl me /Applications/iTerm.app/Contents/MacOS/ShellLauncher --launch_shell"),
            row(12, 11, "-zsh"),
            row(13, 12, "claude"),
        ]
        let cmd = InjectionExecutor.hostAppCommand(forPid: 13, processTable: table)
        XCTAssertEqual(cmd, "/Applications/iTerm.app/Contents/MacOS/ShellLauncher --launch_shell")
        XCTAssertEqual(InjectionExecutor.appName(forCommand: cmd!), "iTerm2")
        XCTAssertEqual(InjectionExecutor.bundlePath(fromAppCommand: cmd!), "/Applications/iTerm.app")
    }

    func testAnAppAboveTheLoginRowStillWins() {
        let app = "/Applications/kitty.app"
        let table = [
            row(10, 1, "\(app)/Contents/MacOS/kitty"),
            row(11, 10, "/usr/bin/login -f -l -p me \(app)/Contents/MacOS/kitten run-shell"),
            row(13, 11, "claude"),
        ]
        XCTAssertEqual(InjectionExecutor.hostAppCommand(forPid: 13, processTable: table), "\(app)/Contents/MacOS/kitty")
    }

    func testAWezTermMuxStartedThroughHomebrewIsWezTerm() {
        let table = [
            row(10, 1, "/opt/homebrew/bin/wezterm-mux-server --daemonize"),
            row(12, 10, "-zsh"),
            row(13, 12, "claude"),
        ]
        let cmd = InjectionExecutor.hostAppCommand(forPid: 13, processTable: table)
        XCTAssertEqual(cmd.flatMap(InjectionExecutor.appName(forCommand:)), "WezTerm")
        XCTAssertNil(InjectionExecutor.bundlePath(fromAppCommand: cmd!), "no bundle: the CLI is found on PATH or in /Applications")
        XCTAssertEqual(InjectionExecutor.appName(forCommand: "/opt/homebrew/bin/wezterm-gui start"), "WezTerm")
        XCTAssertNil(InjectionExecutor.appName(forCommand: "/usr/local/bin/weztermish"))
    }

    func testProcessTableCommandHasNoLeadingPadding() {
        // ps pads the tty column; "??" rows used to keep that padding in front of the command.
        let rows = ProcessRunner.processTable()
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.command == $0.command.trimmingCharacters(in: .whitespaces) })
    }
}
