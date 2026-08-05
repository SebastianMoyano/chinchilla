import Foundation

/// Runs blocking work (fts walks, file hashing, stat storms) on GCD threads
/// and merely awaits from Swift concurrency. The cooperative pool has one
/// lane per core — letting disk walks squat on those lanes starves every
/// other async task in the app (the "switched tabs and it froze" bug).
///
/// The number of those GCD threads is bounded, because moving the work off the
/// cooperative pool only relocated the problem. The scanners fan out one task
/// per file, so a duplicate scan or a rule sweep asks for hundreds of blocks at
/// once; GCD answers by growing its pool to its own limit near 64 threads and
/// then hands out no more — at which point *every* `Blocking.run` in the app
/// waits, including the small ones the UI is awaiting on.
public enum Blocking {
    /// Wide enough that walks stay I/O-bound, far enough below GCD's own
    /// ceiling that the pool never runs dry.
    public static let width = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)

    public static func run<T: Sendable>(
        qos: DispatchQoS.QoSClass = .userInitiated,
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await gate.acquire()
        let result: T = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(returning: work())
            }
        }
        await gate.release()
        return result
    }

    private static let gate = Gate(width: width)
}

/// An async semaphore. Waiters suspend instead of blocking a thread — a
/// `DispatchSemaphore` here would park exactly the threads this exists to
/// conserve.
///
/// Deadlock-free only because every closure handed to `Blocking.run` is
/// synchronous: holding a slot cannot wait on acquiring another one.
actor Gate {
    private var available: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(width: Int) {
        available = width
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            available += 1
        } else {
            waiting.removeFirst().resume()
        }
    }

    /// For tests: how many slots are free right now.
    var free: Int { available }
}
