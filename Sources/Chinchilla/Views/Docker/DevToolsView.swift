import SwiftUI
import SystemKit
import DiskScanKit

struct DevToolsView: View {
    @Environment(AppState.self) private var appState
    @State private var confirmingAction: DockerPruneAction?
    @State private var confirmingArtifactTrash = false

    var body: some View {
        let model = appState.devTools
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                dockerCard(model)
                artifactsCard(model)
                devCachesHint
            }
            .padding(24)
        }
        .navigationTitle("Docker & Dev")
        .onAppear {
            if model.dockerPhase == .unknown { model.refreshDocker() }
            if model.artifacts.isEmpty, !model.artifactsScanning { model.scanArtifacts() }
        }
        .confirmationDialog(
            "This removes data Docker will have to re-download or rebuild.",
            isPresented: Binding(
                get: { confirmingAction != nil },
                set: { if !$0 { confirmingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = confirmingAction {
                Button(action == .volumes ? "Delete Unused Volumes" : "Prune", role: .destructive) {
                    model.prune(action)
                    confirmingAction = nil
                }
            }
        }
    }

    // MARK: Docker

    @ViewBuilder
    private func dockerCard(_ model: DevToolsModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Docker", systemImage: "shippingbox.fill")
                    .font(.headline)
                Spacer()
                Button {
                    model.refreshDocker()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.dockerPhase == .loading)
            }

            switch model.dockerPhase {
            case .unknown, .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .notInstalled:
                Label("Docker CLI not found", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            case .daemonDown:
                HStack {
                    Label("Docker isn't running", systemImage: "moon.zzz.fill")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Docker") { model.openDockerApp() }
                }
            case .ready:
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("Category").font(.caption).foregroundStyle(.secondary)
                        Text("Items").font(.caption).foregroundStyle(.secondary)
                        Text("Size").font(.caption).foregroundStyle(.secondary)
                        Text("Reclaimable").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.dockerUsage) { usage in
                        GridRow {
                            Text(verbatim: usage.type).fontWeight(.medium)
                            Text(verbatim: "\(usage.active)/\(usage.totalCount)")
                                .monospacedDigit().foregroundStyle(.secondary)
                            Text(verbatim: usage.size).monospacedDigit()
                            Text(verbatim: usage.reclaimable)
                                .monospacedDigit().foregroundStyle(.orange)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        model.prune(.safePrune)
                    } label: {
                        Label("Safe Prune", systemImage: "sparkles")
                    }
                    .help("Stopped containers, dangling images, unused networks and dangling build cache. Always safe.")
                    Button("Deep Prune") { confirmingAction = .deepPrune }
                        .help("Also removes every image not used by any container — they'll re-download on next run.")
                    Button("Build Cache") { model.prune(.builderCache) }
                        .help("BuildKit layer cache.")
                    Button("Volumes…") { confirmingAction = .volumes }
                        .help("Unused anonymous volumes. Data inside them is lost — review first.")
                    if model.pruneRunning { ProgressView().controlSize(.small) }
                }
                .disabled(model.pruneRunning)
                if let output = model.lastPruneOutput {
                    Text(verbatim: output)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Project artifacts

    @ViewBuilder
    private func artifactsCard(_ model: DevToolsModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Project Artifacts", systemImage: "folder.badge.gearshape")
                    .font(.headline)
                Spacer()
                if model.artifactsScanning {
                    ProgressView().controlSize(.small)
                }
                Button {
                    model.scanArtifacts()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.artifactsScanning)
            }
            Text("node_modules, Rust targets, virtualenvs and Pods in your project folders. Deleting them is safe — the next install/build recreates them.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.artifacts.isEmpty, !model.artifactsScanning {
                Text("No artifacts found.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(model.artifacts.prefix(40)) { artifact in
                    artifactRow(model, artifact)
                }
            }

            if let error = model.artifactError {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !model.selectedArtifacts.isEmpty {
                HStack {
                    Text(model.selectedArtifactBytes, format: .byteCount(style: .file))
                        .font(.callout.bold().monospacedDigit())
                    Text("selected")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        confirmingArtifactTrash = true
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .confirmationDialog(
                        "Move the selected build artifacts to the Trash? The next install/build recreates them.",
                        isPresented: $confirmingArtifactTrash,
                        titleVisibility: .visible
                    ) {
                        Button("Move to Trash", role: .destructive) {
                            model.trashSelectedArtifacts()
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func artifactRow(_ model: DevToolsModel, _ artifact: ProjectArtifact) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { model.selectedArtifacts.contains(artifact.id) },
                set: { on in
                    if on {
                        model.selectedArtifacts.insert(artifact.id)
                    } else {
                        model.selectedArtifacts.remove(artifact.id)
                    }
                }
            )) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: artifact.projectName).fontWeight(.medium)
                    Text(verbatim: artifact.kind)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.cyan.opacity(0.15), in: Capsule())
                        .foregroundStyle(.cyan)
                }
                Text(verbatim: artifact.projectPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(artifact.size, format: .byteCount(style: .file))
                    .monospacedDigit()
                Text(artifact.lastTouched, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var devCachesHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb")
                .foregroundStyle(.yellow)
            Text("npm, Homebrew, Xcode and other tool caches live in Deep Clean → Developer Junk.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open Deep Clean") { appState.selection = .deepClean }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}
