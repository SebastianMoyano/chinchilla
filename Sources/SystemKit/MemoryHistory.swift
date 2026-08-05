import Foundation

/// What the Mac's memory looked like at one moment.
///
/// The app could already say which apps are big *right now*, which answers the
/// wrong question: a browser at 6 GB while you're using it is not a problem,
/// and a sync agent that sits at 3 GB all day is. Telling those apart needs
/// history, so a sample is written every minute and kept.
public struct MemorySample: Codable, Sendable, Equatable {
    public let at: Date
    public let totalBytes: Int64
    public let usedBytes: Int64
    public let swapBytes: Int64
    /// `MemoryPressureLevel.rawValue` — stored as a string so an added case
    /// never invalidates an old log.
    public let pressure: String
    public let apps: [AppFootprint]

    public struct AppFootprint: Codable, Sendable, Equatable {
        public let name: String
        public let bytes: Int64
        /// CPU over the sampling window, 0–100 per core. Optional because
        /// logs written before this existed must still decode.
        ///
        /// This is what turns a list into a recommendation: "big" is not a
        /// reason to close anything, and "big and has done nothing measurable
        /// for forty minutes" is.
        public let cpu: Double?

        public init(name: String, bytes: Int64, cpu: Double? = nil) {
            self.name = name
            self.bytes = bytes
            self.cpu = cpu
        }
    }

    /// The app in front when the reading was taken. Never a candidate for
    /// anything: it's what the user is doing.
    public let frontmost: String?

    public init(
        at: Date, totalBytes: Int64, usedBytes: Int64, swapBytes: Int64,
        pressure: String, apps: [AppFootprint], frontmost: String? = nil
    ) {
        self.at = at
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.swapBytes = swapBytes
        self.pressure = pressure
        self.apps = apps
        self.frontmost = frontmost
    }

    /// Swapping at all, in the sense a person would notice: macOS keeps a few
    /// hundred MB of swap allocated on machines that are perfectly happy.
    public var isSwapping: Bool { swapBytes > 512 << 20 }

    public var freeFraction: Double {
        guard totalBytes > 0 else { return 1 }
        return max(0, Double(totalBytes - usedBytes) / Double(totalBytes))
    }
}

/// One app's record across the whole history.
public struct MemoryOffender: Sendable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    /// How many samples this app was running in.
    public let sampleCount: Int
    /// Share of all samples — "constantly" made measurable.
    public let presence: Double
    public let averageBytes: Int64
    public let peakBytes: Int64
    /// Its average size in the samples where the Mac was actually swapping.
    /// Nil when the Mac never swapped while this app was up, which is the
    /// answer for most apps and worth showing as such.
    public let averageWhileSwapping: Int64?
    public let swappingSampleCount: Int

    /// What ranks an app: big *and* always there. A 6 GB browser you opened
    /// once shouldn't outrank a 3 GB agent that never leaves.
    public var weight: Double { Double(averageBytes) * presence }
}

