import Foundation
import Testing
@testable import DiskScanKit

/// The scans were uncancellable and nothing said so. These pin down why.

@Test("Task.isCancelled is blind inside Blocking.run — the bug, written down")
func taskCancellationDoesNotReachAGCDThread() async {
    let sawCancellation = Locked(false)
    let started = Locked(false)

    let task = Task {
        await Blocking.run {
            started.withLock { $0 = true }
            // Long enough that the cancel below lands well inside the loop.
            for _ in 0..<200 {
                if Task.isCancelled {
                    sawCancellation.withLock { $0 = true }
                    return
                }
                usleep(1000)
            }
        }
    }

    while !started.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(1)) }
    task.cancel()
    await task.value

    // There is no task on a GCD thread, so this never becomes true — which is
    // exactly why "Cancel" left full-disk walks running behind the new scan.
    #expect(sawCancellation.withLock { $0 } == false)
}

@Test("A CancelFlag does reach it")
func cancelFlagReachesAGCDThread() async {
    let stoppedEarly = Locked(false)
    let started = Locked(false)

    let task = Task {
        await withCancelFlag { cancel in
            await Blocking.run {
                started.withLock { $0 = true }
                for _ in 0..<2000 {
                    if cancel.isCancelled {
                        stoppedEarly.withLock { $0 = true }
                        return
                    }
                    usleep(1000)
                }
            }
        }
    }

    while !started.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(1)) }
    task.cancel()
    await task.value

    #expect(stoppedEarly.withLock { $0 })
}

@Test("The probe closure carries the flag, so walkers can poll it")
func probeSeesTheCancellation() {
    let flag = CancelFlag()
    let probe = flag.probe
    #expect(probe() == false)
    flag.cancel()
    #expect(probe())
    // Cancelling twice is not a state change anyone has to handle.
    flag.cancel()
    #expect(flag.isCancelled)
}
