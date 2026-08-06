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

/// What the protocol can actually see of the mirror's lag. The one part no
/// sender can measure is the TV's own display processing (picture modes,
/// motion smoothing) — glass-to-glass adds that on top, and the TV's "game
/// mode" toggle moves it more than anything this struct contains.
public struct MirrorLatency: Sendable, Equatable {
    /// Send→ACK per frame: one-way transit + the receiver taking the frame.
    public let sendToAckP50Ms: Int
    /// The tail — where a forming queue shows first.
    public let sendToAckP95Ms: Int
    /// What the receiver says it is actually buffering.
    public let playoutDelayMs: Int

    public init(sendToAckP50Ms: Int, sendToAckP95Ms: Int, playoutDelayMs: Int) {
        self.sendToAckP50Ms = sendToAckP50Ms
        self.sendToAckP95Ms = sendToAckP95Ms
        self.playoutDelayMs = playoutDelayMs
    }

    /// Buffer plus roughly one-way transit: what we'd bet the lag is,
    /// before the TV's own processing.
    public var estimatedTotalMs: Int { playoutDelayMs + sendToAckP50Ms / 2 }
}

/// One knob instead of three. Resolution, bitrate and playout delay aren't
/// independent decisions — someone choosing "responsive" wants low delay AND
/// the lighter stream that makes low delay survivable, and someone choosing
/// "best picture" accepts the buffer that keeps 1080p smooth. Each level is a
/// coherent point on that trade; the adaptive ladder then works downward from
/// the level's ceiling when the Wi-Fi disagrees.
public enum MirrorPreset: String, Sendable, CaseIterable, Identifiable {
    /// Ultra is tuned for what ultra-low delay is actually used for: the TV
    /// as a desktop monitor. That content is text and mostly-still frames,
    /// where resolution decides legibility and the encoder's long GOP makes
    /// a quiet screen nearly free — so Ultra keeps 720p and gives up bits
    /// instead. H.264's low-bitrate blockiness only shows during motion
    /// bursts and heals when the screen settles; unreadable 480p text on a
    /// 65-inch panel is constant. (The "fewer pixels with headroom" trade
    /// belongs to game-style constant motion — measured on a real TV, text
    /// lost more at 480p than motion lost at lean 720p.) When the Wi-Fi
    /// truly chokes, the shared 480p floor is still there below.
    case bestPicture, balanced, responsive, ultra
    public var id: String { rawValue }

    /// Resolution ceiling for the level.
    public var quality: MirrorQuality {
        switch self {
        case .bestPicture, .balanced: .p1080
        case .responsive, .ultra: .p720
        }
    }

    /// The ladder never starts above this — each level targets its own Mbps.
    public var bitrateCap: Int {
        switch self {
        case .bestPicture: 8_000_000
        case .balanced: 6_000_000
        case .responsive: 4_000_000
        case .ultra: 2_000_000
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
        // 1.5 exists for Ultra's sake: measured on a real 65-inch panel,
        // text legibility at 720p beats motion robustness at 480p for
        // desktop mirroring, so the ladder holds resolution one rung longer
        // before shedding pixels.
        let p720 = [4_000_000, 3_000_000, 2_000_000, 1_500_000].map {
            QualityRung(quality: .p720, bitrate: $0)
        }
        // The shared floor. Rungs must descend in Mbps — a link that can't
        // carry 1.5 certainly can't carry more — and below that the only
        // honest move is shedding pixels so the bits that remain aren't
        // starved.
        let p480Floor = [1_200_000, 800_000].map {
            QualityRung(quality: .p480, bitrate: $0)
        }
        let full: [QualityRung]
        switch ceiling {
        case .p1080: full = p1080 + p720 + p480Floor
        case .p720: full = p720 + p480Floor
        // A 480p ceiling has no preset behind it; if a caller asks for it,
        // it's the constant-motion trade — pixels for headroom.
        case .p480: full = [2_500_000, 1_800_000].map {
            QualityRung(quality: .p480, bitrate: $0)
        } + p480Floor
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
    /// ladder moves, nil to stay put. `rttP95Ms` is the send→ACK tail
    /// latency: a queue forming on the link shows up there seconds before
    /// packets start dropping, which is the whole point of reacting to it.
    public mutating func assess(
        packetsSent: Int, packetsResent: Int, keyFrameRequests: Int,
        rttP95Ms: Double? = nil
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
        // Well past any healthy LAN ACK time: frames are queueing somewhere.
        let queueing = (rttP95Ms ?? 0) > 250
        let struggling = lossy || keyFrameRequests >= 2 || queueing
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
