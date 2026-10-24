import Foundation

/// Watches local inference (Ollama, LM Studio, llama.cpp, MLX, llama-cli,
/// terminal agents) and reports which of it is working right now, so Page
/// can keep the Mac awake for it. Power-only: it never types, never stops
/// or signals a process and never talks to anything but 127.0.0.1.
///
/// Each poll: discover processes (libproc), one IOKit GPU sample for the
/// relevant pids, terminal mtimes, and concurrent `/slots` probes within a
/// 5 s budget; then the pure aggregator and policy decide. Polls every
/// `pollInterval` while any candidate process exists, every
/// `discoveryInterval` (discovery only) otherwise; at most one poll in
/// flight. Everything runs on the monitor's own serial queue.
final class LocalModelMonitor: @unchecked Sendable {
    /// Injectable side effects. `live()` is the real thing.
    struct Probes {
        var discover: () -> [LocalProcess]
        var listeningPorts: (Int32) -> Set<Int>?
        var gpu: (Set<Int32>) -> GPUSampler.Reading
        var slots: (_ port: Int, _ completion: @escaping (SlotsState) -> Void) -> Void
        var ttyModified: (String) -> Date?
        var teardown: () -> Void = {}

        static func live(home: String = NSHomeDirectory()) -> Probes {
            let scanner = LocalProcessScanner(home: home)
            let sampler = GPUSampler()
            let http = LoopbackHTTP()
            return Probes(
                discover: { scanner.scan() },
                listeningPorts: { LocalProcInfo.listeningTCPPorts($0) },
                gpu: { sampler.sample(pids: $0) },
                slots: { port, completion in http.slots(port: port, completion: completion) },
                ttyModified: { LocalProcInfo.ttyModified($0) },
                teardown: { http.invalidate() })
        }
    }

    private static let gpuKinds: Set<LocalProcess.Kind> = [.ollamaRunner, .llamaServer, .lmStudio, .mlx, .llamaCLI]

    let pollInterval: TimeInterval
    let discoveryInterval: TimeInterval
    let pollBudget: TimeInterval
    private let now: () -> Date
    private let probes: Probes
    private let queue = DispatchQueue(label: "ClaudePowerMode.localModels")

    // Under `lock`.
    private let lock = NSLock()
    private var enabled = true
    private var current: [LocalActivity] = []
    private var changeHandler: (([LocalActivity]) -> Void)?
    private var snapshot = Snapshot()

    // On `queue`.
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var inFlight = false
    private var policyStates: [String: LocalActivityPolicy.State] = [:]
    private var hysteresis: [Int32: GPUHysteresis] = [:]
    private var announced: [LocalActivity] = []

    /// Called on the monitor queue, only when the list changed (timestamps
    /// don't count).
    var onChange: (([LocalActivity]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return changeHandler }
        set { lock.lock(); changeHandler = newValue; lock.unlock() }
    }

