import Foundation
import Synchronization
import CastKit

/// `Chinchilla caststream-mirror <tv-ip> [seconds] [delay-ms]` — runs exactly
/// the path the app uses, and logs what the receiver reports back.
///
/// Launch it from the bundle (`open -a Chinchilla --args caststream-mirror …`)
/// so Screen Recording is attributed to Chinchilla and not to the terminal,
/// then read the log.
enum CastMirrorRTDiagnostics {
    static let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Chinchilla/caststream-mirror.log")

    private static let transcript = Mutex("")

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

    static func run(host: String, seconds: Int, playoutDelayMs: Int) async -> Int32 {
        log("== Cast Streaming live mirror ==")
        log("target: \(host)  duration: \(seconds)s  playout delay: \(playoutDelayMs) ms")
        log("screen recording granted: \(ScreenRecordingPermission.isGranted)")
        guard ScreenRecordingPermission.isGranted else {
            ScreenRecordingPermission.request()
            log("✗ Screen Recording isn't granted yet. Allow Chinchilla in " +
                "System Settings → Privacy & Security → Screen Recording, then rerun.")
            return 1
        }

        let mirror = CastMirrorSession(
            host: host, quality: .p720, includeAudio: true, playoutDelayMs: playoutDelayMs
        )
        mirror.onLog = { log($0) }
        mirror.onStopped = { message in
            log("stream stopped: \(message ?? "no reason given")")
        }

        do {
            try await mirror.start()
        } catch {
            log("✗ \(error.localizedDescription)")
            return 1
        }
        log("audio accepted: \(mirror.audioAccepted)")
        log("streaming… watch the TV")

        for tick in 1...max(1, seconds) {
            try? await Task.sleep(for: .seconds(1))
            if tick % 5 == 0, let stats = mirror.stats() {
                let mbps = Double(stats.bytesSent) * 8 / Double(tick) / 1_000_000
                let ack = stats.lastAckedFrameID.map(String.init) ?? "—"
                let delay = stats.receiverPlayoutDelayMs.map { "\($0)ms" } ?? "—"
                var line = String(
                    format: "t=%ds video: frames=%d packets=%d %.2f Mbps rtcp-in=%d ack=%@ delay=%@ loss=%d resent=%d pli=%d",
                    tick, stats.framesSent, stats.packetsSent, mbps,
                    stats.reportsReceived, ack, delay, stats.lossReports,
                    stats.packetsResent, stats.keyFrameRequests
                )
                if let audio = mirror.audioStats() {
                    let audioAck = audio.lastAckedFrameID.map(String.init) ?? "—"
                    line += String(
                        format: "  |  audio: frames=%d rtcp-in=%d ack=%@ loss=%d",
                        audio.framesSent, audio.reportsReceived, audioAck, audio.lossReports
                    )
                }
                log(line)
            }
        }

        let stats = mirror.stats()
        let audio = mirror.audioStats()
        await mirror.stop()

        log("")
        guard let stats, stats.framesSent > 0 else {
            log("✗ Nothing was sent — the capture produced no frames.")
            return 1
        }
        log("done — video \(stats.framesSent) frames, \(stats.packetsSent) packets.")
        if mirror.audioAccepted {
            if let audio, audio.framesSent > 0 {
                log("audio — \(audio.framesSent) Opus packets sent, " +
                    "\(audio.reportsReceived) reports back.")
            } else {
                log("⚠︎ The receiver accepted audio but the encoder produced nothing. " +
                    "System audio capture is the thing to check.")
                return 2
            }
        } else {
            log("⚠︎ The receiver declined the audio stream.")
        }
        if stats.reportsReceived == 0 {
            log("⚠︎ The receiver never sent an RTCP report back — it accepted the " +
                "offer but isn't acknowledging the media.")
            return 2
        }
        log("receiver sent \(stats.reportsReceived) RTCP reports back — it is " +
            "consuming the stream.")
        return 0
    }
}
