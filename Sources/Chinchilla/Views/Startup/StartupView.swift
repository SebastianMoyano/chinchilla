import SwiftUI
import AppKit
import SystemKit

struct StartupView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let model = appState.startup
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                loginItemsCard
                agentsCard(model)
                fullInventoryCard(model)
                if !model.globalAgents.isEmpty {
                    globalCard(model)
                }
            }
            .padding(24)
        }
        .navigationTitle("Startup")
        // Refresh lives in MainWindow's constant toolbar — see
        // ScreenToolbarItem for why screens don't add their own items.
        .onAppear {
            if model.agents.isEmpty { model.refresh() }
        }
    }

    private var loginItemsCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .foregroundStyle(.blue)
            Text("Apps that open at login are managed by macOS.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open Login Items") {
                if let url = URL(string: LaunchAgentManager.loginItemsSettingsURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func agentsCard(_ model: StartupModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your launch agents", systemImage: "power")
                .font(.headline)
            Text("Background helpers apps install for your user. Toggling off unloads them now and stops them from launching at login — flip it back anytime.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.loading && model.agents.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if model.userAgents.isEmpty {
                Text("No user launch agents. Clean! 🎉")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }

            ForEach(model.userAgents) { agent in
                HStack(spacing: 10) {
                    if LaunchAgentManager.isOwnAgent(agent.label) {
                        // Never hidden (that's what shady apps do) — locked,
                        // with an explanation of where it's actually managed.
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 26)
                            .help("This is Chinchilla itself (weekly clean / Everyday mode). It's managed from the Dashboard toggles — locked here so it can't be removed by accident.")
                    } else {
                        Toggle(isOn: Binding(
                            get: { !agent.isDisabled },
                            set: { _ in model.toggle(agent) }
                        )) { EmptyView() }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .disabled(model.busyIDs.contains(agent.id) || agent.label.hasPrefix("com.apple."))
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(verbatim: agent.label)
                                .fontWeight(.medium)
                            if LaunchAgentManager.isOwnAgent(agent.label) {
                                Text("Chinchilla — managed from the Dashboard")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.purple.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.purple)
                            }
                        }
                        if let program = agent.program {
                            Text(verbatim: program)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                    if model.busyIDs.contains(agent.id) {
                        ProgressView().controlSize(.small)
                    } else if agent.isDisabled {
                        badge("Off at login", .secondary)
                    } else if agent.isLoaded {
                        badge("Running", .green)
                    } else {
                        badge("Loads at login", .orange)
                    }
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: agent.plistPath)]
                        )
                    }
                }
            }

            if let error = model.errorMessage {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .card()
    }

    private func fullInventoryCard(_ model: StartupModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Everything that starts with your Mac", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                if model.btmLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button(model.btmItems.isEmpty ? "Show (admin)…" : "Refresh") {
                        model.loadFullInventory()
                    }
                }
            }
            Text("Modern login items and background daemons live in a database only readable with admin rights. Read-only — enable/disable them in System Settings → Login Items.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = model.btmError {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ForEach(model.btmItems.prefix(60)) { item in
                HStack(spacing: 8) {
                    Circle()
                        .fill(item.enabled ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Text(verbatim: item.name)
                                .font(.callout)
                            if item.name.lowercased().contains("chinchilla") {
                                Text("that's us")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.purple.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.purple)
                            }
                        }
                        if let developer = item.developer {
                            Text(verbatim: developer)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Text(verbatim: item.type)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 1)
            }
        }
        .card()
    }

    private func globalCard(_ model: StartupModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("System-wide agents (read-only)", systemImage: "building.columns")
                .font(.headline)
            Text("Installed for all users in /Library/LaunchAgents. Remove them from their app's own uninstaller or settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(model.globalAgents) { agent in
                HStack {
                    Text(verbatim: agent.label)
                        .font(.callout)
                    Spacer()
                    if agent.isLoaded {
                        badge("Running", .green)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .card()
    }

    private func badge(_ text: LocalizedStringKey, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
