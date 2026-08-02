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
}
