import Foundation

/// A value behind a lock, with the same shape as `Mutex` from Synchronization.
///
/// `Mutex` is macOS 15+, and that was the single thing keeping the whole app
/// off macOS 14 — which matters for the fleets this is actually used on,
/// where machines lag a release or two behind. `NSLock` costs nothing here:
/// these guard short critical sections around counters and buffers, never
/// contended tightly enough for the difference to show.
public final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) {
        self.value = value
    }

    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
