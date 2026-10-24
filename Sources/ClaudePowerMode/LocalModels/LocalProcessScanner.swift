import Foundation
import Darwin

/// libproc readers (no subprocess, no root) used by local-model discovery.
enum LocalProcInfo {
    struct BSDInfo: Equatable {
        let ppid: Int32
        /// Controlling terminal device, NODEV (UInt32.max) when none.
        let tdev: UInt32
        let startSeconds: UInt64
    }

    static func allPids() -> [Int32] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<Int32>.size))
        }
        guard got > 0 else { return [] }
        return pids.prefix(Int(got)).filter { $0 > 0 }
    }

    /// Every process in one `sysctl(KERN_PROC_ALL)`: pid, parent, tty,
    /// start time and the (16-char) command name. One syscall instead of a
    /// libproc call per pid, so an unchanged process table costs ~nothing.
    struct Entry: Equatable {
        let pid: Int32
        let info: BSDInfo
        let startMicros: Int32
        let comm: String
    }

    static func allProcesses() -> [Entry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
            size = procs.count * stride
            let rc = procs.withUnsafeMutableBytes { raw in sysctl(&mib, 4, raw.baseAddress, &size, nil, 0) }
            if rc != 0 {
                if errno == ENOMEM { continue }   // the table grew in between
                return []
            }
            return procs.prefix(size / stride).compactMap { kp in
                let pid = kp.kp_proc.p_pid
                guard pid > 0 else { return nil }
                let comm = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw -> String in
                    let bytes = raw.prefix { $0 != 0 }
                    return String(decoding: bytes, as: UTF8.self)
                }
                let start = kp.kp_proc.p_starttime
                return Entry(pid: pid,
                             info: BSDInfo(ppid: kp.kp_eproc.e_ppid, tdev: UInt32(bitPattern: kp.kp_eproc.e_tdev),
                                           startSeconds: UInt64(max(0, start.tv_sec))),
                             startMicros: start.tv_usec, comm: comm)
            }
        }
        return []
    }

    /// PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) isn't importable.
    static let pathBufferSize = 4 * Int(MAXPATHLEN)

    static func execPath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: pathBufferSize)
        return execPath(pid, buffer: &buf)
    }

    /// Reuses `buffer` (at least `pathBufferSize`) across a scan of every pid.
    static func execPath(_ pid: Int32, buffer buf: inout [CChar]) -> String? {
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        let bytes = buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func bsdInfo(_ pid: Int32) -> BSDInfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return BSDInfo(ppid: Int32(bitPattern: info.pbi_ppid), tdev: info.e_tdev, startSeconds: info.pbi_start_tvsec)
    }

    /// "ttys003" for a controlling-terminal device, nil for NODEV.
    static func ttyName(tdev: UInt32) -> String? {
        guard tdev != UInt32.max, tdev != 0 else { return nil }
        guard let name = devname(dev_t(bitPattern: tdev), S_IFCHR) else { return nil }
        let s = String(cString: name)
        return s.isEmpty || s == "??" ? nil : s
    }

    /// Last write to `/dev/<tty>` (terminal output). nil if unreadable.
    /// A write to a pty updates the slave device node's mtime — checked
    /// in-process with `openpty` (LocalModelsLiveTests); unverified for
    /// every terminal emulator.
    static func ttyModified(_ ttyName: String) -> Date? {
        guard !ttyName.isEmpty, !ttyName.contains("/") else { return nil }
        var st = stat()
        guard stat("/dev/" + ttyName, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
    }

    /// TCP ports `pid` is listening on. nil when the fd list can't be read
    /// (another user's process, gone); an empty set means "readable, none".
    static func listeningTCPPorts(_ pid: Int32) -> Set<Int>? {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let used = fds.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard used > 0 else { return nil }
        var ports = Set<Int>()
        let socketInfoSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, socketInfoSize) == socketInfoSize,
                  si.psi.soi_kind == Int32(SOCKINFO_TCP),
                  si.psi.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            // insi_lport holds the port in network byte order.
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.insert(port) }
        }
        return ports
    }
}

