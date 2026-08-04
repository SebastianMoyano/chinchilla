import SwiftUI
import AppKit
import CleanCore

struct UninstallerView: View {
    @Environment(AppState.self) private var appState

    private enum Tab: String, CaseIterable, Identifiable {
        case installed, leftovers
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .installed: "Installed Apps"
            case .leftovers: "Leftovers"
            }
        }
    }

    @State private var tab: Tab = .installed

    var body: some View {
        @Bindable var model = appState.uninstaller
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .padding(.vertical, 8)
            Divider()

            switch tab {
            case .installed:
                installedList(model)
            case .leftovers:
                OrphansView(model: model)
            }
        }
        .navigationTitle("Uninstaller")
        .toolbar {
            Button {
                model.scan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.scanning)
        }
        .onAppear {
            if model.apps.isEmpty { model.scan() }
        }
        .sheet(item: $model.inspecting) { app in
            LeftoversSheet(model: model, app: app)
        }
    }

    @ViewBuilder
    private func installedList(_ model: UninstallerModel) -> some View {
        @Bindable var model = model
        if model.apps.isEmpty && model.scanning {
            ProgressView("Reading Applications…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(model.filteredApps) { app in
                    AppRow(model: model, app: app)
                }
            }
            .listStyle(.inset)
            .searchable(text: $model.searchText, prompt: "Search apps")
        }
    }
}

private struct AppRow: View {
    let model: UninstallerModel
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: app.name)
                if let bundleID = app.bundleID {
                    Text(verbatim: bundleID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(app.size, format: .byteCount(style: .file))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Uninstall…") {
                model.inspect(app)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
            }
        }
    }
}

private struct LeftoversSheet: View {
    let model: UninstallerModel
    let app: InstalledApp
    @State private var confirmingUninstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: app.name).font(.title3.bold())
                    Text("Everything goes to the Trash — you can put it back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isRunning(app) {
                    Button {
                        model.quit(app)
                    } label: {
                        Label("Quit app first", systemImage: "exclamationmark.triangle.fill")
                    }
                    .tint(.orange)
                }
            }

            Divider()

            List {
                Toggle(isOn: Binding(
                    get: { model.includeAppBundle },
                    set: { model.includeAppBundle = $0 }
                )) {
                    HStack {
                        Label {
                            Text(verbatim: app.path)
                                .lineLimit(1).truncationMode(.middle)
                        } icon: {
                            Image(systemName: "app.fill")
                        }
                        Spacer()
                        Text(app.size, format: .byteCount(style: .file))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                if model.leftovers.isEmpty {
                    Text("No leftovers found.")
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(model.leftovers) { leftover in
                        Toggle(isOn: Binding(
                            get: { model.selectedLeftovers.contains(leftover.id) },
                            set: { on in
                                if on {
                                    model.selectedLeftovers.insert(leftover.id)
                                } else {
                                    model.selectedLeftovers.remove(leftover.id)
                                }
                            }
                        )) {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: leftover.kind.rawValue)
                                        .font(.caption.weight(.medium))
                                    Text(verbatim: leftover.path)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(leftover.size, format: .byteCount(style: .file))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(minHeight: 220)

            if let result = model.lastResult {
                Text(verbatim: result)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel") { model.inspecting = nil }
                Spacer()
                Text(model.inspectedTotalBytes, format: .byteCount(style: .file))
                    .font(.callout.bold().monospacedDigit())
                Button {
                    confirmingUninstall = true
                } label: {
                    Label("Uninstall", systemImage: "trash")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.uninstalling || (model.isRunning(app) && model.includeAppBundle))
                .confirmationDialog(
                    "Uninstall \(app.name)? Everything goes to the Trash and can be put back.",
                    isPresented: $confirmingUninstall,
                    titleVisibility: .visible
                ) {
                    Button("Uninstall", role: .destructive) {
                        model.uninstall()
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
