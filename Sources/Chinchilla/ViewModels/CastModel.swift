import SwiftUI
import Observation
import AppKit
import Network
import UniformTypeIdentifiers
import AVFoundation
import CastKit
import SystemKit

/// One entry in the device list, regardless of protocol.
struct CastTarget: Identifiable, Hashable {
    enum Kind: Hashable {
        case fcast(FCastDevice)
        /// Works with the TV you already own — nothing to install.
        case dlna(DLNARenderer)
        /// Chromecast built-in: what most Android TVs speak out of the box.
        case googlecast(GoogleCastDevice)
        /// Listed so the room is complete; macOS drives it, not us.
        case airplay(AirPlayDevice)
    }

    let id: String
    let name: String
    let kind: Kind
    /// The same television often answers on two protocols. One row per
    /// physical set, with the alternative noted rather than duplicated.
    var alsoAirPlay = false

    var protocolLabel: LocalizedStringKey {
        switch kind {
        case .fcast: "FCast"
        case .dlna: "DLNA"
        case .googlecast: "Chromecast"
        case .airplay: "AirPlay"
        }
    }

    var subtitle: String? {
        if case .dlna(let renderer) = kind { return renderer.modelDescription }
        return nil
    }

    /// What this device can actually do — the question the list used to leave
    /// unanswered. Mirroring being greyed out with no explanation reads as a
    /// bug; saying "this one only plays files" reads as an answer.
    var canPlayFiles: Bool { true }

    var canMirror: Bool {
        switch kind {
        case .googlecast, .fcast: true
        case .dlna: false      // DLNA moves files around; it has no live input
        case .airplay: false   // macOS owns this route; no app can start it
        }
    }

    /// True when the right answer is "use the system", not "use us".
    var handledByMacOS: Bool {
        if case .airplay = kind { return true }
        return false
    }

    /// Chromecast devices carry the same mirroring receiver Chrome uses, which
    /// negotiates its delay instead of buffering like a media player.
    var hasFastMirror: Bool {
        if case .googlecast = kind { return true }
        return false
    }

    var capabilityLabel: LocalizedStringKey {
        switch kind {
        case .googlecast: "Files and screen mirroring · under half a second"
        case .fcast: "Files and screen mirroring · 2–3 seconds"
        case .dlna: "Files only — this one can't mirror your screen"
        // No model comes back from the browse — Bonjour hands over a name and
        // nothing else here — so one wording for all of them.
        case .airplay: "AirPlay: your Mac drives this one natively, and better than we could"
        }
    }

    /// What to add when the same set also speaks AirPlay: mirroring through
    /// macOS beats anything this app can do, and on a DLNA-only set it's the
    /// difference between "files only" and "actually mirrors".
    var airplayNote: LocalizedStringKey? {
        guard alsoAirPlay, !handledByMacOS else { return nil }
        return "Also on AirPlay — for mirroring, macOS does it better"
    }

