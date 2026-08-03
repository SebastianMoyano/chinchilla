import Foundation
import Testing
@testable import CastKit

private let sampleKey = Data((0..<16).map { UInt8($0) })
private let zeroMask = Data(repeating: 0, count: 16)

@Suite("Cast frame encryption")
struct CastFrameCryptoTests {
    @Test("The nonce carries the frame ID big-endian at offset 8")
    func nonceLayout() {
        let crypto = CastFrameCrypto(key: sampleKey, ivMask: zeroMask)
        #expect([UInt8](crypto.nonce(frameID: 0x0102_0304))
                == [0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 0, 0, 0, 0])
    }

    @Test("The nonce is XORed with the session IV mask")
    func nonceMask() {
        let crypto = CastFrameCrypto(key: sampleKey, ivMask: Data(repeating: 0xFF, count: 16))
        #expect([UInt8](crypto.nonce(frameID: 0x0102_0304))
                == [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                    0xFE, 0xFD, 0xFC, 0xFB, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    /// Golden vector produced independently with `openssl enc -aes-128-ctr`,
    /// so a mistake in our CTR plumbing can't hide behind a round trip.
    @Test("Matches a reference AES-128-CTR vector")
    func referenceVector() throws {
        let crypto = CastFrameCrypto(key: sampleKey, ivMask: zeroMask)
        let cipher = try #require(
            crypto.crypt(Data("Chinchilla Cast Streaming test!!".utf8), frameID: 0x0102_0304)
        )
        #expect(cipher.map { String(format: "%02x", $0) }.joined()
                == "4ed0e96e34a067869a0b3ef59e9cd81904c953bd0dd819d628fec9792666887e")
    }

    @Test("Decrypts back, and only with the same frame ID")
    func roundTrip() throws {
        let crypto = CastFrameCrypto(key: sampleKey, ivMask: Data((16..<32).map { UInt8($0) }))
        let plaintext = Data((0..<5000).map { UInt8($0 % 251) })
        let cipher = try #require(crypto.crypt(plaintext, frameID: 42))
        #expect(crypto.crypt(cipher, frameID: 42) == plaintext)
        // Frames must decrypt independently — that's why the nonce is keyed
        // on the frame ID, and why a wrong ID has to produce garbage.
        #expect(crypto.crypt(cipher, frameID: 43) != plaintext)
    }
}

private func testFrame(
    payloadBytes: Int, isKey: Bool = true, delayMs: Int = 0, id: UInt32 = 7
) -> CastEncodedFrame {
    CastEncodedFrame(
        frameID: id, referencedFrameID: isKey ? id : id - 1,
        rtpTimestamp: 987, isKeyFrame: isKey,
        payload: Data((0..<payloadBytes).map { UInt8($0 % 256) }),
        newPlayoutDelayMs: delayMs
    )
}

@Suite("Cast RTP packetization")
struct CastRTPPacketizerTests {
    @Test("Payload size matches the reference implementation")
    func sizes() {
        // 1500 MTU − 20 IPv4 − 8 UDP, then − 23 bytes of maximum header.
        #expect(CastRTPPacketizer.maxPacketSize == 1472)
        #expect(CastRTPPacketizer.maxPayloadSize == 1449)
    }

    @Test("Header fields of a single key-frame packet")
    func keyFrameHeader() throws {
        var packetizer = CastRTPPacketizer(
            payloadType: 101, ssrc: 0x0123_4567, initialSequenceNumber: 100
        )
        let packets = packetizer.packets(for: testFrame(payloadBytes: 10))
        #expect(packets.count == 1)
        let bytes = [UInt8](try #require(packets.first))

        #expect(bytes[0] == 0x80)                                  // version 2, no padding
        #expect(bytes[1] == 0x80 | 101)                            // marker: last packet
        #expect(Int(bytes[2]) << 8 | Int(bytes[3]) == 100)         // sequence number
        #expect(Array(bytes[4...7]) == [0, 0, 0x03, 0xDB])         // rtp timestamp 987
        #expect(Array(bytes[8...11]) == [0x01, 0x23, 0x45, 0x67])  // ssrc
        #expect(bytes[12] == 0xC0)                                 // key frame + reference present
        #expect(bytes[13] == 7)                                    // frame ID
        #expect(Int(bytes[14]) << 8 | Int(bytes[15]) == 0)         // packet ID
        #expect(Int(bytes[16]) << 8 | Int(bytes[17]) == 0)         // max packet ID
        #expect(bytes[18] == 7)                                    // referenced frame ID
        #expect(bytes.count == 19 + 10)
    }

    @Test("A delta frame clears the key-frame bit and points at its predecessor")
    func deltaFrame() throws {
        var packetizer = CastRTPPacketizer(payloadType: 101, ssrc: 1)
        let bytes = [UInt8](try #require(
            packetizer.packets(for: testFrame(payloadBytes: 4, isKey: false, id: 9)).first
        ))
        #expect(bytes[12] == 0x40)
        #expect(bytes[13] == 9)
        #expect(bytes[18] == 8)
    }

