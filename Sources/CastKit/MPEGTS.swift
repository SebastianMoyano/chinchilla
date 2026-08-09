import Foundation

/// MPEG-TS muxing for DLNA live mirroring.
///
/// The rolling fMP4 the fallback path serves needs a player that understands
/// "video with no end", and the DLNA sets that refused it don't. But every
/// television decodes broadcast MPEG-TS by design — it's the format of the
/// antenna signal, index-free and duration-free since the day DVB shipped —
/// and DLNA live-TV bridges (SAT>IP, Plex Live) feed sets exactly this.
/// AVFoundation won't produce TS, so this is the container done by hand:
/// 188-byte packets, PAT/PMT tables, PES with PTS, PCR on the video PID.
public final class MPEGTSMuxer: @unchecked Sendable {
    /// Emitted as runs of whole 188-byte packets.
    public var onPackets: (@Sendable (Data) -> Void)?

    private let lock = NSLock()
    private var epoch: Double?
    private var videoCC: UInt8 = 0
    private var audioCC: UInt8 = 0
    private var patCC: UInt8 = 0
    private var pmtCC: UInt8 = 0
    private var lastTablesAt: Double = -1

    static let pmtPID: UInt16 = 0x1000
    static let videoPID: UInt16 = 0x0100
    static let audioPID: UInt16 = 0x0101

    public init() {}

    /// One encoded H.264 access unit (Annex B, parameter sets inline on key
    /// frames — exactly what `RealtimeH264Encoder` emits).
    public func appendVideo(annexB: Data, hostSeconds: Double, isKeyFrame: Bool) {
        lock.lock()
        let pts = ticks(hostSeconds)
        var out = Data()
        // Tables ride ahead of every key frame and at least twice a second:
        // a TV that joins mid-stream must meet PAT/PMT before the IDR or it
        // has nothing to configure its demuxer with.
        if isKeyFrame || hostSeconds - lastTablesAt > 0.5 {
            out.append(tablePackets())
            lastTablesAt = hostSeconds
        }
        // An access unit delimiter first — several TS demuxers use it to
        // find frame boundaries and stall without it.
        var payload = Data([0, 0, 0, 1, 0x09, 0xF0])
        payload.append(annexB)
        let pes = Self.pes(streamID: 0xE0, pts: pts, payload: payload, unboundedLength: true)
        out.append(Self.packetize(
            pid: Self.videoPID, continuity: &videoCC, payload: pes,
            pcr: pts > 3_000 ? (pts - 3_000) &* 300 : 0, randomAccess: isKeyFrame
        ))
        let handler = onPackets
        lock.unlock()
        handler?(out)
    }

    /// One AAC frame already wrapped in its ADTS header.
    public func appendAudio(adts: Data, hostSeconds: Double) {
        lock.lock()
        let pts = ticks(hostSeconds)
        let pes = Self.pes(streamID: 0xC0, pts: pts, payload: adts, unboundedLength: false)
        let out = Self.packetize(
            pid: Self.audioPID, continuity: &audioCC, payload: pes,
            pcr: nil, randomAccess: false
        )
        let handler = onPackets
        lock.unlock()
        handler?(out)
    }

    /// 90 kHz, rebased to a small positive origin — host-clock seconds are
    /// millions on a long-uptime Mac, and 33-bit PTS wraps at ~26 hours.
    private func ticks(_ hostSeconds: Double) -> UInt64 {
        if epoch == nil { epoch = hostSeconds }
        let elapsed = max(0, hostSeconds - (epoch ?? hostSeconds))
        return (UInt64(elapsed * 90_000) &+ 90_000) & 0x1_FFFF_FFFF
    }

    // MARK: Tables

    private func tablePackets() -> Data {
        var out = Data()
        out.append(Self.packetize(
            pid: 0, continuity: &patCC, payload: Self.patSection(),
            pcr: nil, randomAccess: false
        ))
        out.append(Self.packetize(
            pid: Self.pmtPID, continuity: &pmtCC, payload: Self.pmtSection(),
            pcr: nil, randomAccess: false
        ))
        return out
    }

    static func patSection() -> Data {
        var body = Data()
        body.appendBigEndian(UInt16(1))            // transport_stream_id
        body.append(0xC1)                          // version 0, current
        body.append(0)                             // section_number
        body.append(0)                             // last_section_number
        body.appendBigEndian(UInt16(1))            // program_number
        body.append(0xE0 | UInt8(pmtPID >> 8))     // reserved + PMT PID
        body.append(UInt8(pmtPID & 0xFF))
        return section(tableID: 0x00, body: body)
    }

    static func pmtSection() -> Data {
        var body = Data()
        body.appendBigEndian(UInt16(1))            // program_number
        body.append(0xC1)
        body.append(0)
        body.append(0)
        body.append(0xE0 | UInt8(videoPID >> 8))   // PCR PID = video
        body.append(UInt8(videoPID & 0xFF))
        body.appendBigEndian(UInt16(0xF000))       // program_info_length 0
        for (type, pid): (UInt8, UInt16) in [(0x1B, videoPID), (0x0F, audioPID)] {
            body.append(type)                      // H.264 / ADTS AAC
            body.append(0xE0 | UInt8(pid >> 8))
            body.append(UInt8(pid & 0xFF))
            body.appendBigEndian(UInt16(0xF000))   // es_info_length 0
        }
        return section(tableID: 0x02, body: body)
    }

