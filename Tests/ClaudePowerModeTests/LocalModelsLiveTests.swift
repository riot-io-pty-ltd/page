import XCTest
import Metal
@testable import ClaudePowerMode

/// Cheap, read-only checks against this Mac's real libproc and IOKit. No
/// network beyond an in-process loopback socket, no other processes touched.
final class LocalModelsLiveTests: XCTestCase {
    func testGPUSamplerEnumeratesWithoutCrashing() throws {
        let me = getpid()
        guard let entries = GPUSampler.enumerateAGXClients(wanted: [me]) else {
            throw XCTSkip("no AGX user clients (Intel Mac or no Apple GPU)")
        }
        XCTAssertFalse(entries.isEmpty)
        XCTAssertTrue(entries.allSatisfy { $0["IOUserClientCreator"] is String })
        let sampler = GPUSampler()
        XCTAssertNotEqual(sampler.sample(pids: [me]), .unavailable)
        guard case .utilization(let u) = sampler.sample(pids: [me]) else { return XCTFail("second sample") }
        XCTAssertNotNil(u[me], "our pid reads as 0 even without a GPU client")
    }

    /// End-to-end GPU path: a busy Metal compute loop in this process must
    /// read above the 0.25 enter threshold for our pid.
    func testMetalLoadIsSeenBySampler() throws {
        guard GPUSampler.enumerateAGXClients(wanted: []) != nil else { throw XCTSkip("no AGX") }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("no Metal device")
        }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void spin(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
            float x = float(id);
            for (uint i = 0; i < 20000; i++) { x = fma(x, 1.000001f, 0.5f); x = sin(x); }
            out[id] = x;
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let function = try XCTUnwrap(library.makeFunction(name: "spin"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let count = 1 << 16
        let buffer = try XCTUnwrap(device.makeBuffer(length: count * MemoryLayout<Float>.size, options: .storageModeShared))

        func submit() -> MTLCommandBuffer? {
            guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return nil }
            enc.setComputePipelineState(pipeline)
            enc.setBuffer(buffer, offset: 0, index: 0)
            let w = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
            enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
            enc.endEncoding()
            cb.commit()
            return cb
        }

        // Warm up so our AGX client exists before the baseline sample.
        submit()?.waitUntilCompleted()
        let me = getpid()
        let sampler = GPUSampler()
        _ = sampler.sample(pids: [me])
        let end = Date().addingTimeInterval(1.5)
        var inFlight: [MTLCommandBuffer] = []
        while Date() < end {
            if let cb = submit() { inFlight.append(cb) }
            if inFlight.count >= 3 { inFlight.removeFirst().waitUntilCompleted() }
        }
        inFlight.forEach { $0.waitUntilCompleted() }
        guard case .utilization(let u) = sampler.sample(pids: [me]) else { return XCTFail("unavailable") }
        let util = try XCTUnwrap(u[me])
        XCTAssertGreaterThan(util, GPUHysteresis.enter, "GPU utilization \(util)")
    }

    /// Catches a byte-order bug in the listening-port lookup.
    func testListeningPortsSeesOwnSocket() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("no socket") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 1) == 0 else { throw XCTSkip("bind/listen failed") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        let ports = try XCTUnwrap(LocalProcInfo.listeningTCPPorts(getpid()))
        XCTAssertTrue(ports.contains(port), "\(port) not in \(ports.sorted())")
        XCTAssertEqual(LocalPortSelection.ports(listening: ports, declared: port), [port])
    }

    func testProcInfoForOwnProcess() throws {
        let me = getpid()
        XCTAssertTrue(LocalProcInfo.allPids().contains(me))
        let path = try XCTUnwrap(LocalProcInfo.execPath(me))
        XCTAssertTrue(path.hasPrefix("/"))
        let info = try XCTUnwrap(LocalProcInfo.bsdInfo(me))
        XCTAssertEqual(info.ppid, getppid())
        XCTAssertGreaterThan(info.startSeconds, 0)
        XCTAssertNil(LocalProcInfo.ttyName(tdev: UInt32.max), "NODEV")
        XCTAssertNil(LocalProcInfo.ttyModified("../etc/passwd"))
        XCTAssertNil(LocalProcInfo.listeningTCPPorts(-1))
    }

    /// Discovery runs over every process on this Mac without crashing and
    /// never classifies the test runner itself.
    func testScannerRunsLive() {
        let scanner = LocalProcessScanner()
        let first = scanner.scan()
        let second = scanner.scan()
        XCTAssertFalse(first.contains { $0.pid == getpid() })
        XCTAssertEqual(Set(first.map(\.pid)).count, first.count)
        _ = second
    }
}