    var capabilityTint: Color {
        if handledByMacOS { return Theme.primary }
        return canMirror ? Theme.ok : .secondary
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
    /// Shown in the UI so "which address is my Mac serving from?" is never
    /// a mystery (and to make the manual-IP field's purpose obvious).
    /// Stored, not computed — same reasoning as `screenPermissionGranted`:
    /// the answer only changes when the connection does, and as a computed
    /// property the getifaddrs interface walk behind it ran on every render
    /// of a screen that redraws every couple of seconds while casting.
    private(set) var macAddressForDisplay: String? = CastHTTPServer.lanAddress(reachableFrom: nil)
    var lastError: String?
    var firewallHint = false

    private var session: FCastSession?
    private var eventsTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private let discovery = FCastDiscovery()
    private let server = CastHTTPServer()
    private var fcastDevices: [FCastDevice] = []
    private var castDevices: [GoogleCastDevice] = []
    private let castDiscovery = GoogleCastDiscovery()
    private var castSession: GoogleCastSession?
    private var castEventsTask: Task<Void, Never>?
    private var dlnaRenderers: [DLNARenderer] = []
    private var airplayDevices: [AirPlayDevice] = []
    private let airplayDiscovery = AirPlayDiscovery()
    private var awaitingFetch = false

    // MARK: Screen mirroring
    var mirroring = false
    var mirrorStarting = false
    /// The one mirroring knob the UI shows. Resolution, Mbps target and
    /// playout delay move together — "responsive" means a lighter stream AND
    /// less buffer, "best picture" the opposite — so exposing them as three
    /// controls made users pick contradictions. Applies live mid-stream.
    var mirrorLevel: MirrorPreset = .bestPicture {
        didSet {
            guard mirrorLevel != oldValue else { return }
            mirrorQuality = mirrorLevel.quality
            mirrorDelayMs = mirrorLevel.playoutDelayMs
            let level = mirrorLevel
            // Resolution and bitrate move in-band mid-stream. The playout
            // delay does not: it is honored from the OFFER, and the in-band
            // change the protocol nominally supports is ignored by real
            // receivers — measured live: the reported delay sat at the
            // OFFER's 400 ms through every level switch. A different delay
            // needs a fresh negotiation, so the stream blinks once instead
            // of silently keeping the old buffer.
            if mirroring, fastMirror != nil,
               oldValue.playoutDelayMs != level.playoutDelayMs {
                stopMirroring()
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(600))
                    self?.startMirroring()
                }
            } else {
                Task { [weak self] in
                    await self?.fastMirror?.setLevel(
                        ceiling: level.quality, maxBitrate: level.bitrateCap,
                        playoutDelayMs: level.playoutDelayMs
                    )
                }
            }
        }
    }
    var mirrorQuality: MirrorQuality = .p1080
    /// Applied the moment it changes, not on the next connection — a
    /// checkbox that needs a reconnect to take effect reads as broken.
    var mirrorAudio = true {
        didSet {
            fastMirror?.setSendAudio(mirrorAudio)
            refreshMute()
        }
    }
    var mirrorError: String?
    /// Not probed at init: the TCC round-trip costs ~48 ms and every launch
    /// paid it, including the ones that never open this screen. The view asks
    /// on appear, which is the only moment the answer matters.
    var screenPermissionGranted = false
    private let streamer = ScreenStreamer()

    /// Chromecast devices carry a second, much faster receiver — the one
    /// Chrome uses for "Cast desktop". Nothing extra to install; it just
    /// negotiates a delay instead of buffering like a media player.
    var mirrorFastPath = true
    /// Let the stream follow the Wi-Fi: the quality picker becomes a ceiling
    /// and the session steps down (and back up) as the RTCP feedback says the
    /// link is choking or has recovered.
    var adaptiveMirrorQuality = true
    /// What the ladder is currently sending, e.g. "1080p · 6 Mbps" — nil when
    /// not mirroring on the fast path.
    private(set) var mirrorQualityStatus: String?
    /// Measured lag, refreshed ~1/s from per-frame ACK timing. Excludes the
    /// TV's own display processing, which nothing on this side can see.
    private(set) var mirrorLatency: MirrorLatency?
    /// How long the TV holds frames before showing them. Lower is more
    /// responsive; too low and a jittery Wi-Fi network starts to stutter.
    var mirrorDelayMs = 400 {
        didSet { fastMirror?.setPlayoutDelay(ms: mirrorDelayMs) }
    }
    /// Set when the fast path wasn't available and we fell back.
    var mirrorUsingFallback = false
    /// Whole screen, or one window parked on the TV while you keep working.
    var mirrorSource: MirrorSource = .wholeScreen
    /// The Mac keeps playing what it sends, because ScreenCaptureKit copies
    /// audio rather than moving it. Duplicating means showing something to a
    /// room, so the room's speakers should have it and the laptop shouldn't.
    /// Extending means you're still working here, so it stays here.
    var muteMacWhileCasting = true {
        didSet { refreshMute() }
    }
    /// Which side the second desktop lands on. Getting this wrong means the
    /// pointer leaves by the wrong edge, which feels broken even though
    /// nothing is.
    var extendedSide: ExtendedSide = .right {
        didSet { fastMirror?.setExtendedSide(extendedSide) }
    }
    var availableWindows: [MirrorSource] = []
    var loadingWindows = false
    private var fastMirror: CastMirrorSession?
    /// Bumped whenever mirroring is asked to stop, so a start that's still in
    /// flight can tell it was cancelled and tear itself down.
    private var mirrorGeneration = 0

    /// Only Chromecast and FCast play HLS; DLNA renderers generally don't.
    var canMirrorToConnectedDevice: Bool {
        switch connected?.kind {
        case .googlecast, .fcast: true
        case .dlna, .airplay, nil: false
        }
    }

    /// Chromecast devices have the fast receiver; FCast doesn't.
    var supportsFastMirror: Bool {
        if case .googlecast = connected?.kind { true } else { false }
    }

    /// What the user picks first, because it decides which TVs can even do
    /// the job — a DLNA set plays files and can't take a live screen.
    enum CastMode: String, CaseIterable, Identifiable {
        case duplicate, extendDisplay, window
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .duplicate: "Duplicate"
            case .extendDisplay: "Extend"
            case .window: "Send a window"
            }
        }

        var detail: LocalizedStringKey {
            switch self {
            case .duplicate: "The TV shows the same as your Mac."
            case .extendDisplay: "The TV becomes a second desktop you can drag windows onto."
            case .window: "One window goes to the TV; the Mac stays yours."
            }
        }

        var symbol: String {
            switch self {
            case .duplicate: "rectangle.on.rectangle"
            case .extendDisplay: "rectangle.on.rectangle.angled"
            case .window: "macwindow.on.rectangle"
            }
        }

        /// Sound belongs where the picture is being watched — except when
        /// you're still the one watching.
        var sendsAudioByDefault: Bool { self != .extendDisplay }
    }

    var castMode: CastMode = .duplicate {
        didSet {
            mirrorAudio = castMode.sendsAudioByDefault
            muteMacWhileCasting = castMode == .duplicate
            switch castMode {
            case .duplicate: mirrorSource = .wholeScreen
            case .extendDisplay: mirrorSource = .extendedDisplay
            case .window:
                refreshWindows()
                if case .window = mirrorSource {} else {
                    mirrorSource = availableWindows.first ?? .wholeScreen
                }
            }
        }
    }

    /// Connect and start in one press. Splitting them was a technical detail
    /// of how the session works, not a decision the user ever wanted to make.
    func startCasting(to target: CastTarget) {
        if connected != target {
            connect(to: target)
        }
        Task {
            // Give the session a moment to come up before offering it a stream.
            var waited = 0
            while sessionState != .ready, waited < 60 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            guard sessionState == .ready else {
                mirrorError = String(localized: "Couldn't reach that TV.")
                return
            }
            startMirroring()
        }
    }

    /// Windows are listed on demand: the list is stale the moment it's built,
    /// so it's refreshed when the picker is opened rather than polled.
    func refreshWindows() {
        guard !loadingWindows else { return }
        loadingWindows = true
        Task {
            defer { loadingWindows = false }
            availableWindows = (try? await ScreenStreamer.mirrorableWindows()) ?? []
            // The chosen window may have been closed since.
            if case .window(let id, _, _) = mirrorSource,
               !availableWindows.contains(where: {
                   if case .window(let other, _, _) = $0 { return other == id }
                   return false
               }) {
                mirrorSource = .wholeScreen
            }
        }
    }

    func refreshScreenPermission() {
        // Observation publishes on every set, identical value or not, and this
        // is called on each app activation — so an unconditional assignment
        // re-rendered the whole Cast screen for nothing. The check itself is a
        // ~48 ms TCC round trip, which is the other half of the reason.
        let granted = ScreenRecordingPermission.isGranted
        if granted != screenPermissionGranted { screenPermissionGranted = granted }
    }

    func requestScreenPermission() {
        _ = ScreenRecordingPermission.request()
        refreshScreenPermission()
    }

    /// Recomputed only at the moments the answer can change — connecting,
    /// disconnecting, or a cast start that already did the interface walk
    /// (which passes its result in rather than walking again).
    private func refreshMacAddress(_ known: String? = nil) {
        // Observation publishes on every set, so only write when it changed.
        let address = known ?? CastHTTPServer.lanAddress(reachableFrom: targetHost)
        if address != macAddressForDisplay { macAddressForDisplay = address }
    }

    func startMirroring() {
        guard let target = connected, !mirroring, !mirrorStarting else { return }
        guard ScreenRecordingPermission.isGranted else {
            requestScreenPermission()
            mirrorError = String(localized: "Grant Screen Recording, then reopen Chinchilla — macOS only applies it after a relaunch.")
            return
        }
        mirrorStarting = true
        mirrorError = nil
        mirrorUsingFallback = false
        mirrorGeneration += 1
        let generation = mirrorGeneration
        // A spinner that never stops isn't just confusing: it invalidates the
        // view every frame, so a stuck start burns a core redrawing forever.
        // Whatever happens below, the spinner comes down.
        BusyDeadline.arm("Cast.mirrorStarting", .seconds(45)) { [weak self] in
            guard let self else { return false }
            return mirrorStarting && mirrorGeneration == generation
        } clear: { [weak self] in
            guard let self else { return }
            mirrorStarting = false
            if !mirroring {
                mirrorError = String(localized: "Starting the mirror took too long. Try again.")
            }
        }
        Task {
            defer { mirrorStarting = false }

            // Fast path first. If the receiver turns it down we fall back
            // rather than failing — some Cast devices only speak the slow one.
            if case .googlecast(let device) = target.kind, mirrorFastPath {
                let fast = CastMirrorSession(
                    host: device.host, quality: mirrorQuality,
                    includeAudio: mirrorAudio, source: mirrorSource,
                    extendedSide: extendedSide, playoutDelayMs: mirrorDelayMs,
                    adaptive: adaptiveMirrorQuality,
                    maxBitrate: mirrorLevel.bitrateCap
                )
                fast.onStopped = { [weak self] message in
                    Task { @MainActor in
                        self?.mirroring = false
                        self?.mirrorQualityStatus = nil
                        self?.mirrorLatency = nil
                        if let message { self?.mirrorError = message }
                    }
                }
                fast.onQualityChange = { [weak self] rung in
                    Task { @MainActor in self?.mirrorQualityStatus = rung.label }
                }
                fast.onLatency = { [weak self] latency in
                    Task { @MainActor in
                        // Only rewrite (and re-render) when the number moved.
                        if self?.mirrorLatency != latency {
                            self?.mirrorLatency = latency
                        }
                    }
                }
                do {
                    try await fast.start()
                    // The user may have hit stop (or disconnected) while the
                    // handshake was in flight.
                    guard mirrorGeneration == generation else {
                        await fast.stop()
                        return
                    }
                    fastMirror = fast
                    castingName = String(localized: "Your screen")
                    mirroring = true
                    playbackState = 1
                    applyMuteIfWanted()
                    return
                } catch {
                    // The session may have got as far as opening a socket.
                    await fast.stop()
                    guard mirrorGeneration == generation else { return }
                    mirrorUsingFallback = true
                }
            }

            do {
                try server.start()
                for _ in 0..<40 where server.port == 0 {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard server.port > 0, let ip = CastHTTPServer.lanAddress(reachableFrom: targetHost) else {
                    mirrorError = String(localized: "Couldn't start the local server.")
                    return
                }
                refreshMacAddress(ip)
                // Two ways to feed the TV:
                //  • progressive fMP4 — one long-lived response, the same
                //    container TVs already play for files. Lower latency and
                //    what actually renders on Chromecast receivers.
                //  • HLS — kept for FCast receivers, which expect a playlist.
                let store = streamer.store
                server.setStreamRoute("/mirror/live.mp4") { writer in
                    Task {
                        var waited = 0
                        while store.initSegmentData() == nil, waited < 100 {
                            try? await Task.sleep(for: .milliseconds(100))
                            waited += 1
                        }
                        guard let header = store.initSegmentData(), writer.write(header) else {
                            writer.finish()
                            return
                        }
                        let subscription = store.subscribe { fragment in
                            _ = writer.write(fragment)
                        }
                        while store.hasContent {
                            try? await Task.sleep(for: .seconds(1))
                        }
                        store.unsubscribe(subscription)
                        writer.finish()
                    }
                }
                server.setPrefixRoute("/mirror/") { path in
                    if path == "stream.m3u8" {
                        return ("application/x-mpegurl", Data(store.playlist().utf8))
                    }
                    if path == "init.mp4", let data = store.initSegmentData() {
                        return ("video/mp4", data)
                    }
                    if path.hasPrefix("seg-"), path.hasSuffix(".m4s"),
                       let index = Int(path.dropFirst(4).dropLast(4)),
                       let data = store.segmentData(index: index) {
                        return ("video/mp4", data)
                    }
                    return nil
                }
                streamer.onStopped = { [weak self] message in
                    Task { @MainActor in
                        self?.mirroring = false
                        if let message { self?.mirrorError = message }
                    }
                }
                try await streamer.start(
                    quality: mirrorQuality, includeAudio: mirrorAudio,
                    source: mirrorSource, extendedSide: extendedSide
                )
                // Don't hand the TV a playlist before the first segment exists.
                // Progressive needs only the init segment; HLS wants a few
                // parts in the playlist before a player will touch it.
                let needed = { if case .googlecast = target.kind { 1 } else { 4 } }()
                guard await streamer.waitForFirstSegment(minimumSegments: needed) else {
                    await streamer.stop()
                    mirrorError = String(localized: "The screen encoder didn't produce video. Try again.")
                    return
                }
                guard mirrorGeneration == generation else {
                    await streamer.stop()
                    return
                }
                let base = "http://\(ip):\(server.port)/mirror"
                castingName = String(localized: "Your screen")
                mirroring = true
                applyMuteIfWanted()
                playbackState = 1
                switch target.kind {
                case .googlecast:
                    await castSession?.load(
                        url: "\(base)/live.mp4", mime: "video/mp4",
                        title: String(localized: "Mac screen"), live: true
                    )
                case .fcast:
                    await session?.play(FCastPlayMessage(
                        container: "application/vnd.apple.mpegurl",
                        url: "\(base)/stream.m3u8"
                    ))
                case .dlna, .airplay:
                    break      // not ours to drive
                }
            } catch {
                mirrorError = error.localizedDescription
                await streamer.stop()
            }
        }
    }

    /// Only mute when we're actually sending sound — muting a silent stream
    /// would just leave the user wondering where the audio went.
    private func applyMuteIfWanted() {
        refreshMute()
    }

    /// Brings the Mac's own sound in line with the current settings, whenever
    /// they change and whether or not a cast is running.
    private func refreshMute() {
        let shouldMute = mirroring && muteMacWhileCasting && mirrorAudio
        if shouldMute, !macWasMuted {
            macWasMuted = OutputMute.mute()
        } else if !shouldMute, macWasMuted {
            OutputMute.unmute()
            macWasMuted = false
        }
    }

    private var macWasMuted = false

    func stopMirroring() {
        if macWasMuted {
            OutputMute.unmute()
            macWasMuted = false
        }
        guard mirroring || mirrorStarting else { return }
        mirrorGeneration += 1
        mirroring = false
        castingName = nil
        mirrorQualityStatus = nil
        mirrorLatency = nil
        playbackState = 0
        let target = connected
        let fast = fastMirror
        fastMirror = nil
        Task {
            if let fast {
                await fast.stop()
                return
            }
            await streamer.stop()
            // Not just the routes: the listener and every connection it handed
            // out. Leaving it running kept a socket open and its token table
            // growing for the life of the app.
            server.stopAll()
            switch target?.kind {
            case .googlecast: await castSession?.stop()
            case .fcast: await session?.stop()
            default: break
            }
        }
    }

    /// Ranks by what this app can do with each protocol; the rule itself
    /// lives in CastKit, where it can be tested.
    static func merged(_ targets: [CastTarget]) -> [CastTarget] {
        DeviceMerge.merge(
            targets,
            name: \.name,
            rank: { target in
                switch target.kind {
                case .googlecast: 0     // files and sub-second mirroring
                case .fcast: 1          // files and mirroring
                case .dlna: 2           // files only
                case .airplay: 3        // nothing we can drive
                }
            },
            isAirPlay: { if case .airplay = $0.kind { true } else { false } }
        ).map { merged in
            var target = merged.item
            target.alsoAirPlay = merged.alsoAirPlay
            return target
        }
    }

    // MARK: Discovery (both protocols at once)

    private var lastSweep: Date?
    /// How many views showing the device list are on screen. The Bonjour
    /// browses are continuous, so without a matching stop the first visit to
    /// the Cast screen left three mDNS browsers running for the life of a
    /// menu-bar app that never quits.
    private var discoveryViewers = 0

    func discoveryViewAppeared() {
        discoveryViewers += 1
        startDiscoveryIfStale()
    }

    func discoveryViewDisappeared() {
        discoveryViewers = max(0, discoveryViewers - 1)
        if discoveryViewers == 0 { stopDiscovery() }
    }

    /// For places that open constantly — the menu bar panel — where a full
    /// SSDP sweep per open would be multicast traffic nobody asked for. The
    /// browses restart if a previous close stopped them; only the one-shot
    /// sweep is rate-limited.
    func startDiscoveryIfStale(after interval: TimeInterval = 30) {
        if let lastSweep, Date().timeIntervalSince(lastSweep) < interval {
            startBrowsers()
            return
        }
        startDiscovery()
    }

    func startDiscovery() {
        searchedAndEmpty = false
        lastSweep = Date()
        startBrowsers()
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

    /// Continuous Bonjour browses, one per protocol. Each guards against
    /// double starts, so calling this on every appearance is free.
    private func startBrowsers() {
        // FCast: continuous Bonjour browse.
        if discoveryState != .browsing {
            discovery.start(
                onDevices: { [weak self] devices in
                    Task { @MainActor in
                        self?.fcastDevices = devices
                        self?.rebuildTargets()
                    }
                },
                onState: { [weak self] state in
                    Task { @MainActor in self?.discoveryState = state }
                }
            )
        }
        // Google Cast (Chromecast built-in): continuous Bonjour browse.
        airplayDiscovery.start { [weak self] devices in
            Task { @MainActor in
                self?.airplayDevices = devices
                self?.rebuildTargets()
            }
        }
        castDiscovery.start { [weak self] devices in
            Task { @MainActor in
                self?.castDevices = devices
                self?.rebuildTargets()
            }
        }
    }

    private func rebuildTargets() {
        var list: [CastTarget] = fcastDevices.map {
            CastTarget(id: "fcast:\($0.name)", name: $0.name, kind: .fcast($0))
        }
        list += castDevices.map {
            CastTarget(id: "cast:\($0.id)", name: $0.name, kind: .googlecast($0))
        }
        list += airplayDevices.map {
            CastTarget(id: "airplay:\($0.name)", name: $0.name, kind: .airplay($0))
        }
        list += dlnaRenderers.map {
            CastTarget(id: "dlna:\($0.avTransportURL.absoluteString)", name: $0.name, kind: .dlna($0))
        }
        // Every other multi-source collection in the app dedupes; this one
        // didn't. Two descriptors from one TV, or two Bonjour instances
        // resolving to the same address, put duplicate ids in a live-updating
        // ForEach — which is exactly what spun the view graph before.
        var seen = Set<String>()
        list.removeAll { !seen.insert($0.id).inserted }
        targets = Self.merged(list)
        if !list.isEmpty { searchedAndEmpty = false }
    }

    func stopDiscovery() {
        castDiscovery.stop()
        discovery.stop()
        airplayDiscovery.stop()
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
        refreshMacAddress()
        lastError = nil
        switch target.kind {
        case .airplay:
            // Listed for completeness; macOS owns the connection.
            sessionState = .closed
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
        case .googlecast(let device):
            let session = GoogleCastSession(device: device)
            castSession = session
            sessionState = .connecting
            castEventsTask = Task { [weak self] in
                let stream = await session.events
                for await event in stream {
                    await self?.handle(cast: event)
                }
            }
            Task { await session.connect() }
        }
    }

    private func handle(cast event: GoogleCastEvent) {
        switch event {
        case .state(let state):
            sessionState = state
            if state == .closed { castingName = nil }
        case .media(let time, let duration, let playerState):
            playbackTime = time
            if duration > 0 { playbackDuration = duration }
            playbackState = playerState == "PLAYING" ? 1 : (playerState == "PAUSED" ? 2 : 0)
            if playbackState != 0 {
                awaitingFetch = false
                firewallHint = false
            }
        case .error(let message):
            lastError = message
        }
    }

    func disconnect() {
        // Mirroring holds its own capture and, on the fast path, its own
        // connection to the TV — dropping this session doesn't reach it.
        if mirroring || mirrorStarting { stopMirroring() }
        let old = session
        let oldCast = castSession
        Task { await old?.close() }
        Task { await oldCast?.close() }
        session = nil
        castSession = nil
        eventsTask?.cancel()
        castEventsTask?.cancel()
        pollTask?.cancel()
        pollTask = nil
        connected = nil
        sessionState = .closed
        castingName = nil
        playbackState = 0
        refreshMacAddress()
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

    /// IP of the connected TV, used to pick the local interface that can
    /// actually reach it (VPNs and virtual adapters break naive guesses).
    private var targetHost: String? {
        switch connected?.kind {
        case .airplay: nil
        case .dlna(let renderer): renderer.avTransportURL.host
        case .googlecast(let device): device.host
        case .fcast(let device):
            if case .hostPort(let host, _) = device.endpoint {
                switch host {
                case .ipv4(let address): "\(address)"
                case .name(let name, _): name
                default: nil
                }
            } else { nil }
        case nil: nil
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
        guard let ip = CastHTTPServer.lanAddress(reachableFrom: targetHost) else {
            lastError = String(localized: "No network address found — are you on Wi-Fi?")
            return
        }
        refreshMacAddress(ip)
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
            // Receivers don't always report duration (screen recordings
            // often lack the metadata) — read it locally so the scrubber
            // works from the first second either way.
            if let localDuration = try? await AVURLAsset(url: url).load(.duration).seconds,
               localDuration.isFinite, localDuration > 0 {
                playbackDuration = localDuration
            }
            awaitingFetch = true
            firewallHint = false
            playbackDuration = 0
            playbackTime = 0

            switch target.kind {
            case .fcast:
                await session?.play(FCastPlayMessage(container: mime, url: mediaURL))
            case .googlecast:
                await castSession?.load(url: mediaURL, mime: mime, title: url.lastPathComponent)
            case .airplay:
                break      // macOS drives this one
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

    /// DLNA has no push updates — poll position while something plays. The
    /// loop must also end on its own: it used to keep a SOAP request going
    /// every 2 s forever once the file finished or the TV was switched off,
    /// because nothing but stop/disconnect ever cancelled it.
    private func startDLNAPolling(_ renderer: DLNARenderer) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                if let info = await DLNAControl.positionInfo(renderer) {
                    guard let self else { return }
                    misses = 0
                    playbackTime = info.position
                    if info.duration > 0 { playbackDuration = info.duration }
                    if info.position > 0 {
                        awaitingFetch = false
                        firewallHint = false
                    }
                    // Played to the end (within one poll interval of it).
                    if info.duration > 0, info.position >= info.duration - 2 {
                        playbackState = 0
                        return
                    }
                } else {
                    // Ten seconds of silence means the TV is gone, not busy.
                    misses += 1
                    if misses >= 5 { return }
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
            case .googlecast:
                paused ? await castSession?.play() : await castSession?.pause()
            case .airplay:
                break      // macOS drives this one
            case .dlna(let renderer):
                if paused {
                    try? await DLNAControl.resume(renderer)
                    // The poll ends itself at end-of-track; playing again
                    // needs it back.
                    startDLNAPolling(renderer)
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
            case .googlecast: await castSession?.stop()
            case .airplay: break
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
            case .googlecast: await castSession?.seek(to: time)
            case .airplay: break
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
            case .googlecast: await castSession?.setVolume(value)
            case .airplay: break
            case .dlna(let renderer): try? await DLNAControl.setVolume(renderer, volume: value)
            }
        }
    }
}
