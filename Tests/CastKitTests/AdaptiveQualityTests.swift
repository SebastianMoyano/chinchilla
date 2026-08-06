import Foundation
import Testing
@testable import CastKit

/// The adaptive ladder is what keeps a choking Wi-Fi link from turning the
/// mirror into a slideshow. The controller is pure and clockless precisely so
/// these can drive it tick by tick: down fast on congestion, up slowly on
/// quiet, and never above the user's ceiling.

private extension AdaptiveRateController {
    /// A tick with healthy traffic.
    mutating func goodTick() -> QualityRung? {
        assess(packetsSent: 500, packetsResent: 0, keyFrameRequests: 0)
    }

    /// A tick that looks like a congested link: ~4% retransmission.
    mutating func badTick() -> QualityRung? {
        assess(packetsSent: 500, packetsResent: 20, keyFrameRequests: 0)
    }

    /// Runs off the post-start (or post-switch) cooldown.
    mutating func settle(_ ticks: Int = 5) {
        for _ in 0..<ticks {
            _ = assess(packetsSent: 0, packetsResent: 0, keyFrameRequests: 0)
        }
    }
}

@Test func theLadderNeverClimbsAboveTheCeiling() {
    let capped = AdaptiveQuality.ladder(ceiling: .p720)
    #expect(capped.allSatisfy { $0.quality != .p1080 })
    // And the first rung matches what the OFFER declares for that quality.
    #expect(AdaptiveQuality.ladder(ceiling: .p1080).first?.bitrate == MirrorQuality.p1080.bitrate)
    #expect(capped.first?.bitrate == MirrorQuality.p720.bitrate)
}

@Test func everyLadderDescendsInBitsBecauseDownMustMeanLighter() {
    // A link that can't carry rung N certainly can't carry more than it —
    // whatever the resolutions involved, "down" must cost fewer Mbps.
    for ceiling in MirrorQuality.allCases {
        let rungs = AdaptiveQuality.ladder(ceiling: ceiling)
        let bitrates = rungs.map(\.bitrate)
        #expect(bitrates == bitrates.sorted(by: >))
    }
}

@Test func ultraTradesPixelsForHeadroomNotBitsForBits() {
    // The Ultra ladder is all 480p, and its top rung carries MORE bits per
    // pixel than lean 720p would — H.264 starved of bits shatters on motion.
    let ultra = AdaptiveQuality.ladder(
        ceiling: MirrorPreset.ultra.quality,
        maxBitrate: MirrorPreset.ultra.bitrateCap
    )
    #expect(ultra.allSatisfy { $0.quality == .p480 })
    #expect(ultra.first?.bitrate == 3_500_000)
    // While the shared floor under the bigger ladders goes BELOW 720p@2 —
    // the only honest way down from there.
    let floor = AdaptiveQuality.ladder(ceiling: .p1080)
    #expect(floor.last == QualityRung(quality: .p480, bitrate: 1_200_000))
}

@Test func aLevelsMbpsTargetTrimsTheTopOfTheLadder() {
    // "Balanced": 1080p ceiling but never above 6 Mbps.
    let balanced = AdaptiveQuality.ladder(
        ceiling: MirrorPreset.balanced.quality,
        maxBitrate: MirrorPreset.balanced.bitrateCap
    )
    #expect(balanced.first == QualityRung(quality: .p1080, bitrate: 6_000_000))
    #expect(balanced.allSatisfy { $0.bitrate <= 6_000_000 })
    // A cap below every rung still leaves the floor to stand on.
    let floor = AdaptiveQuality.ladder(ceiling: .p720, maxBitrate: 1)
    #expect(floor == [QualityRung(quality: .p480, bitrate: 1_200_000)])
}