/// Pure: which port(s) to probe for a server.
enum LocalPortSelection {
    /// Prefer ports the process actually listens on, intersected with the
    /// argv/env port when one was given. When the socket lookup failed (nil)
    /// or found nothing, fall back to the declared port. Never guesses a
    /// default (8080, 11434) the process isn't seen listening on.
    static func ports(listening: Set<Int>?, declared: Int?) -> [Int] {
        guard let listening, !listening.isEmpty else { return declared.map { [$0] } ?? [] }
        if let declared { return listening.contains(declared) ? [declared] : [] }
        return listening.sorted()
    }
}

/// Live process discovery: libproc for every pid, argv only for
/// candidates, results cached per (pid, start time, path) so an unchanged
/// process is classified once. Not thread-safe: use from one queue.
///
/// The cache holds derived `LocalProcess` values only — never argv.
final class LocalProcessScanner {
    /// A process instance: a reused pid has another start time, and an
    /// exec changes the command name.
    private struct Key: Hashable {
        let pid: Int32
        let start: UInt64
        let startMicros: Int32
        let comm: String
    }

    private let home: String
    /// Executable path ("" = unreadable) and candidacy per process
    /// instance, so `proc_pidpath` and the name checks run once per new
    /// process, not once per pid per poll.
    private var paths: [Key: (path: String, candidacy: LocalProcessClassifier.Candidacy)] = [:]
    private var classified: [Key: LocalProcess?] = [:]
    /// `devname` is slow (~1 ms) and a device's name never changes.
    private var ttyNames: [UInt32: String?] = [:]

    init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    func scan() -> [LocalProcess] {
        var facts: [Int32: ProcessFacts] = [:]
        var keys: [Int32: Key] = [:]
        var pending: [Int32] = []
        var livePaths: [Key: (path: String, candidacy: LocalProcessClassifier.Candidacy)] = [:]
        var result: [LocalProcess] = []
        var pathBuffer = [CChar](repeating: 0, count: LocalProcInfo.pathBufferSize)

        for entry in LocalProcInfo.allProcesses() {
            let pid = entry.pid
            let key = Key(pid: pid, start: entry.info.startSeconds, startMicros: entry.startMicros, comm: entry.comm)
            let known = paths[key] ?? {
                let path = LocalProcInfo.execPath(pid, buffer: &pathBuffer) ?? ""
                return (path, path.isEmpty ? .none : LocalProcessClassifier.candidacy(execPath: path, home: home))
            }()
            livePaths[key] = known
            let (path, candidacy) = known
            guard candidacy != .none else { continue }
            let tty = ttyName(entry.info.tdev)
            if let cached = classified[key] {
                if let cached { result.append(cached) }
                // Still a possible parent for a new runner.
                facts[pid] = ProcessFacts(pid: pid, ppid: entry.info.ppid, execPath: path, ttyName: tty)
                continue
            }
            let readArgv = candidacy == .needsArgv || (candidacy == .needsArgvIfTTY && tty != nil)
            let args = readArgv ? ProcArgs.read(pid: pid, envKeys: LocalProcessClassifier.envKeys) : nil
            facts[pid] = ProcessFacts(pid: pid, ppid: entry.info.ppid, execPath: path,
                                      argv: args?.argv ?? [], env: args?.env ?? [:], ttyName: tty)
            keys[pid] = key
            pending.append(pid)
        }

        for pid in pending {
            guard let f = facts[pid], let key = keys[pid] else { continue }
            let verdict = LocalProcessClassifier.classify(f, parentOf: { facts[$0] }, home: home)
            // An argv read can fail transiently (process just exec'd); don't
            // cache any verdict built without the argv it needed — a
            // llama-server classified without it would keep no port and
            // miss --api-key / --no-slots / --host for its whole life.
            let candidacy = livePaths[key]?.candidacy ?? .none
            let argvNeeded = candidacy == .needsArgv || (candidacy == .needsArgvIfTTY && f.ttyName != nil)
            if !argvNeeded || !f.argv.isEmpty {
                classified[key] = .some(verdict)
            }
            if let verdict { result.append(verdict) }
        }
        // argv is dropped with `facts` here.
        paths = livePaths
        classified = classified.filter { livePaths[$0.key] != nil }
        return result.sorted { $0.pid < $1.pid }
    }

    private func ttyName(_ tdev: UInt32) -> String? {
        if let cached = ttyNames[tdev] { return cached }
        let name = LocalProcInfo.ttyName(tdev: tdev)
        if ttyNames.count > 512 { ttyNames.removeAll() }
        ttyNames[tdev] = .some(name)
        return name
    }
}
