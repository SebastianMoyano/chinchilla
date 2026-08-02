import Foundation
import Testing
@testable import DiskScanKit

private func makeTree() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("chinchilla-test-\(UUID().uuidString)")
    let fm = FileManager.default
    try fm.createDirectory(at: root.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
    try Data(count: 1 << 21).write(to: root.appendingPathComponent("big.bin"))          // 2 MB
    try Data(count: 4096).write(to: root.appendingPathComponent("small.bin"))
    try Data(count: 1 << 21).write(to: root.appendingPathComponent("sub/deep/nested.bin"))
    return root
}

@Test func walkAccumulatesSizesBottomUp() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }

    let result = FTSWalker.walk(path: root.path)
    let node = try #require(result.root)

    #expect(node.isDirectory)
    // Allocated size ≥ logical content (2 + 2 MB + small file).
    #expect(node.size >= 4 << 20)
    // Both the big file and the sub dir survive the 1 MB pruning threshold.
    #expect(node.children.contains { $0.name == "big.bin" })
    let sub = try #require(node.children.first { $0.name == "sub" })
    #expect(sub.size >= 2 << 20)
    #expect(sub.children.first?.name == "deep")
}

@Test func walkRespectsSkipNames() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }

    var options = WalkOptions()
    options.skipNames.insert("sub")
    let result = FTSWalker.walk(path: root.path, options: options)
    let node = try #require(result.root)
    #expect(!node.children.contains { $0.name == "sub" })
    #expect(node.size < 4 << 20)
}

@Test func walkCollectsLargeFiles() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }

    var options = WalkOptions()
    options.largeFileThreshold = 1 << 20
    let result = FTSWalker.walk(path: root.path, options: options)
    #expect(result.largeFiles.count == 2)
    #expect(result.largeFiles.allSatisfy { $0.size >= 1 << 20 })
}

@Test func treemapMathPlaceholder() {
    let node = FileNode(name: "x", path: "/x", size: 10, isDirectory: true,
                        children: [FileNode(name: "y", path: "/x/y", size: 4, isDirectory: false)])
    #expect(node.remainder == 6)
}
