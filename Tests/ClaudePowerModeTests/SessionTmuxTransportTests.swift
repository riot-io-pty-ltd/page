import XCTest
@testable import ClaudePowerMode

/// Phone text through the input gate into a real tmux transport, on a
/// throwaway private server (`-L pagetest-sessions-*`) whose pane runs
/// `cat -v`, so every byte that arrives is visible. Never touches the
/// user's default tmux server or any real session. Skipped without tmux.
final class SessionTmuxTransportTests: XCTestCase {
    private var socket = ""
    private var dir: URL!
    private var wrapper = ""
    private let sid = "6f1f2b2e-6a54-4b52-9d2c-3f1f7d7b8a90"

    override func setUpWithError() throws {
        guard let tmux = ProcessRunner.findExecutable("tmux") else { throw XCTSkip("tmux not installed") }
        socket = "pagetest-sessions-\(UUID().uuidString.prefix(8))"
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(socket)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        wrapper = dir.appendingPathComponent("tmux").path
        try "#!/bin/bash\nexec \(ProcessRunner.shellQuote(tmux)) -L \(socket) \"$@\"\n".write(toFile: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
        let start = ProcessRunner.run(wrapper, ["-f", "/dev/null", "new-session", "-d", "-s", "t", "-x", "200", "-y", "40",
                                                "sh -c 'stty raw -echo; exec cat -v'"], timeout: 5)
        guard start.succeeded else { throw XCTSkip("couldn't start private tmux server: \(start.stderr)") }
        usleep(400_000)
    }

    override func tearDown() {
        if !wrapper.isEmpty {
            let socketPath = ProcessRunner.run(wrapper, ["display-message", "-p", "#{socket_path}"], timeout: 3).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ProcessRunner.run(wrapper, ["kill-server"], timeout: 5)
            if socketPath.contains("pagetest-sessions-") { try? FileManager.default.removeItem(atPath: socketPath) }
        }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func paneId() throws -> String {
        let r = ProcessRunner.run(wrapper, ["list-panes", "-a", "-F", "#{pane_id}"], timeout: 3)
        return try XCTUnwrap(r.stdout.split(separator: "\n").first.map(String.init))
    }

    private func screen(_ pane: String) -> String {
        usleep(300_000)
        return ProcessRunner.run(wrapper, ["capture-pane", "-p", "-t", pane], timeout: 3).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The gate with a live process faked and the real tmux transport as
    /// the delivery: whatever plan the reply path makes is typed.
    private func io(status: String, pane: String) -> SessionInputGate.ClaudeIO {
        let session = ClaudeLiveSession(pid: 4242, sessionId: sid, cwd: "/tmp", status: ClaudeSessionStatus(raw: status),
                                        statusUpdatedAt: nil, tty: "ttys003", hasSessionFile: true)
        let host = InjectionExecutor.TerminalHost.tmux(tmuxPath: wrapper, paneId: pane, inMode: false)
        return SessionInputGate.ClaudeIO(
            resolve: { _ in .live(session, []) },
            currentRecord: { ClaudeSessionRecord(pid: $0, status: status) },
            resolveHost: { _, _ in host },
            deliver: { req, s, _ in
                guard case .send(let steps, _) = InjectionExecutor.plan(action: req.action, kind: req.kind ?? .other,
                                                                        status: s.status, text: req.text) else {
                    return InjectionResult(method: .none, success: false, output: "refused")
                }
                return InjectionExecutor.sendViaTmux(steps, tmuxPath: self.wrapper, paneId: pane, inMode: false, awaitClosed: { false })
            },
            isForeground: { _ in true },
            sendInterrupt: { InjectionExecutor.sendInterrupt(host: $0) }
        )
    }

    func testIdleTextIsTypedWithEnterAndNoEscape() throws {
        let pane = try paneId()
        let r = SessionInputGate.runClaudeInput(sessionId: sid, clientId: "c1", text: "  run the tests\u{1b}[A  ",
                                                interventionId: nil, io: io(status: "idle", pane: pane))
        XCTAssertEqual(r.code, .delivered, r.detail)
        XCTAssertEqual(screen(pane), "run the tests[A^M", "control characters stripped, one Enter, no Esc")
    }

    func testBusyTextIsQueuedAndARefusalTypesNothing() throws {
        let pane = try paneId()
        let busy = io(status: "busy", pane: pane)
        XCTAssertEqual(SessionInputGate.runClaudeInput(sessionId: sid, clientId: "c2", text: "1", interventionId: nil, io: busy).reason,
                       .digitWhileBusy)
        XCTAssertEqual(SessionInputGate.runClaudeInput(sessionId: sid, clientId: "c3", text: "also lint", interventionId: nil,
                                                       io: io(status: "waiting", pane: pane)).reason, .waiting)
        XCTAssertEqual(screen(pane), "", "refusals type nothing")
        XCTAssertEqual(SessionInputGate.runClaudeInput(sessionId: sid, clientId: "c4", text: "also lint", interventionId: nil, io: busy).code,
                       .queued)
        XCTAssertEqual(screen(pane), "also lint^M")
    }

    func testInterruptPressesALoneEsc() throws {
        let pane = try paneId()
        let r = SessionInputGate.runClaudeInterrupt(sessionId: sid, interventionId: nil, io: io(status: "busy", pane: pane))
        XCTAssertEqual(r.code, .delivered, r.detail)
        XCTAssertEqual(screen(pane), "^[")
    }
}
