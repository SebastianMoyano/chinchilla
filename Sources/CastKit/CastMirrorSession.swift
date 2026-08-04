import Foundation
import ScreenCaptureKit

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

    private var session: GoogleCastSession?
    private var transport: CastStreamTransport?
    private var sender: CastStreamSender?
    private var encoder: RealtimeH264Encoder?
    private var audioSender: CastStreamSender?
    private var audioEncoder: OpusAudioEncoder?
    private var streamer: ScreenStreamer?

    /// Called when the stream dies on its own.
    public var onStopped: (@Sendable (String?) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?

    public init(
        host: String, quality: MirrorQuality = .p720,
        frameRate: Int = 30, includeAudio: Bool = true,
        source: MirrorSource = .wholeScreen,
        extendedSide: ExtendedSide = .right,
        playoutDelayMs: Int = CastStreaming.defaultTargetDelayMs
    ) {
        self.host = host
        self.quality = quality
        self.frameRate = frameRate
        self.includeAudio = includeAudio
        self.source = source
        self.extendedSide = extendedSide
        self.playoutDelayMs = playoutDelayMs
    }

    public func start() async throws {
        guard let size = try? await ScreenStreamer.captureSize(
            for: quality, source: source
        ) else {
            throw Failure.noDisplay
        }

        // The offer has to describe what we will actually send.
        var offer = CastStreaming.Offer()
        offer.width = size.width
        offer.height = size.height
        offer.frameRate = frameRate
        offer.videoBitRate = quality.bitrate
        offer.includeAudio = includeAudio
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
            width: size.width, height: size.height,
            bitrate: sealed.videoBitRate, frameRate: frameRate
        )
        let sender = CastStreamSender(
            transport: transport, keys: sealed.videoKeys,
            ssrc: sealed.videoSSRC, payloadType: 101,
            initialPlayoutDelayMs: playoutDelayMs
        )
        sender.onLog = onLog
        sender.onKeyFrameRequest = { [weak encoder] in encoder?.requestKeyFrame() }
        sender.start()
        encoder.onSample = { [weak sender] sample in sender?.send(sample) }

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
        // Capture the encoders directly rather than reaching through `self`:
        // these fire on the capture queues, and `stop()` clears those
        // properties from another thread.
        streamer.onVideoSample = { [weak encoder] buffer in encoder?.encode(buffer) }
        if let audioEncoder {
            streamer.onAudioSample = { [weak audioEncoder] buffer in
                audioEncoder?.encode(buffer)
            }
        }
        streamer.onStopped = { [weak self] message in self?.onStopped?(message) }
        try await streamer.start(
            quality: quality, includeAudio: audioAccepted, frameRate: frameRate,
            source: source, extendedSide: extendedSide
        )

        self.encoder = encoder
        self.sender = sender
        self.streamer = streamer
    }

    /// Changes how long the receiver holds frames, live — it rides along on
    /// the next frame, so there's no need to renegotiate.
    public func setPlayoutDelay(ms: Int) {
        playoutDelayMs = ms
        sender?.setPlayoutDelay(ms: ms)
    }

    public func stats() -> CastStreamSender.Stats? { sender?.currentStats() }
    public func audioStats() -> CastStreamSender.Stats? { audioSender?.currentStats() }

    public func stop() async {
        await streamer?.stop()
        streamer = nil
        encoder?.finish()
        encoder = nil
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
