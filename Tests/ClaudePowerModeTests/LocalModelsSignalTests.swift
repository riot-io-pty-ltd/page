import XCTest
@testable import ClaudePowerMode

/// GPU parsing, /slots decoding, HTTP outcome mapping, port selection and
/// the loopback-only HTTP client.
final class LocalModelsSignalTests: XCTestCase {
    // MARK: GPU parser

    private func usage(_ times: [UInt64]) -> [[String: Any]] {
        times.map { ["API": "Metal", "accumulatedGPUTime": NSNumber(value: $0), "lastSubmittedTime": NSNumber(value: 1)] }
    }

    func testCreatorPid() {
        XCTAssertEqual(GPUUsageParser.pid(fromCreator: "pid 408, WindowServer"), 408)
        XCTAssertEqual(GPUUsageParser.pid(fromCreator: "pid 31337, LM Studio Helpe"), 31337, "names are truncated; only the pid counts")
        XCTAssertNil(GPUUsageParser.pid(fromCreator: "WindowServer"))
        XCTAssertNil(GPUUsageParser.pid(fromCreator: "pid , x"))
        XCTAssertNil(GPUUsageParser.pid(fromCreator: "pid 0, kernel"))
    }

    func testAccumulatedTimesSumsEntriesAndQueues() {
        let entries: [[String: Any]] = [
            ["IOUserClientCreator": "pid 10, ollama", "AppUsage": usage([100, 50])],
            ["IOUserClientCreator": "pid 10, ollama", "AppUsage": usage([25])],
            ["IOUserClientCreator": "pid 11, LM Studio Helpe", "AppUsage": usage([7])],
            ["IOUserClientCreator": "pid 12, quiet"],                       // missing AppUsage
            ["IOUserClientCreator": "pid 13, empty", "AppUsage": [[String: Any]]()],
            ["AppUsage": usage([999])],                                      // no creator
        ]
        let sums = GPUUsageParser.accumulatedTimes(entries)
        XCTAssertEqual(sums[10], 175)
        XCTAssertEqual(sums[11], 7)
        XCTAssertEqual(sums[12], 0)
        XCTAssertEqual(sums[13], 0)
        XCTAssertEqual(sums.count, 4)
    }

    func testTrackerUtilizationAndPidReuse() {
        var t = GPUUtilizationTracker()
        XCTAssertEqual(t.update(sums: [1: 1_000], pids: [1], nowNs: 1_000_000_000), [:], "first sample has no baseline")
        let u = t.update(sums: [1: 501_000], pids: [1], nowNs: 2_000_000_000)
        XCTAssertEqual(u[1] ?? -1, 0.0005, accuracy: 1e-9)
        let full = t.update(sums: [1: 1_000_501_000], pids: [1], nowNs: 3_000_000_000)
        XCTAssertEqual(full[1] ?? -1, 1.0, accuracy: 1e-9)
        // Sum went down: pid reused / client closed → reset without a reading.
        XCTAssertEqual(t.update(sums: [1: 10], pids: [1], nowNs: 4_000_000_000), [:])
        XCTAssertEqual(t.update(sums: [1: 10], pids: [1], nowNs: 5_000_000_000)[1], 0)
        // Overlapping queues can exceed wall time: clamped.
        XCTAssertEqual(t.update(sums: [1: 3_000_000_010], pids: [1], nowNs: 6_000_000_000)[1], 1)
        // A wanted pid with no AGX client reads as 0 GPU time.
        _ = t.update(sums: [:], pids: [2], nowNs: 7_000_000_000)
        XCTAssertEqual(t.update(sums: [:], pids: [2], nowNs: 8_000_000_000)[2], 0)
    }

    func testSamplerUnavailableWithoutAGX() {
        let sampler = GPUSampler(enumerate: { _ in nil }, clock: { 1 })
        XCTAssertEqual(sampler.sample(pids: [1]), .unavailable)
    }

    func testSamplerFromFakeRegistry() {
        var clock: UInt64 = 1_000_000_000
        var gpu: UInt64 = 0
        let sampler = GPUSampler(enumerate: { _ in
            [["IOUserClientCreator": "pid 42, mlx", "AppUsage": [["accumulatedGPUTime": NSNumber(value: gpu)]]]]
        }, clock: { clock })
        XCTAssertEqual(sampler.sample(pids: [42]), .utilization([:]))
        clock += 1_000_000_000; gpu += 630_000_000
        guard case .utilization(let u) = sampler.sample(pids: [42]) else { return XCTFail() }
        XCTAssertEqual(u[42] ?? -1, 0.63, accuracy: 1e-9)
    }

    // MARK: slots

    private let busyFixture = #"[{"id":0,"id_task":5,"n_ctx":8192,"is_processing":true,"next_token":{"n_decoded":12}}]"#
    private let idleFixture = #"[{"id":0,"id_task":-1,"n_ctx":8192,"is_processing":false},{"id":1,"n_ctx":8192,"is_processing":false}]"#
    private let promptFixture = #"[{"id":0,"is_processing":false,"prompt":"my secret prompt","params":{"stop":["x"]}}]"#

