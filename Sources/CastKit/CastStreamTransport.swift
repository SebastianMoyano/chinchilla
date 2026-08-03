import Foundation
import Network

/// One UDP socket for the whole streaming session.
///
/// Audio and video are separate RTP streams but they share a single socket,
/// told apart by SSRC — that's what the receiver expects, and it replies to
/// the one source address it sees. Giving each stream its own socket means
/// only one of them ever hears back.
public final class CastStreamTransport: @unchecked Sendable {
    private let connection: NWConnection
    let queue = DispatchQueue(label: "cast.stream.transport")
    private let lock = NSLock()
    private var handlers: [UInt32: @Sendable (CastRTP.Feedback) -> Void] = [:]

    public var onLog: (@Sendable (String) -> Void)?

    public init?(host: String, port: Int) {
        guard let port = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0) else { return nil }
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .udp)
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.onLog?("RTP connection failed: \(error)")
            }
        }
        connection.start(queue: queue)
        receive()
    }

    public func stop() {
        lock.lock(); handlers.removeAll(); lock.unlock()
        connection.cancel()
    }

    public func send(_ data: Data) {
        connection.send(content: data, completion: .idempotent)
    }

    func register(ssrc: UInt32, handler: @escaping @Sendable (CastRTP.Feedback) -> Void) {
        lock.lock(); handlers[ssrc] = handler; lock.unlock()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let feedback = CastRTP.parseFeedback(data)
                self.lock.lock()
                // Feedback names the stream it is about. Without a match,
                // hand it to every stream rather than dropping it — some
                // receivers don't fill the field in.
                let targets: [@Sendable (CastRTP.Feedback) -> Void] =
                    if let ssrc = feedback.targetSSRC, let handler = self.handlers[ssrc] {
                        [handler]
                    } else if feedback.targetSSRC == nil {
                        Array(self.handlers.values)
                    } else {
                        []
                    }
                self.lock.unlock()
                for handler in targets { handler(feedback) }
            }
            if error == nil { self.receive() }
        }
    }
}
