import Foundation

/// A cancellation signal that survives the hop onto a GCD thread.
///
/// Every long walk in this package runs its inner loop inside `Blocking.run`,
/// which is a plain `DispatchQueue.global().async` — there is no task there, so
/// `Task.isCancelled` read from inside one is *always* false. Scans wired that
/// way could not be cancelled at all: restarting a disk scan a few times left
/// several full-disk walks running on top of each other, each one still
/// hashing and stat-ing to the end.
///
/// So the flag lives in an object both sides can see: the async side sets it
/// from a cancellation handler, the walker polls it.
public final class CancelFlag: @unchecked Sendable {
    private let flag = Locked(false)

    public init() {}

    public var isCancelled: Bool { flag.withLock { $0 } }

    public func cancel() { flag.withLock { $0 = true } }

    /// The closure the walkers poll. Captures the flag, not a task.
    public var probe: @Sendable () -> Bool {
        { [flag] in flag.withLock { $0 } }
    }
}

/// Runs `body` with a flag that is set if the surrounding task is cancelled.
/// `isolated(any)` keeps a caller on the main actor on the main actor — this
/// wraps model code as often as it wraps package code.
public func withCancelFlag<T: Sendable>(
    isolation: isolated (any Actor)? = #isolation,
    _ body: (CancelFlag) async -> T
) async -> T {
    let flag = CancelFlag()
    return await withTaskCancellationHandler {
        await body(flag)
    } onCancel: {
        flag.cancel()
    }
}
