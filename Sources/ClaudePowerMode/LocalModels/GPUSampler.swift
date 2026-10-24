import Foundation
import IOKit

/// Pure parsing of AGX user-client properties.
///
/// Every process with a Metal device has one or more `AGXDeviceUserClient`
/// objects in the IORegistry. Each carries `IOUserClientCreator`
/// ("pid 123, name" — the name is cut to 16 characters, so only the pid is
/// trusted) and `AppUsage`, an array of per-queue dicts whose
/// `accumulatedGPUTime` is cumulative GPU nanoseconds.
enum GPUUsageParser {
    static func pid(fromCreator creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        let digits = creator.dropFirst(4).prefix { $0.isNumber }
        guard let pid = Int32(digits), pid > 0 else { return nil }
        return pid
    }

    /// Cumulative GPU ns per pid, summed over all of a pid's clients and
    /// queues. A client without `AppUsage` still counts (as 0): the
    /// process has a GPU device but hasn't submitted work.
    static func accumulatedTimes(_ entries: [[String: Any]]) -> [Int32: UInt64] {
        var sums: [Int32: UInt64] = [:]
        for entry in entries {
            guard let creator = entry["IOUserClientCreator"] as? String,
                  let pid = pid(fromCreator: creator) else { continue }
            var total = sums[pid] ?? 0
            if let usage = entry["AppUsage"] as? [[String: Any]] {
                for queue in usage {
                    if let n = queue["accumulatedGPUTime"] as? NSNumber {
                        total &+= n.uint64Value
                    } else if let n = queue["accumulatedGPUTime"] as? UInt64 {
                        total &+= n
                    } else if let n = queue["accumulatedGPUTime"] as? Int, n > 0 {
                        total &+= UInt64(n)
                    }
                }
            }
            sums[pid] = total
        }
        return sums
    }
}

/// Pure: turns cumulative GPU time into utilization between two samples.
struct GPUUtilizationTracker {
    private var last: [Int32: (sum: UInt64, at: UInt64)] = [:]

    /// Utilization (0…1, clamped) for each pid in `pids` that has a
    /// previous sample. A pid with no AGX client reads as 0 GPU time. A
    /// sum that went down (pid reused, client closed) restarts that pid's
    /// baseline without a reading. Pids not asked for are forgotten.
    mutating func update(sums: [Int32: UInt64], pids: Set<Int32>, nowNs: UInt64) -> [Int32: Double] {
        var out: [Int32: Double] = [:]
        var next: [Int32: (sum: UInt64, at: UInt64)] = [:]
        for pid in pids {
            let sum = sums[pid] ?? 0
            next[pid] = (sum, nowNs)
            guard let prev = last[pid], sum >= prev.sum, nowNs > prev.at else { continue }
            out[pid] = min(1, Double(sum - prev.sum) / Double(nowNs - prev.at))
        }
        last = next
        return out
    }
}

/// Samples per-process Apple-GPU utilization from the IORegistry. Not
/// thread-safe: use from one queue (the monitor's).
///
/// Calibrated on an M3 Pro (see LOCAL-MODELS spec): a pure Metal compute
/// load reads 1.00, a ~38 % duty load 0.39, idle 0.00.
///
/// The AGX user clients are not *registered* services, so
/// `IOServiceGetMatchingServices("AGXDeviceUserClient")` finds none; they
/// are found as service-plane children of the registered `IOAccelerator`.
/// Intel Macs (no AGX) report `.unavailable`.
final class GPUSampler {
    enum Reading: Equatable {
        case unavailable
        /// Pids with a utilization this round (absent = first sample or reset).
        case utilization([Int32: Double])
    }

    private let enumerate: (Set<Int32>) -> [[String: Any]]?
    private let clock: () -> UInt64
    private var tracker = GPUUtilizationTracker()
    /// Entries seen by the last enumeration (for diagnostics).
    private(set) var lastClientCount = 0

    init(enumerate: @escaping (Set<Int32>) -> [[String: Any]]? = GPUSampler.enumerateAGXClients,
         clock: @escaping () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        self.enumerate = enumerate
        self.clock = clock
    }

    func sample(pids: Set<Int32>) -> Reading {
        guard let entries = enumerate(pids) else {
            lastClientCount = 0
            return .unavailable
        }
        lastClientCount = entries.count
        let sums = GPUUsageParser.accumulatedTimes(entries)
        return .utilization(tracker.update(sums: sums, pids: pids, nowNs: clock()))
    }

    /// One registry walk. Returns nil when there is no AGX client at all.
    /// `AppUsage` is copied only for clients whose creator pid is in
    /// `wanted`; the rest contribute just their creator string.
    static func enumerateAGXClients(wanted: Set<Int32>) -> [[String: Any]]? {
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(accelerators) }
        var entries: [[String: Any]] = []
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let child = IOIteratorNext(children), child != 0 {
                defer { IOObjectRelease(child) }
                guard IOObjectConformsTo(child, "AGXDeviceUserClient") != 0,
                      let creator = property(child, "IOUserClientCreator") as? String else { continue }
                var entry: [String: Any] = ["IOUserClientCreator": creator]
                if let pid = GPUUsageParser.pid(fromCreator: creator), wanted.contains(pid),
                   let usage = property(child, "AppUsage") {
                    entry["AppUsage"] = usage
                }
                entries.append(entry)
            }
        }
        return entries.isEmpty ? nil : entries
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
