import Foundation
import Darwin
import DiskScanKit

public struct AppMemoryUsage: Sendable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    /// Aggregated phys_footprint (what Activity Monitor's "Memory" column
    /// shows), including the app's helper processes.
    public let footprint: Int64
    /// Aggregated CPU percentage over the sampling window (0–100·ncpu),
    /// nil when CPU sampling wasn't requested.
    public let cpuPercent: Double?

    public init(name: String, footprint: Int64, cpuPercent: Double? = nil) {
        self.name = name
        self.footprint = footprint
        self.cpuPercent = cpuPercent
    }
}

/// Ranks apps by real memory footprint, grouping helper processes
/// (Chrome Helper (Renderer), WebKit content, …) under their host app so
/// non-technical users see "Chrome: 5 GB", not thirty mystery helpers.
public enum ProcessMemory {
    private struct Sample {
        var footprint: [String: Int64] = [:]
        var cpuTime: [String: UInt64] = [:]   // user+system ns, aggregated
    }

    /// Display names already resolved, keyed by pid. Resolving is three
    /// syscalls per process (name, path, and for interpreters the whole
    /// argv), and the memory screen samples every process ~4 times per 3 s
    /// for a name that only changes if the pid itself is reused — which the
    /// process start time detects, since rusage hands it to us for free.
    /// Rebuilt from live pids each sample, so dead pids fall out.
    private static let nameCache = Locked<[pid_t: (startTime: UInt64, name: String)]>([:])

