import Foundation

public struct ShellError: Error, Sendable {
    public let exitCode: Int32
    public let stderr: String
}

/// Async wrapper around Process. Drains stdout/stderr on background threads to
/// avoid the 64 KB pipe deadlock, and enforces a timeout.
public enum ShellRunner {
    public static func run(
        _ tool: String,
        _ args: [String] = [],
        timeout: Duration = .seconds(120)
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await launch(tool, args)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ShellError(exitCode: -1, stderr: "timeout after \(timeout)")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func launch(_ tool: String, _ args: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            // Read fully off the calling thread; readDataToEndOfFile blocks
            // until EOF, so do it on utility QoS threads.
            DispatchQueue.global(qos: .utility).async {
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    continuation.resume(throwing: ShellError(exitCode: process.terminationStatus, stderr: err))
                }
            }
        }
    }
}
