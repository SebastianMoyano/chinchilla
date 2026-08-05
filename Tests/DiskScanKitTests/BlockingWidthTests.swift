import Foundation
import Testing
@testable import DiskScanKit

/// The scanners fan out one task per file. Unbounded, that asked GCD for
/// hundreds of threads at once, it grew to its own ceiling near 64, and then
/// every `Blocking.run` in the app — including the small ones the UI awaits —
/// got nothing. These check the bound holds without serialising the work.

@Test("Never more than `width` blocks run at once")
func concurrencyStaysUnderTheBound() async {
    let live = Locked(0)
    let peak = Locked(0)

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<400 {
            group.addTask {
                await Blocking.run {
                    let now = live.withLock { count in
                        count += 1
                        return count
                    }
                    peak.withLock { $0 = max($0, now) }
                    usleep(2000)
                    live.withLock { $0 -= 1 }
                }
            }
        }
    }

    #expect(peak.withLock { $0 } <= Blocking.width)
    #expect(live.withLock { $0 } == 0)
}

@Test("The bound is a bound, not a queue of one")
func workStillRunsInParallel() async {
    let peak = Locked(0)
    let live = Locked(0)

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<Blocking.width {
            group.addTask {
                await Blocking.run {
                    let now = live.withLock { count in
                        count += 1
                        return count
                    }
                    peak.withLock { $0 = max($0, now) }
                    usleep(20_000)
                    live.withLock { $0 -= 1 }
                }
            }
        }
    }

    // Serialised, this would peak at 1.
    #expect(peak.withLock { $0 } > 1)
}

@Test("Every slot is handed back, so later work isn't starved")
func slotsAreReturned() async {
    for _ in 0..<(Blocking.width * 3) {
        _ = await Blocking.run { 1 }
    }
    // If releases leaked, this last one would never be scheduled.
    let answer = await Blocking.run { 42 }
    #expect(answer == 42)
}
