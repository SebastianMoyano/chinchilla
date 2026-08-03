import Foundation
import Darwin

// MARK: - Health checks (read-only, honest)

public struct HealthReport: Sendable {
    public var smartStatus: String?        // "Verified", "Failing", nil = unknown
    public var batteryCycles: Int?
    public var batteryHealthPercent: Int?  // raw/design capacity
    public var uptimeDays: Int = 0
    public var zombieCount: Int = 0
    public var isMDMManaged: Bool?

    public init() {}
}

public enum SystemUptime {
    public static func days() -> Int {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boottime, &size, nil, 0) == 0 else { return 0 }
        let up = Date().timeIntervalSince1970 - TimeInterval(boottime.tv_sec)
        return max(0, Int(up / 86_400))
    }
}

public enum HealthCheck {
    /// All external probes run CONCURRENTLY with short timeouts — the wall
    /// time is the slowest single probe (~5 s worst case), never the sum.
    /// The UI renders instantly and fills in; a slow probe costs one row.
    public static func run() async -> HealthReport {
        var report = HealthReport()

        async let diskOutput = try? ShellRunner.run(
            "/usr/sbin/diskutil", ["info", "disk0"], timeout: .seconds(5)
        )
        async let batteryOutput = try? ShellRunner.run(
            "/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"], timeout: .seconds(5)
        )
        async let profilesOutput = try? ShellRunner.runMerged(
            "/usr/bin/profiles", ["status", "-type", "enrollment"], timeout: .seconds(5)
        )

        // Local, instant probes while the subprocesses run.
        report.uptimeDays = SystemUptime.days()
        report.zombieCount = countZombies()

        if let output = await diskOutput,
           let line = output.split(separator: "\n").first(where: { $0.contains("SMART Status") }) {
            report.smartStatus = line.split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces)
        }
        if let output = await batteryOutput {
            func intField(_ name: String) -> Int? {
                output.split(separator: "\n")
                    .first { $0.contains("\"\(name)\" =") }
                    .flatMap { Int($0.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "") }
            }
            report.batteryCycles = intField("CycleCount")
            if let raw = intField("AppleRawMaxCapacity"), let design = intField("DesignCapacity"), design > 0 {
                report.batteryHealthPercent = min(100, raw * 100 / design)
            }
        }
        if let output = await profilesOutput {
            report.isMDMManaged = output.contains("Yes")
        }

        return report
    }

    static func countZombies() -> Int {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return 0 }
        var pids = [Int32](repeating: 0, count: Int(capacity) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<Int32>.size))
        var zombies = 0
        for pid in pids.prefix(Int(max(0, filled))) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            if info.pbi_status == 5 { zombies += 1 }  // SZOMB
        }
        return zombies
    }
}

// MARK: - Fix-it kit (repairs, not speed — the UI says so)

public enum FixIt {
    /// mDNSResponder is root-owned, so the flush is one admin prompt.
    public static func flushDNS() async throws {
        _ = try await PrivilegedRunner.run(
            "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder"
        )
    }

    /// User-level font cache rebuild; takes effect fully after re-login.
    public static func rebuildFontCaches() async throws {
        _ = try await ShellRunner.run(
            "/usr/bin/atsutil", ["databases", "-removeUser"], timeout: .seconds(30)
        )
    }
}

// MARK: - Snappy UI (reversible Dock/animation defaults, no root)

public enum SnappyUI {
    static var dockDomain: CFString { "com.apple.dock" as CFString }

    public static var isApplied: Bool {
        CFPreferencesCopyAppValue("autohide-time-modifier" as CFString, dockDomain) != nil
    }

    public static func apply() async {
        CFPreferencesSetAppValue("autohide-delay" as CFString, 0.0 as CFNumber, dockDomain)
        CFPreferencesSetAppValue("autohide-time-modifier" as CFString, 0.3 as CFNumber, dockDomain)
        CFPreferencesSetAppValue("expose-animation-duration" as CFString, 0.12 as CFNumber, dockDomain)
        CFPreferencesSetAppValue("mineffect" as CFString, "scale" as CFString, dockDomain)
        CFPreferencesSetAppValue("launchanim" as CFString, kCFBooleanFalse, dockDomain)
        CFPreferencesAppSynchronize(dockDomain)
        await restartDock()
    }

    public static func revert() async {
        for key in ["autohide-delay", "autohide-time-modifier", "expose-animation-duration",
                    "mineffect", "launchanim"] {
            CFPreferencesSetAppValue(key as CFString, nil, dockDomain)
        }
        CFPreferencesAppSynchronize(dockDomain)
        await restartDock()
    }

    /// The Dock relaunches instantly via launchd; this is how every Dock
    /// tweak takes effect.
    private static func restartDock() async {
        _ = try? await ShellRunner.run("/usr/bin/killall", ["Dock"], timeout: .seconds(10))
    }

    public static let reduceMotionSettingsURL =
        "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"
}

// MARK: - Homebrew background services

public struct BrewService: Sendable, Identifiable {
    public let name: String
    public let status: String   // "started", "none", "error", …
    public var id: String { name }
    public var isRunning: Bool { status == "started" }
}

public enum BrewServices {
    public static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// brew loves to auto-update and hit its API on incidental commands —
    /// on a slow network that read as a frozen Health screen. Both are
    /// disabled here, with a short leash regardless.
    static let quietEnv = [
        "HOMEBREW_NO_AUTO_UPDATE": "1",
        "HOMEBREW_NO_INSTALL_FROM_API_UNSUPPORTED": "1",
        "HOMEBREW_NO_ANALYTICS": "1",
    ]

    public static func list() async -> [BrewService] {
        guard let brew = brewPath,
              let output = try? await ShellRunner.run(
                brew, ["services", "list"], timeout: .seconds(10), environment: quietEnv
              )
        else { return [] }
        return output.split(separator: "\n").compactMap { line in
            // Skip headers and brew's status chatter (e.g. "✔︎ JSON API …").
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, !line.hasPrefix("Name"),
                  ["started", "none", "error", "stopped", "scheduled"].contains(String(parts[1]))
            else { return nil }
            return BrewService(name: String(parts[0]), status: String(parts[1]))
        }
    }

    public static func stopService(_ name: String) async {
        guard let brew = brewPath else { return }
        _ = try? await ShellRunner.run(
            brew, ["services", "stop", name], timeout: .seconds(60), environment: quietEnv
        )
    }

}