    @Test("Large frames split, and only the last packet is marked")
    func splitting() {
        var packetizer = CastRTPPacketizer(payloadType: 101, ssrc: 1, initialSequenceNumber: 0)
        let size = CastRTPPacketizer.maxPayloadSize * 2 + 100
        let packets = packetizer.packets(for: testFrame(payloadBytes: size))
        #expect(packets.count == 3)

        for (index, packet) in packets.enumerated() {
            let bytes = [UInt8](packet)
            let isLast = index == packets.count - 1
            #expect(bytes[1] & 0x80 == (isLast ? 0x80 : 0))
            #expect(Int(bytes[2]) << 8 | Int(bytes[3]) == index)   // sequence increments
            #expect(Int(bytes[14]) << 8 | Int(bytes[15]) == index) // packet ID
            #expect(Int(bytes[16]) << 8 | Int(bytes[17]) == 2)     // max packet ID
        }

        // Every payload byte is carried exactly once, in order.
        let reassembled = packets.map { $0.dropFirst(19) }.reduce(Data(), +)
        #expect(reassembled.count == size)
        #expect([UInt8](reassembled) == (0..<size).map { UInt8($0 % 256) })
    }

    @Test("The adaptive-latency extension rides on the first packet only")
    func adaptiveLatency() {
        var packetizer = CastRTPPacketizer(payloadType: 101, ssrc: 1)
        let size = CastRTPPacketizer.maxPayloadSize + 10
        let packets = packetizer.packets(for: testFrame(payloadBytes: size, delayMs: 120))
        #expect(packets.count == 2)

        let first = [UInt8](packets[0])
        #expect(first[12] & 0x3F == 1)                             // one extension announced
        // Type 1 in the upper 6 bits, data size 2 in the lower 10.
        #expect(Int(first[19]) << 8 | Int(first[20]) == (1 << 10) | 2)
        #expect(Int(first[21]) << 8 | Int(first[22]) == 120)
        #expect([UInt8](packets[1])[12] & 0x3F == 0)
    }

    @Test("An empty payload still produces one packet")
    func emptyPayload() {
        var packetizer = CastRTPPacketizer(payloadType: 96, ssrc: 1)
        #expect(packetizer.packets(for: testFrame(payloadBytes: 0)).count == 1)
    }
}

@Suite("Cast RTCP")
struct CastRTCPTests {
    @Test("Sender report layout")
    func senderReport() {
        let bytes = [UInt8](CastRTP.senderReport(
            ssrc: 0x0123_4567, ntp: 0x1122_3344_5566_7788,
            rtpTimestamp: 90_000, packetCount: 5, octetCount: 1234
        ))
        #expect(bytes.count == 28)
        #expect(bytes[0] == 0x80)
        #expect(bytes[1] == 200)                                   // sender report
        #expect(Int(bytes[2]) << 8 | Int(bytes[3]) == 6)           // words minus one
        #expect(Array(bytes[4...7]) == [0x01, 0x23, 0x45, 0x67])
        #expect(Array(bytes[8...15]) == [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
        #expect(Array(bytes[16...19]) == [0, 0x01, 0x5F, 0x90])    // rtp timestamp 90000
        #expect(Array(bytes[20...23]) == [0, 0, 0, 5])
        #expect(Array(bytes[24...27]) == [0, 0, 0x04, 0xD2])       // 1234 octets
    }

    @Test("NTP timestamps sit in the NTP epoch, not the Unix one")
    func ntpEpoch() {
        let stamp = CastRTP.ntpTimestamp(Date(timeIntervalSince1970: 1_785_628_800))
        #expect(stamp >> 32 == 1_785_628_800 + 2_208_988_800)
    }

    @Test("A picture-loss indication reads as a key-frame request")
    func pictureLoss() {
        var packet = Data([0x81, 206, 0x00, 0x02])     // v2, subtype 1, PSFB, 2 words
        packet.appendBigEndian(UInt32(0xAAAA_AAAA))    // receiver SSRC
        packet.appendBigEndian(UInt32(0xBBBB_BBBB))    // sender SSRC
        #expect(CastRTP.parseFeedback(packet).wantsKeyFrame)
    }

