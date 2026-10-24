import XCTest
@testable import ClaudePowerMode

/// LocalModelMonitor end to end with fake probes (no processes, no IOKit,
/// no network).
final class LocalModelsMonitorTests: XCTestCase {
    /// Mutable fake world, read by the probes on the monitor queue and
    /// written by the test between polls.
    private final class World: @unchecked Sendable {
        let lock = NSLock()
        var processes: [LocalProcess] = []
        var listening: [Int32: Set<Int>] = [:]
        var gpu: GPUSampler.Reading = .utilization([:])
        var slots: [Int: SlotsState] = [:]
        var slotsDelay: TimeInterval = 0
        var ttyMTime: [String: Date] = [:]
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var probedPorts: [Int] = []

        func with<T>(_ body: (World) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
    }

    private func makeMonitor(_ w: World, pollBudget: TimeInterval = 5) -> LocalModelMonitor {
        let probes = LocalModelMonitor.Probes(
            discover: { w.with { $0.processes } },
            listeningPorts: { pid in w.with { $0.listening[pid] } },
            gpu: { _ in w.with { $0.gpu } },
            slots: { port, completion in
                let (state, delay): (SlotsState, TimeInterval) = w.with { w in
                    w.probedPorts.append(port)
                    return (w.slots[port] ?? .noObservation, w.slotsDelay)
                }
                if delay > 0 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { completion(state) }
                } else {
                    completion(state)
                }
            },
            ttyModified: { tty in w.with { $0.ttyMTime[tty] } })
        return LocalModelMonitor(pollInterval: 10, pollBudget: pollBudget, now: { w.with { $0.now } }, probes: probes)
    }

    private func poll(_ m: LocalModelMonitor, timeout: TimeInterval = 3) {
        let done = expectation(description: "poll")
        m.pollNow { done.fulfill() }
        wait(for: [done], timeout: timeout)
    }

    private func advance(_ w: World, _ seconds: TimeInterval) {
        w.with { $0.now = $0.now.addingTimeInterval(seconds) }
    }

    func testIdleLoadedOllamaThenGenerating() {
        let w = World()
        w.processes = [LocalProcess(kind: .ollamaServe, pid: 10, name: "Ollama"),
                       LocalProcess(kind: .ollamaRunner, pid: 11, name: "Ollama", declaredPort: 5000)]
        w.listening = [11: [5000]]
        w.slots = [5000: .idle]
        let m = makeMonitor(w)
        poll(m)
        XCTAssertEqual(m.activities, [LocalActivity(id: "ollama", displayName: "Ollama", kind: .server, busy: false, signal: .exact, detail: "idle")])
        XCTAssertEqual(w.with { $0.probedPorts }, [5000])

        w.with { $0.slots[5000] = .busy }
        advance(w, 10)
        poll(m)
        XCTAssertEqual(m.activities.first?.busy, true)
        XCTAssertEqual(m.activities.first?.detail, "generating · exact")
        XCTAssertNotNil(m.activities.first?.lastBusyAt)

        // Exact idle 20 s after the last busy ends the linger.
        w.with { $0.slots[5000] = .idle }
        advance(w, 20)
        poll(m)
        XCTAssertEqual(m.activities.first?.busy, false)
    }

    func testOnChangeOnlyWhenListChanges() {
        let w = World()
        w.processes = [LocalProcess(kind: .llamaServer, pid: 30, name: "llama.cpp server", declaredPort: 8080)]
        w.listening = [30: [8080]]
        w.slots = [8080: .idle]
        let m = makeMonitor(w)
        var calls: [[LocalActivity]] = []
        let lock = NSLock()
        m.onChange = { list in lock.lock(); calls.append(list); lock.unlock() }
        poll(m)
        advance(w, 10); poll(m)
        advance(w, 10); poll(m)
        lock.lock(); XCTAssertEqual(calls.count, 1); lock.unlock()
        w.with { $0.slots[8080] = .busy }
        advance(w, 10); poll(m)
        lock.lock(); XCTAssertEqual(calls.count, 2); XCTAssertEqual(calls.last?.first?.busy, true); lock.unlock()
        // Busy and unchanged: lastBusyAt moves, but no onChange.
        advance(w, 10); poll(m)
        lock.lock(); XCTAssertEqual(calls.count, 2); lock.unlock()
    }

    func testNeverGuessesPortAndSkipsKeyedServer() {
        let w = World()
        w.processes = [
            LocalProcess(kind: .llamaServer, pid: 30, name: "llama.cpp server"),                              // no port anywhere
            LocalProcess(kind: .llamaServer, pid: 31, name: "llama.cpp server", declaredPort: 9000, hasAPIKey: true),
            LocalProcess(kind: .llamaServer, pid: 32, name: "llama.cpp server", declaredPort: 9100, host: "192.168.1.9"),
        ]
        w.listening = [30: [], 31: [9000], 32: [9100]]
        w.gpu = .utilization([:])
        let m = makeMonitor(w)
        poll(m)
        XCTAssertEqual(w.with { $0.probedPorts }, [])
        XCTAssertEqual(Set(m.activities.map(\.id)), ["llamacpp:pid30", "llamacpp:9000", "llamacpp:9100"])
        XCTAssertTrue(m.activities.allSatisfy { !$0.busy })
    }

