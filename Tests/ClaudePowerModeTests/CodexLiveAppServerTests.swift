import XCTest
@testable import ClaudePowerMode

/// Drives the real `AppServerClient` against the real `codex` on this Mac.
/// Opt-in only (`PAGE_LIVE_CODEX=1`): it spawns `codex app-server`, which
/// reads ~/.codex. It never starts a thread or touches a session.
final class CodexLiveAppServerTests: XCTestCase {
    func testRealCodexAppServerInitializes() async throws {
        guard ProcessInfo.processInfo.environment["PAGE_LIVE_CODEX"] == "1" else {
            throw XCTSkip("set PAGE_LIVE_CODEX=1 to run against the real codex")
        }
        let client = AppServerClient(codexPath: ProcessInfo.processInfo.environment["PAGE_LIVE_CODEX_PATH"] ?? "")
        defer { client.shutdown() }
        let started = Date()
        let result = try await client.start(clientName: "Page", clientVersion: "0.1")
        XCTAssertNotNil(result.userAgent)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertTrue(client.isReady)
    }
}
