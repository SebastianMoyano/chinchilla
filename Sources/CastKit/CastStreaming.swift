import Foundation
import Security

/// Cast Streaming — the protocol Chrome itself uses for "Cast desktop".
/// It lives on every Cast device, needs nothing installed and no developer
/// registration, and its default target playout delay is 400 ms (versus the
/// ~2.5 s floor of the Default Media Receiver).
///
/// Handshake: launch app 0F5096E8, then exchange OFFER/ANSWER as JSON over
/// the `urn:x-cast:com.google.cast.webrtc` namespace on the existing Cast
/// channel. Media then flows as AES-128-CTR encrypted RTP over UDP to the
/// port the receiver names in its ANSWER.
public enum CastStreaming {
    public static let appID = "0F5096E8"
    public static let namespace = "urn:x-cast:com.google.cast.webrtc"

    /// Reference default from Open Screen (`kDefaultTargetPlayoutDelay`);
    /// the receiver accepts anything in 0…5000 ms.
    public static let defaultTargetDelayMs = 400

    public struct StreamKeys: Sendable {
        public let aesKey: Data
        public let aesIvMask: Data

        public init() {
            aesKey = Self.random(16)
            aesIvMask = Self.random(16)
        }

        static func random(_ count: Int) -> Data {
            var bytes = Data(count: count)
            _ = bytes.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
            }
            return bytes
        }

        var keyHex: String { aesKey.map { String(format: "%02x", $0) }.joined() }
        var ivHex: String { aesIvMask.map { String(format: "%02x", $0) }.joined() }
    }

    public struct Offer: Sendable {
        // Cast reads priority from the SSRC: lower wins, and audio should
        // beat video when the network is tight. They also have to stay clear
        // of each other, because the receiver takes `ssrc + 1` for itself —
        // adjacent values collide and the receiver silently drops a stream.
        public var audioSSRC: UInt32 = 1_001
        public var videoSSRC: UInt32 = 51_001
        public var width: Int = 1920
        public var height: Int = 1080
        public var frameRate: Int = 30
        public var videoBitRate: Int = 8_000_000
        public var targetDelayMs: Int = CastStreaming.defaultTargetDelayMs
        public var includeAudio: Bool = true
        public let videoKeys = StreamKeys()
        public let audioKeys = StreamKeys()

        public init() {}

        /// Video is stream index 0, audio index 1 — the ANSWER refers back
        /// to these via `sendIndexes`.
        public func json(sequenceNumber: Int) -> String {
            var streams: [String] = []
            streams.append("""
            {"index":0,"type":"video_source","codecName":"h264","rtpProfile":"cast",\
            "rtpPayloadType":101,"ssrc":\(videoSSRC),"maxFrameRate":"\(frameRate)000/1000",\
            "timeBase":"1/90000","maxBitRate":\(videoBitRate),"profile":"main","level":"4",\
            "targetDelay":\(targetDelayMs),"aesKey":"\(videoKeys.keyHex)",\
            "aesIvMask":"\(videoKeys.ivHex)",\
            "resolutions":[{"width":\(width),"height":\(height)}]}
            """)
            if includeAudio {
                streams.append("""
                {"index":1,"type":"audio_source","codecName":"opus","rtpProfile":"cast",\
                "rtpPayloadType":96,"ssrc":\(audioSSRC),"bitRate":128000,\
                "timeBase":"1/48000","channels":2,"targetDelay":\(targetDelayMs),\
                "aesKey":"\(audioKeys.keyHex)","aesIvMask":"\(audioKeys.ivHex)"}
                """)
            }
            return """
            {"type":"OFFER","seqNum":\(sequenceNumber),\
            "offer":{"castMode":"mirroring","supportedStreams":[\(streams.joined(separator: ","))]}}
            """
        }
    }

    /// What the receiver sends back: the UDP port to stream to, which of our
    /// offered streams it accepted, and its own SSRCs.
    public struct Answer: Sendable {
        public let udpPort: Int
        public let sendIndexes: [Int]
        public let ssrcs: [UInt32]

        public init?(json: [String: Any]) {
            guard let answer = json["answer"] as? [String: Any],
                  let port = answer["udpPort"] as? Int else { return nil }
            udpPort = port
            sendIndexes = answer["sendIndexes"] as? [Int] ?? []
            ssrcs = (answer["ssrcs"] as? [Int] ?? []).map { UInt32(truncatingIfNeeded: $0) }
        }

        public var acceptedVideo: Bool { sendIndexes.contains(0) }
        public var acceptedAudio: Bool { sendIndexes.contains(1) }
    }
}
