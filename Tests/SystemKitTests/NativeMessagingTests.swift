import Foundation
import Testing
@testable import SystemKit

@Test func framingRoundTrip() {
    let json = Data(#"{"type":"hello","extVersion":"0.6.0"}"#.utf8)
    let framed = NativeMessagingCodec.frame(json)
    #expect(framed.count == json.count + 4)
    let length = NativeMessagingCodec.length(from: framed.prefix(4))
    #expect(length == json.count)
    #expect(framed.dropFirst(4) == json)
}

@Test func framingRejectsOversizeAndGarbage() {
    var big = UInt32(2 << 20).littleEndian
    let header = Data(bytes: &big, count: 4)
    #expect(NativeMessagingCodec.length(from: header) == nil)
    #expect(NativeMessagingCodec.length(from: Data([1, 2])) == nil)
    var zero = UInt32(0).littleEndian
    #expect(NativeMessagingCodec.length(from: Data(bytes: &zero, count: 4)) == nil)
}

@Test func eventSeqFiltering() throws {
    // Redirect the mailbox by writing events with known seqs into a temp
    // events file via the real API, then filter.
    let dir = TabGuardMailbox.directory
    let backup = dir.appendingPathComponent("events-backup-\(UUID().uuidString)")
    let events = TabGuardMailbox.eventsURL
    let fm = FileManager.default
    if fm.fileExists(atPath: events.path) {
        try fm.moveItem(at: events, to: backup)
    }
    defer {
        try? fm.removeItem(at: events)
        if fm.fileExists(atPath: backup.path) {
            try? fm.moveItem(at: backup, to: events)
        }
    }

    TabGuardMailbox.appendEvent(TabGuardEvent(seq: 1, type: "openColdSavePage"))
    TabGuardMailbox.appendEvent(TabGuardEvent(seq: 2, type: "restoreColdSaved", all: true))
    TabGuardMailbox.appendEvent(TabGuardEvent(seq: 3, type: "openColdSavePage"))

    #expect(TabGuardMailbox.maxEventSeq() == 3)
    let newer = TabGuardMailbox.readEvents(afterSeq: 1)
    #expect(newer.map(\.seq) == [2, 3])
    #expect(TabGuardMailbox.readEvents(afterSeq: 3).isEmpty)
}

@Test func desiredStateRoundTrip() {
    let desired = TabGuardDesired(
        settings: ["discardAfterMinutes": .number(15), "excludePinned": .bool(true)],
        gamingActive: true, pauseVideos: true, seq: 7
    )
    let data = try! JSONEncoder().encode(desired)
    let decoded = try! JSONDecoder().decode(TabGuardDesired.self, from: data)
    #expect(decoded == desired)
}
