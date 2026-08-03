import Foundation
import StreamHostKit

/// `Chinchilla gamestream-test` — starts the GameStream host and logs every
/// request Moonlight makes, so pairing can be validated end to end.
enum GameStreamDiagnostics {
    static let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Chinchilla/gamestream-test.log")

    nonisolated(unsafe) private static var transcript = ""
    private static let lock = NSLock()

    static func log(_ line: String) {
        print(line)
        lock.withLock {
            transcript += line + "\n"
            try? FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? transcript.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    static func run(seconds: Int) async -> Int32 {
        log("== Chinchilla GameStream host ==")
        let host: GameStreamHost
        do {
            host = try GameStreamHost()
        } catch {
            log("identity failed: \(error)")
            return 1
        }
        host.onLog = { log("  \($0)") }
        host.onClientSeen = { log("★ Moonlight found us (client \($0))") }
        host.onPaired = { log("★★ PAIRED with \($0)") }
        do {
            try host.start()
        } catch {
            log("listen failed: \(error)")
            return 1
        }
        let pin = host.newPIN()
        log("")
        log("On the TV: open Moonlight → the host \"\(host.hostName)\" should appear.")
        log("Tap it and enter this PIN:  \(pin)")
        log("")
        try? await Task.sleep(for: .seconds(seconds))
        host.stop()
        log("== done ==")
        return 0
    }
}