    /// pointer_field + header + body + CRC32, ready to be a packet payload.
    private static func section(tableID: UInt8, body: Data) -> Data {
        var table = Data([tableID])
        let length = body.count + 4                // + CRC
        table.append(0xB0 | UInt8((length >> 8) & 0x0F))
        table.append(UInt8(length & 0xFF))
        table.append(body)
        table.appendBigEndian(crc32(table))
        return Data([0x00]) + table                // pointer_field
    }

    /// CRC-32/MPEG-2 — the one every table carries; a wrong polynomial here
    /// is a demuxer that silently ignores the whole program.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = (crc & 0x8000_0000) != 0
                    ? (crc << 1) ^ 0x04C1_1DB7
                    : crc << 1
            }
        }
        return crc
    }

    // MARK: PES

    /// Video uses the unbounded length (0) the spec allows — access units
    /// can exceed the 16-bit field. Audio frames are small and carry theirs.
    static func pes(streamID: UInt8, pts: UInt64, payload: Data, unboundedLength: Bool) -> Data {
        var out = Data([0x00, 0x00, 0x01, streamID])
        let contentLength = 3 + 5 + payload.count  // flags + headerLen + PTS
        if unboundedLength || contentLength > 0xFFFF {
            out.appendBigEndian(UInt16(0))
        } else {
            out.appendBigEndian(UInt16(contentLength))
        }
        out.append(0x80)                           // marker bits
        out.append(0x80)                           // PTS only
        out.append(5)                              // PES_header_data_length
        out.append(ptsBytes(pts, prefix: 0x20))
        out.append(payload)
        return out
    }

    /// 33 bits spread over 5 bytes with marker bits — the classic encoding.
    static func ptsBytes(_ pts: UInt64, prefix: UInt8) -> Data {
        Data([
            prefix | UInt8((pts >> 29) & 0x0E) | 0x01,
            UInt8((pts >> 22) & 0xFF),
            UInt8((pts >> 14) & 0xFE) | 0x01,
            UInt8((pts >> 7) & 0xFF),
            UInt8((pts << 1) & 0xFE) | 0x01,
        ])
    }

    /// Reads the encoding back — for tests, and for the symmetry that keeps
    /// the writer honest.
    static func decodePTS(_ bytes: Data) -> UInt64 {
        guard bytes.count >= 5 else { return 0 }
        let b = [UInt8](bytes.prefix(5))
        return (UInt64(b[0] & 0x0E) << 29)
            | (UInt64(b[1]) << 22)
            | (UInt64(b[2] & 0xFE) << 14)
            | (UInt64(b[3]) << 7)
            | (UInt64(b[4]) >> 1)
    }

    // MARK: TS packetization

    /// Splits a payload into 188-byte packets: PUSI on the first, PCR and
    /// the random-access flag in its adaptation field when asked, stuffing
    /// in the last so every packet is exactly 188 bytes.
    static func packetize(
        pid: UInt16, continuity: inout UInt8, payload: Data,
        pcr: UInt64?, randomAccess: Bool
    ) -> Data {
        var out = Data(capacity: (payload.count / 184 + 2) * 188)
        var offset = payload.startIndex
        var first = true
        while offset < payload.endIndex {
            let remaining = payload.distance(from: offset, to: payload.endIndex)
            var adaptation = Data()
            var flags: UInt8 = 0
            var fields = Data()
            if first, randomAccess { flags |= 0x40 }
            if first, let pcr {
                flags |= 0x10
                fields.append(pcrBytes(pcr))
            }
            let wantsAF = flags != 0 || remaining < 184
            if wantsAF {
                // length byte + flags + fields + stuffing; a bare length of
                // zero (one spare byte, no flags) is legal and used when the
                // payload is exactly one byte short of full.
                var content = Data()
                if flags != 0 || remaining < 183 {
                    content.append(flags)
                    content.append(fields)
                }
                let space = 184 - 1 - content.count
                let stuffing = max(0, space - remaining)
                adaptation.append(UInt8(content.count + stuffing))
                adaptation.append(content)
                adaptation.append(Data(repeating: 0xFF, count: stuffing))
            }
            let chunk = min(remaining, 184 - adaptation.count)
            var packet = Data(capacity: 188)
            packet.append(0x47)
            packet.append((first ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1F))
            packet.append(UInt8(pid & 0xFF))
            packet.append((adaptation.isEmpty ? 0x10 : 0x30) | (continuity & 0x0F))
            continuity = (continuity &+ 1) & 0x0F
            packet.append(adaptation)
            packet.append(payload[offset..<payload.index(offset, offsetBy: chunk)])
            offset = payload.index(offset, offsetBy: chunk)
            first = false
            out.append(packet)
        }
        return out
    }

    static func pcrBytes(_ pcr: UInt64) -> Data {
        let base = (pcr / 300) & 0x1_FFFF_FFFF
        let ext = UInt16(pcr % 300)
        return Data([
            UInt8((base >> 25) & 0xFF),
            UInt8((base >> 17) & 0xFF),
            UInt8((base >> 9) & 0xFF),
            UInt8((base >> 1) & 0xFF),
            UInt8((base & 1) << 7) | 0x7E | UInt8((ext >> 8) & 0x01),
            UInt8(ext & 0xFF),
        ])
    }
}
