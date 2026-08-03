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
        timeout: Duration = .seconds(120)
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
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
        _ process: Process, _ outPipe: Pipe, _ errPipe: Pipe
    ) async throws -> String {
        nonisolated(unsafe) let child = process
        return try await withCheckedThrowingContinuation { continuation in
            // Read fully off the calling thread; readDataToEndOfFile blocks
            // until EOF, so do it on utility QoS threads.
            DispatchQueue.global(qos: .utility).async {
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                child.waitUntilExit()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                if child.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    continuation.resume(throwing: ShellError(exitCode: child.terminationStatus, stderr: err))
                }
            }
        }
    }
}
