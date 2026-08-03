import Foundation
import Network
import CoreMedia

/// Sends encoded video to a Cast receiver over the UDP port it named in its
/// ANSWER: encrypt the frame, split it into Cast RTP packets, and keep a
/// Sender Report flowing so the receiver knows how our timestamps map to a
/// clock. Also listens for the receiver's feedback, which is how we learn it
/// needs a fresh key frame.
public final class CastStreamSender: @unchecked Sendable {
    public struct Stats: Sendable {
        public var framesSent = 0
        public var packetsSent = 0
        public var bytesSent = 0
        public var keyFrameRequests = 0
        /// RTCP coming back from the receiver. Silence here means the far end
        /// isn't acknowledging anything — the clearest sign it isn't decoding.
        public var reportsReceived = 0
        public var lastAckedFrameID: UInt8?
        /// What the receiver says it is actually holding frames for.
        public var receiverPlayoutDelayMs: Int?
        public var lossReports = 0
        public var packetsResent = 0
    }

    private let connection: NWConnection
    private let crypto: CastFrameCrypto
    private let queue = DispatchQueue(label: "cast.stream.rtp")
    private let lock = NSLock()

    private var packetizer: CastRTPPacketizer
    private let ssrc: UInt32
    private let timebase: Int32
    private var frameID: UInt32 = 0
    private var lastReferencedID: UInt32 = 0
    private var firstPresentationTime: CMTime?
    private var lastRTPTimestamp: UInt32 = 0
    private var stats = Stats()
    private var reportTimer: DispatchSourceTimer?
    private var pendingPlayoutDelayMs = 0

    /// Recently sent packets, keyed by the frame ID as it appears on the wire
    /// (8 bits). The receiver's checkpoint can't move past a frame with a
    /// hole in it, so it asks for the missing packets by number and we have to
    /// still have them. Half the ID space is plenty — anything older is long
    /// past its playout time anyway.
    private var recentPackets: [UInt8: [Data]] = [:]
    private static let retransmitHistory = 128

    /// Fires when the receiver asks for a key frame.
    public var onKeyFrameRequest: (@Sendable () -> Void)?
    public var onLog: (@Sendable (String) -> Void)?

