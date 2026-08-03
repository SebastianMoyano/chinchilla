import Foundation
import Testing
@testable import DiskScanKit

@Test func sharedRegistryDedupesHardlinksAcrossWalkers() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("chinchilla-hardlink-\(UUID().uuidString)")
    try fm.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let original = root.appendingPathComponent("a/file.bin")
    try Data(count: 2 << 20).write(to: original)
    try fm.linkItem(at: original, to: root.appendingPathComponent("b/link.bin"))

    // Simulate DiskScanner: two walkers over sibling subtrees sharing one registry.
    var options = WalkOptions()
    options.hardlinks = HardlinkRegistry()
    let resultA = FTSWalker.walk(path: root.appendingPathComponent("a").path, options: options)
    let resultB = FTSWalker.walk(path: root.appendingPathComponent("b").path, options: options)

    let total = resultA.totalBytes + resultB.totalBytes
    // The old bug: ~4 MB (counted once per walker). Correct: ~2 MB.
    #expect(total < 3 << 20, "hardlinked file was double-counted: \(total) bytes")
    #expect(total >= 2 << 20)
}
