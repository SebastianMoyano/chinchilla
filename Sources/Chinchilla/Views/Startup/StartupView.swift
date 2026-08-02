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
                if !model.globalAgents.isEmpty {
                    globalCard(model)
                }
            }
            .padding(24)
        }
        .navigationTitle("Startup")
        .toolbar {
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.loading)
        }
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
                    Toggle(isOn: Binding(
                        get: { !agent.isDisabled },
                        set: { _ in model.toggle(agent) }
                    )) { EmptyView() }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(model.busyIDs.contains(agent.id) || agent.label.hasPrefix("com.apple."))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: agent.label)
                            .fontWeight(.medium)
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
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
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
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
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
