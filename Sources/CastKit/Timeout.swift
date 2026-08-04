import Foundation

/// Carries an Objective-C object across a task boundary. ScreenCaptureKit's
/// types aren't marked Sendable, but they're thread-safe in the ways we use
/// them: created here, handed straight back, never mutated concurrently.
public struct Unchecked<T>: @unchecked Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
}

public struct TimedOut: LocalizedError {
    public let what: String
    public init(_ what: String) { self.what = what }
    public var errorDescription: String? {
        String(localized: "\(what) didn't respond in time.")
    }
}

/// Whichever of two outcomes lands first, exactly once.
private final class FirstResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var settled: Result<Value, any Error>?
    private var waiter: CheckedContinuation<Result<Value, any Error>, Never>?

    func settle(_ outcome: Result<Value, any Error>) {
        lock.lock()
        guard settled == nil else { lock.unlock(); return }
        settled = outcome
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: outcome)
    }

    var value: Result<Value, any Error> {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let settled {
                    lock.unlock()
                    continuation.resume(returning: settled)
                    return
                }
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

/// Runs `operation` with a deadline that is actually enforced.
///
/// The obvious spelling — a throwing task group with a sleeping racer — does
/// not work, and shipped here for a while pretending to. A task group awaits
/// its children when the scope exits, *including* the path where a child threw,
/// and `cancelAll()` is a polite request. Every call site here is an
/// Objective-C completion-handler bridge, and Swift installs no cancellation
/// handler for those, so the deadline fired on time and then sat waiting for
/// the very operation it was meant to escape. Measured: a 300 ms deadline
/// around a five-second call returned after 5.2 seconds.
///
/// So the operation runs unstructured and is *abandoned* rather than awaited.
/// It keeps running to completion in the background — there's no way to stop
/// a wedged framework call — but the caller gets its answer on schedule.
public func withTimeout<T: Sendable>(
    _ duration: Duration, _ what: String,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let outcome = FirstResult<T>()

    let work = Task {
        do { outcome.settle(.success(try await operation())) }
        catch { outcome.settle(.failure(error)) }
    }
    let deadline = Task {
        try? await Task.sleep(for: duration)
        outcome.settle(.failure(TimedOut(what)))
    }
    defer {
        // Cancelling still helps anything that *does* honour it.
        work.cancel()
        deadline.cancel()
    }
    return try await outcome.value.get()
}
