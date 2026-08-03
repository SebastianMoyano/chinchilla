import Foundation
import CastKit

/// `Chinchilla mirror-test <tv-ip>` — runs the whole mirroring pipeline
/// from the app bundle (which owns the Screen Recording grant) and prints
/// what happens at every stage. Diagnostics only; not in the help text.
enum MirrorDiagnostics {
    static func run(host: String) async -> Int32 {
        print("== Chinchilla mirror diagnostics ==")
        print("Screen Recording granted: \(ScreenRecordingPermission.isGranted)")
        guard ScreenRecordingPermission.isGranted else {
            print("→ Grant it in System Settings → Privacy → Screen Recording, then relaunch.")
            return 1
        }

        let streamer = ScreenStreamer()
        let server = CastHTTPServer()
        server.onRequest = { method, path in
            print("  HTTP \(method) \(path)")
        }
        do {
            try server.start()
        } catch {
            print("HTTP server failed: \(error)")
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

        do {
            try await streamer.start(quality: .p720, includeAudio: false)
        } catch {
            print("Capture failed: \(error)")
            return 1
        }
        let ready = await streamer.waitForFirstSegment()
        print("Segments ready: \(ready)")
        print("Playlist:\n\(store.playlist())")
        print("init segment bytes: \(store.initSegmentData()?.count ?? 0)")
        print("segment 0 bytes: \(store.segmentData(index: 0)?.count ?? 0)")

        guard let ip = CastHTTPServer.lanAddress(reachableFrom: host) else {
            print("No LAN address")
            return 1
        }
        let url = "http://\(ip):\(server.port)/mirror/stream.m3u8"
        print("Serving: \(url)")

        let session = GoogleCastSession(device: GoogleCastDevice(name: "TV", host: host))
        let events = await session.events
        await session.connect()
        let timeout = Task {
            try? await Task.sleep(for: .seconds(40))
            await session.close()
        }
        for await event in events {
            switch event {
            case .state(let state):
                print("Cast state: \(state)")
                if state == .ready {
                    try? await Task.sleep(for: .seconds(1))
                    print("Sending LOAD…")
                    await session.load(url: url, mime: "application/x-mpegurl",
                                       title: "Mac screen", live: true)
                }
                if state == .closed { timeout.cancel() }
            case .media(let time, let duration, let playerState):
                print("Cast media: state=\(playerState) time=\(time) duration=\(duration)")
            case .error(let message):
                print("Cast ERROR: \(message)")
            }
        }
        await streamer.stop()
        server.stopAll()
        print("== done ==")
        return 0
    }
}
