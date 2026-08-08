import Foundation
import ScreenCaptureKit
import DiskScanKit

/// Low-latency screen mirroring to a Cast device.
///
/// Everything the fast path needs, in one object: negotiate with the
/// mirroring receiver, capture, encode, and send RTP. The slow path (HLS to
/// the Default Media Receiver) stays where it is as a fallback for receivers
/// that turn the offer down.
public final class CastMirrorSession: @unchecked Sendable {
    public enum Failure: LocalizedError {
        case noDisplay
        case receiverDeclined
        case noAnswer

        public var errorDescription: String? {
            switch self {
            case .noDisplay:
                String(localized: "No display to capture.")
            case .receiverDeclined:
                String(localized: "This TV answered but wouldn't accept the video stream.")
            case .noAnswer:
                String(localized: "This TV didn't answer the streaming request.")
            }
        }
    }

    public let host: String
    public let quality: MirrorQuality
    public let frameRate: Int
    public let includeAudio: Bool
    public let source: MirrorSource
    public let extendedSide: ExtendedSide
    public private(set) var playoutDelayMs: Int
    /// False when the receiver took video but turned audio down, so the UI
    /// can say so instead of leaving the user wondering.
    public private(set) var audioAccepted = false
    /// Whether audio is actually being delivered right now. The stream is
    /// always negotiated so this can be flipped live: renegotiating an OFFER
    /// mid-cast would mean tearing the picture down to change a checkbox.
    private let sendAudio = Locked(true)

    private var session: GoogleCastSession?
    private var transport: CastStreamTransport?
    private var sender: CastStreamSender?
    /// The encoder lives behind a lock because adaptive quality replaces it
    /// mid-stream (a resolution change needs a new VTCompressionSession) while
    /// the capture queue is reading it. Everyone — capture callback, key-frame
    /// requests, the swap itself — goes through this one box.
    private let activeEncoder = Locked<RealtimeH264Encoder?>(nil)
    private var audioSender: CastStreamSender?
    private var audioEncoder: OpusAudioEncoder?
    private var streamer: ScreenStreamer?

    // MARK: Adaptive quality
    /// Whether the ladder runs at all; chosen before the stream starts.
    public let adaptive: Bool
    /// The level's Mbps target — the ladder never starts above it. Mutable
    /// because the user can switch levels mid-stream.
    private let bitrateCap: Locked<Int>
    private let qualityCeiling: Locked<MirrorQuality>
    /// The capture size at the ceiling quality — rung sizes scale from it so
    /// aspect is preserved for windows and odd-shaped displays.
    private let baseSize = Locked<(width: Int, height: Int)?>(nil)
    private let currentRung = Locked<QualityRung?>(nil)
    private var monitorTask: Task<Void, Never>?
    /// Fires whenever the ladder moves (and once at start), off the main
    /// actor — hop before touching UI state.
    public var onQualityChange: (@Sendable (QualityRung) -> Void)?
    /// The lag the protocol can actually see, refreshed about once a second
    /// while mirroring. Off the main actor.
    public var onLatency: (@Sendable (MirrorLatency) -> Void)?

