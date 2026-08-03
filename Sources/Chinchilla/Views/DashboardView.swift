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
                DailyBoostCard()
                MemoryCard()
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
            appState.snapshots.refresh()
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
                snapshotRow
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var snapshotRow: some View {
        let model = appState.snapshots
        if !model.snapshots.isEmpty {
            HStack {
                Text("Local snapshots")
                    .foregroundStyle(.secondary)
                    .help("Time Machine keeps hourly snapshots on this disk. They can retain data you just deleted — macOS thins them automatically when space runs low.")
                Spacer()
                Text("\(model.snapshots.count)")
                    .monospacedDigit()
                if model.thinning {
                    ProgressView().controlSize(.mini)
                } else {
                    Button("Thin…") { model.thin() }
                        .controlSize(.mini)
                        .help("Asks macOS to thin local snapshots now (admin password required). macOS decides what's safe to remove.")
                }
            }
            .font(.callout)
            if let result = model.thinResult {
                Text(verbatim: result)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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
        VStack(alignment: .leading, spacing: 14) {
            Label("Too many tabs open?", systemImage: "square.on.square.dashed")
                .font(.headline)

            // 1 — Sleep background tabs (persistent switch)
            HStack(alignment: .top, spacing: 10) {
                stepBadge("1")
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Put background tabs to sleep")
                            .font(.callout.weight(.medium))
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
                    if model.policyBrowsers.isEmpty {
                        Text("Needs Chrome, Edge or Brave — none found.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("Tabs you're not looking at free their memory; they reload when you click them. Nothing closes, nothing is lost.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach(model.policyBrowsers) { state in
                                Label(state.browser.name, systemImage: state.memorySaverOn ? "checkmark.circle.fill" : "circle")
                                    .font(.caption2)
                                    .foregroundStyle(state.memorySaverOn ? .indigo : .secondary)
                            }
                            Text("· takes effect after restarting the browser")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if model.anySaverOn {
                            Text("Heads-up: the browser will say \"Managed by your organization\" while this is on. That's this switch — turn it off and the message disappears.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Divider()

            // 2 — Close duplicate tabs (one-time action)
            HStack(alignment: .top, spacing: 10) {
                stepBadge("2")
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Close repeated tabs")
                            .font(.callout.weight(.medium))
                        Spacer()
                        if model.closingTabs {
                            ProgressView().controlSize(.small)
                        }
                        Button("Close now") {
                            model.closeDuplicates()
                        }
                        .disabled(model.closingTabs)
                    }
                    Text("If the same page is open more than once (Chrome and Safari), keeps the first one and closes the copies.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let report = model.lastReport {
                        Text(verbatim: report)
                            .font(.caption)
                            .foregroundStyle(.indigo)
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { model.refresh() }
    }

    private func stepBadge(_ number: String) -> some View {
        Text(verbatim: number)
            .font(.caption.bold())
            .frame(width: 20, height: 20)
            .background(.indigo.opacity(0.15), in: Circle())
            .foregroundStyle(.indigo)
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
            if schedule.needsApproval {
                Button("Approve in Settings") { schedule.openLoginItemsSettings() }
                    .controlSize(.small)
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
