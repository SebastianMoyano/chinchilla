import Foundation
import Darwin

public struct WalkOptions: Sendable {
    /// Bundles reported as leaves — sized but not expanded.
    public var packageExtensions: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "tvlibrary",
        "fcpbundle", "imovielibrary", "framework", "xcarchive",
    ]
    /// Directory names never descended into.
    public var skipNames: Set<String> = [
        ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems",
    ]
    /// Absolute paths never descended into.
    public var skipPaths: Set<String> = []
    /// Directories kept in the tree only if at least this big.
    public var minChildSize: Int64 = 1 << 20  // 1 MB
    /// Cap on children kept per directory (largest win).
    public var maxChildren: Int = 200
    /// Files at or above this size are reported to the large-file collector.
    public var largeFileThreshold: Int64 = 100 << 20  // 100 MB
    /// Called every ~2048 entries with (bytes seen since previous callback,
    /// current path). Deltas let parallel walkers share one accumulator.
    public var onProgress: (@Sendable (Int64, String) -> Void)?
    /// Cooperative cancellation, checked every ~2048 entries.
    public var isCancelled: (@Sendable () -> Bool)?

    public init() {}
}

public struct WalkResult: Sendable {
    public let root: FileNode?
    public let largeFiles: [LargeFile]
    public let totalBytes: Int64
}

/// Synchronous fts(3)-based directory walker. Physical traversal (no symlink
/// follow), stays on one device, accumulates allocated sizes bottom-up.
public enum FTSWalker {
    private static let sfDataless: UInt32 = 0x4000_0000  // SF_DATALESS

    public static func walk(path: String, options: WalkOptions = WalkOptions()) -> WalkResult {
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { free(argv[0]) }
        guard let ftsp = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            return WalkResult(root: nil, largeFiles: [], totalBytes: 0)
        }
        defer { fts_close(ftsp) }

        // In-progress directory frames; frame.node.size accumulates as we go.
        struct Frame {
            var name: String
            var path: String
            var size: Int64 = 0
            var children: [FileNode] = []
            var isPackage: Bool
        }
        var stack: [Frame] = []
        var rootNode: FileNode?
        var largeFiles: [LargeFile] = []
        var seenHardlinks = Set<UInt64>()
        var entryCount = 0
        var totalBytes: Int64 = 0
        var lastReportedBytes: Int64 = 0

        func finishDirectory(_ frame: Frame) -> FileNode {
            var children = frame.children
            if frame.isPackage {
                children = []
            } else {
                children.sort { $0.size > $1.size }
                if children.count > options.maxChildren {
                    children.removeSubrange(options.maxChildren...)
                }
                while let last = children.last, last.size < options.minChildSize {
                    children.removeLast()
                }
            }
            return FileNode(
                name: frame.name, path: frame.path, size: frame.size,
                isDirectory: true, isPackage: frame.isPackage, children: children
            )
        }

        while let ent = fts_read(ftsp) {
            entryCount += 1
            if entryCount % 2048 == 0 {
                if options.isCancelled?() == true { break }
                options.onProgress?(totalBytes - lastReportedBytes, String(cString: ent.pointee.fts_path))
                lastReportedBytes = totalBytes
            }

            let info = Int32(ent.pointee.fts_info)
            let entPath = String(cString: ent.pointee.fts_path)
            let name = (entPath as NSString).lastPathComponent

            switch info {
            case FTS_D:
                if options.skipNames.contains(name) || options.skipPaths.contains(entPath) {
                    fts_set(ftsp, ent, FTS_SKIP)
                    continue
                }
                if let st = ent.pointee.fts_statp?.pointee, st.st_flags & sfDataless != 0 {
                    // Cloud-evicted placeholder: never descend (materialization risk).
                    fts_set(ftsp, ent, FTS_SKIP)
                    continue
                }
                let ext = (name as NSString).pathExtension.lowercased()
                let isPackage = !ext.isEmpty && options.packageExtensions.contains(ext)
                stack.append(Frame(name: name, path: entPath, isPackage: isPackage))

            case FTS_DP:
                guard let frame = stack.popLast() else { continue }
                let node = finishDirectory(frame)
                if stack.isEmpty {
                    rootNode = node
                } else {
                    stack[stack.count - 1].size += node.size
                    if node.size >= options.minChildSize {
                        stack[stack.count - 1].children.append(node)
                    }
                }

            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let st = ent.pointee.fts_statp?.pointee else { continue }
                if st.st_nlink > 1 {
                    // Dedupe hardlinks within this walk.
                    if !seenHardlinks.insert(UInt64(st.st_ino)).inserted { continue }
                }
                let allocated = Int64(st.st_blocks) * 512
                totalBytes += allocated
                if stack.isEmpty { continue }
                stack[stack.count - 1].size += allocated
                if info == FTS_F, allocated >= options.minChildSize,
                   !stack[stack.count - 1].isPackage {
                    stack[stack.count - 1].children.append(
                        FileNode(name: name, path: entPath, size: allocated, isDirectory: false)
                    )
                }
                if info == FTS_F, allocated >= options.largeFileThreshold, st.st_flags & sfDataless == 0 {
                    let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                    largeFiles.append(LargeFile(path: entPath, size: allocated, modified: modified))
                }

            default:
                // FTS_DNR / FTS_NS / FTS_ERR: unreadable — attempt-and-skip.
                continue
            }
        }

        // Cancelled mid-walk: unwind open frames so partial totals are coherent.
        while let frame = stack.popLast() {
            let node = finishDirectory(frame)
            if stack.isEmpty {
                rootNode = node
            } else {
                stack[stack.count - 1].size += node.size
                stack[stack.count - 1].children.append(node)
            }
        }

        // Flush the tail delta so the shared counter matches the final total.
        if totalBytes > lastReportedBytes {
            options.onProgress?(totalBytes - lastReportedBytes, path)
        }
        return WalkResult(root: rootNode, largeFiles: largeFiles, totalBytes: totalBytes)
    }
}