    private static func sample() -> Sample {
        var result = Sample()
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return result }
        var pids = [Int32](repeating: 0, count: Int(capacity) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<Int32>.size))
        guard filled > 0 else { return result }

        // Work on a copy so the lock isn't held across syscalls; whichever
        // concurrent sample stores last still stores a complete, live map.
        let cache = nameCache.withLock { $0 }
        var fresh: [pid_t: (startTime: UInt64, name: String)] = [:]

        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var usage = rusage_info_current()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            // Fails for other users' / entitlement-protected processes — skip.
            guard ok == 0 else { continue }

            let app: String
            if let cached = cache[pid], cached.startTime == usage.ri_proc_start_abstime {
                app = cached.name
            } else {
                app = displayName(for: pid)
            }
            fresh[pid] = (usage.ri_proc_start_abstime, app)
            guard !app.isEmpty else { continue }

            result.footprint[app, default: 0] += Int64(usage.ri_phys_footprint)
            result.cpuTime[app, default: 0] += usage.ri_user_time &+ usage.ri_system_time
        }
        nameCache.withLock { $0 = fresh }
        return result
    }

    /// Resolves what to call a process, uncached; empty when even the
    /// kernel has no name for it.
    private static func displayName(for pid: pid_t) -> String {
        var nameBuffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let raw = String(cString: nameBuffer)
        guard !raw.isEmpty else { return "" }

        // The executable's path says who a process belongs to far more
        // reliably than its name does: "AirPlayXPCHelper" looks like an
        // app's helper and is macOS, and a helper buried inside
        // Chrome.app names its host in the path whatever it calls itself.
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cString: pathBuffer) : ""
        var app = hostAppName(for: raw, path: path)
        // "node" tells nobody anything. Name it after the script it is
        // running, which is the thing a person can actually judge.
        if ProcessArguments.isInterpreter(app),
           let script = ProcessArguments.scriptName(of: pid) {
            app = script
        }
        return app
    }

    /// Every pid that rolls up under `name` in the memory list — the same
    /// grouping, so what the user was shown is exactly what gets acted on.
    ///
    /// The list is by name because that's the only handle a person has: they
    /// see "node, 1.5 GB", not four pids. Helpers included, since a bundle's
    /// renderers are the app as far as anyone reading that row is concerned.
    public static func pids(for name: String) -> [pid_t] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(capacity) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }

        var matches: [pid_t] = []
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            // Resolved fresh, not from the sample cache: this feeds process
            // termination, where a stale name against a reused pid matters.
            let app = displayName(for: pid)
            if !app.isEmpty, app == name {
                matches.append(pid)
            }
        }
        return matches
    }

    /// Memory ranking, optionally with CPU% measured over a real sampling
    /// window (two snapshots of user+system time; mach time units converted
    /// via the timebase — on Apple Silicon these are not raw nanoseconds).
    public static func topConsumers(
        limit: Int = 6, minFootprint: Int64 = 100 << 20
    ) -> [AppMemoryUsage] {
        let snap = sample()
        return snap.footprint
            .filter { $0.value >= minFootprint }
            .map { AppMemoryUsage(name: $0.key, footprint: $0.value) }
            .sorted { $0.footprint > $1.footprint }
            .prefix(limit)
            .map { $0 }
    }

    public static func topConsumersWithCPU(
        limit: Int = 6, minFootprint: Int64 = 100 << 20, window: Duration = .seconds(1)
    ) async -> [AppMemoryUsage] {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let first = sample()
        let start = ContinuousClock.now
        try? await Task.sleep(for: window)
        let second = sample()
        let elapsed = (ContinuousClock.now - start).components
        let elapsedNs = Double(elapsed.seconds) * 1e9 + Double(elapsed.attoseconds) / 1e9

        func cpuPercent(_ app: String) -> Double {
            let delta = Double((second.cpuTime[app] ?? 0) &- (first.cpuTime[app] ?? 0))
            let deltaNs = delta * Double(timebase.numer) / Double(timebase.denom)
            guard elapsedNs > 0, deltaNs >= 0, deltaNs < 1e15 else { return 0 }
            return (deltaNs / elapsedNs) * 100
        }

        return second.footprint
            .filter { $0.value >= minFootprint }
            .map { AppMemoryUsage(name: $0.key, footprint: $0.value, cpuPercent: cpuPercent($0.key)) }
            .sorted { $0.footprint > $1.footprint }
            .prefix(limit)
            .map { $0 }
    }

    /// Apple Intelligence background workers — real CPU/RAM users on 8 GB
    /// Macs; there's no safe way to kill them, only Settings to disable.
    public static func appleIntelligenceActive() -> Bool {
        let markers = ["intelligenceplatform", "knowledgeconstruction", "siriinference"]
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return false }
        var pids = [Int32](repeating: 0, count: Int(capacity) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<Int32>.size))
        for pid in pids.prefix(Int(max(0, filled))) where pid > 0 {
            var nameBuffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = String(cString: nameBuffer).lowercased()
            if markers.contains(where: { name.contains($0) }) { return true }
        }
        return false
    }

    /// System processes users can't (and shouldn't) act on are folded into
    /// one "macOS" bucket; helpers roll up to their host app.
    /// Groups a process under the app a person would recognise, using the
    /// executable path when we have one.
    static func hostAppName(for processName: String, path: String) -> String {
        if !path.isEmpty {
            // Anything Apple ships is "macOS" — users can't act on it
            // individually, and listing it by name is just noise.
            for prefix in ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/",
                           "/Library/Apple/", "/sbin/", "/cores/"] where path.hasPrefix(prefix) {
                return "macOS"
            }
            // The OUTERMOST bundle is the app you launched; helpers nest
            // their own .app bundles inside it.
            if let range = path.range(of: ".app/") {
                let bundle = String(path[path.startIndex..<range.lowerBound])
                if let name = bundle.split(separator: "/").last, !name.isEmpty {
                    return String(name)
                }
            }
            // No bundle at all: a plain executable. Tools that self-update ship
            // as `.../claude/versions/2.1.220`, and taking the file name gives
            // a memory list with a row called "2.1.220" holding 2 GB — true,
            // and no help to anyone.
            if let better = nameFromVersionedPath(path) { return better }
        }
        return hostAppName(for: processName)
    }

    /// Directory names that describe layout rather than software, so they're
    /// never the answer to "what is this?".
    private static let structuralDirectories: Set<String> = [
        "versions", "version", "current", "latest", "bin", "sbin", "libexec",
        "Contents", "MacOS", "Resources", "Frameworks", "share", "lib", "local",
        "node_modules", "dist", "build", "releases", "release", "app", "src",
    ]

    /// Reaching one of these means the walk has left the software behind and
    /// is climbing the filesystem itself. Better no answer than "usr" — or,
    /// worse, the user's own account name.
    private static let terminators: Set<String> = [
        "Users", "usr", "opt", "var", "private", "tmp", "System", "Library",
        "Applications", "homebrew", "Cellar", "Application Support",
    ]

    /// Walks up from the executable past version numbers and structural
    /// directories to the first name that means something.
    static func nameFromVersionedPath(_ path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard let last = components.last, looksLikeVersion(last) else { return nil }
        for component in components.dropLast().reversed() {
            if terminators.contains(component) { return nil }
            if looksLikeVersion(component) { continue }
            if structuralDirectories.contains(component) { continue }
            // Hidden support directories (`.local`, `.cache`) are structure too.
            if component.hasPrefix(".") { continue }
            return component
        }
        return nil
    }

    /// Digits and dots, with at least one dot: 2.1.220, 18.0, v3.2.1.
    static func looksLikeVersion(_ name: String) -> Bool {
        let trimmed = name.hasPrefix("v") ? String(name.dropFirst()) : name
        guard trimmed.contains(".") else { return false }
        return !trimmed.isEmpty && trimmed.allSatisfy { $0.isNumber || $0 == "." }
    }

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
        // Run-together forms too — AirPlayXPCHelper, ControlCenterHelper,
        // AppPredictionIntentsHelperService. Without this they survive as
        // their own rows and read as mystery apps.
        for suffix in ["HelperService", "XPCHelper", "Helper", "Service", "Agent"]
        where name.hasSuffix(suffix) && name.count > suffix.count {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name
    }
}
