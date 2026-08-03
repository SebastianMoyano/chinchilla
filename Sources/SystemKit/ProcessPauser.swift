import Foundation
import Darwin

public struct PausedProcess: Codable, Sendable, Identifiable {
    public let pid: pid_t
    public let startTime: UInt64
    public let bundleID: String
    public let name: String

    public var id: pid_t { pid }

    public init(pid: pid_t, startTime: UInt64, bundleID: String, name: String) {
        self.pid = pid
        self.startTime = startTime
        self.bundleID = bundleID
        self.name = name
    }
}

/// SIGSTOP/SIGCONT for whole process trees. Freezing only the parent leaves
/// Electron/helper children burning CPU, so we walk descendants. Every
/// resume verifies (pid, startTime) so a recycled pid is never signalled.
public enum ProcessPauser {
    public static func startTime(of pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec
    }

    /// All descendant pids (children first order not guaranteed; we sort by
    /// depth via repeated passes over a ppid map).
    static func descendants(of root: pid_t) -> [pid_t] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(capacity) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }

        var parentOf: [pid_t: pid_t] = [:]
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            parentOf[pid] = pid_t(info.pbi_ppid)
        }

        var result: [pid_t] = []
        var frontier: Set<pid_t> = [root]
        while true {
            let next = parentOf.filter { frontier.contains($0.value) && !frontier.contains($0.key) }.map(\.key)
            guard !next.isEmpty else { break }
            result.append(contentsOf: next)
            frontier.formUnion(next)
        }
        return result
    }

    /// Children first, then the parent — the app can't spawn replacements
    /// for frozen children if it's frozen last... reversed: freeze parent
    /// last so its UI thread stops after workers (matches conventional
    /// freeze order). Returns nil if the root vanished.
    public static func pauseTree(pid: pid_t, bundleID: String, name: String) -> PausedProcess? {
        guard let start = startTime(of: pid) else { return nil }
        for child in descendants(of: pid) {
            kill(child, SIGSTOP)
        }
        kill(pid, SIGSTOP)
        return PausedProcess(pid: pid, startTime: start, bundleID: bundleID, name: name)
    }

    /// Parent first (so it can service children), then descendants.
    /// Never signals a pid whose start time no longer matches.
    public static func resumeTree(_ paused: PausedProcess) {
        guard startTime(of: paused.pid) == paused.startTime else { return }
        kill(paused.pid, SIGCONT)
        for child in descendants(of: paused.pid) {
            kill(child, SIGCONT)
        }
    }
}

/// Runs user-created Shortcuts (the only honest path to Focus/DND —
/// macOS gives third-party apps no direct switch).
public enum ShortcutsRunner {
    public static func list() async -> [String] {
        guard let output = try? await ShellRunner.run(
            "/usr/bin/shortcuts", ["list"], timeout: .seconds(10)
        ) else { return [] }
        return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// `shortcuts run` can hang on a shortcut that prompts — ShellRunner
    /// kills it at the timeout.
    public static func run(_ name: String) async {
        _ = try? await ShellRunner.run(
            "/usr/bin/shortcuts", ["run", name], timeout: .seconds(15)
        )
    }
}
