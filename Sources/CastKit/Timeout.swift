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

/// Runs `operation` with a deadline.
///
/// The project rule is that the UI never waits on an external subsystem
/// without a bound — three separate freezes came from doing exactly that.
/// ScreenCaptureKit is the case in point: if its daemon is wedged, the
/// content query never returns and never fails, so the caller must be the
/// one holding the clock.
public func withTimeout<T: Sendable>(
    _ duration: Duration, _ what: String,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimedOut(what)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw TimedOut(what) }
        return result
    }
}
