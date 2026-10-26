import XCTest
@testable import ClaudePowerMode

final class TerminalBridgesTests: XCTestCase {
    // MARK: WezTerm

    /// Shape of `wezterm cli list --format json` (fields Page reads, plus a
    /// few it ignores).
    private let wezList = """
    [{"window_id":0,"tab_id":0,"pane_id":0,"workspace":"default","title":"zsh","cwd":"file:///Users/me","tty_name":"/dev/ttys004","is_active":true},
     {"window_id":0,"tab_id":1,"pane_id":3,"workspace":"default","title":"claude","cwd":"file:///Users/me/p","tty_name":"/dev/ttys007","is_active":false},
     {"window_id":1,"tab_id":2,"pane_id":5,"workspace":"default","title":"ssh","tty_name":null}]
    """

    func testParseWezTermList() {
        let panes = WezTermBridge.parseList(wezList)
        XCTAssertEqual(panes, [.init(paneId: "0", tty: "/dev/ttys004"), .init(paneId: "3", tty: "/dev/ttys007"), .init(paneId: "5", tty: nil)])
        XCTAssertEqual(WezTermBridge.parseList("not json"), [])
    }

    func testWezTermPaneMustMatchTheSessionTTY() {
        let panes = WezTermBridge.parseList(wezList)
        XCTAssertEqual(WezTermBridge.pane(for: "/dev/ttys007", envPane: "3", in: panes)?.paneId, "3")
        XCTAssertNil(WezTermBridge.pane(for: "/dev/ttys007", envPane: "0", in: panes), "env pane on another tty: refuse")
        XCTAssertEqual(WezTermBridge.pane(for: "/dev/ttys007", envPane: nil, in: panes)?.paneId, "3", "single pane on the tty")
        XCTAssertNil(WezTermBridge.pane(for: "/dev/ttys099", envPane: nil, in: panes))
        let dup = panes + [.init(paneId: "9", tty: "/dev/ttys007")]
        XCTAssertNil(WezTermBridge.pane(for: "/dev/ttys007", envPane: nil, in: dup), "ambiguous: refuse")
    }

    func testWezTermSendArgs() {
        let one = WezTermBridge.sendArgs(paneId: "3", key: .text("1"))!
        XCTAssertEqual(one.args, ["send-text", "--pane-id", "3", "--no-paste"], "typed, not pasted, so it picks the menu option")
        XCTAssertEqual(one.stdin, Data("1".utf8))
        let flag = WezTermBridge.sendArgs(paneId: "3", key: .text("--rm everything"))!
        XCTAssertFalse(flag.args.contains("--rm everything"), "text never goes in argv")
        let multi = WezTermBridge.sendArgs(paneId: "3", key: .text("a\nb"))!
        XCTAssertEqual(multi.args, ["send-text", "--pane-id", "3"], "bracketed paste: newlines don't submit")
        XCTAssertEqual(WezTermBridge.sendArgs(paneId: "3", key: .enter)?.stdin, Data("\r".utf8))
        XCTAssertEqual(WezTermBridge.sendArgs(paneId: "3", key: .escape)?.stdin, Data("\u{1B}".utf8))
        XCTAssertNil(WezTermBridge.sendArgs(paneId: "3", key: .pause(0.1)))
    }

    // MARK: kitty

    /// Shape of `kitten @ ls`.
    private let kittyLs = """
    [{"id":1,"is_focused":true,"tabs":[
      {"id":1,"title":"zsh","windows":[{"id":1,"pid":500,"cwd":"/Users/me","foreground_processes":[{"pid":500,"cmdline":["-zsh"]}]}]},
      {"id":2,"title":"claude","windows":[{"id":4,"pid":600,"cwd":"/Users/me/p","foreground_processes":[{"pid":610,"cmdline":["claude"]}]}]}]}]
    """

    func testParseKittyLs() {
        let w = KittyBridge.parseLs(kittyLs)
        XCTAssertEqual(w, [.init(id: "1", pid: 500, foregroundPids: [500]), .init(id: "4", pid: 600, foregroundPids: [610])])
        XCTAssertEqual(KittyBridge.parseLs("[]"), [])
    }

    func testKittyWindowMustOwnTheSession() {
        let w = KittyBridge.parseLs(kittyLs)
        XCTAssertEqual(KittyBridge.window(id: "4", sessionPid: 610, in: w)?.id, "4", "foreground process")
        XCTAssertNil(KittyBridge.window(id: "4", sessionPid: 777, in: w), "behind something else in the window (a multiplexer): refuse")
        XCTAssertNil(KittyBridge.window(id: "1", sessionPid: 610, in: w), "env says window 1, but the session lives in 4")
        XCTAssertNil(KittyBridge.window(id: "9", sessionPid: 610, in: w))
    }

