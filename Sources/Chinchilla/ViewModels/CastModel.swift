import SwiftUI
import Observation
import AppKit
import Network
import UniformTypeIdentifiers
import CastKit

/// One entry in the device list, regardless of protocol.
struct CastTarget: Identifiable, Hashable {
    enum Kind: Hashable {
        case fcast(FCastDevice)
        /// Works with the TV you already own — nothing to install.
        case dlna(DLNARenderer)
    }

    let id: String
    let name: String
    let kind: Kind

    var protocolLabel: LocalizedStringKey {
        switch kind {
        case .fcast: "FCast"
        case .dlna: "DLNA"
        }
    }

    var subtitle: String? {
        if case .dlna(let renderer) = kind { return renderer.modelDescription }
        return nil
    }
}

@MainActor
@Observable
final class CastModel {
    var targets: [CastTarget] = []
    var discoveryState: DiscoveryState = .idle
    /// True once a full search cycle finished with nothing found.
    var searchedAndEmpty = false

    var connected: CastTarget?
    var sessionState: FCastSessionState = .closed

    // Now playing
    var playbackState = 0        // 0 idle, 1 playing, 2 paused
    var playbackTime: Double = 0
    var playbackDuration: Double = 0
    var volume: Double = 1
    var castingName: String?
    var lastError: String?
    var firewallHint = false

    private var session: FCastSession?
    private var eventsTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private let discovery = FCastDiscovery()
    private let server = CastHTTPServer()
    private var fcastDevices: [FCastDevice] = []
    private var dlnaRenderers: [DLNARenderer] = []
    private var awaitingFetch = false

    // MARK: Discovery (both protocols at once)

    func startDiscovery() {
        searchedAndEmpty = false
        // FCast: continuous Bonjour browse.
        if discoveryState != .browsing {
            discovery.start(
                onDevices: { devices in
                    Task { @MainActor [weak self] in
                        self?.fcastDevices = devices
                        self?.rebuildTargets()
                    }
                },
                onState: { state in
                    Task { @MainActor [weak self] in self?.discoveryState = state }
                }
            )
        }
        // DLNA: one SSDP sweep per refresh.
        Task {
            let locations = await SSDP.discoverRenderers()
            var renderers: [DLNARenderer] = []
            for location in locations {
                if let renderer = await UPnPDescription.fetchRenderer(from: location) {
                    renderers.append(renderer)
                }
            }
            dlnaRenderers = renderers.sorted { $0.name < $1.name }
            rebuildTargets()
            searchedAndEmpty = targets.isEmpty
        }
    }

    private func rebuildTargets() {
        var list: [CastTarget] = fcastDevices.map {
            CastTarget(id: "fcast:\($0.name)", name: $0.name, kind: .fcast($0))
        }
        list += dlnaRenderers.map {
            CastTarget(id: "dlna:\($0.avTransportURL.absoluteString)", name: $0.name, kind: .dlna($0))
        }
        targets = list
        if !list.isEmpty { searchedAndEmpty = false }
    }

    func stopDiscovery() {
        discovery.stop()
        discoveryState = .idle
    }

    /// Manual connect for FCast receivers that don't advertise (or when
    /// mDNS is blocked on the network).
    func connectManually(host: String) {
        guard let port = NWEndpoint.Port(rawValue: 46899) else { return }
        let device = FCastDevice(
            name: host,
            endpoint: .hostPort(host: NWEndpoint.Host(host), port: port)
        )
        let target = CastTarget(id: "fcast:\(host)", name: host, kind: .fcast(device))
        connect(to: target)
    }

    // MARK: Connect

    func connect(to target: CastTarget) {
        disconnect()
        connected = target
        lastError = nil
        switch target.kind {
        case .fcast(let device):
            let session = FCastSession(endpoint: device.endpoint)
            self.session = session
            sessionState = .connecting
            eventsTask = Task { [weak self] in
                let stream = await session.events
                for await event in stream {
                    await self?.handle(event)
                }
            }
            Task { await session.connect() }
        case .dlna:
            // DLNA is stateless HTTP — nothing to hold open.
            sessionState = .ready
        }
    }