    func testSlotsDecoder() {
        XCTAssertEqual(SlotsDecoder.anyProcessing(Data(busyFixture.utf8)), true)
        XCTAssertEqual(SlotsDecoder.anyProcessing(Data(idleFixture.utf8)), false)
        XCTAssertEqual(SlotsDecoder.anyProcessing(Data("[]".utf8)), false)
        XCTAssertEqual(SlotsDecoder.anyProcessing(Data(promptFixture.utf8)), false, "extra keys ignored, never decoded")
        XCTAssertNil(SlotsDecoder.anyProcessing(Data("{\"error\":\"x\"}".utf8)))
        XCTAssertNil(SlotsDecoder.anyProcessing(Data("[{\"id\":0}]".utf8)), "no is_processing → malformed")
        XCTAssertNil(SlotsDecoder.anyProcessing(Data("not json".utf8)))
        XCTAssertNil(SlotsDecoder.anyProcessing(Data("[{\"is_processing\":\"yes\"}]".utf8)))
    }

    func testHTTPOutcomeMapping() {
        XCTAssertEqual(SlotsDecoder.state(status: 200, body: Data(busyFixture.utf8)), .busy)
        XCTAssertEqual(SlotsDecoder.state(status: 200, body: Data(idleFixture.utf8)), .idle)
        XCTAssertEqual(SlotsDecoder.state(status: 200, body: Data("[]".utf8)), .idle)
        XCTAssertEqual(SlotsDecoder.state(status: 200, body: Data("garbage".utf8)), .unavailable)
        XCTAssertEqual(SlotsDecoder.state(status: 200, body: nil), .unavailable)
        for status in [401, 403, 404, 501] {
            XCTAssertEqual(SlotsDecoder.state(status: status, body: nil), .unavailable, "\(status)")
        }
        // Timeout / connection error / loading / redirect: never idle.
        XCTAssertEqual(SlotsDecoder.state(status: nil, body: nil), .noObservation)
        XCTAssertEqual(SlotsDecoder.state(status: 503, body: Data(idleFixture.utf8)), .noObservation)
        XCTAssertEqual(SlotsDecoder.state(status: 500, body: nil), .noObservation)
        XCTAssertEqual(SlotsDecoder.state(status: 302, body: nil), .noObservation)
    }

    // MARK: ports

    func testPortSelection() {
        XCTAssertEqual(LocalPortSelection.ports(listening: [8080, 9000], declared: 9000), [9000])
        XCTAssertEqual(LocalPortSelection.ports(listening: [8080], declared: 9000), [], "declared but not listening there")
        XCTAssertEqual(LocalPortSelection.ports(listening: [9001, 8081], declared: nil), [8081, 9001])
        XCTAssertEqual(LocalPortSelection.ports(listening: nil, declared: 9000), [9000], "socket lookup failed → argv port")
        XCTAssertEqual(LocalPortSelection.ports(listening: [], declared: 9000), [9000])
        XCTAssertEqual(LocalPortSelection.ports(listening: nil, declared: nil), [], "never guess 8080")
        XCTAssertEqual(LocalPortSelection.ports(listening: [], declared: nil), [])
    }

    // MARK: LoopbackHTTP

    func testLoopbackOnly() {
        XCTAssertTrue(LoopbackHTTP.isAllowed(URL(string: "http://127.0.0.1:8080/slots")!))
        for s in ["http://localhost:8080/slots", "http://192.168.1.2:8080/slots", "https://127.0.0.1:8080/slots",
                  "http://127.0.0.1/slots", "http://example.com:80/", "http://user:pw@127.0.0.1:8080/",
                  "http://127.0.0.2:8080/", "http://[::1]:8080/", "file:///etc/passwd"] {
            XCTAssertFalse(LoopbackHTTP.isAllowed(URL(string: s)!), s)
        }
        XCTAssertEqual(LoopbackHTTP.url(port: 8080, path: "/slots")?.absoluteString, "http://127.0.0.1:8080/slots")
        XCTAssertNil(LoopbackHTTP.url(port: 0, path: "/slots"))
        XCTAssertNil(LoopbackHTTP.url(port: 8080, path: "slots"))
    }

    func testRefusedHostNeverHitsNetwork() {
        let http = LoopbackHTTP(timeout: 1)
        defer { http.invalidate() }
        let done = expectation(description: "completion")
        http.get(URL(string: "http://example.com:80/slots")!) { status, body in
            XCTAssertNil(status)
            XCTAssertNil(body)
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
    }

    /// A closed loopback port is a connection error → no observation, not idle.
    func testClosedPortIsNoObservation() throws {
        let port = try closedLoopbackPort()
        let http = LoopbackHTTP(timeout: 2)
        defer { http.invalidate() }
        let done = expectation(description: "slots")
        http.slots(port: port) { state in
            XCTAssertEqual(state, .noObservation)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    /// Binds and closes a loopback socket to get a port nothing listens on.
    private func closedLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("no socket") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw XCTSkip("bind failed") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
