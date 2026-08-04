import Foundation
import Darwin

/// One-shot health snapshot of this Mac, shaped for a fleet: stable camelCase
/// keys, every optional present-or-null, no free text that a script would have
/// to parse. Optionals mean "this Mac can't answer" (a desktop has no battery,
/// `diskutil` may not report SMART), never zero.
public struct StatusSnapshot: Codable, Sendable {
    public var freeBytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var memoryUsedBytes: Int64 = 0
    public var memoryTotalBytes: Int64 = 0
    public var memoryPressure: String = "unknown"   // normal | warning | critical | unknown
    public var uptimeDays: Int = 0
    public var bootDate: Date = .init()
    public var batteryCycles: Int?
    public var batteryHealthPercent: Int?
    public var zombieCount: Int = 0
    public var mdmEnrolled: Bool?
    public var smartStatus: String?

    public init() {}

    /// Bounded by construction: the only external processes are HealthCheck's
    /// three probes, which run concurrently behind 5-second ShellRunner
    /// timeouts. Everything else is a sysctl or a stat.
    public static func capture() async -> StatusSnapshot {
        var snapshot = StatusSnapshot()

        let space = VolumeSpace.forHome()
        snapshot.freeBytes = space.free
        snapshot.totalBytes = space.total

        let memory = SystemSampler().sample()
        snapshot.memoryUsedBytes = memory.memoryUsed
        snapshot.memoryTotalBytes = memory.memoryTotal
        snapshot.memoryPressure = name(of: memory.memoryPressure)

        let health = await HealthCheck.run()
        snapshot.uptimeDays = health.uptimeDays
        snapshot.bootDate = bootDate()
        snapshot.batteryCycles = health.batteryCycles
        snapshot.batteryHealthPercent = health.batteryHealthPercent
        snapshot.zombieCount = health.zombieCount
        snapshot.mdmEnrolled = health.isMDMManaged
        snapshot.smartStatus = health.smartStatus

        return snapshot
    }

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// Straight from `kern.boottime`. Deriving it as "now minus uptime"
    /// jitters by a second between runs, and a fleet script diffing snapshots
    /// would read that as a reboot.
    static func bootDate() -> Date {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boottime, &size, nil, 0) == 0 else { return Date() }
        return Date(timeIntervalSince1970: TimeInterval(boottime.tv_sec))
    }

    static func name(of level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        case .unknown: return "unknown"
        }
    }
}

/// Free/total bytes of the volume holding the home directory — the number a
/// remote admin actually cares about. `volumeAvailableCapacity` is the honest
/// one: it excludes the purgeable space macOS advertises but won't hand over
/// until it feels pressure.
public enum VolumeSpace {
    public static func forHome() -> (free: Int64, total: Int64) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        ) else { return (0, 0) }
        return (Int64(values.volumeAvailableCapacity ?? 0), Int64(values.volumeTotalCapacity ?? 0))
    }
}