    /// Thread-safe value copy.
    var activities: [LocalActivity] {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    init(pollInterval: TimeInterval = 10,
         discoveryInterval: TimeInterval = 30,
         pollBudget: TimeInterval = 5,
         now: @escaping () -> Date = Date.init,
         probes: Probes = .live()) {
        self.pollInterval = pollInterval
        self.discoveryInterval = max(discoveryInterval, pollInterval)
        self.pollBudget = pollBudget
        self.now = now
        self.probes = probes
    }

    deinit {
        timer?.cancel()
        probes.teardown()
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    /// Stops polling and forgets what was seen: a stopped monitor never
    /// reports anything busy.
    func stop() {
        queue.async { self.stopOnQueue() }
    }

    /// Off → stop polling, `activities` = [] at once. On → start.
    func setEnabled(_ on: Bool) {
        lock.lock()
        enabled = on
        if !on { current = [] }
        lock.unlock()
        if on { start() } else { stop() }
    }

    /// One poll now (tests and "refresh"); `completion` runs on the monitor
    /// queue after it published, or at once if disabled / already polling.
    func pollNow(completion: (() -> Void)? = nil) {
        queue.async { self.runPoll(completion: completion) }
    }

    // MARK: queue

    private var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    private func startOnQueue() {
        guard isEnabled, timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.setEventHandler { [weak self] in self?.runPoll(completion: nil) }
        t.schedule(deadline: .now())
        t.resume()
        timer = t
    }

    private func stopOnQueue() {
        timer?.cancel()
        timer = nil
        generation += 1
        inFlight = false
        policyStates = [:]
        hysteresis = [:]
        publish([], force: true)
    }

    private func scheduleNext(anyCandidate: Bool) {
        timer?.schedule(deadline: .now() + (anyCandidate ? pollInterval : discoveryInterval), leeway: .seconds(1))
    }

    private func runPoll(completion: (() -> Void)?) {
        guard isEnabled, !inFlight else { completion?(); return }
        inFlight = true
        let gen = generation
        let at = now()
        let processes = probes.discover()

        var ports: [Int32: [Int]] = [:]
        for p in processes where p.kind == .ollamaRunner || p.kind == .llamaServer {
            ports[p.pid] = LocalPortSelection.ports(listening: probes.listeningPorts(p.pid), declared: p.declaredPort)
        }
        let groups = LocalActivityAggregator.groups(processes, ports: ports)
        var signals: [Int32: LocalProcessSignals] = [:]

        let gpuPids = Set(processes.filter { Self.gpuKinds.contains($0.kind) }.map(\.pid))
        var gpuAvailable: Bool?
        if !gpuPids.isEmpty {
            switch probes.gpu(gpuPids) {
            case .unavailable:
                gpuAvailable = false
            case .utilization(let utilization):
                gpuAvailable = true
                for (pid, u) in utilization {
                    var h = hysteresis[pid] ?? GPUHysteresis()
                    let busy = h.update(u)
                    hysteresis[pid] = h
                    signals[pid, default: LocalProcessSignals()].gpuBusy = busy
                    signals[pid, default: LocalProcessSignals()].gpuUtilization = u
                }
            }
        }
        hysteresis = hysteresis.filter { gpuPids.contains($0.key) }

        for p in processes where p.kind == .llamaCLI || p.kind == .terminalAgent {
            guard let tty = p.ttyName else { continue }
            signals[p.pid, default: LocalProcessSignals()].terminalRecent =
                LocalActivityAggregator.terminalRecent(modified: probes.ttyModified(tty), now: at)
        }

        let targets: [(pid: Int32, port: Int)] = processes.compactMap { p in
            guard LocalProcessClassifier.shouldProbeSlots(p), let port = ports[p.pid]?.first else { return nil }
            return (p.pid, port)
        }
        // Unanswered by the budget = no observation, never idle.
        for t in targets { signals[t.pid, default: LocalProcessSignals()].slots = .noObservation }

        let answers = SlotsAnswers()
        let group = DispatchGroup()
        for t in targets {
            group.enter()
            probes.slots(t.port) { state in
                answers.set(t.pid, state)
                group.leave()
            }
        }

        var finished = false
        let finish: () -> Void = { [weak self] in
            guard let self, !finished else { return }
            finished = true
            guard gen == self.generation else { completion?(); return }
            var merged = signals
            for (pid, state) in answers.all() { merged[pid, default: LocalProcessSignals()].slots = state }
            self.complete(processes: processes, groups: groups, ports: ports, signals: merged, gpuAvailable: gpuAvailable, at: at)
            self.inFlight = false
            self.scheduleNext(anyCandidate: !processes.isEmpty)
            completion?()
        }
        group.notify(queue: queue, execute: finish)
        queue.asyncAfter(deadline: .now() + pollBudget, execute: finish)
    }

    private func complete(processes: [LocalProcess], groups: [LocalActivityGroup], ports: [Int32: [Int]],
                          signals: [Int32: LocalProcessSignals], gpuAvailable: Bool?, at: Date) {
        var states: [String: LocalActivityPolicy.State] = [:]
        var list: [LocalActivity] = []
        for g in groups {
            var state = policyStates[g.id] ?? LocalActivityPolicy.State()
            let observation = LocalActivityAggregator.observe(g, signals: signals, at: at)
            let verdict = LocalActivityPolicy.apply(observation, to: &state, now: at, pollInterval: pollInterval)
            states[g.id] = state
            list.append(LocalActivity(id: g.id, displayName: g.displayName, kind: g.kind, busy: verdict.busy,
                                      signal: verdict.signal, detail: verdict.detail, lastBusyAt: state.lastBusyAt))
        }
        let previous = activities
        for a in list where a.busy != (previous.first { $0.id == a.id }?.busy ?? false) {
            Logger.shared.log("LocalModels: \(a.displayName) \(a.busy ? "busy" : "idle") (\(a.detail))")
        }
        policyStates = states

        let diag = Snapshot(
            at: at, gpuAvailable: gpuAvailable,
            processes: processes.map { p in
                let s = signals[p.pid]
                return ProcessDiag(kind: p.kind, pid: p.pid, name: p.name, ports: ports[p.pid] ?? [],
                                   slots: s?.slots, gpu: s?.gpuUtilization, gpuBusy: s?.gpuBusy,
                                   terminalRecent: s?.terminalRecent, probed: LocalProcessClassifier.shouldProbeSlots(p))
            },
            activities: list.map { a in (a, states[a.id] ?? LocalActivityPolicy.State()) })
        lock.lock(); snapshot = diag; lock.unlock()
        publish(list, force: false)
    }

    /// Stores and announces the list when it changed. Unless forced (stop),
    /// a disabled monitor publishes nothing — `setEnabled(false)` already
    /// cleared the list and an in-flight poll must not bring it back.
    private func publish(_ list: [LocalActivity], force: Bool) {
        lock.lock()
        guard enabled || force else { lock.unlock(); return }
        current = list
        let handler = changeHandler
        lock.unlock()
        // Compared with what was last announced, not with `current`:
        // `setEnabled(false)` empties `current` synchronously and the empty
        // list must still be announced.
        guard list != announced else { return }
        announced = list
        handler?(list)
    }

    // MARK: diagnostics

    private struct ProcessDiag {
        let kind: LocalProcess.Kind
        let pid: Int32
        let name: String
        let ports: [Int]
        let slots: SlotsState?
        let gpu: Double?
        let gpuBusy: Bool?
        let terminalRecent: Bool?
        let probed: Bool
    }

    private struct Snapshot {
        var at: Date?
        var gpuAvailable: Bool?
        var processes: [ProcessDiag] = []
        var activities: [(LocalActivity, LocalActivityPolicy.State)] = []
    }

    /// Multi-line text for "Copy diagnostics": kinds, pids, display names,
    /// ports, signals and policy state. No argv, environment values,
    /// paths or prompts.
    func diagnostics() -> String {
        lock.lock()
        let s = snapshot
        let on = enabled
        lock.unlock()
        let reference = s.at ?? now()
        let iso = ISO8601DateFormatter()
        func ago(_ d: Date?) -> String {
            guard let d else { return "never" }
            return "\(Int(reference.timeIntervalSince(d).rounded())) s ago"
        }

        var lines: [String] = []
        lines.append("Local models: \(on ? "enabled" : "disabled") · poll \(Int(pollInterval)) s (\(Int(discoveryInterval)) s when none running) · last poll \(s.at.map { iso.string(from: $0) } ?? "never")")
        switch s.gpuAvailable {
        case true?: lines.append("GPU sampler: available")
        case false?: lines.append("GPU sampler: unavailable (no Apple-GPU user clients — Intel Mac?)")
        case nil: lines.append("GPU sampler: not sampled (no GPU-signal process)")
        }
        lines.append("Processes (\(s.processes.count)):")
        for p in s.processes {
            var parts = ["\(p.kind.rawValue) pid \(p.pid)", p.name]
            if !p.ports.isEmpty { parts.append("ports " + p.ports.map(String.init).joined(separator: ",")) }
            if let slots = p.slots { parts.append("slots \(slots.rawValue)") } else if p.kind == .ollamaRunner || p.kind == .llamaServer {
                parts.append(p.probed ? "slots not probed (no port)" : "slots not probed (non-loopback, API key or --no-slots)")
            }
            if let gpu = p.gpu { parts.append("GPU \(Int((gpu * 100).rounded()))%\(p.gpuBusy == true ? " (busy)" : "")") }
            if let t = p.terminalRecent { parts.append(t ? "terminal active" : "terminal quiet") }
            lines.append("  " + parts.joined(separator: " · "))
        }
        lines.append("Activities (\(s.activities.count)):")
        for (a, st) in s.activities {
            var parts = [a.id, a.displayName, a.busy ? "BUSY" : "not busy", "signal \(a.signal.rawValue)", a.detail,
                         "last busy \(ago(st.lastBusyAt))"]
            if st.lingerEnded { parts.append("linger ended by exact idle") }
            if let since = st.streakSince, let sig = st.streakSignal { parts.append("\(sig.rawValue) busy since \(ago(since))") }
            if st.capped { parts.append("capped") }
            lines.append("  " + parts.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }
}

/// Slots answers arriving on the HTTP session's queue.
private final class SlotsAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Int32: SlotsState] = [:]

    func set(_ pid: Int32, _ state: SlotsState) {
        lock.lock(); answers[pid] = state; lock.unlock()
    }

    func all() -> [Int32: SlotsState] {
        lock.lock(); defer { lock.unlock() }
        return answers
    }
}
