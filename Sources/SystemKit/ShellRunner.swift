import Foundation

public struct ShellError: Error, Sendable {
    public let exitCode: Int32
    public let stderr: String

    public init(exitCode: Int32, stderr: String) {
        self.exitCode = exitCode
        self.stderr = stderr
    }
}

/// Async wrapper around Process. Drains stdout/stderr on background threads to
/// avoid the 64 KB pipe deadlock, enforces a timeout, and — crucially —
/// terminates the child on timeout or task cancellation so hung tools
/// (docker mid-start, osascript waiting on a permission prompt) don't leak.
public enum ShellRunner {
    public static func run(
        _ tool: String,
        _ args: [String] = [],
        timeout: Duration = .seconds(120),
        environment: [String: String]? = nil
    ) async throws -> String {
        try await launch(tool, args, timeout: timeout, mergeStderr: false, environment: environment)
    }

    /// Like `run`, but stderr is merged into the returned output — for tools
    /// like codesign that print their report to stderr.
    public static func runMerged(
        _ tool: String,
        _ args: [String] = [],
        timeout: Duration = .seconds(120)
    ) async throws -> String {
        try await launch(tool, args, timeout: timeout, mergeStderr: true, environment: nil)
    }

    private static func launch(
        _ tool: String, _ args: [String], timeout: Duration, mergeStderr: Bool,
        environment: [String: String]?
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        if let environment {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, new in new }
        }
        let outPipe = Pipe()
        // When merging, stderr shares outPipe; a separate unused Pipe would
        // never reach EOF and deadlock the drain.
        let errPipe = mergeStderr ? nil : Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe ?? outPipe
        try process.run()

        // Process isn't Sendable; we only ever call terminate() from other
        // contexts, which is documented as thread-safe.
        nonisolated(unsafe) let child = process

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await readToEnd(child, outPipe, errPipe)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    child.terminate()
                    throw ShellError(exitCode: -1, stderr: "timeout after \(timeout)")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } onCancel: {
            child.terminate()
        }
    }

    private static func readToEnd(
        _ process: Process, _ outPipe: Pipe, _ errPipe: Pipe?
    ) async throws -> String {
        nonisolated(unsafe) let child = process
        return try await withCheckedThrowingContinuation { continuation in
            // Drain stdout and stderr CONCURRENTLY: reading them one after the
            // other deadlocks if the child fills the 64 KB stderr buffer while
            // we're still blocked on stdout (or vice versa).
            nonisolated(unsafe) var outData = Data()
            nonisolated(unsafe) var errData = Data()
            let drains = DispatchGroup()
            DispatchQueue.global(qos: .utility).async(group: drains) {
                outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            }
            if let errPipe {
                DispatchQueue.global(qos: .utility).async(group: drains) {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                }
            }
            drains.notify(queue: .global(qos: .utility)) {
                child.waitUntilExit()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                if child.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    // When stderr was merged, the error detail lives in `out`.
                    continuation.resume(throwing: ShellError(
                        exitCode: child.terminationStatus,
                        stderr: err.isEmpty ? out : err
                    ))
                }
            }
        }
    }
}
