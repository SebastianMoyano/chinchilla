import Foundation

/// One encoded, already-encrypted frame ready to go on the wire.
public struct CastEncodedFrame: Sendable {
    public var frameID: UInt32
    /// Key frames reference themselves; delta frames reference their predecessor.
    public var referencedFrameID: UInt32
    /// 90 kHz for video, 48 kHz for Opus.
    public var rtpTimestamp: UInt32
    public var isKeyFrame: Bool
    public var payload: Data
    /// Non-zero asks the receiver to change its playout delay (Adaptive
    /// Latency extension), which is how we can push below the 400 ms default.
    public var newPlayoutDelayMs: Int

    public init(frameID: UInt32, referencedFrameID: UInt32, rtpTimestamp: UInt32,
                isKeyFrame: Bool, payload: Data, newPlayoutDelayMs: Int = 0) {
        self.frameID = frameID
        self.referencedFrameID = referencedFrameID
        self.rtpTimestamp = rtpTimestamp
        self.isKeyFrame = isKeyFrame
        self.payload = payload
        self.newPlayoutDelayMs = newPlayoutDelayMs
    }
}

/// Splits frames into Cast RTP packets.
///
/// The header is standard RTP (12 bytes) followed by Cast's own 7-byte
/// extension carrying the frame ID, this packet's index, the index of the
/// last packet in the frame, and the referenced frame ID — which is what
/// lets a receiver reassemble and know exactly what it is missing.
public struct CastRTPPacketizer: Sendable {
    /// Ethernet MTU minus IPv4 and UDP headers.
    public static let maxPacketSize = 1500 - 20 - 8
    static let baseHeaderSize = 19          // 12 RTP + 7 Cast
    static let adaptiveLatencySize = 4
    static let maxHeaderSize = baseHeaderSize + adaptiveLatencySize
    public static let maxPayloadSize = maxPacketSize - maxHeaderSize

    public let payloadType: UInt8
    public let ssrc: UInt32
    private var sequenceNumber: UInt16

    public init(payloadType: UInt8, ssrc: UInt32, initialSequenceNumber: UInt16 = 0) {
        self.payloadType = payloadType & 0x7F
        self.ssrc = ssrc
        self.sequenceNumber = initialSequenceNumber
    }

    public static func packetCount(payloadBytes: Int) -> Int {
        max(1, (payloadBytes + maxPayloadSize - 1) / maxPayloadSize)
    }

    public mutating func packets(for frame: CastEncodedFrame) -> [Data] {
        let total = Self.packetCount(payloadBytes: frame.payload.count)
        var result: [Data] = []
        result.reserveCapacity(total)

        for index in 0..<total {
            let isLast = index == total - 1
            let withLatency = index == 0 && frame.newPlayoutDelayMs > 0

            var packet = Data(capacity: Self.maxPacketSize)
            packet.append(0x80)                                     // V=2, no padding, no CSRC
            packet.append((isLast ? 0x80 : 0) | payloadType)        // marker = last packet of frame
            packet.appendBigEndian(sequenceNumber)
            sequenceNumber &+= 1
            packet.appendBigEndian(frame.rtpTimestamp)
            packet.appendBigEndian(ssrc)

            // Cast header.
            packet.append(
                (frame.isKeyFrame ? 0x80 : 0)
                | 0x40                                              // reference frame ID present
                | (withLatency ? 1 : 0)                             // one extension follows
            )
            packet.append(UInt8(truncatingIfNeeded: frame.frameID))
            packet.appendBigEndian(UInt16(index))
            packet.appendBigEndian(UInt16(total - 1))
            packet.append(UInt8(truncatingIfNeeded: frame.referencedFrameID))

            if withLatency {
                // Type 1 in the top 6 bits, then a 10-bit size of 2 bytes.
                let header = UInt16(CastRTP.adaptiveLatencyType) << 10 | 2
                packet.appendBigEndian(header)
                packet.appendBigEndian(UInt16(clamping: frame.newPlayoutDelayMs))
            }

            let start = index * Self.maxPayloadSize
            if start < frame.payload.count {
                let end = min(start + Self.maxPayloadSize, frame.payload.count)
                packet.append(frame.payload[frame.payload.startIndex.advanced(by: start)
                                            ..< frame.payload.startIndex.advanced(by: end)])
            }
            result.append(packet)
        }
        return result
    }
}

public enum CastRTP {
    static let adaptiveLatencyType: UInt8 = 1

    /// Seconds between the NTP epoch (1900) and the Unix epoch (1970).
    static let ntpEpochOffset: Double = 2_208_988_800

    public static func ntpTimestamp(_ date: Date = Date()) -> UInt64 {
        let seconds = date.timeIntervalSince1970 + ntpEpochOffset
        let whole = UInt64(seconds)
        let fraction = UInt64((seconds - Double(whole)) * 4_294_967_296)
        return (whole << 32) | (fraction & 0xFFFF_FFFF)
    }

