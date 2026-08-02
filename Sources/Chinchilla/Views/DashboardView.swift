import SwiftUI
import CleanCore

struct DiskUsage: Sendable {
    var total: Int64 = 0
    var available: Int64 = 0
    var availableImportant: Int64 = 0

    var used: Int64 { max(0, total - available) }
    var purgeable: Int64 { max(0, availableImportant - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func current() -> DiskUsage {
        var usage = DiskUsage()
        let url = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]) {
            usage.total = Int64(values.volumeTotalCapacity ?? 0)
            usage.available = Int64(values.volumeAvailableCapacity ?? 0)
            usage.availableImportant = values.volumeAvailableCapacityForImportantUsage ?? 0
        }
        return usage
    }
}

struct DashboardView: View {
    @Environment(AppState.self) private var appState
    @State private var usage = DiskUsage()
    @State private var lastClean: Cleaner.LastClean?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                SmartScanCard(usage: $usage)
                TabSaverCard()
                AutoCleanCard()
                HStack(alignment: .top, spacing: 16) {
                    diskCard
                    quickActions
                }
            }
            .padding(28)
        }
        .background(background)
        .onAppear {
            usage = DiskUsage.current()
            lastClean = Cleaner.lastClean()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hello 👋")
                    .font(.largeTitle.bold())
                Text("Your Mac at a glance")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let lastClean {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Last clean: \(Text(lastClean.freedBytes, format: .byteCount(style: .file)))")
                        .font(.callout.weight(.medium))
                    Text(lastClean.date, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var diskCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Startup Disk", systemImage: "internaldrive.fill")
                .font(.headline)
            Gauge(value: usage.usedFraction) {
                EmptyView()
            } currentValueLabel: {
                Text(usage.used, format: .byteCount(style: .file))
                    .font(.title3.bold())
                    .contentTransition(.numericText())
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .scaleEffect(1.4)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            VStack(alignment: .leading, spacing: 4) {
                statRow("Used", usage.used)
                statRow("Free", usage.available)
                statRow("Purgeable", usage.purgeable)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func statRow(_ title: LocalizedStringKey, _ bytes: Int64) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(bytes, format: .byteCount(style: .file))
                .monospacedDigit()
        }
        .font(.callout)
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Quick Actions", systemImage: "bolt.fill")
                .font(.headline)
            ForEach([SidebarItem.deepClean, .diskAnalyzer, .gaming, .devTools]) { item in
                QuickActionRow(item: item)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var background: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.12), .clear],
            startPoint: .top,
            endPoint: .center
        )
        .ignoresSafeArea()
    }
}

struct SmartScanCard: View {
    @Environment(AppState.self) private var appState
    @Binding var usage: DiskUsage

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Smart Scan", systemImage: "wand.and.stars")
                    .font(.headline)
                Text("One click: junk, Docker and old project artifacts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    appState.smartScan()
                } label: {
                    if appState.smartScanRunning {
                        ProgressView().controlSize(.small)
                            .frame(minWidth: 110)
                    } else {
                        Label(appState.smartScanDone ? "Scan Again" : "Smart Scan", systemImage: "sparkles")
                            .frame(minWidth: 110)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(appState.smartScanRunning)
            }
            if appState.smartScanDone {
                Divider().frame(height: 70)
                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.smartTotalBytes, format: .byteCount(style: .file))
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(.purple)
                        .contentTransition(.numericText())
                    Text("reclaimable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider().frame(height: 70)
                VStack(alignment: .leading, spacing: 5) {
                    smartRow("Safe junk", appState.smartCleanBytes, .deepClean)
                    smartRow("Docker", appState.smartDockerBytes, .devTools)
                    smartRow("Project artifacts", appState.smartArtifactBytes, .devTools)
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [.purple.opacity(0.14), .indigo.opacity(0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.purple.opacity(0.25), lineWidth: 1)
        )
    }

    private func smartRow(_ title: LocalizedStringKey, _ bytes: Int64, _ target: SidebarItem) -> some View {
        Button {
            appState.selection = target
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(bytes, format: .byteCount(style: .file))
                    .font(.caption.bold().monospacedDigit())
                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            .frame(minWidth: 180)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct TabSaverCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let model = appState.tabSaver
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "square.on.square.dashed")
                    .font(.title2)
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tab Saver")
                        .font(.callout.weight(.semibold))
                    Text("For tab hoarders: background tabs stop rendering and free their memory (the browser's own Memory Saver).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.anySaverOn },
                    set: { model.setAllMemorySavers($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(.indigo)
                .disabled(model.policyBrowsers.isEmpty)
            }
            HStack(spacing: 8) {
                if model.policyBrowsers.isEmpty {
                    Text("No Chromium browser (Chrome, Edge, Brave) found.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Applies to \(model.policyBrowsers.map(\.browser.name).joined(separator: ", ")) on next browser restart. The browser will show \"Managed by your organization\" while active — turning this off removes it completely.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if model.closingTabs {
                    ProgressView().controlSize(.small)
                }
                Button {
                    model.closeDuplicates()
                } label: {
                    Label("Close duplicate tabs", systemImage: "rectangle.on.rectangle.slash")
                }
                .disabled(model.closingTabs)
                .help("Chrome and Safari: closes tabs whose exact URL is already open, keeping one.")
            }
            if let report = model.lastReport {
                Text(verbatim: report)
                    .font(.caption)
                    .foregroundStyle(.indigo)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { model.refresh() }
    }
}

struct AutoCleanCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let schedule = appState.schedule
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.title2)
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("Weekly auto-clean")
                    .font(.callout.weight(.semibold))
                Text("Sundays at 12:00 — safe categories only, result in Notification Center and the clean log.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = schedule.errorMessage {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { schedule.isEnabled },
                set: { schedule.toggle($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(.teal)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct QuickActionRow: View {
    @Environment(AppState.self) private var appState
    let item: SidebarItem

    var body: some View {
        Button {
            appState.selection = item
        } label: {
            HStack {
                Image(systemName: item.icon)
                    .foregroundStyle(item.tint)
                    .frame(width: 24)
                Text(item.title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
