import Foundation
import DiskScanKit
import Testing
@testable import CastKit

/// The TS muxer exists because a class of DLNA sets can only decode the
/// broadcast container. There is no receiver to argue with in a test, so
/// these pin the wire format itself: a demuxer that meets these bytes has
/// everything it needs, in the right order, with valid checksums.

private func collect(_ feed: (MPEGTSMuxer) -> Void) -> Data {
    let muxer = MPEGTSMuxer()
    let out = Locked(Data())
    muxer.onPackets = { data in out.withLock { $0.append(data) } }
    feed(muxer)
    return out.withLock { $0 }
}

private func packets(of data: Data) -> [Data] {
    stride(from: 0, to: data.count, by: 188).map {
        data.subdata(in: $0..<min($0 + 188, data.count))
    }
}

@Test func everyPacketIs188BytesAndSynced() {
    let data = collect { muxer in
        muxer.appendVideo(annexB: Data(repeating: 0xAB, count: 5_000),
                          hostSeconds: 100.0, isKeyFrame: true)
        muxer.appendAudio(adts: Data(repeating: 0xCD, count: 300), hostSeconds: 100.01)
    }
    #expect(data.count % 188 == 0)
    #expect(!data.isEmpty)
    for packet in packets(of: data) {
        #expect(packet.count == 188)
        #expect(packet[packet.startIndex] == 0x47)
    }
}

@Test func aKeyFrameLeadsWithValidTables() {
    let data = collect { muxer in
        muxer.appendVideo(annexB: Data([0, 0, 0, 1, 0x65]), hostSeconds: 7, isKeyFrame: true)
    }
    let all = packets(of: data)
    func pid(_ packet: Data) -> UInt16 {
        let b = [UInt8](packet)
        return UInt16(b[1] & 0x1F) << 8 | UInt16(b[2])
    }
    // PAT, then PMT, then video — a set that joins at an IDR gets the map
    // before the picture.
    #expect(pid(all[0]) == 0)
    #expect(pid(all[1]) == MPEGTSMuxer.pmtPID)
    #expect(all.count >= 3 && pid(all[2]) == MPEGTSMuxer.videoPID)

    // Both tables carry the CRC their section claims.
    for section in [MPEGTSMuxer.patSection(), MPEGTSMuxer.pmtSection()] {
        let table = section.dropFirst()            // pointer_field
        let body = table.dropLast(4)
        let declared = table.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(MPEGTSMuxer.crc32(Data(body)) == declared)
    }
}

@Test func ptsSurvivesTheFiveByteEncoding() {
    for pts: UInt64 in [0, 90_000, 8_589_934_591, 0x1_2345_6789 & 0x1_FFFF_FFFF] {
        let encoded = MPEGTSMuxer.ptsBytes(pts, prefix: 0x20)
        #expect(MPEGTSMuxer.decodePTS(encoded) == pts)
        // Marker bits present — demuxers check them.
        let b = [UInt8](encoded)
        #expect(b[0] & 0x01 == 1)
        #expect(b[2] & 0x01 == 1)
        #expect(b[4] & 0x01 == 1)
    }
}

@Test func continuityCountsPerPIDAndOnlyWraps() {
    let data = collect { muxer in
        for i in 0..<3 {
            muxer.appendVideo(annexB: Data(repeating: 0x11, count: 2_000),
                              hostSeconds: 50 + Double(i) / 30, isKeyFrame: i == 0)
        }
    }
    var last: UInt8?
    for packet in packets(of: data) {
        let b = [UInt8](packet)
        let pid = UInt16(b[1] & 0x1F) << 8 | UInt16(b[2])
        guard pid == MPEGTSMuxer.videoPID else { continue }
        let cc = b[3] & 0x0F
        if let previous = last {
            #expect(cc == (previous &+ 1) & 0x0F)
        }
        last = cc
    }
    #expect(last != nil)
}

@Test func keyFramesAreMarkedForRandomAccess() {
    let data = collect { muxer in
        muxer.appendVideo(annexB: Data(repeating: 0x22, count: 100),
                          hostSeconds: 9, isKeyFrame: true)
    }
    let video = packets(of: data).first { packet in
        let b = [UInt8](packet)
        return UInt16(b[1] & 0x1F) << 8 | UInt16(b[2]) == MPEGTSMuxer.videoPID
    }
    let b = [UInt8](video ?? Data())
    // PUSI set, adaptation field present, random-access + PCR flags in it.
    #expect(b[1] & 0x40 != 0)
    #expect(b[3] & 0x20 != 0)
    #expect(b[5] & 0x40 != 0)
    #expect(b[5] & 0x10 != 0)
}

@Test func theAdtsHeaderDeclaresItsOwnLength() {
    let frame = AACAudioEncoder.adtsFrame(Data(repeating: 0xEE, count: 200))
    #expect(frame.count == 207)
    let b = [UInt8](frame)
    #expect(b[0] == 0xFF && b[1] & 0xF0 == 0xF0)
    let declared = Int(b[3] & 0x03) << 11 | Int(b[4]) << 3 | Int(b[5] >> 5)
    #expect(declared == 207)
}