    /// RTCP Sender Report — the receiver needs this to tie our RTP timestamps
    /// to a wall clock, which is how it decides when to show each frame.
    /// Without it there is no playout schedule and nothing renders.
    public static func senderReport(
        ssrc: UInt32, ntp: UInt64, rtpTimestamp: UInt32,
        packetCount: UInt32, octetCount: UInt32
    ) -> Data {
        var packet = Data(capacity: 28)
        packet.append(0x80)                    // V=2, padding=0, report count=0
        packet.append(200)                     // Sender Report
        packet.appendBigEndian(UInt16(6))      // length in 32-bit words minus one
        packet.appendBigEndian(ssrc)
        packet.appendBigEndian(ntp)
        packet.appendBigEndian(rtpTimestamp)
        packet.appendBigEndian(packetCount)
        packet.appendBigEndian(octetCount)
        return packet
    }

    /// What the receiver tells us back. We only act on the parts that change
    /// what the sender must do next.
    public struct Feedback: Sendable {
        /// The receiver lost enough that only a fresh key frame will recover it.
        public var wantsKeyFrame = false
        /// Checkpoint frame: everything up to and including this one has been
        /// fully received. Truncated to 8 bits by the protocol.
        public var ackFrameID: UInt8?
        /// The delay the receiver says it is currently applying, in ms.
        public var playoutDelayMs: Int?
        /// How many packet-loss reports rode along — non-zero means the
        /// network is dropping packets, not that decoding failed.
        public var lossFields = 0
        /// Exactly which packets to resend. The receiver's checkpoint cannot
        /// advance past a frame with a hole in it, so ignoring these stalls
        /// playback permanently.
        public var nacks: [Nack] = []

        public struct Nack: Sendable, Equatable {
            public let frameID: UInt8
            /// `0xFFFF` means the receiver has none of this frame's packets.
            public let packetID: UInt16
            /// Bit *n* set means packet `packetID + 1 + n` is missing too.
            public let bitVector: UInt8

            public var allPacketsLost: Bool { packetID == 0xFFFF }

            /// Every packet index this field asks for.
            public var packetIDs: [UInt16] {
                guard !allPacketsLost else { return [] }
                var ids = [packetID]
                for bit in 0..<8 where bitVector & (1 << UInt8(bit)) != 0 {
                    ids.append(packetID + UInt16(bit) + 1)
                }
                return ids
            }
        }
    }

    /// Walks a compound RTCP packet looking for a Picture Loss Indication or a
    /// Cast Feedback message. Unknown blocks are skipped by their length field.
    public static func parseFeedback(_ data: Data) -> Feedback {
        var feedback = Feedback()
        var offset = data.startIndex
        while data.index(offset, offsetBy: 4, limitedBy: data.endIndex) != nil {
            let first = data[offset]
            guard first & 0xC0 == 0x80 else { break }        // version 2
            let subtype = first & 0x1F
            let packetType = data[data.index(offset, offsetBy: 1)]
            let words = Int(data[data.index(offset, offsetBy: 2)]) << 8
                | Int(data[data.index(offset, offsetBy: 3)])
            let bodyLength = words * 4
            guard let bodyStart = data.index(offset, offsetBy: 4, limitedBy: data.endIndex),
                  let next = data.index(bodyStart, offsetBy: bodyLength, limitedBy: data.endIndex)
            else { break }

            // Both live under packet type 206 (payload-specific feedback);
            // the subtype is what tells them apart.
            if packetType == 206, subtype == 1 {
                feedback.wantsKeyFrame = true
            } else if packetType == 206, subtype == 15 {
                // Receiver SSRC, sender SSRC, "CAST", checkpoint frame ID,
                // loss-field count, then the delay the receiver is applying.
                if let cast = data.index(bodyStart, offsetBy: 8, limitedBy: data.endIndex),
                   data.index(cast, offsetBy: 8, limitedBy: data.endIndex) != nil,
                   data[cast] == 0x43, data[data.index(cast, offsetBy: 1)] == 0x41,
                   data[data.index(cast, offsetBy: 2)] == 0x53,
                   data[data.index(cast, offsetBy: 3)] == 0x54 {
                    feedback.ackFrameID = data[data.index(cast, offsetBy: 4)]
                    feedback.lossFields = Int(data[data.index(cast, offsetBy: 5)])
                    feedback.playoutDelayMs = Int(data[data.index(cast, offsetBy: 6)]) << 8
                        | Int(data[data.index(cast, offsetBy: 7)])

                    // Then `lossFields` four-byte records naming what to resend.
                    var field = data.index(cast, offsetBy: 8)
                    for _ in 0..<feedback.lossFields {
                        guard let end = data.index(field, offsetBy: 4, limitedBy: next),
                              end <= next else { break }
                        feedback.nacks.append(Feedback.Nack(
                            frameID: data[field],
                            packetID: UInt16(data[data.index(field, offsetBy: 1)]) << 8
                                | UInt16(data[data.index(field, offsetBy: 2)]),
                            bitVector: data[data.index(field, offsetBy: 3)]
                        ))
                        field = end
                    }
                }
            }
            offset = next
        }
        return feedback
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt64) {
        appendBigEndian(UInt32(truncatingIfNeeded: value >> 32))
        appendBigEndian(UInt32(truncatingIfNeeded: value))
    }
}
