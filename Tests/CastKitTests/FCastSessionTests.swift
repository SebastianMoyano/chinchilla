import Foundation
import Network
import Testing
@testable import CastKit

/// Scripted fake FCast receiver on loopback.
private final class FakeReceiver: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "fake.receiver")
    var codec = FCastFrameCodec()
    var received: [UInt8] = []
    var connection: NWConnection?

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connection = connection
            connection.start(queue: self.queue)
            self.receive(connection)
        }
        listener.start(queue: queue)
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self, error == nil, !done else { return }
            if let data, let frames = self.codec.append(data) {
                for frame in frames {
                    self.received.append(frame.opcode)
                    switch FCastOpcode(rawValue: frame.opcode) {
                    case .version:
                        // Reply version, then push a playback update.
                        connection.send(
                            content: FCastFrameCodec.encode(opcode: .version, message: FCastVersionMessage(version: 2))!,
                            completion: .contentProcessed { _ in }
                        )
                        let update = FCastFrameCodec.encode(
                            opcode: .playbackUpdate,
                            body: Data(#"{"state":1,"time":3.5,"duration":10}"#.utf8)
                        )
                        connection.send(content: update, completion: .contentProcessed { _ in })
                    case .ping:
                        connection.send(
                            content: FCastFrameCodec.encode(opcode: .pong),
                            completion: .contentProcessed { _ in }
                        )
                    default:
                        break
                    }
                }
            }
            self.receive(connection)
        }
    }
}

@Test(.timeLimit(.minutes(1))) func sessionHandshakeAndPlayback() async throws {
    let receiver = try FakeReceiver()
    try await Task.sleep(for: .milliseconds(200))
    #expect(receiver.port > 0)

    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: receiver.port)!)
    let session = FCastSession(endpoint: endpoint)
    let events = await session.events
    await session.connect()

    var sawReady = false
    var sawPlayback = false
    for await event in events {
        switch event {
        case .state(.ready):
            sawReady = true
            await session.play(FCastPlayMessage(container: "video/mp4", url: "http://example/x.mp4"))
        case .playback(let update):
            sawPlayback = true
            #expect(update.state == 1)
            #expect(update.duration == 10)
            await session.close()
        case .state(.closed):
            // Exit the loop.
            #expect(sawReady)
        default:
            break
        }
        if sawPlayback { break }
    }
    #expect(sawReady && sawPlayback)
    try await Task.sleep(for: .milliseconds(200))
    #expect(receiver.received.contains(FCastOpcode.version.rawValue))
    #expect(receiver.received.contains(FCastOpcode.play.rawValue))
}
