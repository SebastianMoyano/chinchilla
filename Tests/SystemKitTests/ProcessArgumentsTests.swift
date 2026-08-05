import Foundation
import Testing
@testable import SystemKit

/// "node, 1.51 GB" was the memory list's answer to "what is eating my RAM".
/// On the machine this was written on, those turned out to be three MCP
/// servers belonging to an editor session — so a prompt offering to close
/// "node" would have killed them with the user having no idea what they were
/// agreeing to. The script is the name a person can judge.

@Test func anInterpreterIsNamedAfterWhatItRuns() {
    #expect(ProcessArguments.scriptName(fromArguments: [
        "node", "/Users/admin/.npm/_npx/9833/node_modules/.bin/playwright-mcp",
    ]) == "playwright-mcp")

    // Extensions get dropped: nobody thinks of it as "server.js".
    #expect(ProcessArguments.scriptName(fromArguments: [
        "node", "/srv/app/server.js",
    ]) == "server")
    #expect(ProcessArguments.scriptName(fromArguments: [
        "python3", "/opt/tools/indexer.py", "--watch",
    ]) == "indexer")
}

@Test func flagsBeforeTheScriptAreSkipped() {
    #expect(ProcessArguments.scriptName(fromArguments: [
        "node", "--max-old-space-size=4096", "--enable-source-maps", "build/main.js",
    ]) == "main")
}

@Test func anInterpreterWithNothingToRunKeepsItsOwnName() {
    // A bare REPL has no script to be named after, and inventing one would be
    // worse than saying "node".
    #expect(ProcessArguments.scriptName(fromArguments: ["node"]) == nil)
    #expect(ProcessArguments.scriptName(fromArguments: ["python3", "-i"]) == nil)
    #expect(ProcessArguments.scriptName(fromArguments: []) == nil)
}

@Test func onlyInterpretersGetRenamed() {
    #expect(ProcessArguments.isInterpreter("node"))
    #expect(ProcessArguments.isInterpreter("python3"))
    #expect(ProcessArguments.isInterpreter("java"))
    // A real application's name already means something.
    #expect(ProcessArguments.isInterpreter("Google Chrome") == false)
    #expect(ProcessArguments.isInterpreter("Docker") == false)
}

@Test func argumentsCanBeReadFromALiveProcess() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    defer { process.terminate() }

    var arguments: [String] = []
    for _ in 0..<50 {
        arguments = ProcessArguments.arguments(of: process.processIdentifier)
        if arguments.count >= 2 { break }
        usleep(20_000)
    }
    #expect(arguments.first?.hasSuffix("sleep") == true)
    #expect(arguments.dropFirst().first == "30")
}

@Test func aProcessThatIsGoneReadsAsNothing() {
    // pid 0 is the kernel's, never readable this way — and an exited pid must
    // not throw or hang either.
    #expect(ProcessArguments.arguments(of: 0).isEmpty)
    #expect(ProcessArguments.arguments(of: 999_999).isEmpty)
}