public enum MemoryHistory {
    public static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Chinchilla/memory-history.jsonl")
    }

    /// A minute per sample, so this holds a few days and stays small enough to
    /// parse in one go. Public because the in-memory array the sampler builds
    /// obeys the same cap.
    public static let keptSamples = 5000
    static let limit = RollingLog.Limit(maxBytes: 2 * 1024 * 1024, keepLines: keptSamples)

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func append(_ sample: MemorySample, to url: URL = MemoryHistory.url) {
        guard let data = try? encoder.encode(sample) else { return }
        RollingLog.append(data, to: url, limit: limit)
    }

    public static func load(from url: URL = MemoryHistory.url, limit count: Int = keptSamples) -> [MemorySample] {
        let decoder = decoder
        return RollingLog.tail(url, lines: count).compactMap {
            try? decoder.decode(MemorySample.self, from: Data($0.utf8))
        }
    }

    // MARK: - Aggregation
    //
    // Deliberately pure: takes samples, returns answers, reads no clock and no
    // disk. It's the part with the actual judgement in it, so it's the part
    // that has to be testable.

    /// Apps ranked by how much memory they hold *and* how constantly.
    /// `minimumPresence` drops one-off spikes: an installer that ran for two
    /// minutes is not what anyone means by "always eating my RAM".
    public static func offenders(
        in samples: [MemorySample],
        minimumPresence: Double = 0.1
    ) -> [MemoryOffender] {
        guard !samples.isEmpty else { return [] }
        let total = Double(samples.count)
        let swappingSamples = samples.filter(\.isSwapping)

        var seen: [String: (count: Int, sum: Int64, peak: Int64)] = [:]
        for sample in samples {
            for app in sample.apps {
                var record = seen[app.name] ?? (0, 0, 0)
                record.count += 1
                record.sum += app.bytes
                record.peak = max(record.peak, app.bytes)
                seen[app.name] = record
            }
        }

        var whileSwapping: [String: (count: Int, sum: Int64)] = [:]
        for sample in swappingSamples {
            for app in sample.apps {
                var record = whileSwapping[app.name] ?? (0, 0)
                record.count += 1
                record.sum += app.bytes
                whileSwapping[app.name] = record
            }
        }

        return seen.map { name, record in
            let swap = whileSwapping[name]
            return MemoryOffender(
                name: name,
                sampleCount: record.count,
                presence: Double(record.count) / total,
                averageBytes: record.sum / Int64(record.count),
                peakBytes: record.peak,
                averageWhileSwapping: swap.map { $0.sum / Int64($0.count) },
                swappingSampleCount: swap?.count ?? 0
            )
        }
        .filter { $0.presence >= minimumPresence }
        .sorted { $0.weight > $1.weight }
    }

    /// An app that is holding a lot and doing nothing with it.
    public struct IdleHog: Sendable, Identifiable, Equatable {
        public var id: String { name }
        public let name: String
        /// What it holds as of the most recent reading.
        public let bytes: Int64
        /// How long it has been doing nothing, in readings — one per minute.
        public let idleSamples: Int
        /// Its average CPU over that stretch, for the sentence shown to the
        /// user. "Doing nothing" has to be a measurement, not a guess.
        public let averageCPU: Double

        /// Big and long-idle beats big and briefly-idle.
        public var weight: Double { Double(bytes) * Double(idleSamples) }
    }

    /// Apps worth *asking* about: large, idle for a while, and not the one the
    /// user is looking at.
    ///
    /// Walks back from the newest reading and stops at the first sign of life,
    /// so a stretch of idleness only counts while it is unbroken — an app that
    /// woke up two minutes ago is not idle, however long it slept before that.
    public static func idleHogs(
        in samples: [MemorySample],
        minimumBytes: Int64 = 512 << 20,
        cpuCeiling: Double = 2.0,
        minimumIdleSamples: Int = 5
    ) -> [IdleHog] {
        let ordered = samples.sorted { $0.at < $1.at }
        guard let latest = ordered.last else { return [] }
        // Whatever the user was last in front of is off the table entirely.
        let frontmost = ordered.suffix(3).compactMap(\.frontmost)

        var hogs: [IdleHog] = []
        for app in latest.apps where app.bytes >= minimumBytes {
            guard !frontmost.contains(app.name) else { continue }
            // Missing CPU data (an older log) is not evidence of idleness.
            guard app.cpu != nil else { continue }

            var idle = 0
            var cpuTotal = 0.0
            for sample in ordered.reversed() {
                guard let entry = sample.apps.first(where: { $0.name == app.name }),
                      let cpu = entry.cpu, cpu <= cpuCeiling else { break }
                idle += 1
                cpuTotal += cpu
            }
            guard idle >= minimumIdleSamples else { continue }
            hogs.append(IdleHog(
                name: app.name, bytes: app.bytes, idleSamples: idle,
                averageCPU: cpuTotal / Double(idle)
            ))
        }
        return hogs.sorted { $0.weight > $1.weight }
    }

    /// Share of samples where the Mac was paging — the number that answers
    /// "is this machine actually short of memory, or did it just feel like it
    /// once?"
    public static func swappingShare(in samples: [MemorySample]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return Double(samples.filter(\.isSwapping).count) / Double(samples.count)
    }

    /// The apps that were up during the worst swapping, biggest first.
    /// Correlation, not blame — and the UI has to say so.
    public static func suspectsDuringWorstSwap(
        in samples: [MemorySample], count: Int = 5
    ) -> (at: Date, swapBytes: Int64, apps: [MemorySample.AppFootprint])? {
        guard let worst = samples.max(by: { $0.swapBytes < $1.swapBytes }),
              worst.isSwapping else { return nil }
        return (
            worst.at,
            worst.swapBytes,
            Array(worst.apps.sorted { $0.bytes > $1.bytes }.prefix(count))
        )
    }

    /// Samples inside the last `hours`, oldest first — what a chart plots.
    public static func recent(
        _ samples: [MemorySample], hours: Double, now: Date
    ) -> [MemorySample] {
        let cutoff = now.addingTimeInterval(-hours * 3600)
        return samples.filter { $0.at >= cutoff }.sorted { $0.at < $1.at }
    }
}
