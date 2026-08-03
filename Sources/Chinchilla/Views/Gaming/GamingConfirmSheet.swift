import SwiftUI

/// Pre-activation summary: exactly what gaming mode is about to do,
/// with a "don't ask again" escape hatch for repeat users.
struct GamingConfirmSheet: View {
    let model: GamingModel
    @AppStorage(GamingModel.skipConfirmKey) private var skipConfirm = false
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Ready to game?", systemImage: "gamecontroller.fill")
                .font(.title3.bold())

            if !model.closingCandidates.isEmpty {
                section(
                    icon: "xmark.circle", tint: .red,
                    title: "These apps will quit (gracefully — they can ask to save):",
                    names: model.closingCandidates.map(\.name)
                )
            }
            if !model.pausingCandidates.isEmpty {
                section(
                    icon: "pause.circle", tint: .orange,
                    title: "These will freeze in place and resume when you're done:",
                    names: model.pausingCandidates.map(\.name)
                )
            }
            if appState.tabGuard.isConnected {
                Label("Background browser tabs will sleep and background videos pause (Tab Guard).", systemImage: "square.on.square.dashed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Label("Mac stays awake · Time Machine backups pause · everything reverts when you turn gaming mode off.", systemImage: "checkmark.shield")
                .font(.callout)
                .foregroundStyle(.secondary)

            Toggle("Don't ask again — just do this next time", isOn: $skipConfirm)
                .font(.callout)

            HStack {
                Button("Cancel") { model.pendingConfirmation = false }
                Spacer()
                Button {
                    model.activate()
                } label: {
                    Label("Activate", systemImage: "gamecontroller.fill")
                        .frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func section(icon: String, tint: Color, title: LocalizedStringKey, names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.callout)
                .foregroundStyle(tint)
            Text(verbatim: names.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 26)
        }
    }
}
