import XCTest
@testable import ClaudePowerMode

final class BoundedFileReadTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testReadsSmallRegularFile() throws {
        let f = dir.appendingPathComponent("settings.json")
        try Data(#"{"env":{}}"#.utf8).write(to: f)
        XCTAssertEqual(BoundedFileRead.read(f.path), Data(#"{"env":{}}"#.utf8))
    }

    func testOverCapRejected() throws {
        let f = dir.appendingPathComponent("big.json")
        try Data(repeating: 0x20, count: 2048).write(to: f)
        XCTAssertNil(BoundedFileRead.read(f.path, maxBytes: 1024))
        XCTAssertNotNil(BoundedFileRead.read(f.path, maxBytes: 4096))
    }

    /// A project settings file symlinked to /dev/zero must not be read.
    func testSymlinkToDevZeroRejected() throws {
        let link = dir.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/dev/zero")
        XCTAssertNil(BoundedFileRead.read(link.path))
        XCTAssertNil(BoundedFileRead.read("/dev/zero"))
    }

    /// A FIFO never delivers EOF; the read must return at once, not hang.
    func testFifoRejectedWithoutBlocking() throws {
        let fifo = dir.appendingPathComponent("settings.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let start = Date()
        XCTAssertNil(BoundedFileRead.read(fifo.path))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testDirectoryAndMissingRejected() {
        XCTAssertNil(BoundedFileRead.read(dir.path))
        XCTAssertNil(BoundedFileRead.read(dir.appendingPathComponent("nope").path))
    }

    /// Settings env read through a hostile project file: skipped, not hung.
    func testSettingsEnvSkipsHostileProjectFile() throws {
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data(#"{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:11434"}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude/settings.json"))
        let project = dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(project.appendingPathComponent(".claude/settings.json").path, 0o600), 0)
        try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent(".claude/settings.local.json").path,
                                                   withDestinationPath: "/dev/zero")
        let env = ClaudeSettingsEnv.read(cwd: project.path, home: home.path)
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "http://127.0.0.1:11434")
    }
}
