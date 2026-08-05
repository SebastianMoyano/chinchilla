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
}