    /// Called when the stream dies on its own.
    public var onStopped: (@Sendable (String?) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?

    public init(
        host: String, quality: MirrorQuality = .p720,
        frameRate: Int = 30, includeAudio: Bool = true,
        source: MirrorSource = .wholeScreen,
        extendedSide: ExtendedSide = .right,
        playoutDelayMs: Int = CastStreaming.defaultTargetDelayMs,
        adaptive: Bool = true,
        maxBitrate: Int = .max
    ) {
        self.host = host
        self.quality = quality
        self.frameRate = frameRate
        self.includeAudio = includeAudio
        self.source = source
        self.extendedSide = extendedSide
        self.playoutDelayMs = playoutDelayMs
        self.adaptive = adaptive
        self.bitrateCap = Locked(maxBitrate)
        self.qualityCeiling = Locked(quality)
    }

    /// Every failure past the first allocation has to give the resources back.
    /// Four of the throw sites did; two didn't, and each of those left a UDP
    /// socket, a TLS session and a heartbeat pinging a dead peer every five
    /// seconds. Measured: 200 failed attempts, 205 open file descriptors, and
    /// the soft limit is 256.
    public func start() async throws {
        do {
            try await startOrThrow()
        } catch {
            await stop()
            throw error
        }
    }

    private func startOrThrow() async throws {
        guard let size = try? await ScreenStreamer.captureSize(
            for: quality, source: source
        ) else {
            throw Failure.noDisplay
        }

        // The level's Mbps target trims the ladder before anything starts.
        let ladder = AdaptiveQuality.ladder(
            ceiling: quality, maxBitrate: bitrateCap.withLock { $0 }
        )
        let startRung = ladder[0]
        let startSize = AdaptiveQuality.fit(size, into: startRung.quality.size)

        // The offer has to describe what we will actually send.
        var offer = CastStreaming.Offer()
        offer.width = startSize.width
        offer.height = startSize.height
        offer.frameRate = frameRate
        offer.videoBitRate = startRung.bitrate
        // Always offered, even when it starts switched off — see `sendAudio`.
        offer.includeAudio = true
        sendAudio.withLock { $0 = includeAudio }
        offer.targetDelayMs = playoutDelayMs
        let sealed = offer

        let session = GoogleCastSession(device: GoogleCastDevice(name: "TV", host: host))
        self.session = session

        let answers = AnswerBox()
        await session.useStreamingApp(namespace: CastStreaming.namespace) { _, payload in
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answer = CastStreaming.Answer(json: json) else { return }
            answers.set(answer)
        }
        await session.connect()

        // Wait for the receiver app, then offer.
        var waited = 0
        while await !session.isAppReady, waited < 60 {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }
        guard await session.isAppReady else {
            await stop()
            throw Failure.noAnswer
        }
        await session.sendCustom(
            namespace: CastStreaming.namespace, payload: sealed.json(sequenceNumber: 1)
        )

        waited = 0
        while answers.value == nil, waited < 40 {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }
        guard let answer = answers.value else {
            await stop()
            throw Failure.noAnswer
        }
        guard answer.acceptedVideo else {
            await stop()
            throw Failure.receiverDeclined
        }
        audioAccepted = answer.acceptedAudio
        onLog?("Cast Streaming: udpPort=\(answer.udpPort), delay=\(playoutDelayMs) ms, " +
               "audio=\(audioAccepted)")

        guard let transport = CastStreamTransport(host: host, port: answer.udpPort) else {
            await stop()
            throw Failure.noAnswer
        }
        transport.onLog = onLog
        transport.start()
        self.transport = transport

        let encoder = try RealtimeH264Encoder(
            width: startSize.width, height: startSize.height,
            bitrate: sealed.videoBitRate, frameRate: frameRate
        )
        let sender = CastStreamSender(
            transport: transport, keys: sealed.videoKeys,
            ssrc: sealed.videoSSRC, payloadType: 101,
            initialPlayoutDelayMs: playoutDelayMs
        )
        sender.onLog = onLog
        // Through the box, not the encoder itself: after an adaptive
        // resolution switch the request must reach the *current* encoder.
        let activeEncoder = self.activeEncoder
        sender.onKeyFrameRequest = {
            activeEncoder.withLock { $0 }?.requestKeyFrame()
        }
        sender.start()
        encoder.onSample = { [weak sender] sample in sender?.send(sample) }
        activeEncoder.withLock { $0 = encoder }
        // Aspect reference at the 1080p box, so a mid-stream level change can
        // raise the capture back up — every source has the detail: real
        // displays are at least that dense, and the virtual desktop is
        // created at 1080p regardless of the stream's box.
        let base: (width: Int, height: Int)
        if quality == .p1080 {
            base = size
        } else {
            let ratio = Double(MirrorQuality.p1080.size.height)
                / Double(quality.size.height)
            base = (max(2, Int((Double(size.width) * ratio / 2).rounded()) * 2),
                    max(2, Int((Double(size.height) * ratio / 2).rounded()) * 2))
        }
        baseSize.withLock { $0 = base }
        currentRung.withLock { $0 = startRung }

        // Audio rides a second RTP stream: its own SSRC, its own keys, and a
        // 48 kHz timebase instead of video's 90 kHz.
        if audioAccepted {
            let audioEncoder = OpusAudioEncoder(bitrate: 128_000)
            let audioSender = CastStreamSender(
                transport: transport, keys: sealed.audioKeys,
                ssrc: sealed.audioSSRC, payloadType: 96, timebase: 48_000,
                initialPlayoutDelayMs: playoutDelayMs
            )
            audioSender.onLog = onLog
            audioSender.start()
            audioEncoder.onPacket = { [weak audioSender] packet in
                audioSender?.sendAudio(packet)
            }
            self.audioEncoder = audioEncoder
            self.audioSender = audioSender
        }

        let streamer = ScreenStreamer()
        // Capture the encoder box rather than reaching through `self`: the
        // callback fires on the capture queue while `stop()` — and adaptive
        // resolution switches — replace the encoder from another thread.
        streamer.onVideoSample = { buffer in
            activeEncoder.withLock { $0 }?.encode(buffer)
        }
        if let audioEncoder {
            let gate = sendAudio
            streamer.onAudioSample = { [weak audioEncoder] buffer in
                guard gate.withLock({ $0 }) else { return }
                audioEncoder?.encode(buffer)
            }
        }
        streamer.onStopped = { [weak self] message in self?.onStopped?(message) }
        try await streamer.start(
            quality: quality, includeAudio: audioAccepted, frameRate: frameRate,
            source: source, extendedSide: extendedSide
        )

        self.sender = sender
        self.streamer = streamer

        // A level whose target sits below the ceiling's resolution starts
        // the capture there too (the config above captured at the ceiling).
        if startRung.quality != quality {
            await streamer.updateCaptureSize(
                width: startSize.width, height: startSize.height
            )
        }
        // Always: latency is measured whether or not the ladder may move.
        startHealthMonitor(sender: sender, ladder: ladder)
        if let rung = currentRung.withLock({ $0 }) {
            onQualityChange?(rung)
        }
    }

    // MARK: Adaptive quality

    /// Switches the level mid-stream: the new delay rides on the next frame,
    /// and the ladder is rebuilt under the new ceiling and Mbps target — the
    /// stream jumps to the new top rung, then adaptation resumes from there.
    public func setLevel(
        ceiling: MirrorQuality, maxBitrate: Int, playoutDelayMs: Int
    ) async {
        setPlayoutDelay(ms: playoutDelayMs)
        qualityCeiling.withLock { $0 = ceiling }
        bitrateCap.withLock { $0 = maxBitrate }
        monitorTask?.cancel()
        monitorTask = nil
        let ladder = AdaptiveQuality.ladder(ceiling: ceiling, maxBitrate: maxBitrate)
        await apply(ladder[0])
        if let sender {
            startHealthMonitor(sender: sender, ladder: ladder)
        }
    }

    /// The stream is the probe: once a second, read the RTCP-fed stats
    /// deltas, publish the latency estimate, and — when adaptation is on —
    /// let the controller move the ladder. Ends with the session — the task
    /// holds everything weakly and exits when the sender goes away.
    private func startHealthMonitor(sender: CastStreamSender, ladder: [QualityRung]) {
        let adaptive = self.adaptive && ladder.count > 1
        monitorTask = Task { [weak self, weak sender] in
            var controller = AdaptiveRateController(ladder: ladder)
            var last = CastStreamSender.Stats()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let sender else { return }
                let stats = sender.currentStats()
                let sent = stats.packetsSent - last.packetsSent
                let resent = stats.packetsResent - last.packetsResent
                let keyFrames = stats.keyFrameRequests - last.keyFrameRequests
                last = stats
                if let p50 = stats.rttMsP50 {
                    // The buffer term is what we last *asked* for, not what
                    // the receiver reports: the report just echoes the
                    // OFFER-time target forever, while field testing showed
                    // in-band changes are honored — the felt lag moved with
                    // the level while the reported value sat still.
                    self?.onLatency?(MirrorLatency(
                        sendToAckP50Ms: Int(p50.rounded()),
                        sendToAckP95Ms: Int((stats.rttMsP95 ?? p50).rounded()),
                        playoutDelayMs: self?.playoutDelayMs ?? 0
                    ))
                }
                if adaptive, let rung = controller.assess(
                    packetsSent: sent, packetsResent: resent,
                    keyFrameRequests: keyFrames, rttP95Ms: stats.rttMsP95
                ) {
                    await self?.apply(rung)
                }
            }
        }
    }

