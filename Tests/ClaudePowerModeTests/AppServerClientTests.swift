import XCTest
@testable import ClaudePowerMode

/// `AppServerClient` against fake app-servers (small shell scripts), so the
/// real process, pipe and reader-thread plumbing is exercised without codex.
final class AppServerClientTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appserver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func script(_ body: String) throws -> String {
        let url = dir.appendingPathComponent("fake-codex")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// Regression: the reader used `FileHandle.read(upToCount: 64 KiB)`,
    /// which on a pipe waits for 64 KiB or EOF. A short line from a writer
    /// that stays open must still be delivered straight away.
    func testDrainDeliversShortChunkWhileWriterStaysOpen() throws {
        let pipe = Pipe()
        let got = expectation(description: "chunk delivered")
        let received = LockedBox(Data())
        let reader = pipe.fileHandleForReading
        Thread.detachNewThread {
            AppServerClient.drain(reader) { chunk in
                received.mutate { $0.append(chunk) }
                got.fulfill()
                return false
            }
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("{\"id\":1}\n".utf8))
        wait(for: [got], timeout: 2)
        XCTAssertEqual(String(decoding: received.value, as: UTF8.self), "{\"id\":1}\n")
        try pipe.fileHandleForWriting.close()
    }

    func testDrainStopsAtEOF() throws {
        let pipe = Pipe()
        let done = expectation(description: "drain returned")
        let reader = pipe.fileHandleForReading
        Thread.detachNewThread {
            AppServerClient.drain(reader) { _ in true }
            done.fulfill()
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("x".utf8))
        try pipe.fileHandleForWriting.close()
        wait(for: [done], timeout: 2)
    }

    /// End to end: a fake server that answers `initialize` and keeps its
    /// stdout open (fd 3 holds it while `cat` eats stdin) must complete the
    /// handshake promptly.
    func testHandshakeCompletesWhileServerKeepsStdoutOpen() async throws {
        let path = try script("""
        read line
        printf '%s\\n' '{"id":1,"result":{"userAgent":"fake/1.0","codexHome":"/tmp/fake"}}'
        exec 3>&1
        exec cat >/dev/null
        """)
        let client = AppServerClient(codexPath: path)
        defer { client.shutdown() }
        let started = Date()
        let result = try await client.start(clientName: "Page", clientVersion: "test")
        XCTAssertEqual(result.userAgent, "fake/1.0")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertTrue(client.isReady)
    }

    /// A child that dies before answering (e.g. `env: node: No such file or
    /// directory`) fails the handshake as soon as it exits, not after the
    /// 20 s initialize timeout.
    func testHandshakeFailsFastWhenChildExits() async throws {
        let path = try script("echo 'env: node: No such file or directory' >&2\nexit 127")
        let client = AppServerClient(codexPath: path)
        defer { client.shutdown() }
        let started = Date()
        do {
            _ = try await client.start(clientName: "Page", clientVersion: "test")
            XCTFail("handshake should fail")
        } catch AppServerClient.ClientError.notRunning {
            // expected
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertFalse(client.isRunning)
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; f(&stored) }
}
