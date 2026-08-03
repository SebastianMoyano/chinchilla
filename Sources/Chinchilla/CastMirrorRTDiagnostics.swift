import Foundation
import Synchronization
import CastKit
import ScreenCaptureKit

/// `Chinchilla caststream-mirror <tv-ip> [seconds]` — the whole low-latency
/// path end to end: negotiate with Chrome's mirroring receiver, then capture,
/// encode and send RTP to the UDP port it gave us.
///
/// Run it from the bundle (`open -a Chinchilla --args caststream-mirror …`)
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

        // Work out the real capture size first: the offer must describe what
        // we will actually send, not a rounded box.
        let quality = MirrorQuality.p720
        let display: SCDisplay
        do {
            display = try await ScreenStreamer.mainDisplay()
        } catch {
            log("✗ Couldn't find a display: \(error.localizedDescription)")
            return 1
        }
        let size = ScreenStreamer.captureSize(for: quality, display: display)
        log("capture: \(size.width)x\(size.height)")

        let session = GoogleCastSession(device: GoogleCastDevice(name: "TV", host: host))
        let answers = Mutex<[CastStreaming.Answer]>([])
        var offer = CastStreaming.Offer()
        offer.width = size.width
        offer.height = size.height
        offer.frameRate = 30
        offer.videoBitRate = 5_000_000
        offer.includeAudio = false
        offer.targetDelayMs = playoutDelayMs
        let sealedOffer = offer

        await session.useStreamingApp(namespace: CastStreaming.namespace) { _, payload in
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answer = CastStreaming.Answer(json: json) else { return }
            answers.withLock { $0.append(answer) }
        }

        let events = await session.events
        await session.connect()

        // Negotiate.
        var offered = false
        let handshake = Task {
            for await event in events {
                if case .state(let state) = event {
                    log("session: \(state)")
                    if state == .ready, !offered {
                        offered = true
                        var waited = 0
                        while await !session.isAppReady, waited < 40 {
                            try? await Task.sleep(for: .milliseconds(250))
                            waited += 1
                        }
                        let json = sealedOffer.json(sequenceNumber: 1)
                        log("→ OFFER (h264 \(sealedOffer.width)x\(sealedOffer.height)@\(sealedOffer.frameRate))")
                        await session.sendCustom(namespace: CastStreaming.namespace, payload: json)
                    }
                    if case .closed = state { break }
                }
            }
        }

        var waited = 0
        while answers.withLock({ $0.isEmpty }), waited < 120 {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }
        guard let answer = answers.withLock({ $0.first }) else {
            log("✗ No ANSWER — nothing to stream to.")
            handshake.cancel()
            await session.close()
            return 1
        }
        guard answer.acceptedVideo else {
            log("✗ The receiver answered but declined the video stream (sendIndexes=\(answer.sendIndexes)).")
            handshake.cancel()
            await session.close()
            return 1
        }
        log("✅ ANSWER — udpPort=\(answer.udpPort) ssrcs=\(answer.ssrcs)")

        let encoder: RealtimeH264Encoder
        do {
            encoder = try RealtimeH264Encoder(
                width: size.width, height: size.height,
                bitrate: sealedOffer.videoBitRate, frameRate: sealedOffer.frameRate
            )
        } catch {
            log("✗ Encoder: \(error.localizedDescription)")
            await session.close()
            return 1
        }

        let sender = CastStreamSender(
            host: host, port: answer.udpPort, keys: sealedOffer.videoKeys,
            ssrc: sealedOffer.videoSSRC, payloadType: 101,
            initialPlayoutDelayMs: playoutDelayMs
        )
        sender.onLog = { log($0) }
        sender.onKeyFrameRequest = { [weak encoder] in
            log("receiver asked for a key frame")
            encoder?.requestKeyFrame()
        }
        sender.start()

        encoder.onSample = { sample in sender.send(sample) }

        let streamer = ScreenStreamer()
        streamer.onVideoSample = { [weak encoder] buffer in encoder?.encode(buffer) }
        do {
            try await streamer.start(
                quality: quality, includeAudio: false, frameRate: sealedOffer.frameRate
            )
        } catch {
            log("✗ Capture: \(error.localizedDescription)")
            sender.stop()
            await session.close()
            return 1
        }
        log("streaming… watch the TV")

        for tick in 1...max(1, seconds) {
            try? await Task.sleep(for: .seconds(1))
            if tick % 5 == 0 {
                let stats = sender.currentStats()
                let mbps = Double(stats.bytesSent) * 8 / Double(tick) / 1_000_000
                let ack = stats.lastAckedFrameID.map(String.init) ?? "—"
                let delay = stats.receiverPlayoutDelayMs.map { "\($0)ms" } ?? "—"
                log(String(format: "t=%ds frames=%d packets=%d %.2f Mbps rtcp-in=%d ack=%@ delay=%@ loss=%d resent=%d keyframe-requests=%d",
                           tick, stats.framesSent, stats.packetsSent, mbps,
                           stats.reportsReceived, ack, delay, stats.lossReports,
                           stats.packetsResent, stats.keyFrameRequests))
            }
        }

        await streamer.stop()
        encoder.finish()
        let stats = sender.currentStats()
        sender.stop()
        handshake.cancel()
        await session.close()

        log("")
        if stats.framesSent == 0 {
            log("✗ Nothing was sent — the capture produced no frames.")
            return 1
        }
        log("done — \(stats.framesSent) frames, \(stats.packetsSent) packets sent.")
        if stats.reportsReceived == 0 {
            log("⚠︎ The receiver never sent a single RTCP report back. It accepted " +
                "the offer but is not acknowledging the media — the packet format " +
                "is the thing to question next.")
            return 2
        }
        log("receiver sent \(stats.reportsReceived) RTCP reports back — it is " +
            "consuming the stream.")
        return 0
    }
}