    func testSlotsTimeoutBudgetIsNoObservationNotIdle() {
        let w = World()
        w.processes = [LocalProcess(kind: .llamaServer, pid: 30, name: "llama.cpp server", declaredPort: 8080)]
        w.listening = [30: [8080]]
        w.slots = [8080: .busy]
        let m = makeMonitor(w, pollBudget: 0.3)
        poll(m)
        XCTAssertEqual(m.activities.first?.busy, true)
        // The server stops answering within the budget: keep busy (linger)
        // until stale — never flip to idle on a timeout.
        w.with { $0.slotsDelay = 1.0; $0.slots[8080] = .idle }
        advance(w, 10)
        poll(m)
        XCTAssertEqual(m.activities.first?.busy, true)
        advance(w, 25)
        poll(m)
        XCTAssertEqual(m.activities.first?.busy, false, "stale after 30 s without an observation")
        XCTAssertEqual(m.activities.first?.detail, "no signal")
    }

    func testGPUHysteresisThroughMonitorAndActivityDisappears() {
        let w = World()
        w.processes = [LocalProcess(kind: .lmStudio, pid: 20, name: "LM Studio"), LocalProcess(kind: .lmStudio, pid: 21, name: "LM Studio")]
        w.gpu = .utilization([20: 0.02, 21: 0.6])
        let m = makeMonitor(w)
        poll(m)
        XCTAssertEqual(m.activities.first?.busy, false, "one high sample")
        advance(w, 10); poll(m)
        XCTAssertEqual(m.activities.first?.busy, true)
        XCTAssertEqual(m.activities.first?.detail, "GPU 60%")
        XCTAssertEqual(m.activities.first?.kind, .app)
        // Process gone → activity gone.
        w.with { $0.processes = [] }
        advance(w, 10); poll(m)
        XCTAssertEqual(m.activities, [])
    }

    func testGPUUnavailableNeverBusy() {
        let w = World()
        w.processes = [LocalProcess(kind: .mlx, pid: 40, name: "MLX")]
        w.gpu = .unavailable
        let m = makeMonitor(w)
        poll(m); advance(w, 10); poll(m)
        XCTAssertEqual(m.activities.first?.busy, false)
        XCTAssertTrue(m.diagnostics().contains("GPU sampler: unavailable"))
    }

    func testTerminalAgentByTTYWrites() {
        let w = World()
        w.processes = [LocalProcess(kind: .terminalAgent, pid: 60, name: "opencode", ttyName: "ttys001")]
        w.ttyMTime = ["ttys001": w.now.addingTimeInterval(-5)]
        let m = makeMonitor(w)
        poll(m)
        XCTAssertEqual(m.activities, [LocalActivity(id: "agent:opencode:60", displayName: "opencode", kind: .terminalTool, busy: true,
                                                    signal: .terminalOutput, detail: "terminal active")])
        advance(w, 200)
        poll(m)
        XCTAssertEqual(m.activities.first?.busy, false)
    }

    func testSetEnabledFalseClearsAndStopsPublishing() {
        let w = World()
        w.processes = [LocalProcess(kind: .llamaServer, pid: 30, name: "llama.cpp server", declaredPort: 8080)]
        w.listening = [30: [8080]]
        w.slots = [8080: .busy]
        let m = makeMonitor(w)
        let cleared = expectation(description: "onChange([])")
        poll(m)
        XCTAssertEqual(m.activities.count, 1)
        m.onChange = { list in if list.isEmpty { cleared.fulfill() } }
        m.setEnabled(false)
        XCTAssertEqual(m.activities, [], "cleared at once")
        wait(for: [cleared], timeout: 2)
        poll(m)
        XCTAssertEqual(m.activities, [], "disabled monitor doesn't poll")
        XCTAssertTrue(m.diagnostics().contains("disabled"))
    }

    func testDiagnosticsHaveNoSecretsOrPaths() {
        let w = World()
        w.processes = [LocalProcess(kind: .ollamaServe, pid: 10, name: "Ollama"),
                       LocalProcess(kind: .ollamaRunner, pid: 11, name: "Ollama", declaredPort: 5000),
                       LocalProcess(kind: .llamaServer, pid: 31, name: "llama.cpp server", declaredPort: 9000, hasAPIKey: true)]
        w.listening = [11: [5000], 31: [9000]]
        w.slots = [5000: .busy]
        w.gpu = .utilization([11: 0.9, 31: 0.0])
        let m = makeMonitor(w)
        poll(m)
        let d = m.diagnostics()
        XCTAssertTrue(d.contains("ollamaRunner pid 11"), d)
        XCTAssertTrue(d.contains("ports 5000"), d)
        XCTAssertTrue(d.contains("slots busy"), d)
        XCTAssertTrue(d.contains("GPU 90%"), d)
        XCTAssertTrue(d.contains("slots not probed (non-loopback, API key or --no-slots)"), d)
        XCTAssertTrue(d.contains("ollama · Ollama · BUSY"), d)
        XCTAssertFalse(d.contains("/"), "no paths: \(d)")
    }

    func testStartPollsOnTimer() {
        let w = World()
        w.processes = [LocalProcess(kind: .ollamaServe, pid: 10, name: "Ollama")]
        let m = makeMonitor(w)
        let changed = expectation(description: "first poll")
        m.onChange = { list in if !list.isEmpty { changed.fulfill() } }
        m.start()
        wait(for: [changed], timeout: 3)
        XCTAssertEqual(m.activities.first?.detail, "idle · no model loaded")
        let stopped = expectation(description: "stopped")
        m.onChange = { list in if list.isEmpty { stopped.fulfill() } }
        m.stop()
        wait(for: [stopped], timeout: 2)
        XCTAssertEqual(m.activities, [], "a stopped monitor reports nothing")
    }
}
