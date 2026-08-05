import Foundation
import Testing
@testable import SystemKit

/// The whole point of the history is telling "big right now" apart from "big
/// always". These pin down that distinction, and the swap correlation.

private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

private func sample(
    minute: Int, swapGB: Double = 0, apps: [(String, Double)]
) -> MemorySample {
    MemorySample(
        at: epoch.addingTimeInterval(Double(minute) * 60),
        totalBytes: 16 << 30,
        usedBytes: 8 << 30,
        swapBytes: Int64(swapGB * Double(1 << 30)),
        pressure: "normal",
        apps: apps.map { .init(name: $0.0, bytes: Int64($0.1 * Double(1 << 30))) }
    )
}

@Test func anAlwaysOnHogOutranksABiggerOccasionalOne() {
    // "Agent" is smaller but never leaves; "Installer" is huge for 2 of 20.
    var samples: [MemorySample] = []
    for minute in 0..<20 {
        var apps = [("Agent", 3.0)]
        if minute < 2 { apps.append(("Installer", 9.0)) }
        samples.append(sample(minute: minute, apps: apps))
    }

    let ranked = MemoryHistory.offenders(in: samples)
    #expect(ranked.first?.name == "Agent")
    // The installer is still listed — 2/20 clears the 10% floor — but below.
    #expect(ranked.map(\.name).contains("Installer"))
    #expect(ranked.count == 2)
}

@Test func aOneOffSpikeIsNotAnOffender() {
    var samples: [MemorySample] = []
    for minute in 0..<100 {
        var apps = [("Agent", 1.0)]
        if minute == 7 { apps.append(("Installer", 12.0)) }
        samples.append(sample(minute: minute, apps: apps))
    }

    let ranked = MemoryHistory.offenders(in: samples)
    // 1% presence, well under the floor: this is not "constantly using RAM".
    #expect(ranked.map(\.name) == ["Agent"])
}

@Test func averagesPeaksAndPresenceAreReported() {
    let samples = [
        sample(minute: 0, apps: [("Chrome", 2.0)]),
        sample(minute: 1, apps: [("Chrome", 4.0)]),
        sample(minute: 2, apps: []),
        sample(minute: 3, apps: [("Chrome", 6.0)]),
    ]

    let chrome = try? #require(MemoryHistory.offenders(in: samples).first)
    #expect(chrome?.name == "Chrome")
    #expect(chrome?.sampleCount == 3)
    #expect(chrome?.presence == 0.75)
    #expect(chrome?.averageBytes == 4 << 30)
    #expect(chrome?.peakBytes == 6 << 30)
}

@Test func swapAveragesOnlyCountSamplesWhereTheMacWasActuallySwapping() {
    let samples = [
        // A few hundred MB of swap is normal and not what anyone notices.
        sample(minute: 0, swapGB: 0.2, apps: [("Xcode", 2.0)]),
        sample(minute: 1, swapGB: 4.0, apps: [("Xcode", 8.0)]),
        sample(minute: 2, swapGB: 6.0, apps: [("Xcode", 10.0)]),
    ]

    let xcode = MemoryHistory.offenders(in: samples).first
    #expect(xcode?.swappingSampleCount == 2)
    #expect(xcode?.averageWhileSwapping == 9 << 30)
    // Its all-time average is lower — the swap figure is the interesting one.
    #expect((xcode?.averageBytes ?? 0) < (xcode?.averageWhileSwapping ?? 0))
}

@Test func anAppNeverUpDuringSwapReportsNoSwapAverage() {
    let samples = [
        sample(minute: 0, swapGB: 0, apps: [("Notes", 0.2)]),
        sample(minute: 1, swapGB: 0, apps: [("Notes", 0.2)]),
    ]
    #expect(MemoryHistory.offenders(in: samples).first?.averageWhileSwapping == nil)
}

@Test func swappingShareIgnoresTheNormalTrickleOfSwap() {
    let samples = [
        sample(minute: 0, swapGB: 0.1, apps: []),
        sample(minute: 1, swapGB: 0.4, apps: []),
        sample(minute: 2, swapGB: 3.0, apps: []),
        sample(minute: 3, swapGB: 5.0, apps: []),
    ]
    #expect(MemoryHistory.swappingShare(in: samples) == 0.5)
    #expect(MemoryHistory.swappingShare(in: []) == 0)
}

@Test func theWorstSwapMomentNamesWhatWasRunning() throws {
    let samples = [
        sample(minute: 0, swapGB: 1.0, apps: [("Slack", 1.0)]),
        sample(minute: 1, swapGB: 7.0, apps: [("Chrome", 9.0), ("Docker", 4.0), ("Slack", 1.0)]),
        sample(minute: 2, swapGB: 2.0, apps: [("Slack", 1.0)]),
    ]

    let worst = try #require(MemoryHistory.suspectsDuringWorstSwap(in: samples, count: 2))
    #expect(worst.swapBytes == 7 << 30)
    #expect(worst.at == epoch.addingTimeInterval(60))
    // Biggest first, and only as many as asked for.
    #expect(worst.apps.map(\.name) == ["Chrome", "Docker"])
}

@Test func aMacThatNeverSwappedHasNoWorstMoment() {
    let samples = [sample(minute: 0, swapGB: 0.1, apps: [("Notes", 0.2)])]
    #expect(MemoryHistory.suspectsDuringWorstSwap(in: samples) == nil)
    #expect(MemoryHistory.offenders(in: []).isEmpty)
}

@Test func recentKeepsTheWindowAndSortsOldestFirst() {
    let now = epoch.addingTimeInterval(10 * 3600)
    let samples = [
        sample(minute: 9 * 60, apps: []),   // 1 hour ago
        sample(minute: 0, apps: []),        // 10 hours ago
        sample(minute: 8 * 60, apps: []),   // 2 hours ago
    ]

    let window = MemoryHistory.recent(samples, hours: 3, now: now)
    #expect(window.count == 2)
    #expect(window.first?.at == epoch.addingTimeInterval(8 * 3600))
}

@Test func samplesSurviveARoundTripThroughTheLog() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("chinchilla-mem-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }

    let written = sample(minute: 3, swapGB: 2.5, apps: [("Chrome", 5.5)])
    MemoryHistory.append(written, to: url)

    let read = MemoryHistory.load(from: url)
    #expect(read.count == 1)
    #expect(read.first == written)
}

@Test func aHistoryFileThatIsGarbageDoesNotTakeTheScreenDown() {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("chinchilla-mem-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    try? Data("not json\n{\"also\":\"not a sample\"}\n".utf8).write(to: url)

    #expect(MemoryHistory.load(from: url).isEmpty)
}
