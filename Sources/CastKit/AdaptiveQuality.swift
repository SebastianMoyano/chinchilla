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
        return "\(quality.heightLabel) · \(number) Mbps"
    }
}

/// One knob instead of three. Resolution, bitrate and playout delay aren't
/// independent decisions — someone choosing "responsive" wants low delay AND
/// the lighter stream that makes low delay survivable, and someone choosing
/// "best picture" accepts the buffer that keeps 1080p smooth. Each level is a
/// coherent point on that trade; the adaptive ladder then works downward from
/// the level's ceiling when the Wi-Fi disagrees.
public enum MirrorPreset: String, Sendable, CaseIterable, Identifiable {
    /// Ultra follows the H.264 playbook, because H.264 is what the Cast
    /// mirror receiver actually negotiates (no Mac has an AV1 hardware
    /// encoder, and HEVC isn't in the receiver's vocabulary): at ultra-low
    /// delay you drop *pixels*, not bits — 480p with bitrate headroom
    /// survives fast motion where a starved 720p shatters into blocks.
    case bestPicture, balanced, responsive, ultra
    public var id: String { rawValue }

    /// Resolution ceiling for the level.
    public var quality: MirrorQuality {
        switch self {
        case .bestPicture, .balanced: .p1080
        case .responsive: .p720
        case .ultra: .p480
        }
    }

    /// The ladder never starts above this — each level targets its own Mbps.
    public var bitrateCap: Int {
        switch self {
        case .bestPicture: 8_000_000
        case .balanced: 6_000_000
        case .responsive: 4_000_000
        case .ultra: 3_500_000
        }
    }

    /// How long the TV holds frames. Lower feels immediate, needs headroom.
    public var playoutDelayMs: Int {
        switch self {
        case .bestPicture: 400
        case .balanced: 200
        case .responsive: 100
        case .ultra: 50
        }
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
    public static func ladder(
        ceiling: MirrorQuality, maxBitrate: Int = .max
    ) -> [QualityRung] {
        let p1080 = [8_000_000, 6_000_000, 4_500_000].map {
            QualityRung(quality: .p1080, bitrate: $0)
        }
        let p720 = [4_000_000, 3_000_000, 2_000_000].map {
            QualityRung(quality: .p720, bitrate: $0)
        }
        // 480p plays two different roles, so it gets two different bitrate
        // sets. As the *floor* of the bigger ladders it sits below 720p@2 —
        // rungs must descend in Mbps, because a link that can't carry 2 Mbps
        // certainly can't carry more, and going lower than 2 on H.264 means
        // shedding pixels so the bits that remain aren't starved. As the
        // *ceiling* of the Ultra level the constraint is latency, not
        // bandwidth: fewer pixels WITH bitrate headroom, because a lean
        // 480p would shatter on motion just like a lean 720p does.
        let p480Floor = [1_800_000, 1_200_000].map {
            QualityRung(quality: .p480, bitrate: $0)
        }
        let p480Ultra = [3_500_000, 2_500_000, 1_500_000].map {
            QualityRung(quality: .p480, bitrate: $0)
        }
        let full: [QualityRung]
        switch ceiling {
        case .p1080: full = p1080 + p720 + p480Floor
        case .p720: full = p720 + p480Floor
        case .p480: full = p480Ultra
        }
        // A level's Mbps target trims the top; the floor always survives, so
        // a cap below every rung still leaves somewhere to stand.
        let capped = full.filter { $0.bitrate <= maxBitrate }
        return capped.isEmpty ? [full[full.count - 1]] : capped
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
