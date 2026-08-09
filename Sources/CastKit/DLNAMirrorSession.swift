import Foundation
import DiskScanKit

/// Screen mirroring for DLNA-only sets: capture → H.264/AAC → hand-rolled
/// MPEG-TS, served over the local HTTP server as `video/mpeg`. No adaptive
/// ladder here — DLNA has no return channel to hear congestion on — so the
/// stream runs at the chosen level's box and bitrate, fixed.
public final class DLNAMirrorSession: @unchecked Sendable {
    private let server: CastHTTPServer
    private let quality: MirrorQuality
    private let frameRate: Int
    private let includeAudio: Bool
    private let source: MirrorSource
    private let extendedSide: ExtendedSide
    private let bitrate: Int

    private let streamer = ScreenStreamer()
    private let muxer = MPEGTSMuxer()
    private let encoder = Locked<RealtimeH264Encoder?>(nil)
    private var audioEncoder: AACAudioEncoder?
    /// TS is stateless enough to join mid-stream: a new viewer just needs
    /// tables and an IDR, both of which a key-frame request produces.
    private let subscribers = Locked<[CastHTTPServer.StreamWriter]>([])
    private let produced = Locked(false)

    public var onStopped: (@Sendable (String?) -> Void)?

    public static let path = "/mirror/live.ts"

    public init(
        server: CastHTTPServer, quality: MirrorQuality,
        frameRate: Int = 30, includeAudio: Bool,
        source: MirrorSource, extendedSide: ExtendedSide,
        maxBitrate: Int = .max
    ) {
        self.server = server
        self.quality = quality
        self.frameRate = frameRate
        self.includeAudio = includeAudio
        self.source = source
        self.extendedSide = extendedSide
        self.bitrate = min(quality.bitrate, maxBitrate)
    }

    /// Registers the route, starts capture, and resolves once the muxer has
    /// produced its first packets — never hand the TV a URL that would read
    /// zero bytes. Returns the route path.
    public func start() async throws -> String {
        let size = try await ScreenStreamer.captureSize(for: quality, source: source)
        let fresh = try RealtimeH264Encoder(
            width: size.width, height: size.height,
            bitrate: bitrate, frameRate: frameRate
        )
        encoder.withLock { $0 = fresh }

        let muxer = self.muxer
        let subscribers = self.subscribers
        let produced = self.produced
        fresh.onSample = { sample in
            muxer.appendVideo(
                annexB: sample.annexB,
                hostSeconds: sample.presentationTime.seconds,
                isKeyFrame: sample.isKeyFrame
            )
        }
        if includeAudio {
            let aac = AACAudioEncoder()
            aac.onPacket = { packet in
                muxer.appendAudio(adts: packet.adts, hostSeconds: packet.captureHostSeconds)
            }
            audioEncoder = aac
            streamer.onAudioSample = { [weak aac] buffer in aac?.encode(buffer) }
        }
        muxer.onPackets = { data in
            produced.withLock { $0 = true }
            // Fan out; a writer whose backlog cap tripped reports false and
            // is dropped — no buffering a link too slow for live video.
            subscribers.withLock { writers in
                writers.removeAll { !$0.write(data) }
            }
        }
        let encoderBox = self.encoder
        server.setStreamRoute(Self.path) { writer in
            subscribers.withLock { $0.append(writer) }
            // The joiner needs tables and an IDR to start decoding.
            encoderBox.withLock { $0 }?.requestKeyFrame()
        }

        let box = self.encoder
        streamer.onVideoSample = { buffer in
            box.withLock { $0 }?.encode(buffer)
        }
        streamer.onStopped = { [weak self] message in self?.onStopped?(message) }
        try await streamer.start(
            quality: quality, includeAudio: includeAudio, frameRate: frameRate,
            source: source, extendedSide: extendedSide
        )

        // Wait for real output, bounded — a wedged encoder must surface as
        // an error, not as a TV spinning on an empty stream.
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if produced.withLock({ $0 }) { return Self.path }
            try? await Task.sleep(for: .milliseconds(100))
        }
        await stop()
        throw NSError(domain: "CastKit", code: 14, userInfo: [
            NSLocalizedDescriptionKey: String(
                localized: "The screen encoder didn't produce video. Try again."
            ),
        ])
    }

    public func stop() async {
        await streamer.stop()
        let old = encoder.withLock { current -> RealtimeH264Encoder? in
            let before = current
            current = nil
            return before
        }
        old?.finish()
        audioEncoder = nil
        muxer.onPackets = nil
        subscribers.withLock { writers in
            for writer in writers { writer.finish() }
            writers.removeAll()
        }
    }
}
