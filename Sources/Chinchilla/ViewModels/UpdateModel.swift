import SwiftUI
import Observation
import AppKit
import SystemKit
import DiskScanKit

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
    /// The release notes, cleaned for the confirmation dialog. Release
    /// bodies are written with a plain-Spanish summary at the top precisely
    /// so this can show it — the reader is a teacher, not a git log.
    var availableNotes: String?
    var releaseURL = URL(string: "https://github.com/\(repo)/releases/latest")!
    /// Direct DMG asset of the latest release, when present.
    var dmgURL: URL?
    /// Transient feedback for the manual "Check for Updates…" menu item.
    var manualResult: String?

    enum InstallPhase: Equatable {
        case idle
        case downloading
        case installing
        case failed(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }
    var installPhase: InstallPhase = .idle

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
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }
            let tag_name: String
            let html_url: String
            let assets: [Asset]
            let body: String?
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
                dmgURL = release.assets
                    .first { $0.name.hasSuffix(".dmg") }
                    .flatMap { URL(string: $0.browser_download_url) }
                availableNotes = Self.displayNotes(from: release.body)
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

    /// The leading lines of the release body, stripped of markdown noise.
    /// A `---` line ends the summary — everything below it is changelog
    /// detail the dialog doesn't need.
    static func displayNotes(from body: String?) -> String? {
        guard let body, !body.isEmpty else { return nil }
        var kept: [String] = []
        for rawLine in body.replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("---") { break }
            while line.first == "#" { line.removeFirst() }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                line = "• " + line.dropFirst(2)
            }
            line = line.replacingOccurrences(of: "**", with: "")
            kept.append(line.trimmingCharacters(in: .whitespaces))
            if kept.count == 14 { break }
        }
        let text = kept.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(1_200))
    }

    // MARK: - One-click self-update

    /// Downloads the new DMG, verifies its Developer ID signature and team,
    /// swaps the app bundle in place and relaunches. Falls back to opening
    /// the release page on any failure.
    static let expectedTeamID = "8457F927YF"

    func installUpdate() {
        guard installPhase == .idle || installPhase.isFailure else { return }
        guard let dmgURL else {
            NSWorkspace.shared.open(releaseURL)
            return
        }
        installPhase = .downloading
        BusyDeadline.arm("Update.install", .seconds(900)) { [weak self] in
            switch self?.installPhase {
            case .downloading, .installing: true
            default: false
            }
        } clear: { [weak self] in
            self?.installPhase = .failed(
                String(localized: "Update failed — opening the download page instead.")
            )
        }
        Task {
            do {
                try await performInstall(from: dmgURL)
                // performInstall relaunches and terminates; nothing after this.
            } catch {
                installPhase = .failed(String(localized: "Update failed — opening the download page instead."))
                NSWorkspace.shared.open(releaseURL)
            }
        }
    }

    private struct UpdateError: Error {
        let reason: String
    }

    /// `URLSession.shared` gives a resource timeout of seven days. A download
    /// that stalls would leave the toolbar spinner turning for a week, and a
    /// spinner that never stops repaints the window at display rate — one
    /// core, indefinitely. Ten minutes is generous for a 20 MB DMG.
    private static let downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

    private func performInstall(from url: URL) async throws {
        // 1. Download.
        let (tempFile, _) = try await Self.downloadSession.download(from: url)
        let dmgPath = tempFile.deletingPathExtension().appendingPathExtension("dmg")
        try? FileManager.default.removeItem(at: dmgPath)
        try FileManager.default.moveItem(at: tempFile, to: dmgPath)
        installPhase = .installing

        // 2. Mount.
        let attachOutput = try await ShellRunner.run(
            "/usr/bin/hdiutil",
            ["attach", dmgPath.path, "-nobrowse", "-readonly", "-plist"],
            timeout: .seconds(60)
        )
        guard let mountPoint = Self.parseMountPoint(attachOutput) else {
            throw UpdateError(reason: "no mount point")
        }
        defer {
            Task {
                _ = try? await ShellRunner.run(
                    "/usr/bin/hdiutil", ["detach", mountPoint, "-force"], timeout: .seconds(30)
                )
            }
        }

        // 3. Locate and VERIFY the new app before touching anything.
        let newApp = mountPoint + "/Chinchilla.app"
        guard FileManager.default.fileExists(atPath: newApp) else {
            throw UpdateError(reason: "app missing from DMG")
        }
        _ = try await ShellRunner.run(
            "/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp], timeout: .seconds(60)
        )
        let signInfo = try await ShellRunner.runMerged(
            "/usr/bin/codesign", ["-dv", "--verbose=2", newApp], timeout: .seconds(30)
        )
        guard signInfo.contains("TeamIdentifier=\(Self.expectedTeamID)") else {
            throw UpdateError(reason: "unexpected signing team")
        }

        // 4. Swap in place (deleting a running bundle is fine — the executable
        //    stays mapped) and relaunch.
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else {
            throw UpdateError(reason: "not running from an app bundle")
        }
        // Copying a whole app bundle is not main-thread work; done here it
        // froze the window for the length of the swap, and looked like the
        // update had hung.
        let swap: Result<Void, Error> = await Blocking.run {
            do {
                try FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: newApp), to: target)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try swap.get()

        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", "sleep 1; /usr/bin/open \"\(target.path)\""]
        try relauncher.run()
        await NSApplication.shared.terminate(nil)
    }

    /// hdiutil -plist output → first mount point.
    static func parseMountPoint(_ plistXML: String) -> String? {
        guard let data = plistXML.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let entities = dict["system-entities"] as? [[String: Any]] else { return nil }
        return entities.compactMap { $0["mount-point"] as? String }.first
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
