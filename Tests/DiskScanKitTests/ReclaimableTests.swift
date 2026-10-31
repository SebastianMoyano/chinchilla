import Foundation
import Darwin
import Testing
@testable import DiskScanKit

@Test func clonesAndHardlinksFreeNothingWhileTheOtherSideLives() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("chinchilla-reclaim-\(UUID().uuidString)")
    let fm = FileManager.default
    try fm.createDirectory(at: dir.appendingPathComponent("cache"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    let original = dir.appendingPathComponent("cache/pkg.bin").path
    try Data(repeating: 7, count: 1 << 20).write(to: URL(fileURLWithPath: original))
    let allocated = DiskSize.allocated(at: dir.appendingPathComponent("cache").path)
    #expect(allocated >= 1 << 20)
    // Alone, every byte is its own.
    #expect(DiskSize.reclaimable(at: dir.appendingPathComponent("cache").path) == allocated)

    // An install clones out of the cache: deleting the cache frees nothing.
    let installed = dir.appendingPathComponent("installed.bin").path
    guard clonefile(original, installed, 0) == 0 else { return }  // not APFS
    #expect(DiskSize.reclaimable(at: dir.appendingPathComponent("cache").path) == 0)

    try fm.removeItem(atPath: installed)
    try fm.linkItem(atPath: original, toPath: installed)
    #expect(DiskSize.reclaimable(at: dir.appendingPathComponent("cache").path) == 0)
}
