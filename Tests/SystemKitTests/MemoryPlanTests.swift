import Foundation
import Testing
@testable import SystemKit

/// The everyday profile's judgement, pinned down. The rules that matter:
/// reversible actions come first, quitting is only ever a question, and the
/// threshold belongs to this Mac rather than to a constant someone picked.

private let epoch = Date(timeIntervalSince1970: 1_770_000_000)
private let gb = Int64(1 << 30)

/// Apps are (name, gigabytes, CPU%). CPU is what decides whether an app is
/// merely big or actually idle, so no fixture may leave it out.
private func sample(
    minute: Int, swapGB: Double, apps: [(String, Double, Double)],
    frontmost: String? = nil
) -> MemorySample {
    MemorySample(
        at: epoch.addingTimeInterval(Double(minute) * 60),
        totalBytes: 8 * gb,
        usedBytes: 6 * gb,
        swapBytes: Int64(swapGB * Double(gb)),
        pressure: "warning",
        apps: apps.map { .init(name: $0.0, bytes: Int64($0.1 * Double(gb)), cpu: $0.2) },
        frontmost: frontmost
    )
}

/// A day on an 8 GB developer Mac: browser and editor always up and in use,
/// Docker always up, a chat app holding 2 GB and doing nothing all day, and an
/// installer that showed up once.
private func devDay(swapGB: Double = 4) -> [MemorySample] {
    (0..<60).map { minute in
        var apps = [
            ("Google Chrome", 4.0, 25.0),
            ("claude", 3.0, 12.0),
            ("Docker", 1.5, 0.0),
            ("Sync", 2.0, 0.0),
        ]
        if minute < 3 { apps.append(("BigInstaller", 6.0, 0.0)) }
        return sample(minute: minute, swapGB: swapGB, apps: apps, frontmost: "Google Chrome")
    }
}

@Test func theThresholdComesFromThisMacNotAConstant() {
    // A Mac used to a bit of swap gets a higher bar than one that never pages.
    let moderate = (0..<60).map { sample(minute: $0, swapGB: 5, apps: []) }
    #expect(MemoryPlan.learnedThreshold(from: moderate, installedBytes: 32 * gb) == 5 * gb)

    // A Mac that barely pages keeps the floor, not a threshold of nearly zero.
    let calm = (0..<60).map { sample(minute: $0, swapGB: 0, apps: [("Notes", 0.2, 0.0)]) }
    #expect(MemoryPlan.learnedThreshold(from: calm, installedBytes: 8 * gb) == 1 * gb)

    // No history: a share of installed memory, never below 1 GB.
    #expect(MemoryPlan.learnedThreshold(from: [], installedBytes: 64 * gb) == 8 * gb)
    #expect(MemoryPlan.learnedThreshold(from: [], installedBytes: 4 * gb) == 1 * gb)
}

/// Found on a real 8 GB Mac: it swapped in every single reading, so the 75th
/// percentile of its own history landed *above* its current swap and the plan
/// reported nothing to do. Learning from a machine must not mean ratifying a
/// machine that is over budget every minute of the day.
@Test func aMacThatAlwaysSwapsIsNotToldThatIsNormal() {
    let always = (0..<60).map { sample(minute: $0, swapGB: 4.9, apps: [("Chrome", 4.0, 30.0)]) }
    let threshold = MemoryPlan.learnedThreshold(from: always, installedBytes: 8 * gb)

    // Capped at a quarter of installed memory, not at what it habitually does.
    #expect(threshold == 2 * gb)
    #expect(threshold < Int64(4.9 * Double(gb)))

    let plan = MemoryPlan.make(
        samples: always, currentSwapBytes: Int64(4.0 * Double(gb)),
        installedBytes: 8 * gb, browserTabsAsleep: false, dockerIdle: false
    )
    #expect(plan.isOverThreshold)
    #expect(!plan.actions.isEmpty)
}