    func testNestedMultiplexerIsRefused() {
        XCTAssertEqual(InjectionExecutor.nestedMultiplexer(env: ["HERDR_ENV": "1"], ancestorCommands: []), "Herdr")
        XCTAssertEqual(InjectionExecutor.nestedMultiplexer(env: ["ZELLIJ": "0"], ancestorCommands: []), "zellij")
        XCTAssertEqual(InjectionExecutor.nestedMultiplexer(env: ["STY": "123.x"], ancestorCommands: []), "screen")
        let table = [ProcessRunner.ProcessInfoRow(pid: 610, ppid: 600, tty: "", command: "claude"),
                     ProcessRunner.ProcessInfoRow(pid: 600, ppid: 500, tty: "", command: "/opt/homebrew/bin/herdr server"),
                     ProcessRunner.ProcessInfoRow(pid: 500, ppid: 400, tty: "", command: "-zsh"),
                     ProcessRunner.ProcessInfoRow(pid: 400, ppid: 1, tty: "", command: "/Applications/cmux.app/Contents/MacOS/cmux")]
        let ancestors = InjectionExecutor.ancestorCommands(of: 610, processTable: table)
        XCTAssertEqual(ancestors.count, 3)
        XCTAssertEqual(InjectionExecutor.nestedMultiplexer(env: [:], ancestorCommands: ancestors), "Herdr", "herdr server under cmux, env scrubbed")
        XCTAssertNil(InjectionExecutor.nestedMultiplexer(env: [:], ancestorCommands: ["-zsh", "/Applications/WezTerm.app/Contents/MacOS/wezterm-gui"]))
    }

    func testKittyOnlyLocalSockets() {
        XCTAssertTrue(KittyBridge.isLocalSocket("unix:/tmp/kitty-123"))
        XCTAssertFalse(KittyBridge.isLocalSocket("tcp:0.0.0.0:8999"), "never type across the network")
        XCTAssertFalse(KittyBridge.isLocalSocket("unix:"))
    }

    func testKittySendArgs() {
        let t = KittyBridge.Target(kittenPath: "/k", socket: "unix:/tmp/kitty-1", windowId: "4")
        let one = KittyBridge.sendArgs(target: t, key: .text("1"))!
        XCTAssertEqual(one.args, ["@", "--to", "unix:/tmp/kitty-1", "send-text", "--match", "id:4", "--bracketed-paste", "disable", "--stdin"])
        XCTAssertEqual(one.stdin, Data("1".utf8))
        XCTAssertTrue(KittyBridge.sendArgs(target: t, key: .text("a\nb"))!.args.contains("enable"))
        XCTAssertEqual(KittyBridge.sendArgs(target: t, key: .escape)?.args.suffix(4), ["send-key", "--match", "id:4", "escape"])
        XCTAssertEqual(KittyBridge.sendArgs(target: t, key: .enter)?.args.last, "enter")
    }

    // MARK: wiring

    func testBundlePath() {
        XCTAssertEqual(InjectionExecutor.bundlePath(fromAppCommand: "/Applications/WezTerm.app/Contents/MacOS/wezterm-gui start"), "/Applications/WezTerm.app")
        XCTAssertNil(InjectionExecutor.bundlePath(fromAppCommand: "/usr/bin/zsh"))
    }

    func testHostsAreTypableAndInterruptible() {
        let wez = InjectionExecutor.TerminalHost.wezterm(.init(cliPath: "/w", paneId: "3", socket: nil))
        let kit = InjectionExecutor.TerminalHost.kitty(.init(kittenPath: "/k", socket: "unix:/tmp/k", windowId: "4"))
        XCTAssertEqual(wez.label, "WezTerm pane 3")
        XCTAssertEqual(kit.label, "kitty window 4")
        XCTAssertTrue(wez.canSendLoneEscape && kit.canSendLoneEscape)
        let wi = LiveSessionBackends.claudeHostInfo(wez, provider: .anthropic)
        XCTAssertEqual(wi.host, "WezTerm"); XCTAssertTrue(wi.canType && wi.canInterrupt)
        XCTAssertEqual(LiveSessionBackends.claudeHostInfo(kit, provider: .anthropic).host, "kitty")
        let blocked = LiveSessionBackends.claudeHostInfo(.unreachable(KittyBridge.remoteControlHint), provider: .anthropic)
        XCTAssertEqual(blocked.host, "kitty")
        XCTAssertFalse(blocked.canType)
        XCTAssertEqual(ClaudeBackend.pauseStrategy(status: .busy, host: wez, mode: .pause, isLocal: true), .interrupt)
        XCTAssertNotNil(SessionScreen.source(for: kit))
    }

    func testControlCLISenderStopsOnPrecheckAndReportsPartial() {
        var sent: [Keystroke] = []
        let ok = InjectionExecutor.sendViaControlCLI([.text("hi"), .enter], method: .wezterm, label: "WezTerm pane 3",
                                                     awaitClosed: { true }) { key in
            sent.append(key); return ProcessRunner.Result(status: 0, stdout: "", stderr: "", timedOut: false, launched: true)
        }
        XCTAssertTrue(ok.success); XCTAssertEqual(sent, [.text("hi"), .enter])
        var n = 0
        let partial = InjectionExecutor.sendViaControlCLI([.text("hi"), .enter], method: .kitty, label: "kitty window 4",
                                                          awaitClosed: { true }, precheck: { k in k == .enter ? "A prompt opened" : nil }) { _ in
            n += 1; return ProcessRunner.Result(status: 0, stdout: "", stderr: "", timedOut: false, launched: true)
        }
        XCTAssertFalse(partial.success)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(partial.detail, "A prompt opened (part of the reply was typed)")
        let gate = InjectionExecutor.sendViaControlCLI([.escape, .awaitPromptClosed, .text("x")], method: .kitty, label: "k",
                                                       awaitClosed: { false }) { _ in
            ProcessRunner.Result(status: 0, stdout: "", stderr: "", timedOut: false, launched: true)
        }
        XCTAssertFalse(gate.success, "never types after Esc unless the menu provably closed")
    }
}
