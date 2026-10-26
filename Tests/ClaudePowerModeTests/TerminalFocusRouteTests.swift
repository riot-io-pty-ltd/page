import XCTest
@testable import ClaudePowerMode

/// The pure part of focusing a session's terminal: the labels it shows, the
/// values it will accept as a tty or pane, and the commands it builds. None
/// of these may type anything: no keystroke, write text or send-text.
final class TerminalFocusRouteTests: XCTestCase {
    func testRouteLabelNamesHostAndProject() {
        XCTAssertEqual(TerminalFocus.routeLabel(host: "cmux", project: "page"), "cmux › page")
        XCTAssertEqual(TerminalFocus.routeLabel(host: "cmux", project: ""), "cmux")
        for host in ["unknown", "desktop", "background", ""] {
            XCTAssertNil(TerminalFocus.routeLabel(host: host, project: "page"), host)
        }
    }

    func testOnlyTTYPathsAreAcceptedIntoAppleScript() {
        XCTAssertTrue(TerminalFocus.isSafeTTY("/dev/ttys003"))
        XCTAssertTrue(TerminalFocus.isSafeTTY("/dev/tty1"))
        for bad in ["/dev/ttys", "ttys003", "/dev/ttys003; rm -rf ~", "/dev/ttys003\" & do shell script \"x", "/tmp/ttys003", "",
                    "/dev/ttys003\n"] {
            XCTAssertFalse(TerminalFocus.isSafeTTY(bad), bad.debugDescription)
        }
    }

    func testOnlyTmuxPaneIdsAreAccepted() {
        XCTAssertTrue(TerminalFocus.isSafePane("%12"))
        for bad in ["12", "%", "%1 2", "%1;kill", "", "%12\n"] {
            XCTAssertFalse(TerminalFocus.isSafePane(bad), bad)
        }
    }

    func testTmuxCommandsShowTheWindowThenThePane() {
        XCTAssertEqual(TerminalFocus.tmuxCommands(paneId: "%3"), [["select-window", "-t", "%3"], ["select-pane", "-t", "%3"]])
        XCTAssertEqual(TerminalFocus.tmuxCommands(paneId: "3"), [], "an unsafe pane id builds nothing")
    }

    func testCmuxCommandsSelectTheWorkspaceWhenKnown() {
        XCTAssertEqual(TerminalFocus.cmuxCommands(surfaceId: "S", workspaceId: "W"),
                       [["select-workspace", "--workspace", "W"], ["focus-panel", "--panel", "S", "--workspace", "W"]])
        XCTAssertEqual(TerminalFocus.cmuxCommands(surfaceId: "S", workspaceId: nil), [["focus-panel", "--panel", "S"]])
        XCTAssertEqual(TerminalFocus.cmuxCommands(surfaceId: "S", workspaceId: ""), [["focus-panel", "--panel", "S"]])
    }

    func testWezTermAndKittyArguments() {
        XCTAssertEqual(TerminalFocus.weztermArgs(paneId: "5"), ["cli", "activate-pane", "--pane-id", "5"])
        XCTAssertEqual(TerminalFocus.kittyArgs(socket: "unix:/tmp/k", windowId: "4"),
                       ["@", "--to", "unix:/tmp/k", "focus-window", "--match", "id:4"])
    }

    func testScriptsEmbedTheQuotedTTYAndNeverType() {
        let scripts = [TerminalFocus.terminalScript(tty: "/dev/ttys003"), TerminalFocus.iTermScript(tty: "/dev/ttys003")]
        for script in scripts {
            XCTAssertTrue(script.contains("\"/dev/ttys003\""))
            let lower = script.lowercased()
            XCTAssertFalse(lower.contains("keystroke"))
            XCTAssertFalse(lower.contains("write text"))
            XCTAssertFalse(lower.contains("send-text"))
        }
    }

    func testAppleScriptQuotingEscapesQuotesAndBackslashes() {
        XCTAssertEqual(ProcessRunner.appleScriptQuote("a\"b\\c"), "\"a\\\"b\\\\c\"")
    }

    func testTheTerminalAppListStartsWithCmux() {
        XCTAssertEqual(TerminalFocus.terminalAppNames.first, "cmux")
        XCTAssertTrue(TerminalFocus.terminalAppNames.contains("Terminal"))
    }
}
