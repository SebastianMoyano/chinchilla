import Foundation
import Testing
@testable import SystemKit

/// "Close node" pressed, nothing happened, and the app reported that node had
/// already closed. `NSWorkspace.runningApplications` lists *applications* —
/// things with a bundle, registered with Launch Services — and a command-line
/// process is not one, so the filter came back empty and no signal was ever
/// sent. These make sure a plain process is actually reachable.

/// A copy of /bin/sleep under a name nothing else on the machine can share,
/// so the test never signals a process it doesn't own. `proc_name` truncates
/// around 16 characters, hence the short name.
private func spawnUniqueSleeper() throws -> (name: String, process: Process, url: URL) {
    let name = "chzz" + UUID().uuidString.prefix(6).lowercased()
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: url)

    let process = Process()
    process.executableURL = url
    process.arguments = ["120"]
    try process.run()
    return (name, process, url)
}

@MainActor
@Test func aPlainProcessIsFoundAndAskedToStop() async throws {
    let (name, process, url) = try spawnUniqueSleeper()
    defer {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: url)
    }

    // Give the kernel a moment to publish it.
    var found: [pid_t] = []
    for _ in 0..<50 {
        found = ProcessMemory.pids(for: name)
        if !found.isEmpty { break }
        usleep(20_000)
    }
    #expect(found == [process.processIdentifier])

    // With the whole suite hammering the machine, one proc_listallpids
    // snapshot can transiently miss a just-spawned process — the pre-check
    // above retries for the same reason. The test is "a plain process is
    // reachable", not "the first snapshot never blinks".
    var outcome = AppTerminator.Outcome()
    for _ in 0..<10 {
        outcome = await AppTerminator.close(name: name)
        if outcome.didSomething { break }
        usleep(50_000)
    }
    // Not an application, so nothing goes through AppKit — this is exactly the
    // path that used to do nothing at all.
    #expect(outcome.applicationsAsked == 0)
    #expect(outcome.processesSignalled == 1)
    #expect(outcome.didSomething)

    for _ in 0..<100 where process.isRunning { usleep(20_000) }
    #expect(process.isRunning == false)
}

@MainActor
@Test func closingSomethingThatIsNotThereSaysSoHonestly() async {
    let outcome = await AppTerminator.close(name: "chinchilla-no-such-process")
    #expect(outcome.didSomething == false)
    #expect(outcome.total == 0)
    #expect(AppTerminator.describe(outcome, target: "Ghost") == "Ghost was already gone.")
}

@MainActor
@Test func closingOurselfIsRefusedRatherThanAttempted() async {
    // Chinchilla can be launched from a terminal; a shell that dies takes the
    // app with it, and our own pid needs no explanation.
    let outcome = await AppTerminator.close(name: ProcessMemory.hostAppName(
        for: ProcessInfo.processInfo.processName,
        path: Bundle.main.executablePath ?? ""
    ))
    #expect(outcome.processesSignalled == 0)
}

@Test func theMessageMatchesWhatActuallyHappened() {
    var outcome = AppTerminator.Outcome()
    outcome.processesSignalled = 4
    #expect(AppTerminator.describe(outcome, target: "node")
            == "Asked node to close (4 processes).")

    outcome = AppTerminator.Outcome()
    outcome.applicationsAsked = 1
    #expect(AppTerminator.describe(outcome, target: "Slack") == "Asked Slack to close.")

    outcome = AppTerminator.Outcome()
    outcome.refused = 2
    #expect(AppTerminator.describe(outcome, target: "mds")
            == "macOS wouldn't let Chinchilla close mds.")

    outcome = AppTerminator.Outcome()
    outcome.protected = 1
    #expect(AppTerminator.describe(outcome, target: "zsh")
            == "zsh is running Chinchilla itself, so it was left alone.")
}
