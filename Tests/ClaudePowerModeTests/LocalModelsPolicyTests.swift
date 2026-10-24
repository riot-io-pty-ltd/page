import XCTest
@testable import ClaudePowerMode

final class LocalModelsPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let poll: TimeInterval = 10

    private func obs(_ busy: Bool, _ signal: LocalActivity.Signal, at seconds: TimeInterval, gpu: Double? = nil) -> LocalObservation {
        LocalObservation(busy: busy, signal: signal, at: t0.addingTimeInterval(seconds), gpuUtilization: gpu)
    }

    private func step(_ o: LocalObservation?, _ state: inout LocalActivityPolicy.State, at seconds: TimeInterval) -> LocalActivityPolicy.Verdict {
        LocalActivityPolicy.apply(o, to: &state, now: t0.addingTimeInterval(seconds), pollInterval: poll)
    }

    // MARK: policy

    func testLoadedButIdleNeverBusy() {
        var s = LocalActivityPolicy.State()
        for i in 0..<100 {
            let t = TimeInterval(i) * 10
            for signal in [LocalActivity.Signal.exact, .gpu, .terminalOutput, .none] {
                var st = s
                XCTAssertFalse(step(obs(false, signal, at: t), &st, at: t).busy)
            }
            XCTAssertFalse(step(obs(false, .exact, at: t), &s, at: t).busy)
        }
        XCTAssertEqual(step(obs(false, .exact, at: 1000), &s, at: 1000).detail, "idle")
        XCTAssertFalse(step(nil, &s, at: 1010).busy)
    }

    func testNoObservationYet() {
        var s = LocalActivityPolicy.State()
        let v = step(nil, &s, at: 0)
        XCTAssertFalse(v.busy)
        XCTAssertEqual(v.detail, "no signal yet")
    }

    func testLingerAfterNonExactBusy() {
        var s = LocalActivityPolicy.State()
        XCTAssertEqual(step(obs(true, .gpu, at: 0, gpu: 0.63), &s, at: 0), .init(busy: true, signal: .gpu, detail: "GPU 65%"))
        XCTAssertEqual(step(obs(false, .gpu, at: 10), &s, at: 10).detail, "just finished")
        XCTAssertTrue(step(obs(false, .gpu, at: 40), &s, at: 40).busy)
        XCTAssertTrue(step(obs(false, .gpu, at: 45), &s, at: 45).busy, "45 s inclusive")
        XCTAssertFalse(step(obs(false, .gpu, at: 50), &s, at: 50).busy)
    }

    func testExactIdleEndsLingerAfter15s() {
        var s = LocalActivityPolicy.State()
        XCTAssertEqual(step(obs(true, .exact, at: 0), &s, at: 0).detail, "generating · exact")
        XCTAssertTrue(step(obs(false, .exact, at: 10), &s, at: 10).busy, "too soon to end linger")
        XCTAssertFalse(step(obs(false, .exact, at: 20), &s, at: 20).busy)
        XCTAssertFalse(step(nil, &s, at: 25).busy, "stays ended")
        // A new busy reading restarts.
        XCTAssertTrue(step(obs(true, .exact, at: 30), &s, at: 30).busy)
    }

    func testStale() {
        var s = LocalActivityPolicy.State()
        XCTAssertTrue(step(obs(true, .exact, at: 0), &s, at: 0).busy)
        XCTAssertTrue(step(nil, &s, at: 30).busy, "stale only after max(3 × poll, 30 s)")
        let v = step(nil, &s, at: 31)
        XCTAssertFalse(v.busy, "linger would last to 45 s but there's no signal")
        XCTAssertEqual(v.detail, "no signal")
        XCTAssertEqual(LocalActivityPolicy.staleAfter(pollInterval: 5), 30)
        XCTAssertEqual(LocalActivityPolicy.staleAfter(pollInterval: 20), 60)
    }

    func testGPUCapAfter3hUntilIdleOnce() {
        var s = LocalActivityPolicy.State()
        var t: TimeInterval = 0
        while t <= 3 * 3600 {
            XCTAssertTrue(step(obs(true, .gpu, at: t, gpu: 0.4), &s, at: t).busy, "\(t)")
            t += 10
        }
        let capped = step(obs(true, .gpu, at: t, gpu: 0.4), &s, at: t)
        XCTAssertFalse(capped.busy)
        XCTAssertEqual(capped.detail, "capped after 3 h")
        XCTAssertFalse(step(obs(true, .gpu, at: t + 10, gpu: 0.4), &s, at: t + 10).busy, "stays capped")
        // Idle once clears the cap; busy counts again.
        XCTAssertFalse(step(obs(false, .gpu, at: t + 20), &s, at: t + 20).busy)
        XCTAssertTrue(step(obs(true, .gpu, at: t + 30, gpu: 0.4), &s, at: t + 30).busy)
    }

    func testTerminalCapAfter90Minutes() {
        var s = LocalActivityPolicy.State()
        var t: TimeInterval = 0
        while t <= 90 * 60 {
            XCTAssertTrue(step(obs(true, .terminalOutput, at: t), &s, at: t).busy)
            t += 10
        }
        let v = step(obs(true, .terminalOutput, at: t), &s, at: t)
        XCTAssertFalse(v.busy)
        XCTAssertEqual(v.detail, "capped after 90 min")
    }

    func testExactUncappedFor5h() {
        var s = LocalActivityPolicy.State()
        var t: TimeInterval = 0
        while t <= 5 * 3600 {
            XCTAssertTrue(step(obs(true, .exact, at: t), &s, at: t).busy, "\(t)")
            t += 10
        }
    }

    func testExactReadingLiftsAGPUCap() {
        var s = LocalActivityPolicy.State()
        _ = step(obs(true, .gpu, at: 0, gpu: 1), &s, at: 0)
        XCTAssertFalse(step(obs(true, .gpu, at: 3 * 3600 + 1, gpu: 1), &s, at: 3 * 3600 + 1).busy)
        XCTAssertTrue(step(obs(true, .exact, at: 3 * 3600 + 11), &s, at: 3 * 3600 + 11).busy)
    }

    func testPercentRounding() {
        XCTAssertEqual(LocalActivityPolicy.percent(0.63), 65)
        XCTAssertEqual(LocalActivityPolicy.percent(0.61), 60)
        XCTAssertEqual(LocalActivityPolicy.percent(1.4), 100)
        XCTAssertEqual(LocalActivityPolicy.percent(-1), 0)
    }

    // MARK: hysteresis

    func testGPUHysteresisTwoSampleEnter() {
        var h = GPUHysteresis()
        XCTAssertFalse(h.update(0.9), "one high sample isn't enough")
        XCTAssertFalse(h.update(0.2), "streak broken")
        XCTAssertFalse(h.update(0.3))
        XCTAssertTrue(h.update(0.25))
        XCTAssertTrue(h.update(0.1), "between exit and enter: hold")
        XCTAssertTrue(h.update(0.08))
        XCTAssertFalse(h.update(0.079))
        XCTAssertFalse(h.update(0.5))
        XCTAssertTrue(h.update(0.5))
    }

    func testUIAnimationLevelNeverEntersBusy() {
        var h = GPUHysteresis()
        for u in [0.02, 0.1, 0.2, 0.24, 0.05, 0.24] { XCTAssertFalse(h.update(u)) }
    }

    // MARK: aggregation

    private let at = Date(timeIntervalSince1970: 1_800_000_000)
    private func proc(_ kind: LocalProcess.Kind, _ pid: Int32, name: String = "x", port: Int? = nil, tty: String? = nil) -> LocalProcess {
        LocalProcess(kind: kind, pid: pid, name: name, declaredPort: port, ttyName: tty)
    }

    func testGrouping() {
        let procs = [
            proc(.ollamaServe, 10, name: "Ollama"), proc(.ollamaRunner, 11, name: "Ollama", port: 5000),
            proc(.lmStudio, 20), proc(.lmStudio, 21),
            proc(.llamaServer, 30, port: 8081), proc(.llamaServer, 31),
            proc(.mlx, 40), proc(.llamaCLI, 50, name: "llama-cli"),
            proc(.terminalAgent, 60, name: "opencode", tty: "ttys001"),
            proc(.terminalAgent, 61, name: "opencode", tty: "ttys001"),   // binary under the npm shim
            proc(.terminalAgent, 62, name: "ollama run", tty: "ttys002"),
        ]
        let groups = LocalActivityAggregator.groups(procs, ports: [31: [8090]])
        XCTAssertEqual(groups.map(\.id), ["agent:ollama-run:62", "agent:opencode:60", "llamacli:50", "llamacpp:8081", "llamacpp:8090",
                                          "lmstudio", "mlx:40", "ollama"])
        XCTAssertEqual(groups.first { $0.id == "ollama" }?.processes.map(\.pid), [10, 11])
        XCTAssertEqual(groups.first { $0.id == "lmstudio" }?.processes.count, 2)
        XCTAssertEqual(groups.first { $0.id == "llamacpp:8090" }?.displayName, "llama.cpp server :8090")
        XCTAssertEqual(groups.first { $0.id == "lmstudio" }?.kind, .app)
        XCTAssertEqual(groups.first { $0.id == "agent:opencode:60" }?.kind, .terminalTool)
        XCTAssertEqual(LocalActivityAggregator.groups([proc(.llamaServer, 7)]).first?.id, "llamacpp:pid7")
    }

    private func observe(_ procs: [LocalProcess], _ signals: [Int32: LocalProcessSignals]) -> LocalObservation? {
        let g = LocalActivityAggregator.groups(procs)
        XCTAssertEqual(g.count, 1)
        return LocalActivityAggregator.observe(g[0], signals: signals, at: at)
    }

    func testLMStudioAnyPidGPUBusy() {
        let procs = [proc(.lmStudio, 1), proc(.lmStudio, 2)]
        let busy = observe(procs, [1: .init(gpuBusy: false, gpuUtilization: 0.01), 2: .init(gpuBusy: true, gpuUtilization: 0.7)])
        XCTAssertEqual(busy?.busy, true)
        XCTAssertEqual(busy?.signal, .gpu)
        XCTAssertEqual(busy?.gpuUtilization, 0.7)
        XCTAssertEqual(observe(procs, [1: .init(gpuBusy: false), 2: .init(gpuBusy: false)])?.busy, false)
        XCTAssertNil(observe(procs, [:]), "no GPU reading (first sample / Intel) → no observation")
    }

    func testOllamaAggregation() {
        let serve = proc(.ollamaServe, 1)
        let r1 = proc(.ollamaRunner, 2), r2 = proc(.ollamaRunner, 3)
        // No runner = no model loaded: idle.
        let none = observe([serve], [:])
        XCTAssertEqual(none?.busy, false)
        XCTAssertEqual(none?.note, "no model loaded")
        // Any runner exact-busy.
        XCTAssertEqual(observe([serve, r1, r2], [2: .init(slots: .idle), 3: .init(slots: .busy)]),
                       LocalObservation(busy: true, signal: .exact, at: at))
        // All exact idle → exact idle.
        XCTAssertEqual(observe([serve, r1, r2], [2: .init(slots: .idle), 3: .init(slots: .idle)])?.signal, .exact)
        // Slots unavailable → that runner's GPU.
        let gpu = observe([serve, r1], [2: .init(slots: .unavailable, gpuBusy: true, gpuUtilization: 0.5)])
        XCTAssertEqual(gpu?.busy, true)
        XCTAssertEqual(gpu?.signal, .gpu)
        let mixedIdle = observe([serve, r1, r2], [2: .init(slots: .idle), 3: .init(slots: .unavailable, gpuBusy: false)])
        XCTAssertEqual(mixedIdle?.busy, false)
        XCTAssertEqual(mixedIdle?.signal, .gpu, "not all exact → no exact-idle linger cut")
        // A timed-out runner can't make the whole thing idle.
        XCTAssertNil(observe([serve, r1, r2], [2: .init(slots: .idle), 3: .init(slots: .noObservation, gpuBusy: false)]))
        // …but its GPU busy still counts.
        XCTAssertEqual(observe([serve, r1], [2: .init(slots: .noObservation, gpuBusy: true)])?.busy, true)
    }

    func testLlamaServerSlotsElseGPU() {
        let p = [proc(.llamaServer, 5, port: 8080)]
        XCTAssertEqual(observe(p, [5: .init(slots: .busy, gpuBusy: false)])?.signal, .exact)
        XCTAssertEqual(observe(p, [5: .init(slots: .idle, gpuBusy: true)]), LocalObservation(busy: false, signal: .exact, at: at), "exact wins over GPU")
        XCTAssertEqual(observe(p, [5: .init(slots: nil, gpuBusy: true)])?.signal, .gpu, "not probed (API key) → GPU")
        XCTAssertNil(observe(p, [5: .init(slots: .noObservation)]))
    }

    func testMLXAndCLIAndAgent() {
        XCTAssertEqual(observe([proc(.mlx, 1)], [1: .init(gpuBusy: true)])?.signal, .gpu)
        // llama-cli prefers GPU, falls back to terminal output.
        let cli = [proc(.llamaCLI, 2, tty: "ttys1")]
        XCTAssertEqual(observe(cli, [2: .init(gpuBusy: false, terminalRecent: true)]), LocalObservation(busy: false, signal: .gpu, at: at))
        XCTAssertEqual(observe(cli, [2: .init(terminalRecent: true)]), LocalObservation(busy: true, signal: .terminalOutput, at: at))
        XCTAssertNil(observe(cli, [:]))
        let agent = [proc(.terminalAgent, 3, name: "aider", tty: "ttys2")]
        XCTAssertEqual(observe(agent, [3: .init(gpuBusy: true, terminalRecent: false)]), LocalObservation(busy: false, signal: .terminalOutput, at: at),
                       "agents use terminal output only")
    }

    func testTerminalWindow() {
        let now = Date()
        XCTAssertEqual(LocalActivityAggregator.terminalRecent(modified: now.addingTimeInterval(-119), now: now), true)
        XCTAssertEqual(LocalActivityAggregator.terminalRecent(modified: now.addingTimeInterval(-121), now: now), false)
        XCTAssertNil(LocalActivityAggregator.terminalRecent(modified: nil, now: now))
    }

    // MARK: Equatable

    func testEquatableIgnoresTimestamps() {
        let a = LocalActivity(id: "ollama", displayName: "Ollama", kind: .server, busy: true, signal: .exact, detail: "generating · exact", lastBusyAt: Date())
        let b = LocalActivity(id: "ollama", displayName: "Ollama", kind: .server, busy: true, signal: .exact, detail: "generating · exact",
                              lastBusyAt: Date().addingTimeInterval(-100))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, LocalActivity(id: "ollama", displayName: "Ollama", kind: .server, busy: false, signal: .exact, detail: "generating · exact"))
        XCTAssertNotEqual(a, LocalActivity(id: "ollama", displayName: "Ollama", kind: .server, busy: true, signal: .exact, detail: "idle"))
    }
}
