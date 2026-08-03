import SwiftUI
import Observation
import SystemKit

@MainActor
@Observable
final class StartupModel {
    var agents: [LaunchAgent] = []
    var loading = false
    var busyIDs: Set<String> = []
    var errorMessage: String?

    var userAgents: [LaunchAgent] { agents.filter { $0.domain == .user } }
    var globalAgents: [LaunchAgent] { agents.filter { $0.domain == .global } }

    func refresh() {
        guard !loading else { return }
        errorMessage = nil
        // Phase 1: pure file reads — the list renders instantly, always.
        agents = LaunchAgentManager.listAgents()
        // Phase 2: probe launchd in parallel; badges fill in when ready.
        loading = true
        Task {
            let labels = agents.filter { !$0.isDisabled }.map(\.label)
            let loaded = await LaunchAgentManager.loadedStatus(for: labels)
            agents = agents.map { $0.withLoaded(loaded.contains($0.label)) }
            loading = false
        }
    }

    // MARK: - Full startup inventory (BTM database, needs admin)

    struct BTMItem: Identifiable {
        let id = UUID()
        let name: String
        let developer: String?
        let type: String
        let enabled: Bool
    }

    var btmItems: [BTMItem] = []
    var btmLoading = false
    var btmError: String?

    /// Modern login items and daemons live in the Background Task Management
    /// database, which only `sfltool dumpbtm` (admin) can enumerate. Shown
    /// read-only — toggling belongs to System Settings, and we say so.
    func loadFullInventory() {
        guard !btmLoading else { return }
        btmLoading = true
        btmError = nil
        Task {
            defer { btmLoading = false }
            do {
                let output = try await PrivilegedRunner.run("/usr/bin/sfltool dumpbtm")
                btmItems = Self.parseBTM(output)
                if btmItems.isEmpty {
                    btmError = String(localized: "Couldn't read the startup database.")
                }
            } catch {
                btmError = String(localized: "Cancelled, or admin rights were denied.")
            }
        }
    }

    static func parseBTM(_ output: String) -> [BTMItem] {
        var items: [BTMItem] = []
        var name: String?
        var developer: String?
        var type = ""
        var enabled = false

        func flush() {
            if let n = name, !n.isEmpty, n != "(null)" {
                items.append(BTMItem(name: n, developer: developer, type: type, enabled: enabled))
            }
            name = nil
            developer = nil
            type = ""
            enabled = false
        }

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Name:") {
                flush()
                name = String(line.dropFirst("Name:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Developer Name:") {
                developer = String(line.dropFirst("Developer Name:".count)).trimmingCharacters(in: .whitespaces)
                if developer == "(null)" { developer = nil }
            } else if line.hasPrefix("Type:") {
                type = String(line.dropFirst("Type:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Disposition:") {
                enabled = line.contains("enabled")
            }
        }
        flush()
        return items.sorted { ($0.enabled ? 0 : 1, $0.name.lowercased()) < ($1.enabled ? 0 : 1, $1.name.lowercased()) }
    }

    func toggle(_ agent: LaunchAgent) {
        guard !busyIDs.contains(agent.id) else { return }
        busyIDs.insert(agent.id)
        errorMessage = nil
        Task {
            defer { busyIDs.remove(agent.id) }
            do {
                if agent.isDisabled {
                    try await LaunchAgentManager.enable(agent)
                } else {
                    try await LaunchAgentManager.disable(agent)
                }
            } catch {
                errorMessage = String(describing: error)
            }
            loading = false
            refresh()
        }
    }
}
