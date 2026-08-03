import SwiftUI
import Observation

/// Passive update check against GitHub Releases — no frameworks, no dialogs.
/// When a newer version exists, MainWindow shows a quiet capsule up top that
/// links to the release page. That's it.
@MainActor
@Observable
final class UpdateModel {
    static let repo = "SebastianMoyano/chinchilla"
    static let sponsorURL = URL(string: "https://github.com/sponsors/SebastianMoyano")!
    private static let lastCheckKey = "updates.lastCheck"

    var availableVersion: String?
    var releaseURL = URL(string: "https://github.com/\(repo)/releases/latest")!
    /// Transient feedback for the manual "Check for Updates…" menu item.
    var manualResult: String?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Quiet check, at most once an hour (daily was too slow — releases went
    /// unseen for a day). Failures are silent — an update check must never
    /// bother anyone. Skipped entirely for unbundled (`swift run`) builds,
    /// whose version reads as "0".
    func checkIfStale() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date.now.timeIntervalSince1970 - last > 3_600 else { return }
        Task { await check(manual: false) }
    }

    func checkNow() {
        manualResult = nil
        Task { await check(manual: true) }
    }

    private func check(manual: Bool) async {
        struct Release: Decodable {
            let tag_name: String
            let html_url: String
        }
        do {
            var request = URLRequest(
                url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
            )
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10
            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try JSONDecoder().decode(Release.self, from: data)
            // Stamp only on success — a transient offline moment shouldn't
            // suppress checks for a whole day.
            UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: Self.lastCheckKey)
            let latest = release.tag_name.hasPrefix("v")
                ? String(release.tag_name.dropFirst())
                : release.tag_name
            if Self.isNewer(latest, than: currentVersion) {
                releaseURL = URL(string: release.html_url) ?? releaseURL
                withAnimation { availableVersion = latest }
                if manual { manualResult = nil }
            } else if manual {
                manualResult = String(localized: "You're up to date (\(currentVersion)).")
            }
        } catch {
            if manual {
                manualResult = String(localized: "Couldn't check for updates.")
            }
        }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
