import Darwin

/// Names of the processes running right now, as `proc_name` reports them
/// (the executable name, truncated by the kernel to 32 bytes).
public enum ProcessNames {
    /// One `proc_name` per pid — a few hundred cheap syscalls, no path or
    /// argument reads. Processes of other users that the kernel won't name
    /// are left out, which is fine: every conflict worth checking is ours.
    public static func running() -> Set<String> {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(capacity) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }

        var names = Set<String>()
        var buffer = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            names.insert(String(cString: buffer))
        }
        return names
    }

    /// Resolved executable paths of the running processes — how to tell that
    /// a program file on disk is in use, whatever the process calls itself.
    public static func executablePaths() -> Set<String> {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(capacity) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }

        var paths = Set<String>()
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            paths.insert(String(cString: buffer))
        }
        return paths
    }
}
