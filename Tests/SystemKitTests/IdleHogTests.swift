import Foundation
import Testing
@testable import SystemKit

/// "Big" is not a reason to close anything. "Big, and has done nothing
/// measurable for forty minutes, and isn't what you're looking at" is. These
/// pin down that distinction, because it's the whole difference between an app
/// that informs and one that helps.

private let epoch = Date(timeIntervalSince1970: 1_770_000_000)
private let gb = Int64(1 << 30)

private func sample(
    minute: Int, frontmost: String? = nil, apps: [(String, Double, Double?)]
) -> MemorySample {
    MemorySample(
        at: epoch.addingTimeInterval(Double(minute) * 60),
        totalBytes: 8 * gb, usedBytes: 6 * gb, swapBytes: 4 * gb,
        pressure: "warning",
        apps: apps.map { .init(name: $0.0, bytes: Int64($0.1 * Double(gb)), cpu: $0.2) },
        frontmost: frontmost
    )
}

@Test func anAppDoingNothingForAWhileIsWorthAskingAbout() throws {
    let samples = (0..<30).map { minute in
        sample(minute: minute, frontmost: "Xcode", apps: [
            ("Xcode", 3.0, 40.0),      // in front and working
            ("Slack", 1.8, 0.1),       // holding memory, doing nothing
        ])
    }

    let hogs = MemoryHistory.idleHogs(in: samples)
    let slack = try #require(hogs.first)
    #expect(slack.name == "Slack")
    #expect(slack.bytes == Int64(1.8 * Double(gb)))
    #expect(slack.idleSamples == 30)
    #expect(slack.averageCPU < 1)
    // Xcode is both busy and in front; twice disqualified.
    #expect(hogs.contains { $0.name == "Xcode" } == false)
}

@Test func idlenessOnlyCountsWhileItIsUnbroken() {
    // Quiet for ages, then it woke up two minutes ago.
    let samples = (0..<30).map { minute in
        sample(minute: minute, apps: [("Backup", 2.0, minute >= 28 ? 60.0 : 0.0)])
    }
    // The streak from the newest reading backwards is 0: it is working now.
    #expect(MemoryHistory.idleHogs(in: samples).isEmpty)
}

@Test func aBriefLullIsNotIdleness() {
    let samples = (0..<30).map { minute in
        sample(minute: minute, apps: [("Compiler", 2.0, minute >= 27 ? 0.0 : 80.0)])
    }
    // Three quiet readings is a pause between builds, not an idle app.
    #expect(MemoryHistory.idleHogs(in: samples).isEmpty)
    // With a lower bar it does appear — the threshold is the judgement.
    #expect(MemoryHistory.idleHogs(in: samples, minimumIdleSamples: 3).count == 1)
}

@Test func whatYouAreLookingAtIsNeverACandidate() {
    let samples = (0..<30).map { minute in
        // Idle by CPU — reading a page is not CPU — but it's in front.
        sample(minute: minute, frontmost: "Safari", apps: [("Safari", 4.0, 0.2)])
    }
    #expect(MemoryHistory.idleHogs(in: samples).isEmpty)
}

@Test func somethingSmallIsNotWorthAQuestion() {
    let samples = (0..<30).map { minute in
        sample(minute: minute, apps: [("Notes", 0.2, 0.0)])
    }
    // Closing a 200 MB app to fix a 1.5 GB shortfall is a waste of a prompt.
    #expect(MemoryHistory.idleHogs(in: samples).isEmpty)
}

@Test func biggerAndLongerIdleRanksFirst() {
    let samples = (0..<30).map { minute in
        sample(minute: minute, apps: [
            ("Sync", 3.0, 0.0),
            ("Music", 1.0, 0.0),
        ])
    }
    #expect(MemoryHistory.idleHogs(in: samples).map(\.name) == ["Sync", "Music"])
}

@Test func anOldLogWithoutCPUDataProposesNothing() {
    // Absence of evidence isn't evidence of idleness: readings recorded before
    // CPU was sampled must not be read as "this app did nothing".
    let samples = (0..<30).map { minute in
        sample(minute: minute, apps: [("Slack", 2.0, nil)])
    }
    #expect(MemoryHistory.idleHogs(in: samples).isEmpty)
}

@Test func anAppThatJustAppearedHasNoIdleHistoryYet() {
    var samples = (0..<30).map { minute in
        sample(minute: minute, apps: [("Chrome", 2.0, 5.0)])
    }
    samples.append(sample(minute: 30, apps: [("Chrome", 2.0, 5.0), ("Installer", 4.0, 0.0)]))
    // One quiet reading is not forty minutes of doing nothing.
    #expect(MemoryHistory.idleHogs(in: samples).isEmpty)
}
