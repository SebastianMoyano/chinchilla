import Foundation
import Testing
@testable import CastKit

@Test func frameRoundTripAllOpcodes() {
    let body = Data(#"{"time":42.5}"#.utf8)
    for opcode: FCastOpcode in [.play, .pause, .resume, .stop, .seek, .setVolume, .version, .ping, .pong] {
        let framed = FCastFrameCodec.encode(opcode: opcode, body: opcode == .ping ? Data() : body)
        var decoder = FCastFrameCodec()
        let frames = decoder.append(framed)
        #expect(frames?.count == 1)
        #expect(frames?.first?.opcode == opcode.rawValue)
    }
}

@Test func bodylessFrameHasSizeOne() {
    let framed = FCastFrameCodec.encode(opcode: .ping)
    #expect(framed.count == 5)
    let size = framed.prefix(4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    #expect(size == 1)
}

@Test func incrementalDecoderHandlesByteByByteAndCoalesced() {
    let messageA = FCastFrameCodec.encode(opcode: .seek, message: FCastSeekMessage(time: 10))!
    let messageB = FCastFrameCodec.encode(opcode: .pause)
    var decoder = FCastFrameCodec()

    // Byte by byte.
    var collected: [FCastFrame] = []
    for byte in messageA {
        collected.append(contentsOf: decoder.append(Data([byte])) ?? [])
    }
    #expect(collected.count == 1)
    #expect(collected.first?.opcode == FCastOpcode.seek.rawValue)

    // Two frames in one chunk.
    let frames = decoder.append(messageA + messageB)
    #expect(frames?.count == 2)
    #expect(frames?.last?.opcode == FCastOpcode.pause.rawValue)
}

@Test func oversizeFramePoisonsStream() {
    var oversize = UInt32(40_000).littleEndian
    var data = Data(bytes: &oversize, count: 4)
    data.append(FCastOpcode.play.rawValue)
    var decoder = FCastFrameCodec()
    #expect(decoder.append(data) == nil)
}

@Test func encodeRejectsOversizeBody() {
    let hugeContent = String(repeating: "x", count: 40_000)
    let message = FCastPlayMessage(container: "video/mp4", content: hugeContent)
    #expect(FCastFrameCodec.encode(opcode: .play, message: message) == nil)
}

@Test func playbackUpdateDecodesLeniently() throws {
    // Receivers vary: missing fields must not fail.
    let minimal = Data(#"{"state":1}"#.utf8)
    let update = try JSONDecoder().decode(FCastPlaybackUpdateMessage.self, from: minimal)
    #expect(update.state == 1)
    #expect(update.time == nil)
}
