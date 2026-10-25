import XCTest
@testable import ClaudePowerMode

/// Drives the REAL live-sessions input gate (fresh lookup → gate →
/// `deliverToLiveSession` / `sendInterrupt`) into a REAL Claude Code
/// session, exactly as a phone command would after decryption. Skipped
/// unless `PAGE_LIVE_SESSION_ID` is set, so it never runs in CI or by
/// accident.
///
/// Only ever point it at a throwaway session started for the purpose, and
/// pass its pid: the test fails before any key if the gate resolves a
/// different process. One command per run; check the outcome on screen.
///
///   PAGE_LIVE_SESSION_ID  the throwaway session's id
///   PAGE_LIVE_PID         its claude pid (required; asserted before any key)
///   PAGE_LIVE_OP          input (default) | interrupt
///   PAGE_LIVE_TEXT        text for input
final class LiveSessionInputTests: XCTestCase {
    func testOneCommandIntoThrowawaySession() throws {
        let env = ProcessInfo.processInfo.environment
        guard let sessionId = env["PAGE_LIVE_SESSION_ID"], !sessionId.isEmpty else {
            throw XCTSkip("live test: set PAGE_LIVE_SESSION_ID to a throwaway session")
        }
        let pid = try XCTUnwrap(env["PAGE_LIVE_PID"].flatMap { Int32($0) }, "PAGE_LIVE_PID is required")
        let registry = ClaudeSessionRegistry(projectsDirectory: "~/.claude/projects", recordProvider: { _, _ in })
        var wrongTarget = false
        let io = SessionInputGate.ClaudeIO(
            resolve: { req in
                let t = InjectionExecutor.resolveClaudeTarget(req, registry: registry)
                if case .live(let s, _) = t, s.pid != pid { wrongTarget = true; return .failed(.init("wrong target")) }
                return t
            },
            currentRecord: { registry.currentRecord(forPid: $0) },
            resolveHost: { InjectionExecutor.resolveHost(for: $0, processTable: $1) },
            deliver: { req, s, table in
                precondition(s.pid == pid, "refusing to type into pid \(s.pid)")
                return InjectionExecutor.deliverToLiveSession(req, session: s, processTable: table, registry: registry)
            },
            isForeground: { ProcessRunner.isForeground(pid: $0) },
            sendInterrupt: { InjectionExecutor.sendInterrupt(host: $0) })

        // Lift the no-live-cmux guard for this one command only; deliver
        // still refuses any pid but the throwaway's.
        CmuxBridge.liveTestAllowsCLI = true
        defer { CmuxBridge.liveTestAllowsCLI = false }
        let result: SessionCommandResult
        if env["PAGE_LIVE_OP"] == "interrupt" {
            result = SessionInputGate.runClaudeInterrupt(sessionId: sessionId, interventionId: nil, io: io)
        } else {
            result = SessionInputGate.runClaudeInput(sessionId: sessionId, clientId: UUID().uuidString,
                                                     text: env["PAGE_LIVE_TEXT"] ?? "", interventionId: nil, io: io)
        }
        XCTAssertFalse(wrongTarget, "the gate resolved a different process")
        print("LIVE result code=\(result.code.rawValue) reason=\(result.reason?.rawValue ?? "-") detail=\(result.detail)")
    }
}
