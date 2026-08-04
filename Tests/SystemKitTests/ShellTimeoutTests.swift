import Foundation
import Testing
@testable import SystemKit

@Suite("Shell deadlines survive hostile children", .serialized)
struct ShellTimeoutTests {
    /// A tool that traps SIGTERM is exactly the tool that hangs, so asking
    /// politely once was never enough.
    @Test("Gives up on a child that ignores SIGTERM")
    func ignoresTerm() async {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: ShellError.self) {
            _ = try await ShellRunner.run(
                "/bin/sh", ["-c", "trap '' TERM; sleep 30"], timeout: .seconds(1)
            )
        }
        #expect(clock.now - start < .seconds(5), "returned after \(clock.now - start)")
    }

    /// The child exits immediately but a grandchild inherits the pipe, so the
    /// old drain never saw EOF and parked two threads forever.
    @Test("Gives up when a grandchild holds the pipe open")
    func grandchildHoldsPipe() async {
        let clock = ContinuousClock()
        let start = clock.now
        _ = try? await ShellRunner.run(
            "/bin/sh", ["-c", "sleep 30 & exit 0"], timeout: .seconds(1)
        )
        #expect(clock.now - start < .seconds(6), "returned after \(clock.now - start)")
    }

    @Test("Normal output still comes back intact")
    func normalOutput() async throws {
        let output = try await ShellRunner.run(
            "/bin/echo", ["hola"], timeout: .seconds(5)
        )
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "hola")
    }

    @Test("A failing tool reports its exit code and stderr")
    func failure() async {
        do {
            _ = try await ShellRunner.run(
                "/bin/sh", ["-c", "echo problema >&2; exit 3"], timeout: .seconds(5)
            )
            Issue.record("should have thrown")
        } catch let error as ShellError {
            #expect(error.exitCode == 3)
            #expect(error.stderr.contains("problema"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }
}
