import SwiftUI
import DiskScanKit
import SystemKit
import AppKit

struct DiskAnalyzerView: View {
    @Environment(AppState.self) private var appState

    private enum Tab: String, CaseIterable, Identifiable {
        case folders, treemap, largeFiles, duplicates
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .folders: "Folders"
            case .treemap: "Treemap"
            case .largeFiles: "Large Files"
            case .duplicates: "Duplicates"
            }
        }
    }

    @State private var tab: Tab = .folders

    var body: some View {
        let model = appState.diskAnalyzer
        VStack(spacing: 0) {
            if !model.hasFullDiskAccess {
                FullDiskAccessBanner()
            }
            HStack {
                if tab != .duplicates, model.phase == .done {
                    BreadcrumbView(model: model)
                }
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                if tab != .duplicates, model.phase == .done {
                    Button {
                        model.startScan()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Rescan")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            Divider()

            if tab == .duplicates {
                DuplicatesView(model: model)
            } else {
                switch model.phase {
                case .idle:
                    idleView(model)
                case .scanning:
                    scanningView(model)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Scan failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(verbatim: message)
                    } actions: {
                        Button("Try Again") { model.startScan() }
                    }
                case .done:
                    switch tab {
                    case .folders: FolderListView(model: model)
                    case .treemap: TreemapView(model: model)
                    case .largeFiles: LargeFilesView(files: model.largeFiles)
                    case .duplicates: EmptyView()
                    }
                }
            }
        }
        .navigationTitle("Disk Space")
        .onAppear { model.refreshPermissions() }
    }

    private func idleView(_ model: DiskAnalyzerModel) -> some View {
        ContentUnavailableView {
            Label("Disk Space", systemImage: "chart.pie.fill")
        } description: {
            Text("Scan your home folder to see what's taking up space.")
        } actions: {
            Button {
                model.startScan()
            } label: {
                Label("Scan Home Folder", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func scanningView(_ model: DiskAnalyzerModel) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(model.scannedBytes, format: .byteCount(style: .file))
                .font(.title2.bold().monospacedDigit())
                .contentTransition(.numericText())
                .animation(.default, value: model.scannedBytes)
            Text(verbatim: model.currentPath)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 420)
            Button("Cancel", role: .cancel) { model.cancelScan() }
            Spacer()
        }
        .padding()
    }

}

struct DuplicatesView: View {
    let model: DiskAnalyzerModel

    var body: some View {
        switch model.dupPhase {
        case .idle:
            ContentUnavailableView {
                Label("Duplicates", systemImage: "doc.on.doc")
            } description: {
                Text("Find identical files (≥5 MB) in Desktop, Documents, Downloads, Movies, Music and Pictures. Compared by content, not name.")
            } actions: {
                Button {
                    model.startDuplicateScan()
                } label: {
                    Label("Find Duplicates", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        case .scanning:
            VStack(spacing: 14) {
                Spacer()
                ProgressView().controlSize(.large)
                Text("Hashing candidate files…")
                    .foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { model.cancelDuplicateScan() }
                Spacer()
            }
        case .done:
            if model.duplicateGroups.isEmpty {
                ContentUnavailableView {
                    Label("No duplicates", systemImage: "checkmark.circle")
                } description: {
                    Text("No identical files above 5 MB were found.")
                } actions: {
                    Button("Scan Again") { model.startDuplicateScan() }
                }
            } else {
                VStack(spacing: 0) {
                    List {
                        ForEach(model.duplicateGroups) { group in
                            DuplicateGroupSection(model: model, group: group)
                        }
                    }
                    .listStyle(.inset)
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.selectedDupeBytes, format: .byteCount(style: .file))
                                .font(.title3.bold().monospacedDigit())
                                .contentTransition(.numericText())
                            Text("selected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let result = model.dupResult {
                            Text(verbatim: result)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button("Scan Again") { model.startDuplicateScan() }
                        Button {
                            model.trashSelectedDuplicates()
                        } label: {
                            Label("Move to Trash", systemImage: "trash")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(model.selectedDupes.isEmpty)
                    }
                    .padding(14)
                    .background(.bar)
                }
            }
        }
    }
}

private struct DuplicateGroupSection: View {
    let model: DiskAnalyzerModel
    let group: DuplicateGroup

    var body: some View {
        Section {
            ForEach(Array(group.paths.enumerated()), id: \.element) { index, path in
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { model.selectedDupes.contains(path) },
                        set: { on in
                            if on {
                                model.selectedDupes.insert(path)
                            } else {
                                model.selectedDupes.remove(path)
                            }
                        }
                    )) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(verbatim: (path as NSString).lastPathComponent)
                                .lineLimit(1)
                            if index == 0 {
                                Text("newest")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.green.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.green)
                            }
                        }
                        Text(verbatim: path)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }
                .contextMenu {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
            }
        } header: {
            HStack {
                Label("\(group.count) copies", systemImage: "doc.on.doc")
                    .font(.headline)
                Spacer()
                Text("wastes \(Text(group.wastedBytes, format: .byteCount(style: .file)))")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct BreadcrumbView: View {
    let model: DiskAnalyzerModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button {
                    model.jump(to: nil)
                } label: {
                    Label {
                        Text(verbatim: model.root?.name ?? "~")
                    } icon: {
                        Image(systemName: "house.fill")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.breadcrumb.isEmpty ? .primary : .secondary)

                ForEach(Array(model.breadcrumb.enumerated()), id: \.element.id) { index, node in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Button {
                        model.jump(to: index)
                    } label: {
                        Text(verbatim: node.name)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == model.breadcrumb.count - 1 ? .primary : .secondary)
                }
            }
            .font(.callout)
        }
    }
}

struct FolderListView: View {
    let model: DiskAnalyzerModel

    var body: some View {
        if let dir = model.displayed {
            let maxSize = dir.children.first?.size ?? 1
            List {
                ForEach(dir.children) { child in
                    FileNodeRow(node: child, fraction: Double(child.size) / Double(max(maxSize, 1))) {
                        model.drillDown(into: child)
                    }
                }
                if dir.remainder > 0 {
                    HStack {
                        Label("Everything smaller", systemImage: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(dir.remainder, format: .byteCount(style: .file))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)
        }
    }
}

struct FileNodeRow: View {
    let node: FileNode
    let fraction: Double
    let onOpen: () -> Void

    private var canDescend: Bool {
        node.isDirectory && !node.isPackage && !node.children.isEmpty
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(node.isDirectory ? Color.orange : Color.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: node.name)
                        .lineLimit(1)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.orange.opacity(0.75))
                            .frame(width: max(2, geo.size.width * fraction), height: 4)
                    }
                    .frame(height: 4)
                }
                Spacer()
                Text(node.size, format: .byteCount(style: .file))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if canDescend {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
            }
        }
    }

    private var icon: String {
        if node.isPackage { return "shippingbox" }
        return node.isDirectory ? "folder.fill" : "doc"
    }
}

struct LargeFilesView: View {
    let files: [LargeFile]

    var body: some View {
        if files.isEmpty {
            ContentUnavailableView {
                Label("No large files", systemImage: "checkmark.circle")
            } description: {
                Text("Nothing above 100 MB was found.")
            }
        } else {
            List(files) { file in
                HStack(spacing: 10) {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: file.name).lineLimit(1)
                        Text(verbatim: file.path)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(file.size, format: .byteCount(style: .file))
                            .monospacedDigit()
                        Text(file.modified, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contextMenu {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

struct FullDiskAccessBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text("Full Disk Access is off")
                    .font(.callout.weight(.semibold))
                Text("Some folders can't be measured or cleaned without it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") {
                if let url = URL(string: Permissions.fullDiskAccessSettingsURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.12))
    }
}
