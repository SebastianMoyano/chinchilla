import SwiftUI
import Observation
import DiskScanKit
import SystemKit

@MainActor
@Observable
final class DiskAnalyzerModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case done
        case failed(String)
    }

    var phase: Phase = .idle
    var scannedBytes: Int64 = 0
    var currentPath = ""
    var root: FileNode?
    var largeFiles: [LargeFile] = []
    /// Drill-down trail; last element is the directory being displayed.
    var breadcrumb: [FileNode] = []
    var hasFullDiskAccess = true

    private var scanTask: Task<Void, Never>?

    var displayed: FileNode? { breadcrumb.last ?? root }

    func refreshPermissions() {
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
    }

    func startScan(rootPath: String = NSHomeDirectory()) {
        guard phase != .scanning else { return }
        phase = .scanning
        scannedBytes = 0
        root = nil
        breadcrumb = []
        largeFiles = []
        scanTask = Task {
            for await event in DiskScanner.scan(root: rootPath) {
                switch event {
                case .progress(let bytes, let path):
                    scannedBytes = bytes
                    currentPath = path
                case .finished(let node, let large):
                    root = node
                    largeFiles = large
                    scannedBytes = node.size
                    withAnimation(.spring) { phase = .done }
                case .failed(let message):
                    phase = message == "cancelled" ? .idle : .failed(message)
                }
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        phase = .idle
    }

    func drillDown(into node: FileNode) {
        guard node.isDirectory, !node.isPackage, !node.children.isEmpty else { return }
        breadcrumb.append(node)
    }

    func jump(to index: Int?) {
        guard let index else {
            breadcrumb = []
            return
        }
        breadcrumb = Array(breadcrumb.prefix(index + 1))
    }

    // MARK: - Duplicates

    enum DupPhase: Equatable {
        case idle, scanning, done
    }

    var dupPhase: DupPhase = .idle
    var duplicateGroups: [DuplicateGroup] = [] {
        didSet { indexDuplicateSizes() }
    }
    var selectedDupes: Set<String> = []
    var dupResult: String?
    private var dupTask: Task<Void, Never>?

    /// Size per duplicate path, indexed when the groups arrive. The view reads
    /// the total on every render, and walking every group and every path in it
    /// to answer that is work proportional to the whole scan, per frame.
    private(set) var dupeSizeByPath: [String: Int64] = [:]

    func indexDuplicateSizes() {
        var sizes: [String: Int64] = [:]
        for group in duplicateGroups {
            for path in group.paths { sizes[path] = group.fileSize }
        }
        dupeSizeByPath = sizes
    }

    var selectedDupeBytes: Int64 {
        selectedDupes.reduce(0) { $0 + (dupeSizeByPath[$1] ?? 0) }
    }

    func startDuplicateScan() {
        guard dupPhase != .scanning else { return }
        dupPhase = .scanning
        dupResult = nil
        duplicateGroups = []
        dupTask = Task {
            // The finder hashes files inside `Blocking.run`, where
            // `Task.isCancelled` is always false — so "Cancel" left a full
            // duplicate scan hashing the disk behind the user's back.
            let groups = await withCancelFlag { cancel in
                await DuplicateFinder.find(isCancelled: cancel.probe)
            }
            guard !Task.isCancelled else {
                dupPhase = .idle
                return
            }
            duplicateGroups = groups
            // Pre-select every copy except the newest — but only for groups
            // verified by full content hash; fingerprint-only giants require
            // an explicit opt-in per file.
            selectedDupes = Set(
                groups.filter { !$0.isFingerprintOnly }.flatMap { $0.paths.dropFirst() }
            )
            withAnimation(.spring) { dupPhase = .done }
        }
    }

    func cancelDuplicateScan() {
        dupTask?.cancel()
        dupTask = nil
        dupPhase = .idle
    }

    /// Trash selected copies; refuses to empty an entire group.
    ///
    /// The deletion runs off the main thread. It used to run on it, straight
    /// from the confirmation button: duplicates are 5 MB or larger by
    /// definition, the scan roots include Movies and Pictures, and those are
    /// commonly symlinked to an external drive — where `trashItem` becomes a
    /// full copy. A few GB of duplicates meant minutes of dead window.
    func trashSelectedDuplicates() {
        guard !trashing else { return }
        trashing = true
        var plan: [(group: DuplicateGroup, selected: [String])] = []
        var failures: [String] = []
        for group in duplicateGroups {
            let selected = group.paths.filter { selectedDupes.contains($0) }
            guard selected.count < group.paths.count else {
                failures.append(String(localized: "Kept 1 copy of \(group.paths.first ?? "?") — can't delete every copy."))
                continue
            }
            plan.append((group, selected))
        }
        let paths = plan.flatMap(\.selected)
        Task {
            defer { trashing = false }
            let outcome = await Blocking.run { Self.trash(paths) }
            failures.append(contentsOf: outcome.failures)
            finishTrashing(trashed: outcome.trashedPaths.count,
                           trashedPaths: outcome.trashedPaths,
                           failures: failures)
        }
    }

    var trashing = false

    private nonisolated static func trash(
        _ paths: [String]
    ) -> (trashedPaths: Set<String>, failures: [String]) {
        var trashedPaths: Set<String> = []
        var failures: [String] = []
        for path in paths {
            do {
                try FileManager.default.trashItem(
                    at: URL(fileURLWithPath: path), resultingItemURL: nil
                )
                trashedPaths.insert(path)
            } catch {
                failures.append("\((path as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (trashedPaths, failures)
    }

    private func finishTrashing(trashed: Int, trashedPaths: Set<String>, failures: [String]) {
        // Update the list in place — no need to rescan the whole disk.
        duplicateGroups = duplicateGroups.compactMap { group in
            let remaining = group.paths.filter { !trashedPaths.contains($0) }
            guard remaining.count > 1 else { return nil }
            return DuplicateGroup(id: group.id, fileSize: group.fileSize, paths: remaining)
        }
        selectedDupes.subtract(trashedPaths)
        dupResult = failures.isEmpty
            ? String(localized: "Moved \(trashed) duplicates to Trash.")
            : failures.joined(separator: "\n")
    }
}
