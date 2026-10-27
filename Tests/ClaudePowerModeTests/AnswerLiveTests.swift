import XCTest
@testable import ClaudePowerMode

/// Drives the REAL answer path (registry → gate → screen driver → tmux) into a
/// REAL Claude Code AskUserQuestion dialog. Skipped unless
/// `PAGE_LIVE_ANSWER_SESSION` is set, so it never runs in CI or by accident.
///
/// Only ever point it at a throwaway session you started for the purpose, on a
/// private tmux server (`TMUX_TMPDIR` in a scratch directory, so `tmux
/// list-panes -a` can't see any other pane), e.g. `claude --session-id <uuid>
/// --setting-sources project` in a temp dir. One delivery per run; the caller
/// checks the transcript afterwards.
///
///   PAGE_LIVE_ANSWER_SESSION  the throwaway session's id
///   PAGE_LIVE_ANSWER_PICKS    JSON: [{"i":0,"picks":[1]},{"i":1,"picks":[1,3],"other":"x"}]
///   PAGE_LIVE_ANSWER_OUT      where to write the result JSON
final class AnswerLiveTests: XCTestCase {
    func testAnswerOneDialogInThrowawaySession() throws {
        let env = ProcessInfo.processInfo.environment
        guard let sessionId = env["PAGE_LIVE_ANSWER_SESSION"], !sessionId.isEmpty else {
            throw XCTSkip("live test: set PAGE_LIVE_ANSWER_SESSION to a throwaway session")
        }
        let registry = ClaudeSessionRegistry(projectsDirectory: "~/.claude/projects")
        let io = AnswerDelivery.liveIO(registry: registry)
        guard case .live(let session, _) = io.resolve(sessionId) else { return XCTFail("session \(sessionId) isn't live") }
        let tool = try XCTUnwrap(io.pendingTools(session)?.first { $0.name == "AskUserQuestion" }, "no pending AskUserQuestion")
        let picksJSON = try XCTUnwrap(env["PAGE_LIVE_ANSWER_PICKS"]?.data(using: .utf8))
        let answers = try XCTUnwrap(AnswerRequest.parseAnswers(try JSONSerialization.jsonObject(with: picksJSON)))

        let result = AnswerDelivery.run(sessionId: sessionId, request: AnswerRequest(promptKey: tool.id, answers: answers), io: io)
        let line = "code=\(result.code.rawValue) reason=\(result.reason?.rawValue ?? "-") detail=\(result.detail)"
        print("LIVE ANSWER RESULT: \(line)")
        if let out = env["PAGE_LIVE_ANSWER_OUT"] { try? line.write(toFile: out, atomically: true, encoding: .utf8) }
        XCTAssertEqual(result.code, .delivered, line)
    }
}