    func disconnect() {
        let old = session
        Task { await old?.close() }
        session = nil
        eventsTask?.cancel()
        pollTask?.cancel()
        pollTask = nil
        connected = nil
        sessionState = .closed
        castingName = nil
        playbackState = 0
    }

    private func handle(_ event: FCastEvent) {
        switch event {
        case .state(let state):
            sessionState = state
            if state == .closed || state == .unreachable { castingName = nil }
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
        guard let target = connected else { return }
        lastError = nil
        do {
            try server.start()
        } catch {
            lastError = String(localized: "Couldn't start the local server.")
            return
        }
        guard let ip = CastHTTPServer.lanAddress() else {
            lastError = String(localized: "No network address found — are you on Wi-Fi?")
            return
        }
        // The listener publishes its port asynchronously.
        Task {
            for _ in 0..<40 where server.port == 0 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard server.port > 0 else {
                lastError = String(localized: "Couldn't start the local server.")
                return
            }
            let path = server.register(file: url)
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "video/mp4"
            let mediaURL = "http://\(ip):\(server.port)\(path)"
            castingName = url.lastPathComponent
            awaitingFetch = true
            firewallHint = false
            playbackDuration = 0
            playbackTime = 0

            switch target.kind {
            case .fcast:
                await session?.play(FCastPlayMessage(container: mime, url: mediaURL))
            case .dlna(let renderer):
                do {
                    try await DLNAControl.play(
                        renderer, url: mediaURL, title: url.lastPathComponent, mime: mime
                    )
                    playbackState = 1
                    startDLNAPolling(renderer)
                } catch {
                    lastError = String(localized: "The TV rejected the file. Try an .mp4 (H.264) — TVs are picky about formats.")
                }
            }

            try? await Task.sleep(for: .seconds(5))
            if awaitingFetch, playbackState == 0 { firewallHint = true }
        }
    }

    /// DLNA has no push updates — poll position while something plays.
    private func startDLNAPolling(_ renderer: DLNARenderer) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let info = await DLNAControl.positionInfo(renderer) {
                    await MainActor.run {
                        self?.playbackTime = info.position
                        if info.duration > 0 { self?.playbackDuration = info.duration }
                        if info.position > 0 {
                            self?.awaitingFetch = false
                            self?.firewallHint = false
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Controls

    func togglePlayPause() {
        guard let target = connected else { return }
        let paused = playbackState == 2
        playbackState = paused ? 1 : 2
        Task {
            switch target.kind {
            case .fcast:
                paused ? await session?.resume() : await session?.pause()
            case .dlna(let renderer):
                if paused {
                    try? await DLNAControl.resume(renderer)
                } else {
                    try? await DLNAControl.pause(renderer)
                }
            }
        }
    }

    func stopCasting() {
        guard let target = connected else { return }
        castingName = nil
        playbackState = 0
        pollTask?.cancel()
        Task {
            switch target.kind {
            case .fcast: await session?.stop()
            case .dlna(let renderer): try? await DLNAControl.stop(renderer)
            }
        }
    }

    func seek(to time: Double) {
        guard let target = connected else { return }
        playbackTime = time
        Task {
            switch target.kind {
            case .fcast: await session?.seek(to: time)
            case .dlna(let renderer): try? await DLNAControl.seek(renderer, to: time)
            }
        }
    }

    func setVolume(_ value: Double) {
        guard let target = connected else { return }
        volume = value
        Task {
            switch target.kind {
            case .fcast: await session?.setVolume(value)
            case .dlna(let renderer): try? await DLNAControl.setVolume(renderer, volume: value)
            }
        }
    }
}
