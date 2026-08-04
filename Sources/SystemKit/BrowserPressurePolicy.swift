import Foundation

/// Decides how hard to throttle browsers, from what actually makes a Mac feel
/// stuck rather than from how much RAM it was sold with.
///
/// The old rule was two lines: 8 GB or less → always throttle, otherwise ask
/// the pressure sysctl. Both halves were wrong in practice. An 8 GB Mac with
/// nothing open got its browsers throttled for no reason, and above 8 GB a
/// single flapping sysctl decided everything — which is also what made the
/// level cycle recurse without end.
///
/// What a person actually notices is **swap**. Once macOS is paging, every
/// click waits on the disk, and that is the "it feels stuck" everyone
/// describes. Free memory and the pressure level corroborate it.
///
/// Every threshold here has two values, not one. A single boundary makes a
/// machine sitting on it flip back and forth, rewriting browser policies each
/// time; you have to be clearly worse to get throttled and clearly better to
/// be let go.
public enum BrowserPressurePolicy {

    public enum Level: String, Sendable, CaseIterable {
        /// Everything sleeps aggressively. The machine is struggling now.
        case light
        /// Background tabs sleep, foreground untouched.
        case balanced
        /// Nothing throttled.
        case full
    }

    public struct Reading: Sendable {
        public let totalBytes: Int64
        public let usedBytes: Int64
        public let swapBytes: Int64
        public let pressure: MemoryPressureLevel

        public init(
            totalBytes: Int64, usedBytes: Int64, swapBytes: Int64,
            pressure: MemoryPressureLevel
        ) {
            self.totalBytes = totalBytes
            self.usedBytes = usedBytes
            self.swapBytes = swapBytes
            self.pressure = pressure
        }

        /// What's left, as a share of the whole. Comparing shares rather than
        /// gigabytes is what lets one rule serve an 8 GB laptop and a 64 GB
        /// desktop: 2 GB free is comfortable on one and dire on the other.
        public var freeFraction: Double {
            guard totalBytes > 0 else { return 1 }
            return max(0, Double(totalBytes - usedBytes) / Double(totalBytes))
        }
    }

    /// `current` is what's applied right now, and it widens the band: the
    /// thresholds to tighten are stricter than the thresholds to relax.
    public static func level(for reading: Reading, current: Level?) -> Level {
        let free = reading.freeFraction
        let swappingHard = reading.swapBytes > 3 << 30       // 3 GB
        let swappingAtAll = reading.swapBytes > 512 << 20    // 512 MB

        // Paging heavily, or the kernel is shouting: nothing else matters.
        if swappingHard || reading.pressure == .critical { return .light }

        switch current {
        case .light:
            // Earn the way out. Swap has to be essentially gone and a real
            // margin of memory back before we stop throttling.
            if !swappingAtAll, free > 0.30, reading.pressure == .normal {
                return .balanced
            }
            return .light

        case .full, .balanced, .none:
            if swappingAtAll || reading.pressure == .warning || free < 0.15 {
                return .light
            }
            // Plenty of headroom and nothing paging: get out of the way.
            if free > 0.45, reading.swapBytes == 0, reading.pressure == .normal {
                return .full
            }
            return .balanced
        }
    }

    /// Plain-language reason, so the UI can say why it did something instead
    /// of silently changing the user's browser.
    public static func reason(for reading: Reading, level: Level) -> String {
        let swap = ByteCountFormatter.string(
            fromByteCount: reading.swapBytes, countStyle: .file
        )
        switch level {
        case .light where reading.swapBytes > 512 << 20:
            return String(localized: "Your Mac is using \(swap) of swap — it's reading memory off the disk, which is what makes everything feel slow.")
        case .light:
            return String(localized: "Memory is tight right now.")
        case .balanced:
            return String(localized: "Memory is comfortable; only background tabs sleep.")
        case .full:
            return String(localized: "Plenty of memory free — nothing is being throttled.")
        }
    }
}
