import XCTest
@testable import ClaudePowerMode

final class ProcArgsTests: XCTestCase {
    private func buffer(argc: Int32, exec: String, padding: Int, args: [String], env: [String]) -> Data {
        var d = Data()
        withUnsafeBytes(of: argc.littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: Array(exec.utf8)); d.append(0)
        d.append(contentsOf: [UInt8](repeating: 0, count: padding))
        for s in args + env { d.append(contentsOf: Array(s.utf8)); d.append(0) }
        return d
    }

    func testParsesArgvAndOnlyAllowlistedEnv() throws {
        let data = buffer(argc: 3, exec: "/usr/local/bin/claude", padding: 5,
                          args: ["claude", "--resume", "abc"],
                          env: ["ANTHROPIC_BASE_URL=http://127.0.0.1:11434", "SECRET_TOKEN=sk-xyz", "HOME=/Users/alex", "OLLAMA_HOST=0.0.0.0"])
        let info = try XCTUnwrap(ProcArgs.parse(data, envKeys: ProcArgs.envAllowlist))
        XCTAssertEqual(info.argv, ["claude", "--resume", "abc"])
        XCTAssertEqual(info.env, ["ANTHROPIC_BASE_URL": "http://127.0.0.1:11434", "OLLAMA_HOST": "0.0.0.0"])
        XCTAssertFalse(String(describing: info).contains("sk-xyz"))
    }

    func testValueContainingEqualsSign() throws {
        let data = buffer(argc: 1, exec: "/x", padding: 0, args: ["x"], env: ["ANTHROPIC_BASE_URL=http://h/?a=b"])
        XCTAssertEqual(ProcArgs.parse(data, envKeys: ProcArgs.envAllowlist)?.env["ANTHROPIC_BASE_URL"], "http://h/?a=b")
    }

    func testNoEnvironment() throws {
        let data = buffer(argc: 2, exec: "/bin/llama-server", padding: 2, args: ["llama-server", "--port"], env: [])
        let info = try XCTUnwrap(ProcArgs.parse(data, envKeys: ProcArgs.envAllowlist))
        XCTAssertEqual(info.argv, ["llama-server", "--port"])
        XCTAssertTrue(info.env.isEmpty)
    }

    func testTruncatedBufferRejected() {
        let data = buffer(argc: 4, exec: "/x", padding: 0, args: ["a", "b"], env: [])
        XCTAssertNil(ProcArgs.parse(data, envKeys: []))
        XCTAssertNil(ProcArgs.parse(Data([1, 0]), envKeys: []))
        XCTAssertNil(ProcArgs.parse(buffer(argc: 0, exec: "/x", padding: 0, args: [], env: []), envKeys: []))
    }

    /// Our own process: argv[0] is the test runner and the read needs no root.
    func testReadsOwnProcess() throws {
        let info = try XCTUnwrap(ProcArgs.read(pid: getpid()))
        XCTAssertFalse(info.argv.isEmpty)
        XCTAssertNil(ProcArgs.read(pid: -1))
    }
}
