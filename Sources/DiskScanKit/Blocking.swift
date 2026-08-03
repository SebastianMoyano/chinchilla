import Foundation

/// Runs blocking work (fts walks, file hashing, stat storms) on GCD threads
/// and merely awaits from Swift concurrency. The cooperative pool has one
/// lane per core — letting disk walks squat on those lanes starves every
/// other async task in the app (the "switched tabs and it froze" bug).
public enum Blocking {
    public static func run<T: Sendable>(
        qos: DispatchQoS.QoSClass = .userInitiated,
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(returning: work())
            }
        }
    }
}
