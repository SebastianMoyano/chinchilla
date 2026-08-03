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
    var duplicateGroups: [DuplicateGroup] = []
    var selectedDupes: Set<String> = []
    var dupResult: String?
    private var dupTask: Task<Void, Never>?

    var selectedDupeBytes: Int64 {
        var total: Int64 = 0
        for group in duplicateGroups {
            total += group.fileSize * Int64(group.paths.count { selectedDupes.contains($0) })
        }
        return total
    }

    func startDuplicateScan() {
        guard dupPhase != .scanning else { return }
        dupPhase = .scanning
        dupResult = nil
        duplicateGroups = []
        dupTask = Task {
            let groups = await DuplicateFinder.find(isCancelled: { Task.isCancelled })
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
    func trashSelectedDuplicates() {
        var failures: [String] = []
        var trashed = 0
        var trashedPaths: Set<String> = []
        for group in duplicateGroups {
            let selected = group.paths.filter { selectedDupes.contains($0) }
            guard selected.count < group.paths.count else {
                failures.append(String(localized: "Kept 1 copy of \(group.paths.first ?? "?") — can't delete every copy."))
                continue
            }
            for path in selected {
                do {
                    try FileManager.default.trashItem(
                        at: URL(fileURLWithPath: path), resultingItemURL: nil
                    )
                    trashed += 1
                    trashedPaths.insert(path)
                } catch {
                    failures.append("\((path as NSString).lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
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
