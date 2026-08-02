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
        loading = true
        errorMessage = nil
        Task {
            agents = await LaunchAgentManager.list()
            loading = false
        }
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
            agents = await LaunchAgentManager.list()
        }
    }
}
