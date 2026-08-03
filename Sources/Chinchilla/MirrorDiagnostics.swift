import Foundation
import CastKit

/// `Chinchilla mirror-test <tv-ip>` — runs the whole mirroring pipeline
/// from the app bundle (which owns the Screen Recording grant) and prints
/// what happens at every stage. Diagnostics only; not in the help text.
enum MirrorDiagnostics {
    /// TCC attributes permissions to the launching process, so running the
    /// binary from a shell reports the terminal's rights, not the app's.
    /// Launch it with `open -a Chinchilla --args mirror-test <ip>` and read
    /// this report instead.
    static let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Chinchilla/mirror-test.log")

    nonisolated(unsafe) private static var transcript = ""

    static func log(_ line: String) {
        print(line)
        transcript += line + "\n"
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? transcript.write(to: logURL, atomically: true, encoding: .utf8)
    }

    static func run(host: String) async -> Int32 {
        transcript = ""
        log("== Chinchilla mirror diagnostics ==")
        log("Screen Recording granted: \(ScreenRecordingPermission.isGranted)")
        guard ScreenRecordingPermission.isGranted else {
            log("→ Grant it in System Settings → Privacy → Screen Recording, then relaunch.")
            return 1
        }

        let streamer = ScreenStreamer()
        let server = CastHTTPServer()
        server.onRequest = { method, path in
            log("  HTTP \(method) \(path)")
        }
        do {
            try server.start()
        } catch {
            log("HTTP server failed: \(error)")
            return 1
        }
        for _ in 0..<40 where server.port == 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let store = streamer.store
        server.setPrefixRoute("/mirror/") { path in
            if path == "stream.m3u8" { return ("application/x-mpegurl", Data(store.playlist().utf8)) }
            if path == "init.mp4", let data = store.initSegmentData() { return ("video/mp4", data) }
            if path.hasPrefix("seg-"), path.hasSuffix(".m4s"),
               let index = Int(path.dropFirst(4).dropLast(4)),
               let data = store.segmentData(index: index) { return ("video/mp4", data) }
            return nil
        }

        // Progressive fMP4: init segment, then every new fragment pushed
        // down one long-lived response. No playlist, no polling, and the
        // same container the TV already plays for files.
        server.setStreamRoute("/mirror/live.mp4") { writer in
            Task {
                var attempts = 0
                while store.initSegmentData() == nil, attempts < 100 {
                    try? await Task.sleep(for: .milliseconds(100))
                    attempts += 1
                }
                guard let header = store.initSegmentData(), writer.write(header) else {
                    writer.finish()
                    return
                }
                let subscription = store.subscribe { fragment in
                    _ = writer.write(fragment)
                }
                // Keep the response open while mirroring lasts.
                while store.hasContent {
                    try? await Task.sleep(for: .seconds(1))
                }
                store.unsubscribe(subscription)
                writer.finish()
            }
        }

        do {
            try await streamer.start(quality: .p720, includeAudio: true)
        } catch {
            log("Capture failed: \(error)")
            return 1
        }
        let ready = await streamer.waitForFirstSegment(minimumSegments: 1)
        log("Segments ready: \(ready)")
        log("Playlist:\n\(store.playlist())")
        log("init segment bytes: \(store.initSegmentData()?.count ?? 0)")
        log("segment 0 bytes: \(store.segmentData(index: 0)?.count ?? 0)")

        guard let ip = CastHTTPServer.lanAddress(reachableFrom: host) else {
            log("No LAN address")
            return 1
        }
        let url = "http://\(ip):\(server.port)/mirror/stream.m3u8"
        log("Serving: \(url)")

        let session = GoogleCastSession(device: GoogleCastDevice(name: "TV", host: host))
        let events = await session.events
        await session.connect()
        var catchingUp = false
        let timeout = Task {
            try? await Task.sleep(for: .seconds(45))
            await session.close()
        }
        for await event in events {
            switch event {
            case .state(let state):
                log("Cast state: \(state)")
                if state == .ready {
                    try? await Task.sleep(for: .seconds(1))
                    log("Sending LOAD…")
                    let progressive = url.replacingOccurrences(
                        of: "/mirror/stream.m3u8", with: "/mirror/live.mp4"
                    )
                    log("Trying progressive: \(progressive)")
                    await session.load(url: progressive, mime: "video/mp4",
                                       title: "Mac screen", live: true)
                    // Poll: receivers only push status on change, so a
                    // silent stall looks identical to smooth playback.
                    Task {
                        for _ in 0..<20 {
                            try? await Task.sleep(for: .seconds(2))
                            await session.requestStatus()
                        }
                    }
                }
                if state == .closed { timeout.cancel() }
            case .media(let time, let duration, let playerState):
                let drift = duration - time
                log(String(format: "Cast media: %@ drift=%.2fs", playerState, drift))
                // Catch-up: run fast while behind, back to 1× near the edge.
                if drift > 1.2, !catchingUp {
                    catchingUp = true
                    log("→ catching up at 1.15×")
                    await session.setPlaybackRate(1.15)
                } else if drift < 0.6, catchingUp {
                    catchingUp = false
                    log("→ back to 1×")
                    await session.setPlaybackRate(1.0)
                }
            case .error(let message):
                log("Cast ERROR: \(message)")
            }
        }
        await streamer.stop()
        server.stopAll()
        log("== done ==")
        return 0
    }
}
