import Foundation
import Testing
@testable import DiskScanKit

@Test func findsExactDuplicatesAndSkipsDifferentContent() async throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("chinchilla-dup-\(UUID().uuidString)")
    try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    var payload = Data(count: 6 << 20)          // 6 MB of zeros…
    payload[123] = 0xAB                          // …with a distinguishing byte
    var different = payload
    different[123] = 0xCD                        // same size, different content

    try payload.write(to: root.appendingPathComponent("a.bin"))
    try payload.write(to: root.appendingPathComponent("sub/b.bin"))
    try different.write(to: root.appendingPathComponent("c.bin"))

    let groups = await DuplicateFinder.find(roots: [root.path], minSize: 1 << 20)

    #expect(groups.count == 1)
    let group = try #require(groups.first)
    #expect(group.count == 2)
    #expect(Set(group.paths.map { ($0 as NSString).lastPathComponent }) == ["a.bin", "b.bin"])
    #expect(group.wastedBytes == group.fileSize)
}
