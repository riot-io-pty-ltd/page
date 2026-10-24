import XCTest
@testable import ClaudePowerMode

/// The scanner's caching rules against a fake process table, the monitor's
/// polling cadence, and llamafile under the APE loader.
final class LocalModelsScannerCadenceTests: XCTestCase {
    private final class Table {
        var entries: [LocalProcInfo.Entry] = []
        var paths: [Int32: String] = [:]
        var argv: [Int32: [String]] = [:]
        var argvFails: Set<Int32> = []
        var argvReads: [Int32] = []
        var pathReads = 0

        func add(_ pid: Int32, ppid: Int32 = 1, path: String, argv: [String] = [], start: UInt64 = 100, tty: UInt32 = UInt32.max) {
            entries.append(LocalProcInfo.Entry(pid: pid, info: .init(ppid: ppid, tdev: tty, startSeconds: start),
                                               startMicros: 0, comm: String((path as NSString).lastPathComponent.prefix(16))))
            paths[pid] = path
            self.argv[pid] = argv
        }

        func scanner() -> LocalProcessScanner {
            var r = LocalProcessScanner.Readers()
            r.allProcesses = { self.entries }
            r.execPath = { self.pathReads += 1; return self.paths[$0] }
            r.procArgs = { pid in
                self.argvReads.append(pid)
                guard !self.argvFails.contains(pid), let a = self.argv[pid] else { return nil }
                return ProcArgs.Info(argv: a, env: [:])
            }
            r.ttyName = { $0 == UInt32.max ? nil : "ttys00\($0)" }
            return LocalProcessScanner(home: "/Users/alex", readers: r)
        }
    }

    func testArgvFailureIsRetriedNotCached() {
        let t = Table()
        t.add(20, path: "/opt/homebrew/bin/llama-server", argv: ["llama-server", "--port", "8081"])
        t.argvFails = [20]
        let s = t.scanner()
        let first = s.scan()
        XCTAssertEqual(first.first?.declaredPort, nil, "classified without argv this poll")
        t.argvFails = []
        let second = s.scan()
        XCTAssertEqual(second.first?.declaredPort, 8081, "re-read once argv is available")
        _ = s.scan()
        XCTAssertEqual(t.argvReads, [20, 20], "cached once argv was read")
    }

    func testNewRunnerUnderCachedOllamaParent() {
        let t = Table()
        t.add(10, path: "/Applications/Ollama.app/Contents/Resources/ollama", argv: ["ollama", "serve"])
        let s = t.scanner()
        XCTAssertEqual(s.scan().map(\.kind), [.ollamaServe])
        t.add(11, ppid: 10, path: "/Applications/Ollama.app/Contents/Resources/llama-server", argv: ["llama-server", "--port", "51234"])
        let kinds = s.scan().map(\.kind)
        XCTAssertEqual(kinds, [.ollamaServe, .ollamaRunner], "parent known from an earlier poll")
    }

    func testReusedPidIsReclassifiedAndDeadEntriesPruned() {
        let t = Table()
        t.add(30, path: "/usr/local/bin/llama-cli", start: 100)
        let s = t.scanner()
        XCTAssertEqual(s.scan().map(\.kind), [.llamaCLI])
        // Same pid, new process (later start time), now unrelated.
        t.entries = []; t.add(30, path: "/usr/bin/vim", start: 200)
        XCTAssertEqual(s.scan(), [])
        let reads = t.pathReads
        t.entries = []
        XCTAssertEqual(s.scan(), [])
        t.add(30, path: "/usr/bin/vim", start: 200)
        _ = s.scan()
        XCTAssertEqual(t.pathReads, reads + 1, "the pruned entry is looked up again")
    }

    func testLlamafileUnderAPELoader() {
        let t = Table()
        t.add(40, path: "/Users/alex/.ape-1.10", argv: ["/Users/alex/.ape-1.10", "/Users/alex/models/qwen.llamafile", "--server"])
        t.add(41, path: "/Users/alex/.ape-1.10", argv: ["/Users/alex/.ape-1.10", "/Users/alex/bin/redbean.com"])
        let found = t.scanner().scan()
        XCTAssertEqual(found.map(\.kind), [.llamaCLI])
        XCTAssertEqual(found.first?.name, "qwen.llamafile")
    }

    /// The timer is one-shot and re-armed after each poll: polling must keep
    /// going (fast while something runs, slower when nothing does) and stop.
    func testPollingContinuesAtBothCadencesAndStops() {
        let lock = NSLock()
        var calls = 0
        var processes: [LocalProcess] = [LocalProcess(kind: .ollamaServe, pid: 10, name: "Ollama")]
        let probes = LocalModelMonitor.Probes(
            discover: { lock.lock(); defer { lock.unlock() }; calls += 1; return processes },
            listeningPorts: { _ in [] },
            gpu: { _ in .utilization([:]) },
            slots: { _, done in done(.noObservation) },
            ttyModified: { _ in nil })
        let m = LocalModelMonitor(pollInterval: 0.05, discoveryInterval: 0.4, pollBudget: 0.2, probes: probes)
        func count() -> Int { lock.lock(); defer { lock.unlock() }; return calls }

        m.start()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertGreaterThanOrEqual(count(), 4, "re-armed at the poll interval while something runs")

        lock.lock(); processes = []; lock.unlock()
        Thread.sleep(forTimeInterval: 0.15)    // let the switch to discovery cadence happen
        let before = count()
        Thread.sleep(forTimeInterval: 0.6)
        let idlePolls = count() - before
        XCTAssertGreaterThanOrEqual(idlePolls, 1, "still discovering when nothing runs")
        XCTAssertLessThanOrEqual(idlePolls, 3, "but at the slower discovery interval")

        m.stop()
        Thread.sleep(forTimeInterval: 0.1)
        let afterStop = count()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(count(), afterStop, "no polls after stop")
    }
}
