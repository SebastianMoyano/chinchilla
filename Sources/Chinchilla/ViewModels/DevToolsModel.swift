import SwiftUI
import Observation
import AppKit
import SystemKit
import DiskScanKit

@MainActor
@Observable
final class DevToolsModel {
    // Docker
    enum DockerPhase: Equatable {
        case unknown
        case loading
        case notInstalled
        case daemonDown
        case ready
    }
    var dockerPhase: DockerPhase = .unknown
    var dockerUsage: [DockerCategoryUsage] = []
    var pruneRunning = false
    var lastPruneOutput: String?

    // Project artifacts
    var artifactsScanning = false
    var artifacts: [ProjectArtifact] = []
    var selectedArtifacts: Set<String> = []
    var artifactError: String?

    var selectedArtifactBytes: Int64 {
        artifacts.filter { selectedArtifacts.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    func refreshDocker() {
        dockerPhase = .loading
        BusyDeadline.arm("DevTools.docker", .seconds(60)) { [weak self] in
            self?.dockerPhase == .loading
        } clear: { [weak self] in
            // Docker not answering looks the same as Docker being down, and
            // that's the honest reading — the daemon isn't usable either way.
            self?.dockerPhase = .daemonDown
        }
        lastPruneOutput = nil
        Task {
            switch await DockerClient.state() {
            case .notInstalled:
                dockerPhase = .notInstalled
            case .daemonDown:
                dockerPhase = .daemonDown
            case .ready(let usage):
                dockerUsage = usage
                dockerPhase = .ready
            }
        }
    }

    func prune(_ action: DockerPruneAction) {
        guard !pruneRunning else { return }
        pruneRunning = true
        BusyDeadline.arm("DevTools.prune", .seconds(300)) { [weak self] in
            self?.pruneRunning ?? false
        } clear: { [weak self] in self?.pruneRunning = false }
        Task {
            defer { pruneRunning = false }
            do {
                let output = try await DockerClient.prune(action)
                lastPruneOutput = output.split(separator: "\n").last.map(String.init) ?? output
            } catch let error as ShellError {
                lastPruneOutput = error.stderr.isEmpty ? "exit \(error.exitCode)" : error.stderr
            } catch {
                lastPruneOutput = error.localizedDescription
            }
            refreshDocker()
        }
    }

    func openDockerApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.docker.docker") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.orbstack.OrbStack") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    func scanArtifacts() {
        guard !artifactsScanning else { return }
        artifactsScanning = true
        artifactError = nil
        Task {
            let found = await ArtifactFinder.find()
            artifacts = found
            // Pre-select nothing: deleting build artifacts always costs a
            // reinstall, so the user opts in per project.
            selectedArtifacts = []
            artifactsScanning = false
        }
    }

    /// Moves selected artifacts to Trash. Guard: the path must be a known
    /// artifact dir name with its project marker still present.
    /// `Task {}` inside a `@MainActor` class inherits the main actor, so this
    /// loop ran on the main thread despite looking asynchronous. Deleting a
    /// `node_modules` is tens of thousands of files.
    func trashSelectedArtifacts() {
        guard !trashingArtifacts else { return }
        trashingArtifacts = true
        let paths = artifacts.filter { selectedArtifacts.contains($0.id) }.map(\.path)
        Task {
            defer { trashingArtifacts = false }
            let failures = await Blocking.run { Self.trashArtifacts(paths) }
            artifactError = failures.isEmpty ? nil : failures.joined(separator: "\n")
            scanArtifacts()
        }
    }

    var trashingArtifacts = false

    private nonisolated static func trashArtifacts(_ paths: [String]) -> [String] {
        var failures: [String] = []
        for path in paths {
            let name = (path as NSString).lastPathComponent
            let isKnownKind = ArtifactKind.allCases.contains { $0.rawValue == name }
            guard isKnownKind, path.hasPrefix(NSHomeDirectory() + "/") else {
                failures.append(path)
                continue
            }
            do {
                try FileManager.default.trashItem(
                    at: URL(fileURLWithPath: path), resultingItemURL: nil
                )
            } catch {
                failures.append("\(path): \(error.localizedDescription)")
            }
        }
        return failures
    }

}
