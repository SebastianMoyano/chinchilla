import SwiftUI
import AppKit
import CleanCore

/// Leftovers from apps that were dragged to the Trash. Same shape as the
/// uninstall sheet — a checklist of paths with sizes — because it is the
/// same decision, just after the fact.
struct OrphansView: View {
    let model: UninstallerModel
    @State private var confirmingTrash = false

    var body: some View {
        switch model.orphanPhase {
        case .idle:
            explainer
        case .scanning:
            VStack(spacing: 14) {
                Spacer()
                ProgressView().controlSize(.large)
                Text("Comparing your Library with the apps you have installed…")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        case .done:
            if model.orphans.isEmpty {
                ContentUnavailableView {
                    Label("Nothing left behind", systemImage: "checkmark.circle")
                } description: {
                    Text("Every folder in your Library belongs to an app you still have.")
                } actions: {
                    Button("Look Again") { model.scanOrphans() }
                }
            } else {
                results
            }
        }
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Label("Leftovers from apps you deleted", systemImage: "questionmark.folder")
                .font(.title2.bold())
            // Numbered steps: the user has to trust this before they let it
            // delete anything, and "orphaned bundle identifiers" earns no trust.
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Chinchilla lists every app you have installed.")
                Text("2. It looks at the folders apps leave in your Library — settings, saved data, caches.")
                Text("3. Anything that belongs to an app you no longer have shows up here.")
                Text("4. You pick what goes. Everything moves to the Trash, so you can put it back.")
            }
            .foregroundStyle(.secondary)
            Text("When you drag an app to the Trash, these folders stay behind forever. Nothing is ticked for you — an app you plan to reinstall keeps its settings this way.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.scanOrphans()
            } label: {
                Label("Look for Leftovers", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: 560)
        .padding(30)
    }

    private var results: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.orphans) { orphan in
                    OrphanRow(model: model, orphan: orphan)
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedOrphanBytes, format: .byteCount(style: .file))
                        .font(.title3.bold().monospacedDigit())
                        .contentTransition(.numericText())
                    Text("selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let result = model.orphanResult {
                    Text(verbatim: result)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer()
                Button("Look Again") { model.scanOrphans() }
                Button {
                    confirmingTrash = true
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(model.selectedOrphans.isEmpty)
                .confirmationDialog(
                    "Move the leftovers of \(model.selectedOrphans.count) apps to the Trash? If one of them comes back, it will start with its settings reset.",
                    isPresented: $confirmingTrash,
                    titleVisibility: .visible
                ) {
                    Button("Move to Trash", role: .destructive) {
                        model.trashSelectedOrphans()
                    }
                }
            }
            .padding(14)
            .background(.bar)
        }
    }
}

private struct OrphanRow: View {
    let model: UninstallerModel
    let orphan: Orphan
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { model.selectedOrphans.contains(orphan.id) },
                set: { on in
                    if on {
                        model.selectedOrphans.insert(orphan.id)
                    } else {
                        model.selectedOrphans.remove(orphan.id)
                    }
                }
            )) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: orphan.displayName)
                            .fontWeight(.medium)
                        HStack(spacing: 6) {
                            Text(verbatim: orphan.bundleID)
                            Text("last changed \(Text(orphan.lastTouched, format: .relative(presentation: .named)))")
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(orphan.size, format: .byteCount(style: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                Label(
                    expanded ? "Hide the \(orphan.files.count) items" : "Show the \(orphan.files.count) items",
                    systemImage: expanded ? "chevron.down" : "chevron.right"
                )
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.leading, 22)

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(orphan.files) { file in
                        HStack(spacing: 6) {
                            Text(verbatim: file.kind.rawValue)
                                .font(.caption2.weight(.medium))
                            Text(verbatim: file.path)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(file.size, format: .byteCount(style: .file))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [URL(fileURLWithPath: file.path)]
                                )
                            }
                        }
                    }
                }
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, 3)
    }
}
