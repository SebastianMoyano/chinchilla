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
    func trashSelectedArtifacts() {
        let toTrash = artifacts.filter { selectedArtifacts.contains($0.id) }
        Task {
            var failures: [String] = []
            for artifact in toTrash {
                let name = (artifact.path as NSString).lastPathComponent
                let isKnownKind = ArtifactKind.allCases.contains { $0.rawValue == name }
                guard isKnownKind, artifact.path.hasPrefix(NSHomeDirectory() + "/") else {
                    failures.append(artifact.path)
                    continue
                }
                do {
                    try FileManager.default.trashItem(
                        at: URL(fileURLWithPath: artifact.path), resultingItemURL: nil
                    )
                } catch {
                    failures.append("\(artifact.path): \(error.localizedDescription)")
                }
            }
            artifactError = failures.isEmpty ? nil : failures.joined(separator: "\n")
            scanArtifacts()
        }
    }
}
