import XCTest
@testable import ClaudePowerMode

final class PendingRetirementsTests: XCTestCase {
    private var saved: URL!
    private var dir: URL!

    override func setUp() {
        saved = PendingRetirements.fileURL
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pr-\(UUID().uuidString)")
        PendingRetirements.fileURL = dir.appendingPathComponent("retire-pending.json")
    }

    override func tearDown() {
        PendingRetirements.fileURL = saved
        try? FileManager.default.removeItem(at: dir)
    }

    private let ws = URL(string: "wss://relay.example.workers.dev/ws")!

    func testAddPersistsOwnerOnlyAndDeduplicates() throws {
        PendingRetirements.add(token: "old-token-aaaaaaaa", wsURL: ws)
        PendingRetirements.add(token: "old-token-aaaaaaaa", wsURL: ws)
        XCTAssertEqual(PendingRetirements.all().map(\.token), ["old-token-aaaaaaaa"])
        let perms = try FileManager.default.attributesOfItem(atPath: PendingRetirements.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testTwoQuickRegeneratesBothStayPending() {
        // A → B → C within the retire window: both A and B must be retired.
        PendingRetirements.add(token: "token-A-aaaaaaaaaa", wsURL: ws)
        PendingRetirements.add(token: "token-B-bbbbbbbbbb", wsURL: ws)
        let due = PendingRetirements.claimDue(currentToken: "token-C-cccccccccc")
        XCTAssertEqual(Set(due.map(\.token)), ["token-A-aaaaaaaaaa", "token-B-bbbbbbbbbb"])
    }

    func testNeverRetiresTheTokenInUse() {
        PendingRetirements.add(token: "same-token-xxxxxxx", wsURL: ws)
        XCTAssertTrue(PendingRetirements.claimDue(currentToken: "same-token-xxxxxxx").isEmpty)
        XCTAssertTrue(PendingRetirements.all().isEmpty, "a token back in use is dropped, not retried")
    }

    func testClaimBacksOffUntilConfirmed() {
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        PendingRetirements.add(token: "old-token-aaaaaaaa", wsURL: ws, now: t0)
        XCTAssertEqual(PendingRetirements.claimDue(currentToken: "new", now: t0).count, 1)
        XCTAssertTrue(PendingRetirements.claimDue(currentToken: "new", now: t0.addingTimeInterval(30)).isEmpty)
        XCTAssertEqual(PendingRetirements.claimDue(currentToken: "new", now: t0.addingTimeInterval(61)).count, 1)
        PendingRetirements.remove(token: "old-token-aaaaaaaa")
        XCTAssertTrue(PendingRetirements.all().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: PendingRetirements.fileURL.path))
    }

    func testExpiredEntriesAreDropped() {
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        let old = PendingRetirements.Entry(token: "t", wsURL: ws, since: t0)
        let (due, kept) = PendingRetirements.due([old], currentToken: "x", now: t0.addingTimeInterval(PendingRetirements.maxAge + 1))
        XCTAssertTrue(due.isEmpty)
        XCTAssertTrue(kept.isEmpty)
    }

    func testBackoffIsCapped() {
        XCTAssertEqual(PendingRetirements.backoff(attempts: 1), 60)
        XCTAssertEqual(PendingRetirements.backoff(attempts: 2), 120)
        XCTAssertEqual(PendingRetirements.backoff(attempts: 50), 3600)
    }
}
