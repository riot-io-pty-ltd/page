import XCTest
@testable import ClaudePowerMode

/// Provider detection must never block the tick queue (a file read behind a
/// macOS privacy prompt once froze keep-awake), and must never read inside
/// privacy-protected folders.
final class ProviderResolutionTests: XCTestCase {
    private let sid = "6a1f0c2e-9b7d-4e1a-8c3f-2d4e6f8a0b1c"

    private func live(_ pid: Int32, cwd: String? = "/p") -> ClaudeLiveSession {
        ClaudeLiveSession(pid: pid, sessionId: sid, cwd: cwd, status: .busy, statusUpdatedAt: nil,
                          tty: "ttys001", hasSessionFile: true)
    }

    func testProtectedFolders() {
        let home = "/Users/alex"
        for p in ["/Users/alex/Documents", "/Users/alex/Documents/PlatformIO/Projects/x", "/Users/alex/Desktop/a",
                  "/Users/alex/Downloads/b", "/Users/alex/Library/Mobile Documents/com~apple~CloudDocs/c",
                  "/Users/alex/Library/CloudStorage/Dropbox/d", "/Volumes/USB/e", "~/Documents/f"] {
            XCTAssertTrue(PrivacyProtectedPaths.contains(p, home: home), p)
        }
        for p in ["/Users/alex/projects/x", "/Users/alex/DocumentsArchive/x", "/Users/alex/.claude/settings.json",
                  "/private/tmp/x", "/Users/alex/Library/Application Support/x"] {
            XCTAssertFalse(PrivacyProtectedPaths.contains(p, home: home), p)
        }
    }

    /// A session in ~/Documents: settings aren't read, provider is unknown
    /// (which never counts as Anthropic evidence).
    func testClaudeLiveUnknownForProtectedProject() {
        let home = "/Users/alex"
        XCTAssertEqual(ModelProviderClassifier.claudeLive(argv: ["claude"], env: [:], cwd: "/Users/alex/Documents/proj", home: home), .unknown)
        XCTAssertEqual(ModelProviderClassifier.claudeLive(argv: ["claude"], env: ["CLAUDE_CONFIG_DIR": "/Users/alex/Desktop/cfg"],
                                                          cwd: "/tmp/proj", home: home), .unknown)
    }

    /// The resolver hangs (as `open()` does behind a privacy prompt): the
    /// tick-side call returns at once with `.unknown`, records nothing, and
    /// queues one resolution; once it lands the next pass uses and records it.
    func testBlockingResolverNeverBlocksTheCaller() {
        let gate = DispatchSemaphore(value: 0)
        let calls = Counter()
        var recorded: [ModelProvider] = []
        let queue = DispatchQueue(label: "test.resolver")
        let reg = ClaudeSessionRegistry(
            projectsDirectory: "/nonexistent", sessionsDirectory: "/nonexistent",
            resolveProvider: { _, _ in calls.bump(); gate.wait(); return .ollama },
            startSeconds: { _ in 1000 },
            recordProvider: { recorded.append($1) },
            resolverQueue: queue)

        let started = Date()
        XCTAssertEqual(reg.annotateProviders([live(10)]).first?.provider, .unknown)
        XCTAssertEqual(reg.annotateProviders([live(10)]).first?.provider, .unknown)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "the caller must not wait on the resolver")
        XCTAssertTrue(recorded.isEmpty, "nothing recorded while unresolved")

        gate.signal()
        queue.sync {}   // the resolution has landed
        XCTAssertEqual(calls.value, 1, "one resolution per (pid, start), however many passes ask")
        XCTAssertEqual(reg.annotateProviders([live(10)]).first?.provider, .ollama)
        XCTAssertEqual(recorded, [.ollama])
    }

    /// A result that lands between a pass's snapshot and its write-back
    /// survives (the pass only writes back entries it changed).
    func testBackgroundResultNotClobberedByConcurrentPass() {
        let queue = DispatchQueue(label: "test.resolver2")
        let reg = ClaudeSessionRegistry(
            projectsDirectory: "/nonexistent", sessionsDirectory: "/nonexistent",
            resolveProvider: { pid, _ in pid == 10 ? .lmStudio : .anthropic },
            startSeconds: { _ in 1000 },
            recordProvider: { _, _ in },
            resolverQueue: queue)
        _ = reg.annotateProviders([live(10), live(11)])
        queue.sync {}
        // A pass that only sees pid 11 (no prune) must keep pid 10's entry.
        _ = reg.annotateProviders([live(11)])
        XCTAssertEqual(reg.annotateProviders([live(10)]).first?.provider, .lmStudio)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
