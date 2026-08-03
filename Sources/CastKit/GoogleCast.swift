import Foundation
import Network
import Security

/// Google Cast v2 (Chromecast built-in) — the protocol most Android TVs
/// already speak, so nothing has to be installed on the TV.
/// Transport: TLS on port 8009, 4-byte big-endian length prefix + a
/// protobuf CastMessage whose payload is JSON.
public struct GoogleCastDevice: Sendable, Identifiable, Hashable {
    public let name: String
    public let host: String
    public let port: UInt16

    public var id: String { "\(host):\(port)" }

    public init(name: String, host: String, port: UInt16 = 8009) {
        self.name = name
        self.host = host
        self.port = port
    }
}

// MARK: - Minimal protobuf for CastMessage

enum CastProto {
    /// CastMessage fields: 1 protocol_version (varint), 2 source_id,
    /// 3 destination_id, 4 namespace, 5 payload_type (varint), 6 payload_utf8.
    static func encode(source: String, destination: String, namespace: String, payload: String) -> Data {
        var data = Data()
        data.append(0x08); data.append(contentsOf: varint(0))        // protocol_version = CASTV2_1_0
        append(&data, field: 2, string: source)
        append(&data, field: 3, string: destination)
        append(&data, field: 4, string: namespace)
        data.append(0x28); data.append(contentsOf: varint(0))        // payload_type = STRING
        append(&data, field: 6, string: payload)
        return data
    }

    static func append(_ data: inout Data, field: Int, string: String) {
        let bytes = Data(string.utf8)
        data.append(contentsOf: varint(UInt64(field) << 3 | 2))
        data.append(contentsOf: varint(UInt64(bytes.count)))
        data.append(bytes)
    }

    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    /// Returns (namespace, payload) of a CastMessage.
    static func decode(_ data: Data) -> (namespace: String, payload: String)? {
        var index = data.startIndex
        var namespace = ""
        var payload = ""
        while index < data.endIndex {
            guard let (tag, next) = readVarint(data, from: index) else { return nil }
            index = next
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            if wire == 0 {
                guard let (_, after) = readVarint(data, from: index) else { return nil }
                index = after
            } else if wire == 2 {
                guard let (length, after) = readVarint(data, from: index) else { return nil }
                let end = data.index(after, offsetBy: Int(length), limitedBy: data.endIndex) ?? data.endIndex
                let value = String(decoding: data[after..<end], as: UTF8.self)
                if field == 4 { namespace = value }
                if field == 6 { payload = value }
                index = end
            } else {
                return nil  // unexpected wire type
            }
        }
        return (namespace, payload)
    }

