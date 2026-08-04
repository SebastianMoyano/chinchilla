import SwiftUI
import CleanCore

extension CleanCategory {
    var displayTitle: LocalizedStringKey {
        switch self {
        case .userCaches: "App Caches"
        case .browsers: "Browser Caches"
        case .logs: "Logs"
        case .installers: "Old Installers"
        case .trash: "Trash"
        case .developer: "Developer Junk"
        }
    }

    var icon: String {
        switch self {
        case .userCaches: "internaldrive"
        case .browsers: "safari"
        case .logs: "doc.text"
        case .installers: "arrow.down.circle"
        case .trash: "trash"
        case .developer: "hammer"
        }
    }
}

extension Safety {
    var badge: (LocalizedStringKey, Color) {
        switch self {
        case .safe: ("Safe", .green)
        case .moderate: ("Review", .orange)
        case .caution: ("Caution", .red)
        }
    }
}

struct DeepCleanView: View {
    @Environment(AppState.self) private var appState
    @State private var showExclusions = false

    var body: some View {
        let model = appState.deepClean
        VStack(spacing: 0) {
            if !model.hasFullDiskAccess, model.phase != .idle {
                FullDiskAccessBanner()
            }
            switch model.phase {
            case .idle:
                idleView(model)
            case .scanning:
                VStack(spacing: 14) {
                    Spacer()
                    ProgressView().controlSize(.large)
                    Text("Scanning caches, logs and leftovers…")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            case .review, .cleaning:
                reviewView(model)
            case .summary:
                summaryView(model)
            }
        }
        .navigationTitle("Deep Clean")
        .toolbar {
            Button {
                showExclusions = true
            } label: {
                Label("Protected Folders", systemImage: "lock.shield")
            }
            .help("Folders Chinchilla will never touch")
        }
        .sheet(isPresented: $showExclusions) { ExclusionsView() }
    }

    private func idleView(_ model: DeepCleanModel) -> some View {
        ContentUnavailableView {
            Label("Deep Clean", systemImage: "sparkles")
        } description: {
            Text("Find caches, logs, old installers and developer junk. Nothing is deleted without your review.")
        } actions: {
            Button {
                model.scan()
            } label: {
                Label("Scan", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: Review

    private func reviewView(_ model: DeepCleanModel) -> some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            List {
                ForEach(model.categories) { category in
                    CategorySection(model: model, category: category)
                }
            }
            .listStyle(.inset)
            .disabled(model.phase == .cleaning)
            Divider()
            footer(model)
        }
    }

    private func footer(_ model: DeepCleanModel) -> some View {
        @Bindable var model = model
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedBytes, format: .byteCount(style: .file))
                    .font(.title3.bold().monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.default, value: model.selectedBytes)
                Text("selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: $model.dryRun) {
                Label("Preview only", systemImage: "eye")
                    .help("When on, nothing is deleted — you get a report of what would be removed.")
            }
            .toggleStyle(.switch)
            if model.phase == .cleaning {
                ProgressView().controlSize(.small)
            }
            Button {
                model.clean()
            } label: {
                Label(
                    model.dryRun ? "Preview Clean" : "Clean Now",
                    systemImage: model.dryRun ? "eye" : "sparkles"
                )
                .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.dryRun ? .blue : .purple)
            .disabled(model.selectedItems.isEmpty || model.phase == .cleaning)
        }
        .padding(14)
        .background(.bar)
    }

    // MARK: Summary

    private func summaryView(_ model: DeepCleanModel) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: model.outcome?.dryRun == true ? "eye.fill" : "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(model.outcome?.dryRun == true ? .blue : .green)
            Text(model.outcome?.dryRun == true ? "Preview complete" : "Clean complete")
                .font(.title2.bold())
            if let outcome = model.outcome {
                Text(outcome.freedBytes, format: .byteCount(style: .file))
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                    .foregroundStyle(.purple)
                Text(outcome.dryRun ? "would be freed" : "freed")
                    .foregroundStyle(.secondary)
                if model.skippedForRunningApps > 0 {
                    Label("\(model.skippedForRunningApps) items skipped — their app was running", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if outcome.dryRun == false, !appState.snapshots.snapshots.isEmpty {
                    Text("Finder may take a while to reflect this: \(appState.snapshots.snapshots.count) local Time Machine snapshots and purgeable space can hold on to deleted data. See the Dashboard for details.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
                if !outcome.failures.isEmpty {
                    DisclosureGroup {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(outcome.failures) { failure in
                                    Text(verbatim: "\(failure.path) — \(failure.reason)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxHeight: 140)
                    } label: {
                        Label("\(outcome.failures.count) items skipped", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .frame(maxWidth: 480)
                }
            }
            HStack {
                Button("Done") { model.backToIdle() }
                if model.outcome?.dryRun == true {
                    Button("Scan Again") { model.scan() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 6)
            Spacer()
        }
        .padding()
    }
}

private struct CategorySection: View {
    let model: DeepCleanModel
    let category: CleanCategory

    var body: some View {
        let items = model.report.items(in: category)
        let selectedCount = items.count { model.selected.contains($0.id) }
        let bytes = items.reduce(Int64(0)) { $0 + $1.size }

        Section {
            ForEach(items.prefix(60)) { item in
                ItemRow(model: model, item: item)
            }
            if items.count > 60 {
                Text("…and \(items.count - 60) more")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } header: {
            HStack {
                Toggle(isOn: Binding(
                    get: { selectedCount == items.count && !items.isEmpty },
                    set: { _ in model.toggleCategory(category) }
                )) {
                    Label(category.displayTitle, systemImage: category.icon)
                        .font(.headline)
                }
                .toggleStyle(.checkbox)
                if selectedCount > 0 && selectedCount < items.count {
                    Text("\(selectedCount)/\(items.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(bytes, format: .byteCount(style: .file))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ItemRow: View {
    let model: DeepCleanModel
    let item: CleanItem

    var body: some View {
        let conflict = model.itemHasConflict(item)
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { model.selected.contains(item.id) },
                set: { on in
                    if on { model.selected.insert(item.id) } else { model.selected.remove(item.id) }
                }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.name)
                    .lineLimit(1)
                Text(verbatim: item.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if conflict {
                Label("App is running", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
            }
            Spacer()
            let (text, color) = item.safety.badge
            Text(text)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
            Text(item.size, format: .byteCount(style: .file))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .trailing)
        }
    }
}