    /// Moves the stream to a rung. Same resolution: one live encoder
    /// property. Different resolution: new encoder (its first frame is an
    /// IDR carrying the new parameter sets, which Cast receivers switch on
    /// seamlessly), then the capture rescales — order matters, because the
    /// old-size frames still in flight must meet an encoder that accepts them.
    private func apply(_ rung: QualityRung) async {
        let previous = currentRung.withLock { current -> QualityRung? in
            let before = current
            current = rung
            return before
        }
        onLog?("adaptive: \(previous?.label ?? "start") → \(rung.label)")

        if previous?.quality == rung.quality {
            activeEncoder.withLock { $0 }?.setBitrate(rung.bitrate)
        } else if let base = baseSize.withLock({ $0 }) {
            let size = AdaptiveQuality.fit(base, into: rung.quality.size)
            let sender = self.sender
            guard let fresh = try? RealtimeH264Encoder(
                width: size.width, height: size.height,
                bitrate: rung.bitrate, frameRate: frameRate
            ) else {
                // Encoder creation failing is exotic; degrade by bitrate only
                // rather than dropping the stream over it.
                activeEncoder.withLock { $0 }?.setBitrate(rung.bitrate)
                onQualityChange?(rung)
                return
            }
            fresh.onSample = { [weak sender] sample in sender?.send(sample) }
            let old = activeEncoder.withLock { current -> RealtimeH264Encoder? in
                let before = current
                current = fresh
                return before
            }
            old?.finish()
            await streamer?.updateCaptureSize(width: size.width, height: size.height)
        }
        onQualityChange?(rung)
    }

