import Foundation

public struct ShellError: Error, Sendable {
    public let exitCode: Int32
    public let stderr: String

    public init(exitCode: Int32, stderr: String) {
        self.exitCode = exitCode
        self.stderr = stderr
    }
}

/// Async wrapper around Process.
///
/// Two things here are not the obvious spelling, both for the same reason: the
/// obvious spelling was measured and it doesn't hold.
///
/// **The deadline abandons rather than awaits.** A throwing task group awaits
/// its children when the scope exits, including on the path where a child
/// threw, so racing a sleeper against the work only *reports* a timeout — it
/// still waits for the work. Two real cases never returned at all: a child
/// that ignores SIGTERM (`trap '' TERM`), and a child that exits while a
/// grandchild keeps the pipe open (`sleep 60 & exit 0`).
///
/// **Output is drained by readability handlers, not `readDataToEndOfFile`.**
/// That call parks a GCD thread until EOF. Two per hung child, against a
/// global pool that caps near 64 — and once that pool is exhausted, every
/// `Blocking.run` in the app stops getting a thread. A stuck `docker` would
/// have taken the whole app down with it, not one screen.
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
        // never reach EOF and stall the drain.
        let errPipe = mergeStderr ? nil : Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe ?? outPipe
        try process.run()

        // Process isn't Sendable; terminate() and the pid are documented as
        // safe to touch from other threads.
        nonisolated(unsafe) let child = process
        let collector = OutputCollector(out: outPipe, err: errPipe)
        collector.start()

        let finished = Waiter()
        process.terminationHandler = { _ in finished.signal() }

        return try await withTaskCancellationHandler {
            let timedOut = await finished.wait(for: timeout)
            if timedOut {
                kill(child, escalate: true)
                collector.stop()
                throw ShellError(exitCode: -1, stderr: "timeout after \(timeout)")
            }
            // The child is gone; its writers are closed, so this lands promptly.
            let (out, err) = await collector.drain(within: .seconds(2))
            guard child.terminationStatus == 0 else {
                throw ShellError(
                    exitCode: child.terminationStatus,
                    stderr: err.isEmpty ? out : err
                )
            }
            return out
        } onCancel: {
            kill(child, escalate: true)
            collector.stop()
        }
    }

    /// SIGTERM, then SIGKILL if it's still there. A tool that traps TERM is
    /// exactly the tool that hangs, so asking politely once isn't enough.
    private static func kill(_ process: Process, escalate: Bool) {
        guard process.isRunning else { return }
        process.terminate()
        guard escalate else { return }
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
            if process.isRunning { Foundation.kill(pid, SIGKILL) }
        }
    }
}

/// Reads both pipes with readability handlers so no thread ever parks.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var openStreams = 0
    /// Signalled once both streams hit EOF.
    private let eof = Waiter()

    private let outPipe: Pipe
    private let errPipe: Pipe?

    init(out: Pipe, err: Pipe?) {
        self.outPipe = out
        self.errPipe = err
    }

    func start() {
        lock.lock()
        openStreams = errPipe == nil ? 1 : 2
        lock.unlock()
        attach(outPipe) { [weak self] data in self?.append(data, toOut: true) }
        if let errPipe {
            attach(errPipe) { [weak self] data in self?.append(data, toOut: false) }
        }
    }

    private func attach(_ pipe: Pipe, _ sink: @escaping @Sendable (Data?) -> Void) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            sink(chunk.isEmpty ? nil : chunk)      // empty means EOF
            if chunk.isEmpty { handle.readabilityHandler = nil }
        }
    }

    /// Nothing this app runs has a legitimate reason to print megabytes, and
    /// the timeout can be as long as 300 s (docker prune). Without a cap, a
    /// child spewing output filled memory for the whole window; past the cap
    /// we keep the head, which is where the error message is.
    static let maxBytesPerStream = 4 * 1024 * 1024

    private func append(_ data: Data?, toOut: Bool) {
        lock.lock()
        if let data {
            if toOut {
                if out.count < Self.maxBytesPerStream { out.append(data) }
            } else {
                if err.count < Self.maxBytesPerStream { err.append(data) }
            }
            lock.unlock()
            return
        }
        openStreams -= 1
        let finished = openStreams == 0
        lock.unlock()
        if finished { eof.signal() }
    }

    /// Waits for both streams to hit EOF, but not forever: a grandchild can
    /// hold the write end open after the child we launched is gone.
    func drain(within duration: Duration) async -> (String, String) {
        _ = await eof.wait(for: duration)
        stop()
        return collected()
    }

    private func collected() -> (String, String) {
        lock.lock(); defer { lock.unlock() }
        return (String(data: out, encoding: .utf8) ?? "",
                String(data: err, encoding: .utf8) ?? "")
    }

    func stop() {
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe?.fileHandleForReading.readabilityHandler = nil
    }
}

/// A one-shot signal with a deadline, and no parked threads.
private final class Waiter: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var continuation: CheckedContinuation<Bool, Never>?

    func signal() {
        lock.lock()
        guard !signalled else { lock.unlock(); return }
        signalled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: false)      // false == didn't time out
    }

    /// Returns true when the deadline won.
    func wait(for duration: Duration) async -> Bool {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: duration)
            self?.expire()
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            lock.lock()
            if signalled {
                lock.unlock()
                continuation.resume(returning: false)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func expire() {
        lock.lock()
        guard !signalled else { lock.unlock(); return }
        signalled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: true)
    }
}
