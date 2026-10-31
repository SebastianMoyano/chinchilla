import Foundation
import Darwin

public enum DiskSize {
    /// Total allocated bytes of a file or directory tree (st_blocks * 512).
    /// Lightweight fts loop — no tree building.
    ///
    /// Callers run this inside `Blocking.run`, where `Task.isCancelled` is
    /// always false — `isCancelled` is the probe of a `CancelFlag` set from
    /// the async side. Checked every ~2048 entries (same cadence as
    /// FTSWalker); on cancellation the partial total is returned, which
    /// callers discard along with the rest of the abandoned scan.
    public static func allocated(
        at path: String,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) -> Int64 {
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        if st.st_mode & S_IFMT != S_IFDIR {
            return Int64(st.st_blocks) * 512
        }
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { free(argv[0]) }
        guard let ftsp = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            return 0
        }
        defer { fts_close(ftsp) }
        var total: Int64 = 0
        var entryCount = 0
        while let ent = fts_read(ftsp) {
            entryCount += 1
            if entryCount % 2048 == 0, isCancelled?() == true { break }
            switch Int32(ent.pointee.fts_info) {
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                if let st = ent.pointee.fts_statp?.pointee {
                    total += Int64(st.st_blocks) * 512
                }
            default:
                continue
            }
        }
        return total
    }

    /// Bytes that deleting `path` would actually give back. An APFS clone
    /// shares its blocks with the file it was cloned from, so removing one
    /// side frees only what it doesn't share; a hardlinked file frees nothing
    /// while another link lives. Package managers that install by cloning
    /// out of their cache (uv, bun) made `allocated` promise twice what a
    /// clean returned. Costs one extra `getattrlist` per file, so only rules
    /// that ask for it pay it.
    public static func reclaimable(
        at path: String,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) -> Int64 {
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        if st.st_mode & S_IFMT != S_IFDIR {
            return privateBytes(path, st)
        }
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { free(argv[0]) }
        guard let ftsp = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            return 0
        }
        defer { fts_close(ftsp) }
        var total: Int64 = 0
        var entryCount = 0
        while let ent = fts_read(ftsp) {
            entryCount += 1
            if entryCount % 2048 == 0, isCancelled?() == true { break }
            switch Int32(ent.pointee.fts_info) {
            case FTS_F:
                if let st = ent.pointee.fts_statp?.pointee {
                    total += privateBytes(ent.pointee.fts_path, st)
                }
            case FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                if let st = ent.pointee.fts_statp?.pointee {
                    total += Int64(st.st_blocks) * 512
                }
            default:
                continue
            }
        }
        return total
    }

    private static func privateBytes(_ path: UnsafePointer<CChar>, _ st: stat) -> Int64 {
        let allocated = Int64(st.st_blocks) * 512
        guard st.st_mode & S_IFMT == S_IFREG else { return allocated }
        if st.st_nlink > 1 { return 0 }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        // getattrlist packs at 4-byte alignment: a UInt32 length, then the
        // off_t at offset 4 — a Swift struct would pad it to 8 and read zero.
        var raw = (UInt64(0), UInt64(0))
        let ok = withUnsafeMutableBytes(of: &raw) { buffer in
            getattrlist(path, &request, buffer.baseAddress, buffer.count,
                        UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)) == 0
        }
        // Not APFS (or no answer): the old, optimistic number.
        guard ok else { return allocated }
        let unshared = withUnsafeBytes(of: raw) { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
        return min(max(unshared, 0), allocated)
    }

    private static func privateBytes(_ path: String, _ st: stat) -> Int64 {
        path.withCString { privateBytes($0, st) }
    }
}
