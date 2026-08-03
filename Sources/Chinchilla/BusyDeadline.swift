import Foundation

/// Guards against a loading indicator that never comes down.
///
/// This isn't cosmetic. An indeterminate `ProgressView` invalidates its view
/// every frame by design, so one left on screen makes the whole window
/// re-layout at display rate — forever. Measured on a real freeze: 100% of a
/// core, hundreds of MB of allocation churn per second, and an app that looks
/// hung while doing nothing at all.
///
/// Every busy flag in the app therefore gets a deadline. When one fires we
/// also write it down, because the flag that got stuck is exactly the thing
/// worth knowing next time.
@MainActor
enum BusyDeadline {
    static let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Chinchilla/ui-stalls.log")

    /// After `deadline`, if `isStillBusy()` is true, record it and `clear()`.
    static func arm(
        _ label: String,
        _ deadline: Duration = .seconds(60),
        isStillBusy: @escaping @MainActor () -> Bool,
        clear: @escaping @MainActor () -> Void
    ) {
        Task {
            try? await Task.sleep(for: deadline)
            guard isStillBusy() else { return }
            record(label, deadline)
            clear()
        }
    }

    private static func record(_ label: String, _ deadline: Duration) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  " +
            "\(label) was still busy after \(deadline) — cleared to stop the redraw loop\n"
        let directory = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }
}