    @Test("Unrelated reports are skipped without losing what follows")
    func compoundPacket() {
        var packet = Data([0x80, 201, 0x00, 0x01])     // receiver report
        packet.appendBigEndian(UInt32(0xAAAA_AAAA))
        packet.append(contentsOf: [0x81, 206, 0x00, 0x02])
        packet.appendBigEndian(UInt32(0xAAAA_AAAA))
        packet.appendBigEndian(UInt32(0xBBBB_BBBB))
        #expect(CastRTP.parseFeedback(packet).wantsKeyFrame)
    }

    @Test("Feedback names the stream it is about, so audio and video can share a socket")
    func targetSSRC() {
        var packet = Data([0x8F, 206, 0x00, 0x04])
        packet.appendBigEndian(UInt32(0xAAAA_AAAA))     // receiver's own SSRC
        packet.appendBigEndian(UInt32(51_001))          // ours — the video stream
        packet.append(contentsOf: Array("CAST".utf8))
        packet.append(contentsOf: [200, 0, 0x01, 0x90])
        #expect(CastRTP.parseFeedback(packet).targetSSRC == 51_001)
    }

    @Test("Cast feedback yields the checkpoint frame and the receiver's delay")
    func castFeedback() {
        // Type 206 subtype 15, body: receiver SSRC, sender SSRC, 'CAST',
        // checkpoint frame 200, 0 loss fields, 400 ms of playout delay.
        var packet = Data([0x8F, 206, 0x00, 0x04])
        packet.appendBigEndian(UInt32(0xAAAA_AAAA))
        packet.appendBigEndian(UInt32(0xBBBB_BBBB))
        packet.append(contentsOf: Array("CAST".utf8))
        packet.append(200)
        packet.append(0)
        packet.appendBigEndian(UInt16(400))

        let feedback = CastRTP.parseFeedback(packet)
        #expect(feedback.ackFrameID == 200)
        #expect(feedback.playoutDelayMs == 400)
        #expect(feedback.lossFields == 0)
        #expect(!feedback.wantsKeyFrame)
    }

    @Test("Loss fields name exactly which packets to resend")
    func nackParsing() {
        var packet = Data([0x8F, 206, 0x00, 0x06])
        packet.appendBigEndian(UInt32(0xAAAA_AAAA))
        packet.appendBigEndian(UInt32(0xBBBB_BBBB))
        packet.append(contentsOf: Array("CAST".utf8))
        packet.append(10)                                   // checkpoint frame
        packet.append(2)                                    // two loss fields
        packet.appendBigEndian(UInt16(400))
        // Frame 11: packet 3 missing, and via the bit vector 4 and 6 too.
        packet.append(contentsOf: [11, 0x00, 0x03, 0b0000_0101])
        // Frame 12: nothing arrived at all.
        packet.append(contentsOf: [12, 0xFF, 0xFF, 0x00])

        let feedback = CastRTP.parseFeedback(packet)
        #expect(feedback.nacks.count == 2)
        #expect(feedback.nacks[0].frameID == 11)
        #expect(feedback.nacks[0].packetIDs == [3, 4, 6])
        #expect(!feedback.nacks[0].allPacketsLost)
        #expect(feedback.nacks[1].allPacketsLost)
        #expect(feedback.nacks[1].packetIDs.isEmpty)
    }

    @Test("A truncated loss field is dropped rather than read past the packet")
    func truncatedNack() {
        // Body is 20 bytes: the 16-byte header plus room for exactly one
        // loss field, even though the count claims three.
        var packet = Data([0x8F, 206, 0x00, 0x05])
        packet.appendBigEndian(UInt32(0xAAAA_AAAA))
        packet.appendBigEndian(UInt32(0xBBBB_BBBB))
        packet.append(contentsOf: Array("CAST".utf8))
        packet.append(10)
        packet.append(3)                                    // claims three...
        packet.appendBigEndian(UInt16(400))
        packet.append(contentsOf: [11, 0x00, 0x03, 0x00])   // ...but sends one
        #expect(CastRTP.parseFeedback(packet).nacks.count == 1)
    }

    @Test("A feedback message without the CAST magic is left alone")
    func feedbackWithoutMagic() {
        var packet = Data([0x8F, 206, 0x00, 0x04])
        packet.appendBigEndian(UInt32(0xAAAA_AAAA))
        packet.appendBigEndian(UInt32(0xBBBB_BBBB))
        packet.append(contentsOf: Array("XXXX".utf8))
        packet.append(contentsOf: [200, 0, 0x01, 0x90])
        #expect(CastRTP.parseFeedback(packet).ackFrameID == nil)
    }

