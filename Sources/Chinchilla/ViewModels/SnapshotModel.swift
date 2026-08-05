import SwiftUI
import Observation
import SystemKit

/// APFS honesty: local Time Machine snapshots can retain data the user just
/// "deleted", and purgeable space makes Finder's numbers lag. We surface
/// both instead of letting the freed-bytes claim look broken.
@MainActor
@Observable
final class SnapshotModel {
    var snapshots: [String] = []
    var thinning = false
    var thinResult: String?

    private var lastRefresh: Date?

    /// Rate-limited: `tmutil` spawns a process, and the Dashboard — the
    /// default tab — asks on every appearance. Snapshots are made hourly, so
    /// a five-minute-old answer is still the truth. `force` is for the one
    /// caller that just changed them (thinning).
    func refresh(force: Bool = false) {
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 300 { return }
        lastRefresh = Date()
        Task {
            snapshots = await TimeMachine.localSnapshots()
        }
    }

    func thin() {
        guard !thinning else { return }
        thinning = true
        BusyDeadline.arm("Snapshots.thinning", .seconds(300)) { [weak self] in
            self?.thinning ?? false
        } clear: { [weak self] in self?.thinning = false }
        thinResult = nil
        Task {
            defer { thinning = false }
            do {
                _ = try await TimeMachine.thinLocalSnapshots()
                thinResult = String(localized: "macOS thinned what it considered safe.")
            } catch {
                thinResult = String(localized: "Thinning was cancelled or failed.")
            }
            refresh(force: true)
        }
    }
}
