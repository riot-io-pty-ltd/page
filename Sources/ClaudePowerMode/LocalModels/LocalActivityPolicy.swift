import Foundation

/// One reading of whether an activity is working right now.
struct LocalObservation: Equatable {
    let busy: Bool
    let signal: LocalActivity.Signal
    let at: Date
    /// Highest GPU utilization behind a `.gpu` reading, for the detail text.
    var gpuUtilization: Double? = nil
    /// Extra idle wording ("no model loaded").
    var note: String? = nil
}

/// Pure GPU hysteresis for one process: enter busy at ≥ 0.25 on two
/// consecutive samples, leave below 0.08, hold in between. 0.25 sits well
/// above UI compositing (LM Studio's and Ollama's GUIs animate).
struct GPUHysteresis: Equatable {
    static let enter = 0.25
    static let exit = 0.08
    static let enterSamples = 2

    private(set) var busy = false
    private var highStreak = 0

    mutating func update(_ utilization: Double) -> Bool {
        if busy {
            if utilization < Self.exit { busy = false; highStreak = 0 }
        } else if utilization >= Self.enter {
            highStreak += 1
            if highStreak >= Self.enterSamples { busy = true }
        } else {
            highStreak = 0
        }
        return busy
    }
}

/// Pure per-activity busy policy.
///
/// - busy only after a positive observation; lingers 45 s after the last
///   one, except that an exact idle reading ends the linger once ≥ 15 s
///   have passed since the last busy reading;
/// - no observation for longer than max(3 × poll, 30 s) → not busy;
/// - non-exact signals are capped (GPU 3 h, terminal output 90 min of
///   continuous busy) until the signal reads idle once; exact is uncapped.
enum LocalActivityPolicy {
    static let linger: TimeInterval = 45
    static let exactIdleEndsLingerAfter: TimeInterval = 15
    static let gpuCap: TimeInterval = 3 * 3600
    static let terminalCap: TimeInterval = 90 * 60

    static func staleAfter(pollInterval: TimeInterval) -> TimeInterval {
        max(3 * pollInterval, 30)
    }

    static func cap(for signal: LocalActivity.Signal) -> TimeInterval? {
        switch signal {
        case .gpu: return gpuCap
        case .terminalOutput: return terminalCap
        case .exact, .none: return nil
        }
    }

    static func capText(_ signal: LocalActivity.Signal) -> String {
        signal == .gpu ? "capped after 3 h" : "capped after 90 min"
    }

    struct State: Equatable {
        var last: LocalObservation?
        var lastBusyAt: Date?
        var lastBusy: LocalObservation?
        /// An exact idle reading ended the current linger.
        var lingerEnded = false
        /// Start and signal of the current continuous non-exact busy run.
        var streakSince: Date?
        var streakSignal: LocalActivity.Signal?
        var capped = false
    }

    struct Verdict: Equatable {
        let busy: Bool
        let signal: LocalActivity.Signal
        let detail: String
    }

    static func apply(_ observation: LocalObservation?, to state: inout State, now: Date, pollInterval: TimeInterval) -> Verdict {
        if let o = observation {
            // A gap without readings (the Mac slept, polling stopped) or a
            // wall clock set backwards breaks continuity: a run that was busy
            // before the gap must not hit its cap the moment the Mac wakes.
            if let prev = state.last {
                let gap = o.at.timeIntervalSince(prev.at)
                if gap < 0 || gap > staleAfter(pollInterval: pollInterval) {
                    state.streakSince = nil
                    state.streakSignal = nil
                    if gap < 0 { state.lastBusyAt = nil; state.lastBusy = nil }
                }
            }
            state.last = o
            if o.busy {
                state.lastBusyAt = o.at
                state.lastBusy = o
                state.lingerEnded = false
                if cap(for: o.signal) == nil {
                    // Exact readings are trusted for any length of time.
                    state.streakSince = nil
                    state.streakSignal = nil
                    state.capped = false
                } else if state.streakSince == nil || state.streakSignal != o.signal {
                    state.streakSince = o.at
                    state.streakSignal = o.signal
                }
            } else {
                // A capped run wasn't counted, so there's nothing to linger on.
                if state.capped { state.lingerEnded = true }
                state.capped = false
                state.streakSince = nil
                state.streakSignal = nil
                if o.signal == .exact, let lastBusy = state.lastBusyAt,
                   o.at.timeIntervalSince(lastBusy) >= exactIdleEndsLingerAfter {
                    state.lingerEnded = true
                }
            }
        }

        // A reading "from the future" (clock set backwards) is as good as none.
        guard let last = state.last, (0...staleAfter(pollInterval: pollInterval)).contains(now.timeIntervalSince(last.at)) else {
            if !state.capped { state.streakSince = nil; state.streakSignal = nil }
            return Verdict(busy: false, signal: .none, detail: state.last == nil ? "no signal yet" : "no signal")
        }

        let lingering: Bool = {
            guard let lastBusyAt = state.lastBusyAt, !state.lingerEnded else { return false }
            return (0...linger).contains(now.timeIntervalSince(lastBusyAt))
        }()
        guard lingering, let busyObs = state.lastBusy else {
            if !state.capped { state.streakSince = nil; state.streakSignal = nil }
            return Verdict(busy: false, signal: last.signal, detail: idleDetail(last))
        }

        if let since = state.streakSince, let signal = state.streakSignal, let limit = cap(for: signal),
           now.timeIntervalSince(since) > limit {
            state.capped = true
        }
        if state.capped {
            return Verdict(busy: false, signal: state.streakSignal ?? busyObs.signal, detail: capText(state.streakSignal ?? busyObs.signal))
        }
        if last.busy {
            return Verdict(busy: true, signal: busyObs.signal, detail: busyDetail(busyObs))
        }
        return Verdict(busy: true, signal: busyObs.signal, detail: "just finished")
    }

