import SwiftUI
import SystemKit

/// Step 3 of the Tab Saver card: the per-tab intelligence that needs the
/// companion Chrome extension. Multi-profile aware: stats aggregate every
/// connected browser profile.
struct TabGuardSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let model = appState.tabGuard
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "3")
                .font(.caption.bold())
                .frame(width: 20, height: 20)
                .background(.indigo.opacity(0.15), in: Circle())
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Per-tab smarts (Tab Guard)")
                        .font(.callout.weight(.medium))
                    Spacer()
                    if model.isConnected {
                        Label("\(model.connections) profile(s)", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Button(model.isManifestInstalled ? "Finish setup…" : "Set up…") {
                            model.showingSetup = true
                        }
                        .controlSize(.small)
                    }
                }
                if model.isConnected {
                    Text("Sleeping tabs by real inactivity, cold-saving ancient ones. \(model.stats.tabs) tabs open · \(model.stats.discarded) asleep · \(model.stats.coldSavedCount) cold-saved (≈\(Text(model.stats.estSavedBytes, format: .byteCount(style: .memory))) freed, rough estimate).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.stats.coldSavedCount > 0 {
                        Button("Open cold-saved list") { model.openColdSaveList() }
                            .controlSize(.small)
                    }
                } else {
                    Text("A small optional Chrome extension that sleeps each tab based on when YOU last used it, and saves+closes tabs untouched for days (restorable anytime).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { model.showingSetup },
            set: { model.showingSetup = $0 }
        )) {
            TabGuardSetupSheet(model: model)
        }
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }
}

struct TabGuardSetupSheet: View {
    let model: TabGuardModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Set up Tab Guard", systemImage: "puzzlepiece.extension")
                .font(.title3.bold())

            step(1, done: model.isManifestInstalled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Install the connector")
                        .font(.callout.weight(.medium))
                    Text("Lets the extension talk to Chinchilla. One click, no admin needed.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.isManifestInstalled {
                        Button("Install connector") { model.installConnector() }
                            .buttonStyle(.borderedProminent)
                    }
                    if let error = model.setupError {
                        Text(verbatim: error).font(.caption).foregroundStyle(.red)
                    }
                }
            }

            step(2, done: model.isConnected) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Load the extension in Chrome")
                        .font(.callout.weight(.medium))
                    Text("Open chrome://extensions, turn on \"Developer mode\" (top right), click \"Load unpacked\" and pick the folder below. Repeat in each Chrome profile you use — extensions are per-profile.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let path = model.bundledExtensionPath {
                        HStack(spacing: 8) {
                            Text(verbatim: path)
                                .font(.caption2.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.tertiary)
                            Button("Copy path") { model.copyExtensionPath() }
                                .controlSize(.small)
                            Button("Show in Finder") { model.revealExtensionInFinder() }
                                .controlSize(.small)
                        }
                    }
                }
            }

            HStack {
                if model.isConnected {
                    Label("Connected — you're done!", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Waiting for the extension…", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { model.startPolling() }
    }

    private func step(_ number: Int, done: Bool, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title3)
                .foregroundStyle(done ? .green : .secondary)
            content()
            Spacer()
        }
    }
}
