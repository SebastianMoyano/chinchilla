import Foundation

public struct DockerCategoryUsage: Sendable, Identifiable, Decodable {
    public var id: String { type }
    public let type: String
    public let totalCount: String
    public let active: String
    public let size: String
    public let reclaimable: String

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case totalCount = "TotalCount"
        case active = "Active"
        case size = "Size"
        case reclaimable = "Reclaimable"
    }
}

public enum DockerState: Sendable {
    case notInstalled
    case daemonDown
    case ready([DockerCategoryUsage])
}

public enum DockerPruneAction: String, Sendable, CaseIterable, Identifiable {
    /// Stopped containers, dangling images, unused networks, dangling build cache.
    case safePrune
    /// Also removes ALL unused images (re-pull cost).
    case deepPrune
    /// BuildKit cache layers.
    case builderCache
    /// Unused anonymous volumes — data loss possible.
    case volumes

    public var id: String { rawValue }

    var arguments: [String] {
        switch self {
        case .safePrune: ["system", "prune", "-f"]
        case .deepPrune: ["system", "prune", "-a", "-f"]
        case .builderCache: ["builder", "prune", "-f"]
        case .volumes: ["volume", "prune", "-f"]
        }
    }
}

public enum DockerClient {
    public static func binaryPath() -> String? {
        let candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func state() async -> DockerState {
        guard let docker = binaryPath() else { return .notInstalled }
        do {
            // Docker CLI hangs while Desktop is mid-start; keep the timeout short.
            _ = try await ShellRunner.run(docker, ["info", "--format", "{{.ServerVersion}}"], timeout: .seconds(5))
        } catch {
            return .daemonDown
        }
        do {
            let output = try await ShellRunner.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: .seconds(30))
            let decoder = JSONDecoder()
            let usages = output.split(separator: "\n").compactMap { line in
                try? decoder.decode(DockerCategoryUsage.self, from: Data(line.utf8))
            }
            return .ready(usages)
        } catch {
            return .daemonDown
        }
    }

    /// Runs a prune and returns docker's own report (includes reclaimed space).
    public static func prune(_ action: DockerPruneAction) async throws -> String {
        guard let docker = binaryPath() else {
            throw ShellError(exitCode: -1, stderr: "docker not installed")
        }
        return try await ShellRunner.run(docker, action.arguments, timeout: .seconds(300))
    }

}

public extension DockerCategoryUsage {
    /// Parses docker's human "4.2GB (42%)" into bytes (SI units, as docker
    /// prints them). Returns 0 when unparseable.
    var reclaimableBytes: Int64 {
        Self.parseSize(reclaimable)
    }

    static func parseSize(_ text: String) -> Int64 {
        let scanner = Foundation.Scanner(string: text)
        guard let value = scanner.scanDouble() else { return 0 }
        let unit = scanner.scanCharacters(from: .letters)?.uppercased() ?? "B"
        let multiplier: Double = switch unit {
        case "B": 1
        case "KB": 1e3
        case "MB": 1e6
        case "GB": 1e9
        case "TB": 1e12
        default: 0
        }
        return Int64(value * multiplier)
    }
}
