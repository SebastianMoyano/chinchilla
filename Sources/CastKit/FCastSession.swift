import Foundation
import Network

public enum FCastSessionState: Sendable, Equatable {
    case connecting
    case ready
    case unreachable
    case closed
}

public enum FCastEvent: Sendable {
    case state(FCastSessionState)
    case playback(FCastPlaybackUpdateMessage)
    case volume(FCastVolumeUpdateMessage)
    case error(String)
}

/// One connection to one receiver. Network.framework is fully async, so
/// nothing here ever blocks the cooperative pool.
public actor FCastSession {
    private let connection: NWConnection
    private var codec = FCastFrameCodec()
    private var eventContinuation: AsyncStream<FCastEvent>.Continuation?
    private var keepaliveTask: Task<Void, Never>?
    private var lastTraffic = ContinuousClock.now
    public private(set) var state: FCastSessionState = .connecting

    public let events: AsyncStream<FCastEvent>

    public init(endpoint: NWEndpoint) {
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: options))
        var continuation: AsyncStream<FCastEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    public func connect() {
        connection.stateUpdateHandler = { [weak self] nwState in
            Task { await self?.handleConnectionState(nwState) }
        }
        connection.start(queue: DispatchQueue(label: "cast.session"))
    }

    private func handleConnectionState(_ nwState: NWConnection.State) {
        switch nwState {
        case .ready:
            setState(.ready)
            send(opcode: .version, message: FCastVersionMessage())
            receiveLoop()
            startKeepalive()
        case .failed, .cancelled:
            setState(.closed)
        case .waiting:
            setState(.unreachable)
        default:
            break
        }
    }

    private func setState(_ newState: FCastSessionState) {
        guard state != newState else { return }
        state = newState
        eventContinuation?.yield(.state(newState))
        if newState == .closed {
            keepaliveTask?.cancel()
            eventContinuation?.finish()
        }
    }

    // MARK: - Sending

    private func send(opcode: FCastOpcode, body: Data = Data()) {
        connection.send(
            content: FCastFrameCodec.encode(opcode: opcode, body: body),
            completion: .contentProcessed { _ in }
        )
    }

    private func send(opcode: FCastOpcode, message: some Encodable) {
        guard let framed = FCastFrameCodec.encode(opcode: opcode, message: message) else { return }
        connection.send(content: framed, completion: .contentProcessed { _ in })
    }

    public func play(_ message: FCastPlayMessage) { send(opcode: .play, message: message) }
    public func pause() { send(opcode: .pause) }
    public func resume() { send(opcode: .resume) }
    public func stop() { send(opcode: .stop) }
    public func seek(to time: Double) { send(opcode: .seek, message: FCastSeekMessage(time: time)) }
    public func setVolume(_ volume: Double) {
        send(opcode: .setVolume, message: FCastSetVolumeMessage(volume: volume))
    }

    public func close() {
        keepaliveTask?.cancel()
        connection.cancel()
        setState(.closed)
    }

    // MARK: - Receiving

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { await self?.handleReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty {
            lastTraffic = ContinuousClock.now
            guard let frames = codec.append(data) else {
                // Malformed stream — poison; tear down.
                close()
                return
            }
            for frame in frames { handle(frame) }
        }
        if isComplete || error != nil {
            setState(.closed)
            return
        }
        if state == .ready || state == .connecting {
            receiveLoop()
        }
    }

    private func handle(_ frame: FCastFrame) {
        let decoder = JSONDecoder()
        switch FCastOpcode(rawValue: frame.opcode) {
        case .playbackUpdate:
            if let update = try? decoder.decode(FCastPlaybackUpdateMessage.self, from: frame.body) {
                eventContinuation?.yield(.playback(update))
            }
        case .volumeUpdate:
            if let update = try? decoder.decode(FCastVolumeUpdateMessage.self, from: frame.body) {
                eventContinuation?.yield(.volume(update))
            }
        case .playbackError:
            let message = (try? decoder.decode(FCastPlaybackErrorMessage.self, from: frame.body))?.message
            eventContinuation?.yield(.error(message ?? "playback error"))
        case .ping:
            send(opcode: .pong)
        case .pong, .version:
            break  // traffic timestamp already updated
        default:
            break  // unknown opcodes: skip (forward compatibility)
        }
    }

    // MARK: - Keepalive (ping every 5 s; dead after 15 s of silence)

    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.keepaliveTick()
            }
        }
    }

    private func keepaliveTick() {
        guard state == .ready else { return }
        if ContinuousClock.now - lastTraffic > .seconds(15) {
            setState(.unreachable)
            close()
            return
        }
        send(opcode: .ping)
    }
}
