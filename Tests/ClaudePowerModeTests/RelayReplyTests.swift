import XCTest
@testable import ClaudePowerMode

final class RelayReplyTests: XCTestCase {
    private func reply(id: String, backend: String?) -> RelayReply {
        RelayReply(interventionId: id, text: "", action: nil, sessionId: nil, cwd: nil,
                   kind: nil, backend: backend, source: nil)
    }

    func testExplicitBackendWins() {
        XCTAssertEqual(reply(id: "codex-abc", backend: "claude").owningBackend, .claude)
        XCTAssertEqual(reply(id: "hook-abc", backend: "codex").owningBackend, .codex)
    }

    func testPrefixFallbackForOldWorkers() {
        XCTAssertEqual(reply(id: "codex-abc", backend: nil).owningBackend, .codex)
        XCTAssertEqual(reply(id: "hook-abc", backend: nil).owningBackend, .claude)
        XCTAssertEqual(reply(id: "abc-idle-123", backend: "bogus").owningBackend, .claude)
    }

    func testDecodesV1PayloadWithoutNewFields() throws {
        let json = #"{"interventionId":"x","text":"hi","action":null,"sessionId":"s","cwd":"/tmp"}"#
        let r = try JSONDecoder().decode(RelayReply.self, from: Data(json.utf8))
        XCTAssertNil(r.kind)
        XCTAssertEqual(r.owningBackend, .claude)
    }
}

final class ProcessRunnerTests: XCTestCase {
    func testDrainsLargeOutputWithoutDeadlock() {
        // 1 MB on stdout — far beyond the 64 KB pipe buffer.
        let r = ProcessRunner.run("/bin/sh", ["-c", "head -c 1048576 /dev/zero | tr '\\0' a"], timeout: 10)
        XCTAssertTrue(r.succeeded)
        XCTAssertEqual(r.stdout.count, 1_048_576)
    }

    func testTimeoutKillsChild() {
        let start = Date()
        let r = ProcessRunner.run("/bin/sleep", ["30"], timeout: 0.5)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testShellQuote() {
        XCTAssertEqual(ProcessRunner.shellQuote("it's"), #"'it'\''s'"#)
    }
}
