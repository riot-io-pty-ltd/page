import XCTest
@testable import ClaudePowerMode

/// Drives the REAL reply path (registry → staleness → keystroke plan → tmux
/// transport) into a REAL Claude Code session. Skipped unless
/// `PAGE_LIVE_SESSION_ID` is set, so it never runs in CI or by accident.
///
/// Only ever point it at a throwaway session you started for the purpose —
/// e.g. a uniquely named session on the default tmux server running
/// `claude --session-id <uuid> --setting-sources project` in a temp dir with
/// a Bash "ask" rule — never at a session you care about. One delivery per
/// run; the caller checks the outcome on screen (`tmux capture-pane`) and in
/// `~/.claude/sessions/<pid>.json`.
///
///   PAGE_LIVE_SESSION_ID  the throwaway session's id
///   PAGE_LIVE_ACTION      approve | deny | carry_on | custom
///   PAGE_LIVE_TEXT        reply text (custom)
///   PAGE_LIVE_KIND        approval (default) | idle
///   PAGE_LIVE_STATE_START / PAGE_LIVE_PROMPT_KEY  stamps of a page captured
///                         earlier (ms epoch / tool_use id), to replay a late
///                         reply; default: the session's current state
final class LiveInjectionTests: XCTestCase {
    func testDeliverOneReplyToThrowawaySession() throws {
        let env = ProcessInfo.processInfo.environment
        guard let sessionId = env["PAGE_LIVE_SESSION_ID"], !sessionId.isEmpty else {
            throw XCTSkip("live test: set PAGE_LIVE_SESSION_ID to a throwaway session")
        }
        let action = env["PAGE_LIVE_ACTION"].flatMap { $0.isEmpty ? nil : $0 }
        let text = env["PAGE_LIVE_TEXT"] ?? ""
        let kind: ReplyPromptKind = env["PAGE_LIVE_KIND"] == "idle" ? .idle : .approval

        let registry = ClaudeSessionRegistry(projectsDirectory: "~/.claude/projects")
        let table = ProcessRunner.processTable()
        let live = registry.liveSessions(forSessionId: sessionId, processTable: table)
        let session = try XCTUnwrap(live.first, "session \(sessionId) isn't live")
        XCTAssertEqual(live.count, 1, "ambiguous session id")

        // What the detector would have stamped on the page.
        var promptKey: String?
        if let url = registry.transcriptURL(forSessionId: sessionId, cwdHint: session.cwd),
           let tail = InterventionDetector.readTranscriptTail(url) {
            promptKey = tail.pendingToolUses.first?.id
        }
        var stateStart = session.statusUpdatedAt
        if let ms = env["PAGE_LIVE_STATE_START"].flatMap(Double.init) {
            stateStart = Date(timeIntervalSince1970: ms / 1000)
        }
        if let key = env["PAGE_LIVE_PROMPT_KEY"], !key.isEmpty { promptKey = key }
        print("LIVE_STAMP state_start_ms=\(Int((session.statusUpdatedAt?.timeIntervalSince1970 ?? 0) * 1000)) prompt_key=\(promptKey ?? "")")
        let req = InjectionExecutor.ClaudeReplyRequest(
            interventionId: "\(sessionId)-live-test", sessionId: sessionId,
            action: action, text: text, kind: kind,
            pagePid: session.pid, pageStateStart: stateStart,
            pagePromptKey: promptKey, hookCreatedAt: nil
        )

        // Off the main thread: the AppleScript transports hop to main.
        let done = expectation(description: "delivered")
        var result: InjectionResult?
        DispatchQueue.global().async {
            guard case .live(let s, let t) = InjectionExecutor.resolveClaudeTarget(req, registry: registry) else {
                done.fulfill()
                return
            }
            result = InjectionExecutor.deliverToLiveSession(req, session: s, processTable: t, registry: registry)
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        let r = try XCTUnwrap(result, "target didn't resolve")
        print("LIVE_RESULT status=\(session.status.rawValue) action=\(action ?? "nil") method=\(r.method.rawValue) success=\(r.success) detail=\(r.detail)")
    }
}
