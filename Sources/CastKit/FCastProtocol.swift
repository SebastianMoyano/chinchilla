import Foundation

/// FCast protocol v2 (docs.fcast.org): TCP 46899, mDNS _fcast._tcp.
/// Frame = uint32 LE size (counts opcode + body) + uint8 opcode + UTF-8 JSON.
public enum FCastOpcode: UInt8, Sendable {
    case play = 1, pause = 2, resume = 3, stop = 4, seek = 5
    case playbackUpdate = 6, volumeUpdate = 7, setVolume = 8
    case playbackError = 9, setSpeed = 10, version = 11, ping = 12, pong = 13
}

public struct FCastPlayMessage: Codable, Sendable {
    public var container: String
    public var url: String?
    public var content: String?
    public var time: Double?
    public var speed: Double?
    public var headers: [String: String]?

    public init(container: String, url: String? = nil, content: String? = nil,
                time: Double? = nil, speed: Double? = nil, headers: [String: String]? = nil) {
        self.container = container
        self.url = url
        self.content = content
        self.time = time
        self.speed = speed
        self.headers = headers
    }
}

public struct FCastSeekMessage: Codable, Sendable {
    public var time: Double
    public init(time: Double) { self.time = time }
}

public struct FCastSetVolumeMessage: Codable, Sendable {
    public var volume: Double
    public init(volume: Double) { self.volume = volume }
}

/// Receiver implementations vary — every inbound field decodes leniently.
public struct FCastPlaybackUpdateMessage: Codable, Sendable {
    public var generationTime: Int64?
    public var time: Double?
    public var duration: Double?
    public var state: Int?      // 0 idle, 1 playing, 2 paused
    public var speed: Double?
}

public struct FCastVolumeUpdateMessage: Codable, Sendable {
    public var generationTime: Int64?
    public var volume: Double?
}

public struct FCastVersionMessage: Codable, Sendable {
    public var version: Int
    public init(version: Int = 2) { self.version = version }
}

public struct FCastPlaybackErrorMessage: Codable, Sendable {
    public var message: String?
}

public struct FCastFrame: Sendable {
    public let opcode: UInt8
    public let body: Data
}

/// Same 4-byte LE idiom as NativeMessagingCodec, plus an INCREMENTAL
/// decoder: NWConnection delivers arbitrary chunks, so frames must be
/// reassembled from a rolling buffer.
public struct FCastFrameCodec: Sendable {
    /// Spec limit: bodies above 32,000 bytes are invalid.
    public static let maxBodySize = 32_000

    private var buffer = Data()

    public init() {}

    public static func encode(opcode: FCastOpcode, body: Data = Data()) -> Data {
        var size = UInt32(1 + body.count).littleEndian
        var framed = Data(bytes: &size, count: 4)
        framed.append(opcode.rawValue)
        framed.append(body)
        return framed
    }

    public static func encode(opcode: FCastOpcode, message: some Encodable) -> Data? {
        guard let body = try? JSONEncoder().encode(message), body.count <= maxBodySize else {
            return nil
        }
        return encode(opcode: opcode, body: body)
    }

    /// Feed received bytes; returns every complete frame now available.
    /// Oversized or malformed frames poison the connection — the caller
    /// should tear it down (returns nil).
    public mutating func append(_ data: Data) -> [FCastFrame]? {
        buffer.append(data)
        var frames: [FCastFrame] = []
        while buffer.count >= 4 {
            let size = buffer.prefix(4).withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
            }
            guard size >= 1, Int(size) - 1 <= Self.maxBodySize else { return nil }
            let total = 4 + Int(size)
            guard buffer.count >= total else { break }
            let opcode = buffer[buffer.startIndex + 4]
            let body = Data(buffer[(buffer.startIndex + 5)..<(buffer.startIndex + total)])
            frames.append(FCastFrame(opcode: opcode, body: body))
            buffer.removeFirst(total)
        }
        return frames
    }
}