    @Test("Garbage is not mistaken for a key-frame request")
    func garbage() {
        #expect(!CastRTP.parseFeedback(Data([0x00, 0x00])).wantsKeyFrame)
        #expect(!CastRTP.parseFeedback(Data(repeating: 0xFF, count: 40)).wantsKeyFrame)
        #expect(!CastRTP.parseFeedback(Data()).wantsKeyFrame)
    }
}

@Suite("Waiting on external subsystems")
struct TimeoutTests {
    @Test("A call that never returns gives up instead of hanging the caller")
    func neverReturns() async {
        let start = ContinuousClock.now
        await #expect(throws: TimedOut.self) {
            try await withTimeout(.milliseconds(150), "Test subsystem") {
                try await Task.sleep(for: .seconds(60))
                return 1
            }
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("A call that answers in time returns its value untouched")
    func answersInTime() async throws {
        let value = try await withTimeout(.seconds(5), "Test subsystem") {
            try await Task.sleep(for: .milliseconds(20))
            return 42
        }
        #expect(value == 42)
    }

    @Test("The operation's own error wins over the deadline")
    func propagatesFailure() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await withTimeout(.seconds(5), "Test subsystem") {
                throw Boom()
            }
        }
    }

    @Test("Timing out says which subsystem stalled")
    func message() {
        #expect(TimedOut("Screen capture").errorDescription?.contains("Screen capture") == true)
    }
}

@Suite("Cast Streaming negotiation")
struct CastStreamingOfferTests {
    @Test("The offer is valid JSON with the fields the receiver reads back")
    func offerShape() throws {
        var offer = CastStreaming.Offer()
        offer.width = 1280
        offer.height = 720
        offer.includeAudio = false
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(offer.json(sequenceNumber: 3).utf8))
                as? [String: Any]
        )
        #expect(json["type"] as? String == "OFFER")
        #expect(json["seqNum"] as? Int == 3)

        let streams = try #require(
            (json["offer"] as? [String: Any])?["supportedStreams"] as? [[String: Any]]
        )
        #expect(streams.count == 1)                     // audio was excluded
        #expect(streams[0]["codecName"] as? String == "h264")
        #expect(streams[0]["rtpPayloadType"] as? Int == 101)
        #expect(streams[0]["index"] as? Int == 0)
        // Keys travel as 32 hex characters — 16 bytes each.
        #expect((streams[0]["aesKey"] as? String)?.count == 32)
        #expect((streams[0]["aesIvMask"] as? String)?.count == 32)
    }

    @Test("Audio is stream index 1 when included")
    func audioIndex() throws {
        let json = try #require(
            try JSONSerialization.jsonObject(
                with: Data(CastStreaming.Offer().json(sequenceNumber: 1).utf8)
            ) as? [String: Any]
        )
        let streams = try #require(
            (json["offer"] as? [String: Any])?["supportedStreams"] as? [[String: Any]]
        )
        #expect(streams.count == 2)
        #expect(streams[1]["index"] as? Int == 1)
        #expect(streams[1]["codecName"] as? String == "opus")
    }

    @Test("Each offer gets its own keys")
    func freshKeys() {
        let first = CastStreaming.Offer()
        let second = CastStreaming.Offer()
        #expect(first.videoKeys.aesKey != second.videoKeys.aesKey)
        #expect(first.videoKeys.aesKey != first.audioKeys.aesKey)
        #expect(first.videoKeys.aesKey.count == 16)
    }

    /// The exact payload the user's TV sent back on 2026-08-03.
    @Test("Parses the answer a real receiver sent")
    func realAnswer() throws {
        let payload = """
        {"answer":{"castMode":"mirroring","rtpExtensions":[[]],"sendIndexes":[0],\
        "ssrcs":[19088744],"udpPort":52373},"result":"ok","seqNum":1,"type":"ANSWER"}
        """
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        )
        let answer = try #require(CastStreaming.Answer(json: json))
        #expect(answer.udpPort == 52373)
        #expect(answer.acceptedVideo)
        #expect(!answer.acceptedAudio)
        #expect(answer.ssrcs == [19_088_744])
    }

    @Test("A message that isn't an answer is rejected")
    func notAnAnswer() {
        #expect(CastStreaming.Answer(json: ["type": "STATUS_RESPONSE"]) == nil)
        #expect(CastStreaming.Answer(json: ["answer": ["result": "error"]]) == nil)
    }
}
