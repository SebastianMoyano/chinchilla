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

    func refresh() {
        Task {
            snapshots = await TimeMachine.localSnapshots()
        }
    }

    func thin() {
        guard !thinning else { return }
        thinning = true
        thinResult = nil
        Task {
            defer { thinning = false }
            do {
                _ = try await TimeMachine.thinLocalSnapshots()
                thinResult = String(localized: "macOS thinned what it considered safe.")
            } catch {
                thinResult = String(localized: "Thinning was cancelled or failed.")
            }
            refresh()
        }
    }
}
