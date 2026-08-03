import Foundation
import SwiftUI

/// Notices when Chinchilla is burning CPU while sitting still, and writes down
/// what it was doing at the time.
///
/// Two freezes have now been caught in the act — both with the same shape:
/// the app pinned at ~100% of a core, redrawing continuously, with no work of
/// ours running. Three candidate explanations were tested and each turned out
/// not to reproduce, so rather than keep guessing, the app records its own
/// state when it happens. The log is what the next report should carry.
@MainActor
final class StallDetector {
    static let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Chinchilla/ui-stalls.log")

    private var timer: Task<Void, Never>?
    private var lastCPUSeconds = StallDetector.cpuSeconds()
    private var lastSample = Date()
    private var busySince: Date?
    private var reported = false

    /// Describes what's on screen — filled in by the app so the log names the
    /// screen and any operation in flight.
    var context: @MainActor () -> String = { "unknown" }

    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.sample()
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func sample() {
        let now = Date()
        let cpu = Self.cpuSeconds()
        let elapsed = now.timeIntervalSince(lastSample)
        defer { lastCPUSeconds = cpu; lastSample = now }
        guard elapsed > 0 else { return }

        let usage = (cpu - lastCPUSeconds) / elapsed        // 1.0 == one full core
        guard usage > 0.6 else {
            busySince = nil
            reported = false
            return
        }
        guard let since = busySince else {
            busySince = now
            return
        }
        // Sustained, not a one-off scan or an encode burst.
        guard !reported, now.timeIntervalSince(since) >= 20 else { return }
        reported = true
        record(usage: usage, seconds: now.timeIntervalSince(since))
    }

    private func record(usage: Double, seconds: TimeInterval) {
        let line = String(
            format: "%@  spinning at %.0f%% of a core for %.0fs — %@\n",
            ISO8601DateFormatter().string(from: Date()), usage * 100, seconds, context()
        )
        let directory = Self.logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: Self.logURL)
        }
    }

    /// Total CPU time this process has used, in seconds.
    nonisolated static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ time: timeval) -> Double {
            Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
        }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
