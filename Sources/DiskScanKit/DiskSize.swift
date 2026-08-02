import Foundation
import Darwin

public enum DiskSize {
    /// Total allocated bytes of a file or directory tree (st_blocks * 512).
    /// Lightweight fts loop — no tree building.
    public static func allocated(at path: String) -> Int64 {
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
        while let ent = fts_read(ftsp) {
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