@Test func sustainedLossStepsDownASingleBlipDoesNot() {
    var controller = AdaptiveRateController(ladder: AdaptiveQuality.ladder(ceiling: .p1080))
    controller.settle()

    // One bad second is Wi-Fi being Wi-Fi.
    #expect(controller.badTick() == nil)
    #expect(controller.goodTick() == nil)
    #expect(controller.current.bitrate == 8_000_000)

    // Two in a row is a trend.
    #expect(controller.badTick() == nil)
    let dropped = controller.badTick()
    #expect(dropped?.bitrate == 6_000_000)
    #expect(dropped?.quality == .p1080)
}

@Test func keyFrameRequestsCountAsCongestionToo() {
    var controller = AdaptiveRateController(ladder: AdaptiveQuality.ladder(ceiling: .p1080))
    controller.settle()
    #expect(controller.assess(packetsSent: 500, packetsResent: 0, keyFrameRequests: 2) == nil)
    let dropped = controller.assess(packetsSent: 500, packetsResent: 0, keyFrameRequests: 3)
    #expect(dropped != nil)
}

@Test func fallingFarEnoughCrossesIntoTheLowerResolution() {
    var controller = AdaptiveRateController(ladder: AdaptiveQuality.ladder(ceiling: .p1080))
    controller.settle()
    var last: QualityRung?
    // Keep the link bad; each drop has a cooldown to run off.
    for _ in 0..<50 {
        if let rung = controller.badTick() { last = rung }
    }
    #expect(last?.quality == .p480)
    #expect(last?.bitrate == 1_200_000)   // pinned to the floor, not past it
}

@Test func aQuietStretchClimbsBackOneRung() {
    var controller = AdaptiveRateController(ladder: AdaptiveQuality.ladder(ceiling: .p1080))
    controller.settle()
    _ = controller.badTick()
    _ = controller.badTick()              // down to 6 Mbps
    controller.settle(3)

    var climbed: QualityRung?
    for _ in 0..<20 where climbed == nil {
        climbed = controller.goodTick()
    }
    #expect(climbed?.bitrate == 8_000_000)
}

@Test func aFailedProbeDoublesTheQuietTheNextOneNeeds() {
    var controller = AdaptiveRateController(ladder: AdaptiveQuality.ladder(ceiling: .p1080))
    controller.settle()
    _ = controller.badTick()
    _ = controller.badTick()              // 8 → 6
    controller.settle(3)
    for _ in 0..<20 { _ = controller.goodTick() }   // climbs back to 8
    #expect(controller.current.bitrate == 8_000_000)
    controller.settle(3)
    _ = controller.badTick()
    _ = controller.badTick()              // probe failed: 8 → 6 again
    controller.settle(3)

    // The next climb now needs 40 quiet ticks, not 20.
    for _ in 0..<25 { #expect(controller.goodTick() == nil) }
    var climbed: QualityRung?
    for _ in 0..<20 where climbed == nil { climbed = controller.goodTick() }
    #expect(climbed?.bitrate == 8_000_000)
}

@Test func idleTrafficIsEvidenceOfNothing() {
    var controller = AdaptiveRateController(ladder: AdaptiveQuality.ladder(ceiling: .p1080))
    controller.settle()
    _ = controller.badTick()
    _ = controller.badTick()              // down one rung
    controller.settle(3)

    // A static desktop sends a trickle; hours of it must not climb the ladder.
    for _ in 0..<500 {
        #expect(controller.assess(packetsSent: 3, packetsResent: 0, keyFrameRequests: 0) == nil)
    }
    #expect(controller.current.bitrate == 6_000_000)
}

@Test func rungSizesKeepAspectAndNeverUpscale() {
    // A 1080p-shaped base dropping to the 720p box.
    let scaled = AdaptiveQuality.fit((1920, 1080), into: (1280, 720))
    #expect(scaled == (1280, 720))
    // A tall window is fitted, not stretched…
    let tall = AdaptiveQuality.fit((800, 1200), into: (1280, 720))
    #expect(tall.height == 720)
    #expect(tall.width == 480)
    // …and a small window is left alone rather than blown up.
    let small = AdaptiveQuality.fit((640, 400), into: (1280, 720))
    #expect(small == (640, 400))
}