    public init(
        host: String, port: Int, keys: CastStreaming.StreamKeys,
        ssrc: UInt32, payloadType: UInt8, timebase: Int32 = 90_000,
        initialPlayoutDelayMs: Int = 0
    ) {
        self.crypto = CastFrameCrypto(keys: keys)
        self.ssrc = ssrc
        self.timebase = timebase
        self.packetizer = CastRTPPacketizer(
            payloadType: payloadType, ssrc: ssrc,
            initialSequenceNumber: UInt16.random(in: 0...UInt16.max)
        )
        self.pendingPlayoutDelayMs = initialPlayoutDelayMs
        self.connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port))!,
            using: .udp
        )
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.onLog?("RTP connection failed: \(error)")
            }
        }
        connection.start(queue: queue)
        receiveFeedback()
        startSenderReports()
    }

    public func stop() {
        reportTimer?.cancel()
        reportTimer = nil
        connection.cancel()
    }

    public func currentStats() -> Stats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    /// Asks the receiver to change how long it holds frames before showing
    /// them. Lower is more responsive and less tolerant of a jittery network;
    /// it rides along on the next frame's first packet.
    public func setPlayoutDelay(ms: Int) {
        lock.lock()
        pendingPlayoutDelayMs = ms
        lock.unlock()
    }

    public func send(_ sample: RealtimeH264Encoder.EncodedSample) {
        lock.lock()
        if firstPresentationTime == nil { firstPresentationTime = sample.presentationTime }
        let base = firstPresentationTime ?? sample.presentationTime
        let elapsed = CMTimeSubtract(sample.presentationTime, base)
        let ticks = CMTimeConvertScale(
            elapsed, timescale: timebase, method: .roundHalfAwayFromZero
        ).value
        let rtpTimestamp = UInt32(truncatingIfNeeded: ticks)

        let id = frameID
        // A key frame stands on its own; a delta frame names the one before it.
        let referenced = sample.isKeyFrame ? id : lastReferencedID
        frameID &+= 1
        lastReferencedID = id
        lastRTPTimestamp = rtpTimestamp
        let delay = pendingPlayoutDelayMs
        pendingPlayoutDelayMs = 0
        lock.unlock()

        guard let encrypted = crypto.crypt(sample.annexB, frameID: id) else {
            onLog?("Frame \(id) couldn't be encrypted — dropped")
            return
        }

        let frame = CastEncodedFrame(
            frameID: id, referencedFrameID: referenced, rtpTimestamp: rtpTimestamp,
            isKeyFrame: sample.isKeyFrame, payload: encrypted, newPlayoutDelayMs: delay
        )

        lock.lock()
        let packets = packetizer.packets(for: frame)
        stats.framesSent += 1
        stats.packetsSent += packets.count
        stats.bytesSent += packets.reduce(0) { $0 + $1.count }
        let wireID = UInt8(truncatingIfNeeded: id)
        recentPackets[wireID] = packets
        // Drop the entry half a wrap behind, so IDs never alias.
        recentPackets[wireID &- UInt8(Self.retransmitHistory)] = nil
        lock.unlock()

        send(packets: packets)
    }

    /// A key frame is a few dozen packets; firing them back to back overruns
    /// the receiver's socket buffer, which is what shows up as "loss" on a
    /// LAN that isn't actually losing anything. Small bursts, small gaps.
    private func send(packets: [Data]) {
        let burst = 4
        for (index, packet) in packets.enumerated() {
            let group = index / burst
            if group == 0 {
                connection.send(content: packet, completion: .idempotent)
            } else {
                queue.asyncAfter(deadline: .now() + .milliseconds(group)) { [weak self] in
                    self?.connection.send(content: packet, completion: .idempotent)
                }
            }
        }
    }

    // MARK: RTCP

    private func startSenderReports() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.sendSenderReport() }
        timer.resume()
        reportTimer = timer
    }

    private func sendSenderReport() {
        lock.lock()
        let rtpTimestamp = lastRTPTimestamp
        let packets = UInt32(truncatingIfNeeded: stats.packetsSent)
        let octets = UInt32(truncatingIfNeeded: stats.bytesSent)
        lock.unlock()

        let report = CastRTP.senderReport(
            ssrc: ssrc, ntp: CastRTP.ntpTimestamp(), rtpTimestamp: rtpTimestamp,
            packetCount: packets, octetCount: octets
        )
        connection.send(content: report, completion: .idempotent)
    }

    /// Caller must hold the lock.
    private func packetsToResend(for nacks: [CastRTP.Feedback.Nack]) -> [Data] {
        guard !nacks.isEmpty else { return [] }
        var result: [Data] = []
        for nack in nacks {
            guard let packets = recentPackets[nack.frameID] else { continue }
            if nack.allPacketsLost {
                result.append(contentsOf: packets)
            } else {
                for id in nack.packetIDs where Int(id) < packets.count {
                    result.append(packets[Int(id)])
                }
            }
        }
        return result
    }

    private func receiveFeedback() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let feedback = CastRTP.parseFeedback(data)
                self.lock.lock()
                self.stats.reportsReceived += 1
                if let ack = feedback.ackFrameID { self.stats.lastAckedFrameID = ack }
                if let delay = feedback.playoutDelayMs { self.stats.receiverPlayoutDelayMs = delay }
                if feedback.lossFields > 0 { self.stats.lossReports += feedback.lossFields }
                if feedback.wantsKeyFrame { self.stats.keyFrameRequests += 1 }
                let isFirst = self.stats.reportsReceived == 1
                let resend = self.packetsToResend(for: feedback.nacks)
                self.stats.packetsResent += resend.count
                self.lock.unlock()

                for packet in resend {
                    self.connection.send(content: packet, completion: .idempotent)
                }
                if isFirst {
                    self.onLog?("first RTCP from the receiver (\(data.count) bytes) — " +
                                "it is talking back")
                }
                if feedback.wantsKeyFrame { self.onKeyFrameRequest?() }
            }
            if error == nil { self.receiveFeedback() }
        }
    }
}
