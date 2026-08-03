import SwiftUI
import Observation
import AppKit
import UniformTypeIdentifiers
import CastKit

@MainActor
@Observable
final class CastModel {
    // Discovery
    var devices: [FCastDevice] = []
    var discoveryState: DiscoveryState = .idle

    // Session
    var connectedDevice: FCastDevice?
    var sessionState: FCastSessionState = .closed
    private var session: FCastSession?
    private var eventsTask: Task<Void, Never>?

    // Now playing
    var playbackState = 0        // 0 idle, 1 playing, 2 paused
    var playbackTime: Double = 0
    var playbackDuration: Double = 0
    var volume: Double = 1
    var castingName: String?
    var lastError: String?
    /// Play sent but the TV never fetched from our server → firewall hint.
    var firewallHint = false

    private let discovery = FCastDiscovery()
    private let server = CastHTTPServer()
    private var awaitingFetch = false

    // MARK: Discovery

    func startDiscovery() {
        // Restart when idle or failed; leave an active browse alone.
        switch discoveryState {
        case .idle, .failed, .waitingForLocalNetworkPermission:
            break
        case .browsing:
            return
        }
        discovery.start(
            onDevices: { devices in
                Task { @MainActor [weak self] in self?.devices = devices }
            },
            onState: { state in
                Task { @MainActor [weak self] in self?.discoveryState = state }
            }
        )
    }

    func stopDiscovery() {
        discovery.stop()
        discoveryState = .idle
    }

    // MARK: Session

    func connect(to device: FCastDevice) {
        disconnect()
        let session = FCastSession(endpoint: device.endpoint)
        self.session = session
        connectedDevice = device
        sessionState = .connecting
        eventsTask = Task { [weak self] in
            let stream = await session.events
            for await event in stream {
                await self?.handle(event)
            }
        }
        Task { await session.connect() }
    }

    func disconnect() {
        let old = session
        Task { await old?.close() }
        session = nil
        eventsTask?.cancel()
        connectedDevice = nil
        sessionState = .closed
        castingName = nil
        playbackState = 0
    }

    private func handle(_ event: FCastEvent) {
        switch event {
        case .state(let state):
            sessionState = state
            if state == .closed || state == .unreachable {
                castingName = nil
            }
        case .playback(let update):
            playbackState = update.state ?? playbackState
            playbackTime = update.time ?? playbackTime
            playbackDuration = update.duration ?? playbackDuration
            if playbackState != 0 {
                awaitingFetch = false
                firewallHint = false
            }
        case .volume(let update):
            if let value = update.volume { volume = value }
        case .error(let message):
            lastError = message
        }
    }

    // MARK: Casting files

    func pickAndCastFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio, .mpeg4Movie, .quickTimeMovie, .mp3]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        castFile(url)
    }

    func castFile(_ url: URL) {
        guard let session else { return }
        lastError = nil
        do {
            try server.start()
        } catch {
            lastError = String(localized: "Couldn't start the local server.")
            return
        }
        guard let ip = CastHTTPServer.lanAddress(), server.port > 0 else {
            lastError = String(localized: "No network address found — are you on Wi-Fi?")
            return
        }
        let path = server.register(file: url)
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "video/mp4"
        let mediaURL = "http://\(ip):\(server.port)\(path)"
        castingName = url.lastPathComponent
        awaitingFetch = true
        firewallHint = false
        Task {
            await session.play(FCastPlayMessage(container: mime, url: mediaURL))
            try? await Task.sleep(for: .seconds(5))
            if awaitingFetch, playbackState == 0 {
                firewallHint = true
            }
        }
    }

    // MARK: Controls

    func togglePlayPause() {
        guard let session else { return }
        let paused = playbackState == 2
        Task { paused ? await session.resume() : await session.pause() }
    }

    func stopCasting() {
        guard let session else { return }
        castingName = nil
        Task { await session.stop() }
    }

    func seek(to time: Double) {
        guard let session else { return }
        playbackTime = time
        Task { await session.seek(to: time) }
    }

    func setVolume(_ value: Double) {
        guard let session else { return }
        volume = value
        Task { await session.setVolume(value) }
    }
}