@Test func aFewReadingsAreNotAHistory() {
    // Five samples of a quiet morning must not set the bar for the whole Mac.
    let thin = (0..<5).map { sample(minute: $0, swapGB: 6, apps: []) }
    #expect(MemoryPlan.learnedThreshold(from: thin, installedBytes: 8 * gb) == 1 * gb)
}

@Test func rolesSeparateWhatYouUseFromWhatMerelySits() {
    let offenders = MemoryHistory.offenders(in: devDay())
    let roles = MemoryPlan.roles(for: offenders)
    #expect(roles["Google Chrome"] == .essential)
    #expect(roles["claude"] == .essential)
    // Docker is up as constantly as the rest, and is still the one to stop:
    // its VM holds the memory whether or not anything is running in it.
    #expect(roles["Docker"] == .reclaimable)
    // The installer was up for 3 minutes of an hour, so it isn't in the
    // constant-hog list at all — that list answers "what holds memory all
    // day". It reappears as a quit candidate through the wider net, which is
    // a separate question with a separate list.
    #expect(roles["BigInstaller"] == nil)
    #expect(MemoryPlan.roles(
        for: MemoryHistory.offenders(in: devDay(), minimumPresence: 0.02)
    )["BigInstaller"] == .occasional)
}

@Test func nothingIsProposedBelowTheThreshold() {
    let plan = MemoryPlan.make(
        samples: devDay(), currentSwapBytes: 1 * gb, installedBytes: 8 * gb,
        browserTabsAsleep: false, dockerIdle: true
    )
    #expect(plan.isOverThreshold == false)
    #expect(plan.actions.isEmpty)
}

@Test func reversibleActionsComeBeforeAnythingThatAsks() {
    let plan = MemoryPlan.make(
        samples: devDay(), currentSwapBytes: 7 * gb, installedBytes: 8 * gb,
        browserTabsAsleep: false, dockerIdle: true
    )
    #expect(plan.isOverThreshold)
    let kinds = plan.actions.map(\.kind)
    #expect(kinds.first == .sleepBackgroundTabs)
    #expect(kinds.contains(.stopDockerVM))
    // Quitting is last, always.
    #expect(kinds.last == .quitApp)
    #expect(plan.reversibleActions.count == 2)
    #expect(plan.reversibleActions.allSatisfy { $0.isReversible })
}

@Test func anIdleDockerIsTheOneReclaimThatIsAlwaysWorthIt() {
    let busy = MemoryPlan.make(
        samples: devDay(), currentSwapBytes: 7 * gb, installedBytes: 8 * gb,
        browserTabsAsleep: true, dockerIdle: false
    )
    // Containers are running: stopping the VM would cost the user real work.
    #expect(busy.actions.contains { $0.kind == .stopDockerVM } == false)

    let idle = MemoryPlan.make(
        samples: devDay(), currentSwapBytes: 7 * gb, installedBytes: 8 * gb,
        browserTabsAsleep: true, dockerIdle: true
    )
    let docker = idle.actions.first { $0.kind == .stopDockerVM }
    #expect(docker?.target == "Docker")
    #expect(docker?.estimatedBytes == Int64(1.5 * Double(gb)))
    #expect(docker?.isReversible == true)
}

@Test func anAppTheUserRefusedIsNeverAskedAboutAgain() {
    let asked = MemoryPlan.make(
        samples: devDay(), currentSwapBytes: 7 * gb, installedBytes: 8 * gb,
        browserTabsAsleep: true, dockerIdle: false
    )
    #expect(asked.actions.first { $0.kind == .quitApp }?.target == "Sync")

    let refused = MemoryPlan.make(
        samples: devDay(), currentSwapBytes: 7 * gb, installedBytes: 8 * gb,
        browserTabsAsleep: true, dockerIdle: false, refusedQuits: ["Sync"]
    )
    #expect(refused.actions.contains { $0.kind == .quitApp } == false)
}

