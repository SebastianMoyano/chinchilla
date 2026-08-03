import Foundation
import Darwin

public struct AppMemoryUsage: Sendable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    /// Aggregated phys_footprint (what Activity Monitor's "Memory" column
    /// shows), including the app's helper processes.
    public let footprint: Int64

    public init(name: String, footprint: Int64) {
        self.name = name
        self.footprint = footprint
    }
}

/// Ranks apps by real memory footprint, grouping helper processes
/// (Chrome Helper (Renderer), WebKit content, …) under their host app so
/// non-technical users see "Chrome: 5 GB", not thirty mystery helpers.
public enum ProcessMemory {
    public static func topConsumers(limit: Int = 6, minFootprint: Int64 = 100 << 20) -> [AppMemoryUsage] {
        var byApp: [String: Int64] = [:]

        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(capacity) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }

        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var usage = rusage_info_current()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            // Fails for other users' / entitlement-protected processes — skip.
            guard result == 0 else { continue }
            let footprint = Int64(usage.ri_phys_footprint)
            guard footprint > 0 else { continue }

            var nameBuffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let raw = String(cString: nameBuffer)
            guard !raw.isEmpty else { continue }
            let app = hostAppName(for: raw)
            guard !app.isEmpty else { continue }
            byApp[app, default: 0] += footprint
        }

        return byApp
            .filter { $0.value >= minFootprint }
            .map { AppMemoryUsage(name: $0.key, footprint: $0.value) }
            .sorted { $0.footprint > $1.footprint }
            .prefix(limit)
            .map { $0 }
    }

    /// System processes users can't (and shouldn't) act on are folded into
    /// one "macOS" bucket; helpers roll up to their host app.
    static func hostAppName(for processName: String) -> String {
        let systemNames: Set<String> = [
            "kernel_task", "WindowServer", "launchd", "logd", "mds", "mds_stores",
            "mdworker", "mdworker_shared", "softwareupdated", "coreduetd",
            "spotlightknowledged", "syspolicyd", "trustd", "opendirectoryd",
        ]
        if systemNames.contains(processName) { return "macOS" }
        if processName.hasPrefix("com.apple.WebKit") { return "Safari" }
        if processName.hasPrefix("com.apple.") { return "macOS" }

        var name = processName
        for suffix in [
            " Helper (Renderer)", " Helper (GPU)", " Helper (Plugin)",
            " Helper (Alerts)", " Helper", " Web Content", " Networking",
            " Graphics and Media", " (Renderer)", " (GPU)",
        ] {
            if name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
        }
        return name
    }
}