    /// Turns the sound on or off without touching the picture.
    public func setSendAudio(_ on: Bool) {
        sendAudio.withLock { $0 = on }
    }

    /// Moves the extra desktop to the other side of the real one, live.
    public func setExtendedSide(_ side: ExtendedSide) {
        guard case .extendedDisplay = source else { return }
        streamer?.repositionVirtualDisplay(on: side, quality: quality)
    }

    /// Asks the receiver to hold frames for a different time, riding on the
    /// next frame. Honored in practice — field-tested: the felt lag tracks
    /// this — but the receiver's *reported* delay keeps echoing the OFFER's
    /// original target, so never treat that report as confirmation.
    public func setPlayoutDelay(ms: Int) {
        playoutDelayMs = ms
        sender?.setPlayoutDelay(ms: ms)
    }

    public func stats() -> CastStreamSender.Stats? { sender?.currentStats() }
    public func audioStats() -> CastStreamSender.Stats? { audioSender?.currentStats() }

    public func stop() async {
        monitorTask?.cancel()
        monitorTask = nil
        await streamer?.stop()
        streamer = nil
        let encoder = activeEncoder.withLock { current -> RealtimeH264Encoder? in
            let before = current
            current = nil
            return before
        }
        encoder?.finish()
        audioEncoder = nil
        sender?.stop()
        sender = nil
        audioSender?.stop()
        audioSender = nil
        transport?.stop()
        transport = nil
        await session?.close()
        session = nil
    }

    /// The answer arrives on the Cast session's own callback queue.
    private final class AnswerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CastStreaming.Answer?
        var value: CastStreaming.Answer? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
        func set(_ answer: CastStreaming.Answer) {
            lock.lock(); stored = answer; lock.unlock()
        }
    }
}
