import SwiftUI
import Observation
import SystemKit
import DiskScanKit

/// Keeps a record of what the Mac's memory has been doing, and works out which
/// apps are behind it.
///
/// The rest of the app can already say what's big *right now*. That answers the
/// wrong question — a browser at 6 GB while you're reading in it is fine, and a
/// sync agent that sits at 3 GB all day is not. Only a record over time tells
/// those apart, so one sample a minute is written to disk and kept for a few
/// days.
@MainActor
@Observable
final class MemoryHistoryModel {
    private(set) var samples: [MemorySample] = []
    private(set) var offenders: [MemoryOffender] = []
    private(set) var swappingShare: Double = 0
    private(set) var worstSwap: (at: Date, swapBytes: Int64, apps: [MemorySample.AppFootprint])?
    private(set) var loading = false

    /// How far back the chart looks. A whole day is the useful default: long
    /// enough to catch "it gets bad in the afternoon", short enough to be about
    /// today rather than last week.
    var windowHours: Double = 24 {
        didSet { recompute() }
    }

    private var sampler: Task<Void, Never>?

    /// Fired after each new reading, with everything known so far. The
    /// everyday plan hangs off this so it never has to poll or recompute
    /// while drawing.
    var onSample: (@MainActor ([MemorySample]) -> Void)?

    /// One a minute at rest. Each sample costs a process enumeration, so this
    /// is a deliberate trade: fine enough to see an afternoon build up, cheap
    /// enough to leave running.
    static let interval: Duration = .seconds(60)
    /// On a Mac with no history yet, a minute per reading means ten minutes of
    /// staring at "still collecting". The first stretch is sampled faster so
    /// the screen becomes worth opening in about two minutes; the record it
    /// leaves behind is the same shape either way.
    static let warmUpInterval: Duration = .seconds(12)
    static let warmUpSamples = 12

    func start() {
        guard sampler == nil else { return }
        sampler = Task { [weak self] in
            // Every reading and the disk write happen off the main actor;
            // only the assignment back comes home.
            var taken = 0
            while !Task.isCancelled {
                // Read on the main actor, where NSWorkspace belongs.
                let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName
                let sample = await Self.takeSample(frontmost: frontmost)
                guard let self else { return }
                await Blocking.run(qos: .utility) { MemoryHistory.append(sample) }
                samples.append(sample)
                // The disk log rolls; this array didn't, and in an app that
                // stays up for weeks it grew by the minute with recompute()
                // walking all of it each time.
                if samples.count > MemoryHistory.keptSamples {
                    samples.removeFirst(samples.count - MemoryHistory.keptSamples)
                }
                recompute()
                onSample?(samples)
                taken += 1
                let warmingUp = taken < Self.warmUpSamples && samples.count < Self.warmUpSamples
                try? await Task.sleep(for: warmingUp ? Self.warmUpInterval : Self.interval)
            }
        }
    }

    func stop() {
        sampler?.cancel()
        sampler = nil
    }

    /// Only the first visit needs the disk: after that the in-app sampler is
    /// feeding `samples`, and re-reading days of readings on every tab switch
    /// was redundant IO that also overwrote fresher data with the same data.
    private var loadedOnce = false

    /// Reads what previous runs recorded. Called when the screen appears, so
    /// history survives quitting the app.
    func load() {
        guard !loadedOnce, !loading else { return }
        loadedOnce = true
        loading = true
        BusyDeadline.arm("MemoryHistory.load", .seconds(30)) { [weak self] in
            self?.loading ?? false
        } clear: { [weak self] in self?.loading = false }
        Task {
            defer { loading = false }
            let loaded = await Blocking.run { MemoryHistory.load() }
            samples = loaded
            recompute()
        }
    }

    /// Derived once per change, never inside a view body — the screens that
    /// did that arithmetic while drawing are what made this app feel stuck.
    private func recompute() {
        let window = MemoryHistory.recent(samples, hours: windowHours, now: Date())
        chartSamples = window
        offenders = MemoryHistory.offenders(in: window)
        swappingShare = MemoryHistory.swappingShare(in: window)
        worstSwap = MemoryHistory.suspectsDuringWorstSwap(in: window)
    }

    private(set) var chartSamples: [MemorySample] = []

    /// Long enough to be worth reading. Below this the screen says it's still
    /// collecting rather than drawing conclusions from four minutes of data.
    var hasEnoughHistory: Bool { chartSamples.count >= 10 }

    var coverage: String? {
        guard let first = chartSamples.first?.at, let last = chartSamples.last?.at,
              last > first else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .short
        return formatter.string(from: last.timeIntervalSince(first))
    }

    /// `nonisolated` so it can run on the GCD thread it's handed to: a process
    /// enumeration on the main actor is exactly the kind of thing that makes
    /// the window stutter once a minute, forever.
    private nonisolated static func takeSample(frontmost: String?) async -> MemorySample {
        let memory = SystemSampler.memoryUsage()
        // With CPU, over a one-second window. That extra second once a minute
        // buys the difference between "this app is big" and "this app is big
        // and has done nothing for forty minutes" — which is the difference
        // between a screen that informs and one that can offer to help.
        let apps = await ProcessMemory.topConsumersWithCPU(limit: 12)
        return MemorySample(
            at: Date(),
            totalBytes: memory.total,
            usedBytes: memory.used,
            swapBytes: SystemSampler.swapUsed(),
            pressure: SystemSampler.memoryPressure().name,
            // "macOS" is the kernel's own bucket, not an app anyone can act
            // on; listing it as the top offender every single time would be
            // true and useless.
            apps: apps
                .filter { $0.name != "macOS" }
                .map {
                    MemorySample.AppFootprint(
                        name: $0.name, bytes: $0.footprint, cpu: $0.cpuPercent
                    )
                },
            frontmost: frontmost
        )
    }
}
