import Foundation

/// One step of the adaptive ladder: a resolution box and the bitrate to run
/// it at.
public struct QualityRung: Sendable, Equatable {
    public let quality: MirrorQuality
    public let bitrate: Int

    public init(quality: MirrorQuality, bitrate: Int) {
        self.quality = quality
        self.bitrate = bitrate
    }

    /// "1080p · 6 Mbps" — what the UI shows while the ladder moves.
    public var label: String {
        let mbps = Double(bitrate) / 1_000_000
        let number = mbps == mbps.rounded()
            ? String(Int(mbps))
            : String(format: "%.1f", mbps)
        let box = quality == .p1080 ? "1080p" : "720p"
        return "\(box) · \(number) Mbps"
    }
}

/// Adaptive mirroring quality, the way Chrome's own Cast sender does it: the
/// stream is the probe. There is no separate "speed test" to the TV — the
/// receiver can't cooperate with one, and saturating the Wi-Fi right before
/// streaming over it would measure the wrong thing. Instead the RTCP feedback
/// the sender already collects (retransmissions, key-frame requests) says
/// within a second or two whether the network is keeping up.
public enum AdaptiveQuality {
    /// Best-first. The user's quality picker is a ceiling, not a promise:
    /// the ladder never climbs above it, and drops below it when the Wi-Fi
    /// says so. Bitrate steps inside a resolution are cheap (a live encoder
    /// property); crossing a resolution boundary rebuilds the encoder.
    public static func ladder(ceiling: MirrorQuality) -> [QualityRung] {
        let p1080 = [8_000_000, 6_000_000, 4_500_000].map {
            QualityRung(quality: .p1080, bitrate: $0)
        }
        let p720 = [4_000_000, 3_000_000, 2_000_000].map {
            QualityRung(quality: .p720, bitrate: $0)
        }
        switch ceiling {
        case .p1080: return p1080 + p720
        case .p720: return p720
        }
    }

    /// Scales a capture size into a rung's box, keeping aspect and never
    /// upscaling — the same fitting rule `ScreenStreamer.captureSize` uses.
    public static func fit(
        _ size: (width: Int, height: Int), into box: (width: Int, height: Int)
    ) -> (width: Int, height: Int) {
        let scale = min(Double(box.width) / Double(size.width),
                        Double(box.height) / Double(size.height), 1)
        return (max(2, Int((Double(size.width) * scale / 2).rounded()) * 2),
                max(2, Int((Double(size.height) * scale / 2).rounded()) * 2))
    }
}

/// The decision logic, pure and clockless so it can be tested: feed it one
/// tick of stats deltas, get back the rung to switch to (or nil to hold).
///
/// Classic AIMD. Down is fast — two consecutive bad ticks and we drop a rung,
/// because a choked link degrades in hundreds of milliseconds. Up is slow —
/// a long clean streak buys one rung back — and a probe that immediately
/// fails doubles the streak the next one needs, so a link that tops out at
/// 6 Mbps isn't poked at 8 every twenty seconds forever.
public struct AdaptiveRateController: Sendable {
    private let ladder: [QualityRung]
    private var index = 0
    private var badTicks = 0
    private var goodTicks = 0
    /// Ticks to ignore after any switch: a resolution change costs a key
    /// frame burst that looks exactly like congestion.
    private var cooldown = 5
    private var goodTicksNeeded = 20
    private var ticksSinceStepUp = 1_000

    public init(ladder: [QualityRung]) {
        precondition(!ladder.isEmpty)
        self.ladder = ladder
    }

    public var current: QualityRung { ladder[index] }

    /// One tick (~a second) of stats deltas. Returns the new rung when the
    /// ladder moves, nil to stay put.
    public mutating func assess(
        packetsSent: Int, packetsResent: Int, keyFrameRequests: Int
    ) -> QualityRung? {
        ticksSinceStepUp = min(ticksSinceStepUp + 1, 1_000)
        if cooldown > 0 {
            cooldown -= 1
            return nil
        }
        // An idle desktop sends almost nothing — no evidence either way.
        // Counting quiet ticks as "good" would climb the ladder on a link
        // that was never exercised, then choke on the first busy scene.
        guard packetsSent >= 50 else {
            badTicks = 0
            return nil
        }

        let lossy = packetsResent >= 5 && packetsResent * 100 > packetsSent * 2
        let struggling = lossy || keyFrameRequests >= 2
        if struggling {
            badTicks += 1
            goodTicks = 0
            guard badTicks >= 2 else { return nil }
            badTicks = 0
            // A drop right after a climb means the probe failed: make the
            // next climb earn twice the quiet.
            if ticksSinceStepUp <= 10 {
                goodTicksNeeded = min(goodTicksNeeded * 2, 320)
            }
            guard index < ladder.count - 1 else { return nil }
            index += 1
            cooldown = 3
            return ladder[index]
        }

        badTicks = 0
        goodTicks += 1
        guard goodTicks >= goodTicksNeeded, index > 0 else { return nil }
        goodTicks = 0
        index -= 1
        cooldown = 3
        ticksSinceStepUp = 0
        return ladder[index]
    }
}