    static func busyDetail(_ o: LocalObservation) -> String {
        switch o.signal {
        case .exact: return "generating · exact"
        case .gpu: return o.gpuUtilization.map { "GPU \(percent($0))%" } ?? "GPU busy"
        case .terminalOutput: return "terminal active"
        case .none: return "busy"
        }
    }

    static func idleDetail(_ o: LocalObservation) -> String {
        o.note.map { "idle · \($0)" } ?? "idle"
    }

    /// Rounded to 5 % so a busy model doesn't change the list (and fire
    /// `onChange`) on every poll.
    static func percent(_ utilization: Double) -> Int {
        Int((min(1, max(0, utilization)) * 20).rounded()) * 5
    }
}

/// Per-process readings gathered in one poll.
struct LocalProcessSignals: Equatable {
    /// nil = not probed (no /slots for this kind, no port, or disallowed).
    var slots: SlotsState? = nil
    /// Hysteresis output; nil = no GPU reading this poll.
    var gpuBusy: Bool? = nil
    var gpuUtilization: Double? = nil
    /// Terminal written within the window; nil = no tty / unreadable.
    var terminalRecent: Bool? = nil
}

/// Processes that make up one logical activity.
struct LocalActivityGroup: Equatable {
    enum Family: String, Equatable {
        case ollama, lmStudio, llamaServer, mlx, llamaCLI, terminalAgent
    }

    let id: String
    let displayName: String
    let kind: LocalActivity.Kind
    let family: Family
    let processes: [LocalProcess]
}

/// Pure grouping of processes into activities and per-activity aggregation.
enum LocalActivityAggregator {
    static let terminalWindow: TimeInterval = 120

    /// `ports` = ports chosen per server pid (`LocalPortSelection`).
    static func groups(_ processes: [LocalProcess], ports: [Int32: [Int]] = [:]) -> [LocalActivityGroup] {
        var out: [LocalActivityGroup] = []
        let ollama = processes.filter { $0.kind == .ollamaServe || $0.kind == .ollamaRunner }
        if !ollama.isEmpty {
            out.append(LocalActivityGroup(id: "ollama", displayName: "Ollama", kind: .server, family: .ollama, processes: ollama))
        }
        let lms = processes.filter { $0.kind == .lmStudio }
        if !lms.isEmpty {
            out.append(LocalActivityGroup(id: "lmstudio", displayName: "LM Studio", kind: .app, family: .lmStudio, processes: lms))
        }
        var agentsSeen = Set<String>()
        var serverPorts = Set<Int>()
        for p in processes.sorted(by: { $0.pid < $1.pid }) {
            switch p.kind {
            case .llamaServer:
                // Two servers can claim one port (one still loading or
                // failed to bind with the same --port); ids must stay unique
                // or they'd share policy state.
                var port = ports[p.pid]?.first ?? p.declaredPort
                if let claimed = port, !serverPorts.insert(claimed).inserted { port = nil }
                out.append(LocalActivityGroup(
                    id: port.map { "llamacpp:\($0)" } ?? "llamacpp:pid\(p.pid)",
                    displayName: port.map { "llama.cpp server :\($0)" } ?? "llama.cpp server",
                    kind: .server, family: .llamaServer, processes: [p]))
            case .mlx:
                out.append(LocalActivityGroup(id: "mlx:\(p.pid)", displayName: "MLX", kind: .server, family: .mlx, processes: [p]))
            case .llamaCLI:
                out.append(LocalActivityGroup(id: "llamacli:\(p.pid)", displayName: p.name, kind: .terminalTool, family: .llamaCLI, processes: [p]))
            case .terminalAgent:
                // A launcher and the binary it starts (npm's opencode shim)
                // share a name and tty: one activity, lowest pid.
                guard agentsSeen.insert("\(p.name)|\(p.ttyName ?? "")").inserted else { continue }
                let slug = p.name.replacingOccurrences(of: " ", with: "-")
                out.append(LocalActivityGroup(id: "agent:\(slug):\(p.pid)", displayName: p.name, kind: .terminalTool, family: .terminalAgent, processes: [p]))
            case .ollamaServe, .ollamaRunner, .lmStudio:
                break
            }
        }
        return out.sorted { $0.id < $1.id }
    }

