import Foundation
import Testing
@testable import SystemKit

/// SIGSTOP to our own pid is unrecoverable from inside the app: nothing is
/// left running to send the SIGCONT. The pause path must refuse it outright
/// rather than rely on callers filtering first.

@Test func ourOwnProcessCountsAsUnpausable() {
    #expect(ProcessPauser.isSelfOrAncestor(getpid()))
}

@Test func ourParentCountsAsUnpausable() throws {
    let parent = try #require(ProcessPauser.parentOf(getpid()))
    #expect(parent > 0)
    #expect(ProcessPauser.isSelfOrAncestor(parent))
}

@Test func launchdIsAnAncestorOfEverything() {
    #expect(ProcessPauser.isSelfOrAncestor(1))
}

@Test func anUnrelatedProcessIsPausable() {
    // A pid that cannot be an ancestor of ours: our own child.
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try? child.run()
    defer { child.terminate() }
    #expect(child.processIdentifier > 0)
    #expect(ProcessPauser.isSelfOrAncestor(child.processIdentifier) == false)
}

@Test func pauseTreeRefusesToFreezeUs() {
    let outcome = ProcessPauser.pauseTree(
        pid: getpid(), bundleID: "com.sebastian.chinchilla", name: "Chinchilla"
    )
    // If this ever returns non-nil, the test run itself would stop here.
    #expect(outcome == nil)
}
