import Foundation
import Darwin
import DiskScanKit
import IOKit

public enum MemoryPressureLevel: Int, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4
    case unknown = 0

    /// Stable name for anything written to disk. The integers are the
    /// kernel's, and storing those in a log would tie the file format to a
    /// header we don't control.
    public var name: String {
        switch self {
        case .normal: "normal"
        case .warning: "warning"
        case .critical: "critical"
        case .unknown: "unknown"
        }
    }

    public init(name: String) {
        switch name {
        case "normal": self = .normal
        case "warning": self = .warning
        case "critical": self = .critical
        default: self = .unknown
        }
    }
}

public struct SystemSnapshot: Sendable {
    public var cpuUsage: Double?          // 0…1
    public var memoryUsed: Int64 = 0      // active + wired + compressed
    public var memoryTotal: Int64 = 0
    public var memoryPressure: MemoryPressureLevel = .unknown
    public var swapUsed: Int64 = 0
    public var gpuUtilization: Double?    // 0…1, Apple Silicon IOAccelerator
    public var thermalState: ProcessInfo.ThermalState = .nominal

    public init() {}
}

/// Polls unprivileged system metrics. Keep one sampler alive: CPU usage is a
/// delta between consecutive samples.
public final class SystemSampler {
    private var previousTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    public init() {}

    public func sample() -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.cpuUsage = sampleCPU()
        sampleMemory(&snapshot)
        snapshot.memoryPressure = Self.memoryPressure()
        snapshot.swapUsed = Self.swapUsed()
        snapshot.gpuUtilization = Self.gpuUtilization()
        snapshot.thermalState = ProcessInfo.processInfo.thermalState
        return snapshot
    }

    private func sampleCPU() -> Double? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = (
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
        defer { previousTicks = ticks }
        guard let prev = previousTicks else { return nil }
        let busy = (ticks.user &- prev.user) &+ (ticks.system &- prev.system) &+ (ticks.nice &- prev.nice)
        let idle = ticks.idle &- prev.idle
        let total = busy &+ idle
        guard total > 0 else { return nil }
        return Double(busy) / Double(total)
    }

    func sampleMemoryPublic(_ snapshot: inout SystemSnapshot) { sampleMemory(&snapshot) }

    private func sampleMemory(_ snapshot: inout SystemSnapshot) {
        var size: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &length, nil, 0)
        snapshot.memoryTotal = Int64(size)

        var vmInfo = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let pageSize = Int64(getpagesize())
        let used = Int64(vmInfo.active_count) + Int64(vmInfo.wire_count)
            + Int64(vmInfo.compressor_page_count)
        snapshot.memoryUsed = used * pageSize
    }

    /// Total and used memory, without needing a stateful sampler — the CPU
    /// figures are the only part of `sample()` that needs one.
    public static func memoryUsage() -> (total: Int64, used: Int64) {
        var snapshot = SystemSnapshot()
        SystemSampler().sampleMemoryPublic(&snapshot)
        return (snapshot.memoryTotal, snapshot.memoryUsed)
    }

    public static func memoryPressure() -> MemoryPressureLevel {
        var level: Int32 = 0
        var length = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &length, nil, 0) == 0 else {
            return .unknown
        }
        return MemoryPressureLevel(rawValue: Int(level)) ?? .unknown
    }

    public static func swapUsed() -> Int64 {
        var swap = xsw_usage()
        var length = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &length, nil, 0) == 0 else { return 0 }
        return Int64(swap.xsu_used)
    }

    /// The accelerator that publishes the statistic, matched once and kept
    /// retained. This runs on 1 Hz timers, and re-matching services plus
    /// copying the accelerator's entire property table every second is real
    /// work for one integer; the entry itself outlives us, so per call we
    /// only ask it for the one statistics dictionary. Never released while
    /// cached — only when swapped out for a fresh match.
    private static let cachedAccelerator = Locked<io_registry_entry_t>(0)

    /// Undocumented-but-stable IOAccelerator statistic on Apple Silicon.
    /// Returns nil (hiding the stat) if the key ever changes.
    public static func gpuUtilization() -> Double? {
        cachedAccelerator.withLock { entry -> Double? in
            if entry != 0 {
                if let value = deviceUtilization(of: entry) { return value }
                // The cached entry can go stale (GPU driver restart, sleep
                // cycles): drop it and re-match once before giving up.
                IOObjectRelease(entry)
                entry = 0
            }
            entry = matchAccelerator()
            guard entry != 0 else { return nil }
            return deviceUtilization(of: entry)
        }
    }

    /// Just the statistics dictionary — not the whole property table.
    private static func deviceUtilization(of entry: io_registry_entry_t) -> Double? {
        guard let raw = IORegistryEntryCreateCFProperty(
            entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue(),
              let perf = raw as? [String: Any],
              let utilization = perf["Device Utilization %"] as? Int else { return nil }
        return min(1, max(0, Double(utilization) / 100))
    }

    /// The first accelerator that answers with the statistic we want, still
    /// retained — the caller owns (and caches) it.
    private static func matchAccelerator() -> io_registry_entry_t {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator
        ) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if deviceUtilization(of: entry) != nil { return entry }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return 0
    }
}