    /// One observation for the group, or nil when nothing usable was seen
    /// (the policy then keeps the last one until it goes stale).
    static func observe(_ group: LocalActivityGroup, signals: [Int32: LocalProcessSignals], at: Date) -> LocalObservation? {
        switch group.family {
        case .lmStudio, .mlx:
            return gpuObservation(group.processes.map { signals[$0.pid] ?? LocalProcessSignals() }, at: at)
        case .ollama:
            let runners = group.processes.filter { $0.kind == .ollamaRunner }
            if runners.isEmpty {
                return LocalObservation(busy: false, signal: .none, at: at, note: "no model loaded")
            }
            return combineServers(runners.map { signals[$0.pid] ?? LocalProcessSignals() }, at: at)
        case .llamaServer:
            return combineServers(group.processes.map { signals[$0.pid] ?? LocalProcessSignals() }, at: at)
        case .llamaCLI:
            let s = group.processes.map { signals[$0.pid] ?? LocalProcessSignals() }
            if let gpu = gpuObservation(s, at: at) { return gpu }
            return terminalObservation(s, at: at)
        case .terminalAgent:
            return terminalObservation(group.processes.map { signals[$0.pid] ?? LocalProcessSignals() }, at: at)
        }
    }

    private enum ServerReading {
        case exactBusy, exactIdle, gpuBusy(Double?), gpuIdle, nothing
    }

    /// Per server process: slots first; when slots are unavailable (or not
    /// probed) fall back to its GPU. A probe that got no answer can only be
    /// rescued by GPU *busy* — a timeout must never read as idle.
    private static func reading(_ s: LocalProcessSignals) -> ServerReading {
        switch s.slots {
        case .busy?: return .exactBusy
        case .idle?: return .exactIdle
        case .unavailable?, nil:
            switch s.gpuBusy {
            case true?: return .gpuBusy(s.gpuUtilization)
            case false?: return .gpuIdle
            case nil: return .nothing
            }
        case .noObservation?:
            return s.gpuBusy == true ? .gpuBusy(s.gpuUtilization) : .nothing
        }
    }

    /// Any busy wins; otherwise idle only if every process gave a reading
    /// (exact when all were exact).
    private static func combineServers(_ all: [LocalProcessSignals], at: Date) -> LocalObservation? {
        let readings = all.map(reading)
        if readings.contains(where: { if case .exactBusy = $0 { return true }; return false }) {
            return LocalObservation(busy: true, signal: .exact, at: at)
        }
        let gpuBusy: [Double?] = readings.compactMap { if case .gpuBusy(let u) = $0 { return u }; return nil }
        if !gpuBusy.isEmpty {
            return LocalObservation(busy: true, signal: .gpu, at: at, gpuUtilization: gpuBusy.compactMap { $0 }.max())
        }
        guard !readings.isEmpty, !readings.contains(where: { if case .nothing = $0 { return true }; return false }) else { return nil }
        let allExact = readings.allSatisfy { if case .exactIdle = $0 { return true }; return false }
        return LocalObservation(busy: false, signal: allExact ? .exact : .gpu, at: at)
    }

    private static func gpuObservation(_ all: [LocalProcessSignals], at: Date) -> LocalObservation? {
        let read = all.filter { $0.gpuBusy != nil }
        guard !read.isEmpty else { return nil }
        let busy = read.filter { $0.gpuBusy == true }
        let util = (busy.isEmpty ? read : busy).compactMap(\.gpuUtilization).max()
        return LocalObservation(busy: !busy.isEmpty, signal: .gpu, at: at, gpuUtilization: util)
    }

    private static func terminalObservation(_ all: [LocalProcessSignals], at: Date) -> LocalObservation? {
        let read = all.compactMap(\.terminalRecent)
        guard !read.isEmpty else { return nil }
        return LocalObservation(busy: read.contains(true), signal: .terminalOutput, at: at)
    }

    /// Pure: terminal output counts as activity within `terminalWindow`.
    static func terminalRecent(modified: Date?, now: Date) -> Bool? {
        guard let modified else { return nil }
        return now.timeIntervalSince(modified) <= terminalWindow
    }
}
