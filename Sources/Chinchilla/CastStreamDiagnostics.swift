import Foundation
import DiskScanKit
import CastKit

/// `Chinchilla caststream-test <tv-ip>` — launches Chrome's own mirroring
/// receiver on the TV and offers it an H.264 stream, logging the handshake.
/// A successful ANSWER (with a UDP port) means the ~400 ms path is open.
enum CastStreamDiagnostics {
    static let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Chinchilla/caststream-test.log")

    private static let transcript = Locked("")

    static func log(_ line: String) {
        print(line)
        transcript.withLock { text in
            text += line + "\n"
            try? FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? text.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    static func run(host: String) async -> Int32 {
        log("== Cast Streaming handshake test ==")
        log("target: \(host):8009  app: \(CastStreaming.appID) (Chrome mirroring)")

        let session = GoogleCastSession(device: GoogleCastDevice(name: "TV", host: host))
        let answers = Locked<[CastStreaming.Answer]>([])
        await session.setOnAnyMessage { namespace, payload in
            let short = namespace.replacingOccurrences(
                of: "urn:x-cast:com.google.cast.", with: ""
            )
            log("← [\(short)] \(payload.prefix(400))")
        }
        await session.useStreamingApp(namespace: CastStreaming.namespace) { _, payload in
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answer = CastStreaming.Answer(json: json) else { return }
            answers.withLock { $0.append(answer) }
        }

        let events = await session.events
        await session.connect()
        var offered = false
        let timeout = Task {
            try? await Task.sleep(for: .seconds(40))
            await session.close()
        }

        for await event in events {
            switch event {
            case .state(let state):
                log("session: \(state)")
                if state == .ready, !offered {
                    offered = true
                    // Wait for the mirroring receiver to come up.
                    var waited = 0
                    while await !session.isAppReady, waited < 40 {
                        try? await Task.sleep(for: .milliseconds(250))
                        waited += 1
                    }
                    log("receiver app ready: \(await session.isAppReady)")
                    var offer = CastStreaming.Offer()
                    offer.width = 1280
                    offer.height = 720
                    offer.includeAudio = false
                    let json = offer.json(sequenceNumber: 1)
                    log("→ OFFER \(json.prefix(320))")
                    await session.sendCustom(namespace: CastStreaming.namespace, payload: json)
                }
            case .error(let message):
                log("error: \(message)")
            default:
                break
            }
            if !answers.withLock({ $0.isEmpty }) {
                try? await Task.sleep(for: .milliseconds(300))
                await session.close()
            }
            if case .state(.closed) = event { break }
        }
        timeout.cancel()

        if let answer = answers.withLock({ $0.first }) {
            log("")
            log("✅ ANSWER received — udpPort=\(answer.udpPort) " +
                "video=\(answer.acceptedVideo) audio=\(answer.acceptedAudio) ssrcs=\(answer.ssrcs)")
            log("The ~400 ms path is open: RTP media can now be sent to that port.")
            return 0
        }
        log("")
        log("✗ No ANSWER. Is the TV awake and on the same Wi-Fi?")
        return 1
    }
}
