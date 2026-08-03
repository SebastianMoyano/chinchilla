import Foundation
import IOKit.pwr_mgt

/// Keeps the machine and display awake while gaming mode is on.
public final class SleepAssertion {
    private var displayAssertion: IOPMAssertionID = 0
    private var systemAssertion: IOPMAssertionID = 0
    private(set) public var isActive = false

    public init() {}

    public func activate() {
        guard !isActive else { return }
        let reason = "Chinchilla Gaming Mode" as CFString
        IOPMAssertionCreateWithName(
            "PreventUserIdleDisplaySleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &displayAssertion
        )
        IOPMAssertionCreateWithName(
            "PreventUserIdleSystemSleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &systemAssertion
        )
        isActive = true
    }

    public func release() {
        guard isActive else { return }
        IOPMAssertionRelease(displayAssertion)
        IOPMAssertionRelease(systemAssertion)
        displayAssertion = 0
        systemAssertion = 0
        isActive = false
    }

    deinit {
        release()
    }
}

public enum TimeMachine {
    /// Stops an in-flight backup. No root needed; harmless when idle.
    /// Gaming mode re-issues this periodically instead of `tmutil disable`
    /// (which needs admin and persists across crashes/reboots).
    public static func stopBackup() async {
        _ = try? await ShellRunner.run("/usr/bin/tmutil", ["stopbackup"], timeout: .seconds(10))
    }

    /// Local APFS snapshot names on the boot volume, e.g.
    /// "com.apple.TimeMachine.2026-08-02-123456.local". These can hold on to
    /// deleted data — the #1 reason "I freed 50 GB but Finder disagrees".
    public static func localSnapshots() async -> [String] {
        guard let output = try? await ShellRunner.run(
            "/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: .seconds(15)
        ) else { return [] }
        return output.split(separator: "\n")
            .map(String.init)
            .filter { $0.contains("com.apple.TimeMachine") }
    }

    /// Asks macOS to thin local snapshots (admin prompt; macOS decides what
    /// is safe to remove — we never pick snapshots ourselves).
    public static func thinLocalSnapshots() async throws -> String {
        try await PrivilegedRunner.run("/usr/bin/tmutil thinlocalsnapshots / 999999999999 4")
    }
}

/// Runs a FIXED command line with administrator privileges via the standard
/// macOS password prompt. Callers pass literal strings only — never
/// user-controlled paths — keeping the injection surface zero.
public enum PrivilegedRunner {
    public static func run(_ command: String) async throws -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return try await ShellRunner.run(
            "/usr/bin/osascript",
            ["-e", "do shell script \"\(escaped)\" with administrator privileges"],
            timeout: .seconds(120)
        )
    }
}
