import Foundation
import Synchronization

public enum ScanEvent: Sendable {
    case progress(bytes: Int64, path: String)
    case finished(root: FileNode, largeFiles: [LargeFile])
    case failed(String)
}

/// Orchestrates parallel FTSWalker runs: one child task per top-level
/// subdirectory of the scan root, loose files at the root sized inline.
public enum DiskScanner {
    public static func scan(
        root: String,
        options: WalkOptions = WalkOptions()
    ) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let result = await runScan(root: root, options: options) { bytes, path in
                    continuation.yield(.progress(bytes: bytes, path: path))
                }
                switch result {
                case .success(let (node, large)):
                    continuation.yield(.finished(root: node, largeFiles: large))
                case .failure(let message):
                    continuation.yield(.failed(message))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum ScanResult {
        case success((FileNode, [LargeFile]))
        case failure(String)
    }

    private static func runScan(
        root: String,
        options: WalkOptions,
        emitProgress: @escaping @Sendable (Int64, String) -> Void
    ) async -> ScanResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return .failure("Not a directory: \(root)")
        }
        let entries = (try? fm.contentsOfDirectory(atPath: root)) ?? []

        // Shared progress accumulator across walkers, throttled to ~10 Hz.
        let progressState = Mutex<(total: Int64, lastEmit: ContinuousClock.Instant)>(
            (0, ContinuousClock.now)
        )
        var opts = options
        opts.isCancelled = { Task.isCancelled }
        opts.hardlinks = HardlinkRegistry()  // shared across parallel walkers
        opts.onProgress = { delta, path in
            let emit: Int64? = progressState.withLock { state in
                state.total += delta
                let now = ContinuousClock.now
                guard now - state.lastEmit > .milliseconds(100) else { return nil }
                state.lastEmit = now
                return state.total
            }
            if let bytes = emit { emitProgress(bytes, path) }
        }
        let walkerOptions = opts

        var subdirs: [String] = []
        var rootChildren: [FileNode] = []
        var rootSize: Int64 = 0
        for entry in entries {
            if walkerOptions.skipNames.contains(entry) { continue }
            let path = (root as NSString).appendingPathComponent(entry)
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            if st.st_mode & S_IFMT == S_IFDIR {
                subdirs.append(path)
            } else {
                let allocated = Int64(st.st_blocks) * 512
                rootSize += allocated
                if allocated >= walkerOptions.minChildSize {
                    rootChildren.append(
                        FileNode(name: entry, path: path, size: allocated, isDirectory: false)
                    )
                }
            }
        }

        var allLarge: [LargeFile] = []
        await withTaskGroup(of: WalkResult.self) { group in
            for dir in subdirs {
                group.addTask {
                    await Blocking.run { FTSWalker.walk(path: dir, options: walkerOptions) }
                }
            }
            for await result in group {
                if let node = result.root {
                    rootChildren.append(node)
                    rootSize += node.size
                }
                allLarge.append(contentsOf: result.largeFiles)
            }
        }

        if Task.isCancelled {
            return .failure("cancelled")
        }

        rootChildren.sort { $0.size > $1.size }
        allLarge.sort { $0.size > $1.size }
        if allLarge.count > 200 { allLarge.removeSubrange(200...) }

        let rootNode = FileNode(
            name: (root as NSString).lastPathComponent.isEmpty ? root : (root as NSString).lastPathComponent,
            path: root,
            size: rootSize,
            isDirectory: true,
            children: rootChildren
        )
        return .success((rootNode, allLarge))
    }
}
