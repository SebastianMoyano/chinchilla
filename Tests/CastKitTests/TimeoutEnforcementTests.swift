import Foundation
import Testing
@testable import CastKit

/// The operations `withTimeout` exists to bound — ScreenCaptureKit, and every
/// other Objective-C completion-handler bridge — ignore cancellation. This is
/// that shape: a continuation resumed from a queue, deaf to `cancelAll()`.
private func deafOperation(seconds: Double) async -> Int {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            continuation.resume(returning: 1)
        }
    }
}

@Suite("Deadlines are actually enforced")
struct TimeoutEnforcementTests {
    @Test("A deadline fires even when the operation ignores cancellation")
    func boundsUncancellableWork() async {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: TimedOut.self) {
            try await withTimeout(.milliseconds(300), "Deaf subsystem") {
                await deafOperation(seconds: 5)
            }
        }
        let elapsed = clock.now - start
        // The whole point: give up on schedule instead of waiting out the
        // operation. Before the fix this took the full five seconds.
        #expect(elapsed < .seconds(2), "gave up after \(elapsed)")
    }

    @Test("Work that finishes in time still returns its value")
    func passesThroughOnTime() async throws {
        let value = try await withTimeout(.seconds(5), "Deaf subsystem") {
            await deafOperation(seconds: 0.05)
        }
        #expect(value == 1)
    }
}
