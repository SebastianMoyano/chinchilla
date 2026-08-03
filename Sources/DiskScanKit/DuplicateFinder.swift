import Foundation
import Darwin
import CryptoKit

public struct DuplicateGroup: Sendable, Identifiable {
    public let id: String          // content fingerprint
    public let fileSize: Int64     // per copy
    public let paths: [String]     // ≥ 2, newest first

    public var wastedBytes: Int64 { fileSize * Int64(paths.count - 1) }
    public var count: Int { paths.count }
    /// Files above the full-hash limit are matched by size + head/tail
    /// fingerprint only — near-certain, but the UI must not pre-select them.
    public var isFingerprintOnly: Bool { fileSize > DuplicateFinder.fullHashLimit }

    public init(id: String, fileSize: Int64, paths: [String]) {
        self.id = id
        self.fileSize = fileSize
        self.paths = paths
    }
}

/// Finds duplicate files: candidates grouped by exact size, then fingerprinted
/// with SHA-256 (full content < 64 MB; head+tail 1 MB for giants — with equal
/// size that's a near-certain match, and everything goes to Trash anyway).
public enum DuplicateFinder {
    public static let fullHashLimit: Int64 = 64 << 20
    static let chunk = 1 << 20

    public static func find(
        roots: [String]? = nil,
        minSize: Int64 = 5 << 20,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async -> [DuplicateGroup] {
        let home = NSHomeDirectory()
        let scanRoots = roots ?? ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]
            .map { home + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }

        // Phase 1: collect (path, size, mtime) of candidate files. Hardlinked
        // paths share an inode — deleting one frees nothing, so they count as
        // ONE file here, never as a duplicate pair.
        var bySize: [Int64: [(path: String, mtime: Date)]] = [:]
        var seenInodes = Set<String>()
        for root in scanRoots {
            collectFiles(root: root, minSize: minSize, isCancelled: isCancelled) { path, size, mtime, dev, ino in
                guard seenInodes.insert("\(dev):\(ino)").inserted else { return }
                bySize[size, default: []].append((path, mtime))
            }
        }

        // Phase 2: fingerprint only sizes with 2+ files, in parallel.
        struct Hit: Sendable {
            let key: String
            let size: Int64
            let path: String
            let mtime: Date
        }
        var groups: [String: (size: Int64, files: [(String, Date)])] = [:]
        await withTaskGroup(of: Hit?.self) { group in
            for (size, files) in bySize where files.count > 1 {
                for file in files {
                    group.addTask {
                        if isCancelled?() == true { return nil }
                        guard let digest = fingerprint(path: file.path, size: size) else { return nil }
                        return Hit(key: "\(size)-\(digest)", size: size, path: file.path, mtime: file.mtime)
                    }
                }
            }
            for await hit in group {
                guard let hit else { continue }
                groups[hit.key, default: (hit.size, [])].files.append((hit.path, hit.mtime))
            }
        }

        return groups
            .filter { $0.value.files.count > 1 }
            .map { key, value in
                DuplicateGroup(
                    id: key,
                    fileSize: value.size,
                    paths: value.files.sorted { $0.1 > $1.1 }.map(\.0)
                )
            }
            .sorted { $0.wastedBytes > $1.wastedBytes }
            .prefix(100)
            .map { $0 }
    }

    // MARK: - Internals

    private static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "fcpbundle", "imovielibrary", "framework",
    ]
    private static let sfDataless: UInt32 = 0x4000_0000

    private static func collectFiles(
        root: String, minSize: Int64,
        isCancelled: (@Sendable () -> Bool)?,
        emit: (String, Int64, Date, Int32, UInt64) -> Void
    ) {
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(root), nil]
        defer { free(argv[0]) }
        guard let ftsp = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(ftsp) }
        var count = 0
        while let ent = fts_read(ftsp) {
            count += 1
            if count % 4096 == 0, isCancelled?() == true { return }
            let info = Int32(ent.pointee.fts_info)
            let path = String(cString: ent.pointee.fts_path)
            let name = (path as NSString).lastPathComponent
            if info == FTS_D {
                let ext = (name as NSString).pathExtension.lowercased()
                if name.hasPrefix(".") || packageExtensions.contains(ext)
                    || name == "node_modules" || name == "Library" {
                    fts_set(ftsp, ent, FTS_SKIP)
                }
                continue
            }
            guard info == FTS_F, let st = ent.pointee.fts_statp?.pointee else { continue }
            if st.st_flags & sfDataless != 0 { continue }  // cloud placeholder
            let size = Int64(st.st_size)
            guard size >= minSize else { continue }
            emit(
                path, size,
                Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                st.st_dev, UInt64(st.st_ino)
            )
        }
    }

    private static func fingerprint(path: String, size: Int64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            if size <= fullHashLimit {
                while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty {
                    hasher.update(data: data)
                }
            } else {
                // Head + tail. Same size + same edges ≈ certain duplicate.
                if let head = try handle.read(upToCount: chunk) { hasher.update(data: head) }
                try handle.seek(toOffset: UInt64(size - Int64(chunk)))
                if let tail = try handle.read(upToCount: chunk) { hasher.update(data: tail) }
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
