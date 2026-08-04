import SwiftUI
import AppKit
import Observation
import CleanCore

/// Thin front for `UserExclusions` — the file on disk stays the source of
/// truth, so a hand edit and a click in the UI can't disagree.
@MainActor
@Observable
final class ExclusionsModel {
    var entries: [UserExclusions.Entry] = []
    var errorMessage: String?

    var fileURL: URL { UserExclusions.fileURL }

    func refresh() {
        UserExclusions.reload()
        entries = UserExclusions.entries()
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Protect")
        panel.message = String(localized: "Chinchilla will never delete anything inside the folders you pick.")
        guard panel.runModal() == .OK else { return }
        apply { for url in panel.urls { try UserExclusions.add(url.path) } }
    }

    func remove(_ entry: UserExclusions.Entry) {
        apply { try UserExclusions.remove(entry) }
    }

    func revealFile() {
        let url = UserExclusions.fileURL
        // Nothing to reveal until the first entry creates the file.
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func apply(_ edit: () throws -> Void) {
        errorMessage = nil
        do {
            try edit()
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }
}
