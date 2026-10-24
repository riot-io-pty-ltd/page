import XCTest
@testable import ClaudePowerMode

/// Exercises the real tmux transport against a throwaway private tmux
/// server (`-L pagetest-macclaude-*`) whose pane runs `cat -v` with
/// bracketed paste enabled, so every byte that arrives is visible. Never
/// touches the user's default tmux server. Skipped when tmux isn't installed.
final class ClaudeTmuxTransportTests: XCTestCase {
    private var socket = ""
    private var dir: URL!
    private var wrapper = ""
    private var tmux = ""

    override func setUpWithError() throws {
        guard let found = ProcessRunner.findExecutable("tmux") else { throw XCTSkip("tmux not installed") }
        tmux = found
        socket = "pagetest-macclaude-\(UUID().uuidString.prefix(8))"
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(socket)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The transport takes a tmux path; point it at a wrapper bound to
        // the private socket.
        wrapper = dir.appendingPathComponent("tmux").path
        try "#!/bin/bash\nexec \(ProcessRunner.shellQuote(tmux)) -L \(socket) \"$@\"\n".write(toFile: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
        let start = ProcessRunner.run(wrapper, ["-f", "/dev/null", "new-session", "-d", "-s", "t", "-x", "200", "-y", "40",
                                                "sh -c 'stty raw -echo; printf \"\\033[?2004h\"; exec cat -v'"], timeout: 5)
        guard start.succeeded else { throw XCTSkip("couldn't start private tmux server: \(start.stderr)") }
        usleep(400_000)
    }

    override func tearDown() {
        if !wrapper.isEmpty {
            let socketPath = ProcessRunner.run(wrapper, ["display-message", "-p", "#{socket_path}"], timeout: 3).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ProcessRunner.run(wrapper, ["kill-server"], timeout: 5)
            // kill-server leaves the socket file behind.
            if socketPath.contains("pagetest-macclaude-") { try? FileManager.default.removeItem(atPath: socketPath) }
        }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func pane() throws -> (id: String, tty: String) {
        let r = ProcessRunner.run(wrapper, ["list-panes", "-a", "-F", "#{pane_id}\t#{pane_tty}\t#{pane_in_mode}"], timeout: 3)
        let line = try XCTUnwrap(r.stdout.split(separator: "\n").first)
        let cols = line.split(separator: "\t").map(String.init)
        // The production parser must agree with real tmux output.
        XCTAssertEqual(InjectionExecutor.tmuxPane(forTTY: cols[1], listing: r.stdout)?.id, cols[0])
        return (cols[0], cols[1])
    }

    private func screen(_ paneId: String) -> String {
        usleep(300_000)
        return ProcessRunner.run(wrapper, ["capture-pane", "-p", "-t", paneId], timeout: 3).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testLiteralTextWithLeadingDashAndEnter() throws {
        let p = try pane()
        let r = InjectionExecutor.sendViaTmux([.text("-y --force"), .enter], tmuxPath: wrapper, paneId: p.id,
                                              inMode: false, awaitClosed: { true })
        XCTAssertTrue(r.success, r.output)
        XCTAssertEqual(screen(p.id), "-y --force^M")
    }

    func testEnterIsNeverSentWhenPromptDoesNotClose() throws {
        let p = try pane()
        let r = InjectionExecutor.sendViaTmux([.escape, .awaitPromptClosed, .text("a\nb"), .enter], tmuxPath: wrapper,
                                              paneId: p.id, inMode: false, awaitClosed: { false })
        XCTAssertFalse(r.success)
        XCTAssertFalse(r.detail.isEmpty)
        XCTAssertEqual(screen(p.id), "^[")
    }

    func testEscapeThenBracketedPasteThenEnter() throws {
        let p = try pane()
        let r = InjectionExecutor.sendViaTmux([.escape, .awaitPromptClosed, .text("line one\nline two"), .enter],
                                              tmuxPath: wrapper, paneId: p.id, inMode: false, awaitClosed: { true })
        XCTAssertTrue(r.success, r.output)
        XCTAssertEqual(screen(p.id), "^[^[[200~line one^Mline two^[[201~^M")
        // The temporary paste buffer is deleted.
        XCTAssertFalse(ProcessRunner.run(wrapper, ["list-buffers"], timeout: 3).stdout.contains("page-"))
    }

    func testApproveDigitHasNoEnter() throws {
        let p = try pane()
        let r = InjectionExecutor.sendViaTmux([.text("1")], tmuxPath: wrapper, paneId: p.id, inMode: false, awaitClosed: { true })
        XCTAssertTrue(r.success)
        XCTAssertEqual(screen(p.id), "1")
    }

    func testMissingPaneFailsHonestly() throws {
        _ = try pane()
        let r = InjectionExecutor.sendViaTmux([.text("hi"), .enter], tmuxPath: wrapper, paneId: "%999", inMode: false, awaitClosed: { true })
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.method, .tmux)
        XCTAssertFalse(r.detail.isEmpty)
    }

    func testCopyModeIsCancelledFirst() throws {
        let p = try pane()
        XCTAssertTrue(ProcessRunner.run(wrapper, ["copy-mode", "-t", p.id], timeout: 3).succeeded)
        let listing = ProcessRunner.run(wrapper, ["list-panes", "-a", "-F", "#{pane_id}\t#{pane_tty}\t#{pane_in_mode}"], timeout: 3).stdout
        let info = try XCTUnwrap(InjectionExecutor.tmuxPane(forTTY: p.tty, listing: listing))
        XCTAssertTrue(info.inMode)
        let r = InjectionExecutor.sendViaTmux([.text("ok"), .enter], tmuxPath: wrapper, paneId: p.id, inMode: info.inMode, awaitClosed: { true })
        XCTAssertTrue(r.success, r.output)
        XCTAssertEqual(screen(p.id), "ok^M")
    }
}
