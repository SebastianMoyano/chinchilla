import Foundation
import Darwin

public struct LaunchAgent: Sendable, Identifiable, Hashable {
    public enum Domain: String, Sendable {
        case user     // ~/Library/LaunchAgents — actionable
        case global   // /Library/LaunchAgents — read-only (needs admin)
    }

    public var id: String { plistPath }
    public let plistPath: String
    public let label: String
    public let program: String?
    public let domain: Domain
    /// True when the plist is parked as ".plist.disabled" (won't load at login).
    public let isDisabled: Bool
    /// True when currently bootstrapped in launchd.
    public let isLoaded: Bool

    public var fileName: String { (plistPath as NSString).lastPathComponent }

    public func withLoaded(_ loaded: Bool) -> LaunchAgent {
        LaunchAgent(
            plistPath: plistPath, label: label, program: program,
            domain: domain, isDisabled: isDisabled, isLoaded: loaded
        )
    }
}

/// Lists and toggles login launch agents. Disabling = bootout from launchd +
/// renaming the plist to .plist.disabled (reversible, survives reboots).
///
/// Two-phase by design: `listAgents()` is pure file I/O and can never hang,
/// so the UI renders instantly; `loadedStatus(for:)` probes launchd in
/// parallel afterwards. The UI must never block on an external process.
public enum LaunchAgentManager {
    /// Synchronous plist parse — instant, no subprocesses. `isLoaded` is
    /// false pending a `loadedStatus` probe.
    public static func listAgents() -> [LaunchAgent] {
        var agents: [LaunchAgent] = []
        agents += scan(dir: NSHomeDirectory() + "/Library/LaunchAgents", domain: .user)
        agents += scan(dir: "/Library/LaunchAgents", domain: .global)
        return agents.sorted {
            ($0.domain.rawValue, $0.label.lowercased()) < ($1.domain.rawValue, $1.label.lowercased())
        }
    }

    private static func scan(dir: String, domain: LaunchAgent.Domain) -> [LaunchAgent] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var agents: [LaunchAgent] = []
        for entry in entries {
            let isDisabled = entry.hasSuffix(".plist.disabled")
            guard entry.hasSuffix(".plist") || isDisabled else { continue }
            let path = dir + "/" + entry
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dict = plist as? [String: Any] else { continue }
            let label = dict["Label"] as? String
                ?? (entry as NSString).deletingPathExtension
            let program = dict["Program"] as? String
                ?? (dict["ProgramArguments"] as? [String])?.first
            agents.append(LaunchAgent(
                plistPath: path,
                label: label,
                program: program,
                domain: domain,
                isDisabled: isDisabled,
                isLoaded: false
            ))
        }
        return agents
    }

    /// Probes launchd for each label in parallel, each with a short timeout.
    /// A slow or wedged launchctl costs at most one badge, never the list.
    public static func loadedStatus(for labels: [String]) async -> Set<String> {
        var loaded = Set<String>()
        await withTaskGroup(of: (String, Bool).self) { group in
            for label in labels {
                group.addTask {
                    (label, await isLoaded(label: label))
                }
            }
            for await (label, isUp) in group where isUp {
                loaded.insert(label)
            }
        }
        return loaded
    }

    public static func isLoaded(label: String) async -> Bool {
        let target = "gui/\(getuid())/\(label)"
        do {
            _ = try await ShellRunner.run("/bin/launchctl", ["print", target], timeout: .seconds(3))
            return true
        } catch {
            return false
        }
    }

    public struct AgentError: Error, Sendable, CustomStringConvertible {
        public let description: String
    }

    /// Unloads now and parks the plist so it won't load on next login.
    public static func disable(_ agent: LaunchAgent) async throws {
        guard agent.domain == .user else {
            throw AgentError(description: "System-wide agents need admin — manage them in their app's settings.")
        }
        guard !agent.label.hasPrefix("com.apple.") else {
            throw AgentError(description: "Apple agents are protected.")
        }
        // Bootout may fail if not currently loaded — that's fine.
        _ = try? await ShellRunner.run(
            "/bin/launchctl", ["bootout", "gui/\(getuid())/\(agent.label)"], timeout: .seconds(10)
        )
        let parked = agent.plistPath + ".disabled"
        do {
            try FileManager.default.moveItem(atPath: agent.plistPath, toPath: parked)
        } catch {
            throw AgentError(description: error.localizedDescription)
        }
    }

    /// Restores the plist and bootstraps it immediately.
    public static func enable(_ agent: LaunchAgent) async throws {
        guard agent.domain == .user, agent.isDisabled else {
            throw AgentError(description: "Agent is not disabled.")
        }
        let restored = String(agent.plistPath.dropLast(".disabled".count))
        do {
            try FileManager.default.moveItem(atPath: agent.plistPath, toPath: restored)
        } catch {
            throw AgentError(description: error.localizedDescription)
        }
        _ = try? await ShellRunner.run(
            "/bin/launchctl", ["bootstrap", "gui/\(getuid())", restored], timeout: .seconds(10)
        )
    }

    public static let loginItemsSettingsURL =
        "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
}