@Test func weNeverProposeQuittingOurselvesOrWhatYouAreWorkingIn() {
    let samples = (0..<60).map { minute in
        sample(minute: minute, swapGB: 6, apps: [
            ("Chinchilla", 0.3, 1.0), ("Finder", 0.2, 0.0), ("Google Chrome", 5.0, 0.1),
        ])
    }
    let plan = MemoryPlan.make(
        samples: samples, currentSwapBytes: 7 * gb, installedBytes: 8 * gb,
        browserTabsAsleep: true, dockerIdle: false
    )
    // Chrome is essential *and* a browser: it gets its tabs slept, never a
    // quit prompt. Chinchilla and Finder are off the table outright.
    #expect(plan.actions.contains { $0.kind == .quitApp } == false)
}

/// Size alone was never a reason to close anything. The candidate has to be
/// doing nothing with what it holds — otherwise the app is proposing you kill
/// your own build.
@Test func theQuitCandidateIsTheOneDoingNothing() {
    var samples: [MemorySample] = []
    for minute in 0..<60 {
        samples.append(sample(minute: minute, swapGB: 7, apps: [
            ("Compiler", 5.0, 85.0),   // bigger, and hard at work
            ("Sync", 2.0, 0.0),        // smaller, and idle all day
        ], frontmost: "Compiler"))
    }

    let plan = MemoryPlan.make(
        samples: samples, currentSwapBytes: 9 * gb, installedBytes: 8 * gb,
        browserTabsAsleep: true, dockerIdle: false
    )
    let quit = plan.actions.first { $0.kind == .quitApp }
    #expect(quit?.target == "Sync")
    // The reason travels with the action: an app that just says "close this"
    // is being bossy, one that says why can be judged.
    #expect(quit?.reason.contains("hasn't done anything") == true)
    #expect(quit?.reason.contains("60 minutes") == true)
}

@Test func nothingIsProposedWhenEverythingIsBusy() {
    let samples = (0..<60).map { minute in
        sample(minute: minute, swapGB: 7, apps: [
            ("Compiler", 5.0, 85.0), ("Tests", 2.0, 60.0),
        ], frontmost: "Compiler")
    }
    let plan = MemoryPlan.make(
        samples: samples, currentSwapBytes: 9 * gb, installedBytes: 8 * gb,
        browserTabsAsleep: true, dockerIdle: false
    )
    // The Mac is short of memory and every app is earning it. Say nothing.
    #expect(plan.actions.contains { $0.kind == .quitApp } == false)
}

@Test func theBudgetSaysWhetherTheMacIsSimplyTooSmallForTheWork() {
    let plan = MemoryPlan.make(
        samples: devDay(), currentSwapBytes: 7 * gb, installedBytes: 8 * gb,
        browserTabsAsleep: false, dockerIdle: true
    )
    // Chrome 4 + claude 3 + Docker 1.5 — the installer isn't part of a day.
    // Chrome 4 + claude 3 + Docker 1.5 + Sync 2 — the installer isn't a day.
    #expect(plan.dailyDemandBytes == Int64(10.5 * Double(gb)))
    #expect(plan.shortfallBytes == Int64(2.5 * Double(gb)))
}

@Test func browserChannelsAreStillBrowsers() {
    #expect(MemoryPlan.isBrowser("Google Chrome"))
    #expect(MemoryPlan.isBrowser("Google Chrome Canary"))
    #expect(MemoryPlan.isBrowser("Safari Technology Preview"))
    #expect(MemoryPlan.isBrowser("Firefox Developer Edition"))
    // Not a browser just because a browser's name starts it.
    #expect(MemoryPlan.isBrowser("Arcade") == false)
    #expect(MemoryPlan.isBrowser("Docker") == false)
}

@Test func aMacWithRoomToSpareReportsNoShortfall() {
    let samples = (0..<60).map { sample(minute: $0, swapGB: 0, apps: [("Notes", 0.3, 0.0)]) }
    let plan = MemoryPlan.make(
        samples: samples, currentSwapBytes: 0, installedBytes: 16 * gb,
        browserTabsAsleep: false, dockerIdle: true
    )
    #expect(plan.shortfallBytes == 0)
    #expect(plan.actions.isEmpty)
}
