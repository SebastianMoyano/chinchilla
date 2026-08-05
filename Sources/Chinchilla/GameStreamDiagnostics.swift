import Foundation
import DiskScanKit
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
        // First launch mints an RSA-2048 identity via two openssl runs plus
        // synchronous file I/O — blocking work, so it goes through
        // Blocking.run like everything else instead of parking a
        // cooperative-pool thread for the whole keygen.
        let made = await Blocking.run { Result { try GameStreamHost() } }
        do {
            host = try made.get()
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
