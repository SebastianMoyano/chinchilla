import Foundation
import SwiftUI
import DiskScanKit

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
    nonisolated static let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Chinchilla/ui-stalls.log")

    private var timer: Task<Void, Never>?
    private let stateLock = NSLock()
    nonisolated(unsafe) private var lastCPUSeconds = StallDetector.cpuSeconds()
    nonisolated(unsafe) private var lastSample = Date()
    nonisolated(unsafe) private var busySince: Date?
    nonisolated(unsafe) private var reported = false

    /// Describes what's on screen — filled in by the app so the log names the
    /// screen and any operation in flight.
    /// Refreshed by the app while it's still responsive; read from the
    /// watchdog's own thread when it isn't.
    let lastKnownContext = Locked("unknown")

    func start() {
        guard timer == nil else { return }
        // Deliberately NOT on the main actor. The first version sampled from a
        // MainActor task, which cannot run while the main thread is the thing
        // that's stuck — so the one time it mattered, it recorded nothing. A
        // watchdog that shares a lane with what it watches is decoration.
        let queue = DispatchQueue(label: "chinchilla.stalls", qos: .utility)
        timer = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                let snapshot: Snapshot? = await withCheckedContinuation { continuation in
                    queue.async { continuation.resume(returning: self.sampleOffMain()) }
                }
                guard let snapshot else { continue }
                // Asking the main actor for context would hang with it, so the
                // record goes out first and the context is best-effort after.
                self.record(snapshot)
            }
        }
    }

    struct Snapshot: Sendable {
        let usage: Double
        let seconds: TimeInterval
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Runs off the main thread, and touches nothing that lives on it.
    nonisolated private func sampleOffMain() -> Snapshot? {
        stateLock.lock(); defer { stateLock.unlock() }
        let now = Date()
        let cpu = Self.cpuSeconds()
        let elapsed = now.timeIntervalSince(lastSample)
        defer { lastCPUSeconds = cpu; lastSample = now }
        guard elapsed > 0 else { return nil }

        let usage = (cpu - lastCPUSeconds) / elapsed        // 1.0 == one full core
        guard usage > 0.6 else {
            busySince = nil
            reported = false
            return nil
        }
        guard let since = busySince else {
            busySince = now
            return nil
        }
        // Sustained, not a one-off scan or an encode burst.
        guard !reported, now.timeIntervalSince(since) >= 20 else { return nil }
        reported = true
        return Snapshot(usage: usage, seconds: now.timeIntervalSince(since))
    }

    nonisolated private func record(_ snapshot: Snapshot) {
        record(usage: snapshot.usage, seconds: snapshot.seconds)
    }

    nonisolated private func record(usage: Double, seconds: TimeInterval) {
        let line = String(
            format: "%@  spinning at %.0f%% of a core for %.0fs — %@\n",
            ISO8601DateFormatter().string(from: Date()), usage * 100, seconds,
            lastKnownContext.withLock { $0 }
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