    static func readVarint(_ data: Data, from start: Data.Index) -> (UInt64, Data.Index)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var index = start
        while index < data.endIndex {
            let byte = data[index]
            value |= UInt64(byte & 0x7F) << shift
            index = data.index(after: index)
            if byte & 0x80 == 0 { return (value, index) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    static func frame(_ message: Data) -> Data {
        var length = UInt32(message.count).bigEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(message)
        return framed
    }
}

// MARK: - Session

public enum GoogleCastEvent: Sendable {
    case state(FCastSessionState)
    case media(time: Double, duration: Double, playerState: String)
    case error(String)
}

public actor GoogleCastSession {
    /// Google's Default Media Receiver — plays mp4, HLS and DASH.
    static let defaultMediaAppID = "CC1AD845"
    static let namespaceConnection = "urn:x-cast:com.google.cast.tp.connection"
    static let namespaceHeartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
    static let namespaceReceiver = "urn:x-cast:com.google.cast.receiver"
    static let namespaceMedia = "urn:x-cast:com.google.cast.media"

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "cast.googlecast")
    private var buffer = Data()
    private var requestID = 1
    private var transportID: String?
    private var sessionID: String?
    private var mediaSessionID: Int?
    private var pendingLoad: (url: String, mime: String, title: String, live: Bool)?
    /// Which receiver app to launch: media player by default, or Cast
    /// Streaming for low-latency mirroring.
    private var appID = GoogleCastSession.defaultMediaAppID
    /// Extra namespace to listen on (Cast Streaming's OFFER/ANSWER).
    private var extraNamespace: String?
    private var onNamespaceMessage: (@Sendable (String, String) -> Void)?
    private var heartbeat: Task<Void, Never>?
    private var continuation: AsyncStream<GoogleCastEvent>.Continuation?

    public let events: AsyncStream<GoogleCastEvent>

    public init(device: GoogleCastDevice) {
        let tls = NWProtocolTLS.Options()
        // Chromecast devices present a self-signed certificate — validating
        // it against a CA is impossible by design; the link is still
        // encrypted and confined to the LAN.
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, complete in complete(true) },
            DispatchQueue(label: "cast.tls.verify")
        )
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(
            host: NWEndpoint.Host(device.host),
            port: NWEndpoint.Port(rawValue: device.port) ?? 8009,
            using: NWParameters(tls: tls, tcp: tcp)
        )
        var cont: AsyncStream<GoogleCastEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    public func connect() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleState(state) }
        }
        connection.start(queue: queue)
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            send(namespace: Self.namespaceConnection, to: "receiver-0", payload: #"{"type":"CONNECT"}"#)
            send(namespace: Self.namespaceReceiver, to: "receiver-0",
                 payload: #"{"type":"LAUNCH","appId":"\#(appID)","requestId":\#(nextRequestID())}"#)
            receiveLoop()
            startHeartbeat()
            continuation?.yield(.state(.ready))
        case .failed(let error):
            continuation?.yield(.error(String(describing: error)))
            continuation?.yield(.state(.closed))
        case .cancelled:
            continuation?.yield(.state(.closed))
        default:
            break
        }
    }

    private func nextRequestID() -> Int {
        requestID += 1
        return requestID
    }

    private func send(namespace: String, to destination: String, payload: String) {
        let message = CastProto.encode(
            source: "sender-0", destination: destination,
            namespace: namespace, payload: payload
        )
        connection.send(content: CastProto.frame(message), completion: .contentProcessed { _ in })
    }

    // MARK: Receiving

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { await self?.handleReceive(data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(_ data: Data?, isComplete: Bool, error: NWError?) {
        if let data { buffer.append(data) }
        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard buffer.count >= 4 + length else { break }
            let message = Data(buffer[(buffer.startIndex + 4)..<(buffer.startIndex + 4 + length)])
            buffer.removeFirst(4 + length)
            if let decoded = CastProto.decode(message) {
                handle(namespace: decoded.namespace, payload: decoded.payload)
            }
        }
        if isComplete || error != nil {
            continuation?.yield(.state(.closed))
            return
        }
        receiveLoop()
    }

    /// Diagnostics: see everything the receiver says.
    public var onAnyMessage: (@Sendable (String, String) -> Void)?

    private func handle(namespace: String, payload: String) {
        onAnyMessage?(namespace, payload)
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = json["type"] as? String ?? ""

        switch namespace {
        case Self.namespaceHeartbeat:
            if type == "PING" {
                send(namespace: Self.namespaceHeartbeat, to: "receiver-0", payload: #"{"type":"PONG"}"#)
            }
        case Self.namespaceReceiver:
            guard type == "RECEIVER_STATUS",
                  let status = json["status"] as? [String: Any],
                  let apps = status["applications"] as? [[String: Any]],
                  let app = apps.first(where: { ($0["appId"] as? String) == appID })
            else { return }
            let transport = app["transportId"] as? String
            let session = app["sessionId"] as? String
            if transport != transportID {
                transportID = transport
                sessionID = session
                // Open a virtual connection to the media app, then load.
                if let transport {
                    send(namespace: Self.namespaceConnection, to: transport, payload: #"{"type":"CONNECT"}"#)
                    if let pending = pendingLoad {
                        pendingLoad = nil
                        performLoad(pending)
                    }
                }
            }
        case Self.namespaceMedia:
            if type == "LOAD_FAILED" || type == "LOAD_CANCELLED" || type == "ERROR" || type == "INVALID_REQUEST" {
                let detail = (json["detailedErrorCode"] as? Int).map { " (code \($0))" } ?? ""
                let reason = (json["reason"] as? String).map { ": \($0)" } ?? ""
                continuation?.yield(.error("\(type)\(detail)\(reason)"))
                return
            }
            guard type == "MEDIA_STATUS",
                  let statuses = json["status"] as? [[String: Any]],
                  let status = statuses.first else { return }
            mediaSessionID = status["mediaSessionId"] as? Int
            let time = status["currentTime"] as? Double ?? 0
            var playerState = status["playerState"] as? String ?? ""
            if let idleReason = status["idleReason"] as? String {
                playerState += " (idleReason: \(idleReason))"
            }
            var duration: Double = 0
            if let media = status["media"] as? [String: Any] {
                duration = media["duration"] as? Double ?? 0
            }
            continuation?.yield(.media(time: time, duration: duration, playerState: playerState))
        default:
            if namespace == extraNamespace {
                onNamespaceMessage?(namespace, payload)
            }
        }
    }

    /// Switches this session to Cast Streaming: launches the mirroring
    /// receiver and routes its messages to `handler`.
    public func useStreamingApp(
        namespace: String, handler: @escaping @Sendable (String, String) -> Void
    ) {
        appID = CastStreaming.appID
        extraNamespace = namespace
        onNamespaceMessage = handler
    }

    /// Sends a raw payload on a custom namespace to the launched app.
    public func sendCustom(namespace: String, payload: String) {
        guard let transport = transportID else { return }
        send(namespace: namespace, to: transport, payload: payload)
    }

    public var isAppReady: Bool { transportID != nil }

    public func setOnAnyMessage(_ handler: @escaping @Sendable (String, String) -> Void) {
        onAnyMessage = handler
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.ping()
            }
        }
    }

    private func ping() {
        send(namespace: Self.namespaceHeartbeat, to: "receiver-0", payload: #"{"type":"PING"}"#)
    }

    // MARK: Commands

    public func load(url: String, mime: String, title: String, live: Bool = false) {
        let request = (url: url, mime: mime, title: title, live: live)
        guard transportID != nil else {
            // Receiver app still launching — load as soon as it's up.
            pendingLoad = request
            return
        }
        performLoad(request)
    }

    private func performLoad(_ request: (url: String, mime: String, title: String, live: Bool)) {
        guard let transport = transportID, let session = sessionID else { return }
        let metadata = """
        {"metadataType":0,"title":\(jsonString(request.title))}
        """
        // Cast receivers assume HLS carries MPEG-2 TS segments unless told
        // otherwise. Ours are fMP4/CMAF — without these hints the receiver
        // downloads every segment and renders a black screen.
        let hlsHints = request.mime.contains("mpegurl")
            ? ",\"hlsSegmentFormat\":\"FMP4\",\"hlsVideoSegmentFormat\":\"FMP4\""
            : ""
        let payload = """
        {"type":"LOAD","requestId":\(nextRequestID()),"sessionId":"\(session)",\
        "media":{"contentId":\(jsonString(request.url)),"streamType":"\(request.live ? "LIVE" : "BUFFERED")",\
        "contentType":"\(request.mime)","metadata":\(metadata)\(hlsHints)},"autoplay":true,"currentTime":0}
        """
        send(namespace: Self.namespaceMedia, to: transport, payload: payload)
    }

    private func mediaCommand(_ type: String, extra: String = "") {
        guard let transport = transportID, let media = mediaSessionID else { return }
        let payload = """
        {"type":"\(type)","requestId":\(nextRequestID()),"mediaSessionId":\(media)\(extra)}
        """
        send(namespace: Self.namespaceMedia, to: transport, payload: payload)
    }

    /// Asks the receiver for a full status report (it only pushes on
    /// changes, which hides "stuck buffering" states).
    public func requestStatus() {
        guard let transport = transportID else { return }
        send(namespace: Self.namespaceMedia, to: transport,
             payload: #"{"type":"GET_STATUS","requestId":\#(nextRequestID())}"#)
    }

    /// Nudges playback speed. A live stream that started a couple of
    /// seconds behind never catches up at 1×; running slightly fast for a
    /// few seconds walks the playhead to the live edge, then we go back.
    public func setPlaybackRate(_ rate: Double) {
        guard let transport = transportID else { return }
        send(namespace: Self.namespaceMedia, to: transport,
             payload: #"{"type":"SET_PLAYBACK_RATE","requestId":\#(nextRequestID()),"playbackRate":\#(rate)}"#)
    }

    public func play() { mediaCommand("PLAY") }
    public func pause() { mediaCommand("PAUSE") }
    public func stop() { mediaCommand("STOP") }
    public func seek(to time: Double) { mediaCommand("SEEK", extra: ",\"currentTime\":\(time)") }

    public func setVolume(_ volume: Double) {
        send(namespace: Self.namespaceReceiver, to: "receiver-0",
             payload: #"{"type":"SET_VOLUME","requestId":\#(nextRequestID()),"volume":{"level":\#(volume)}}"#)
    }

    public func close() {
        heartbeat?.cancel()
        if let transport = transportID {
            send(namespace: Self.namespaceConnection, to: transport, payload: #"{"type":"CLOSE"}"#)
        }
        send(namespace: Self.namespaceConnection, to: "receiver-0", payload: #"{"type":"CLOSE"}"#)
        connection.cancel()
        continuation?.yield(.state(.closed))
        continuation?.finish()
    }

    private func jsonString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
