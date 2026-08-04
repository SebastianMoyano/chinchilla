import Foundation
import Testing
@testable import SystemKit

private func reading(
    totalGB: Double, usedGB: Double, swapGB: Double = 0,
    pressure: MemoryPressureLevel = .normal
) -> BrowserPressurePolicy.Reading {
    BrowserPressurePolicy.Reading(
        totalBytes: Int64(totalGB * 1024 * 1024 * 1024),
        usedBytes: Int64(usedGB * 1024 * 1024 * 1024),
        swapBytes: Int64(swapGB * 1024 * 1024 * 1024),
        pressure: pressure
    )
}

@Suite("Throttling follows how the Mac feels, not how much RAM it was sold with")
struct BrowserPressurePolicyTests {
    /// The old rule threw every 8 GB Mac straight to `.light` forever. An
    /// idle one has no reason to be throttled.
    @Test("An idle 8 GB Mac is left alone")
    func idleSmallMacIsNotThrottled() {
        let level = BrowserPressurePolicy.level(
            for: reading(totalGB: 8, usedGB: 2), current: nil
        )
        #expect(level == .full)
    }

    /// And the old rule left a 32 GB Mac at `.balanced` while it paged,
    /// because the sysctl hadn't tipped yet.
    @Test("A big Mac that is swapping gets throttled anyway")
    func swappingBigMacIsThrottled() {
        let level = BrowserPressurePolicy.level(
            for: reading(totalGB: 32, usedGB: 20, swapGB: 4), current: .balanced
        )
        #expect(level == .light)
    }

    @Test("Heavy swap overrides everything, even a calm pressure reading")
    func heavySwapWins() {
        let level = BrowserPressurePolicy.level(
            for: reading(totalGB: 64, usedGB: 10, swapGB: 5, pressure: .normal),
            current: .full
        )
        #expect(level == .light)
    }

    /// The whole point of two thresholds: a machine parked on the boundary
    /// must not flip on every reading. This is the shape that recursed.
    @Test("A reading on the boundary doesn't flip back and forth")
    func hysteresisHoldsOnTheBoundary() {
        // Just past the tighten threshold: 84% used, a little swap.
        let onEdge = reading(totalGB: 16, usedGB: 13.5, swapGB: 0.6)
        var level = BrowserPressurePolicy.level(for: onEdge, current: .balanced)
        #expect(level == .light)

        // Same reading again. A single-threshold rule would let it back to
        // balanced and start the cycle over.
        for _ in 0..<20 {
            level = BrowserPressurePolicy.level(for: onEdge, current: level)
            #expect(level == .light)
        }
    }

    @Test("Recovery needs a real margin, not one good reading")
    func recoveryNeedsHeadroom() {
        // Swap gone but memory still tight — not enough.
        #expect(BrowserPressurePolicy.level(
            for: reading(totalGB: 16, usedGB: 12), current: .light
        ) == .light)

        // Swap gone and a genuine margin back.
        #expect(BrowserPressurePolicy.level(
            for: reading(totalGB: 16, usedGB: 8), current: .light
        ) == .balanced)
    }

    @Test("A warning from the kernel is enough to tighten")
    func warningTightens() {
        #expect(BrowserPressurePolicy.level(
            for: reading(totalGB: 16, usedGB: 6, pressure: .warning), current: .full
        ) == .light)
    }

    @Test("The reason names swap, because that's what people feel")
    func reasonMentionsSwap() {
        let hot = reading(totalGB: 16, usedGB: 14, swapGB: 2)
        let text = BrowserPressurePolicy.reason(for: hot, level: .light)
        #expect(text.contains("swap"))
    }

    @Test("Free share is what's compared, so one rule fits every size")
    func freeFractionIsRelative() {
        #expect(reading(totalGB: 8, usedGB: 4).freeFraction == 0.5)
        #expect(reading(totalGB: 64, usedGB: 32).freeFraction == 0.5)
    }
}
