import Foundation
import Testing
@testable import SystemKit

private func state(of pid: pid_t) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "stat=", "-p", "\(pid)"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

@Test func pauseAndResumeRealProcess() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["60"]
    try child.run()
    let pid = child.processIdentifier
    defer { child.terminate() }

    let paused = ProcessPauser.pauseTree(pid: pid, bundleID: "test", name: "sleep")
    let pausedRecord = try #require(paused)
    #expect(state(of: pid).hasPrefix("T"), "process should be stopped (T)")

    ProcessPauser.resumeTree(pausedRecord)
    #expect(!state(of: pid).hasPrefix("T"), "process should be running again")
}

@Test func resumeRefusesRecycledPid() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["60"]
    try child.run()
    let pid = child.processIdentifier
    defer { child.terminate() }

    // A record with a wrong start time must never signal the process.
    let bogus = PausedProcess(pid: pid, startTime: 12345, bundleID: "test", name: "sleep")
    ProcessPauser.pauseTree(pid: pid, bundleID: "test", name: "sleep").map { _ in }
    ProcessPauser.resumeTree(bogus)
    #expect(state(of: pid).hasPrefix("T"), "wrong startTime must not resume the process")

    // Correct record resumes it.
    if let start = ProcessPauser.startTime(of: pid) {
        ProcessPauser.resumeTree(PausedProcess(pid: pid, startTime: start, bundleID: "test", name: "sleep"))
    }
    #expect(!state(of: pid).hasPrefix("T"))
}
