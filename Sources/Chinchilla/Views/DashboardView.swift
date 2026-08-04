import SwiftUI
import CleanCore
import SystemKit

struct DiskUsage: Sendable {
    var total: Int64 = 0
    var available: Int64 = 0
    var availableImportant: Int64 = 0

    var used: Int64 { max(0, total - available) }
    var purgeable: Int64 { max(0, availableImportant - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    /// A verdict, not a number — the number is already in the ring.
    var headline: LocalizedStringKey {
        switch usedFraction {
        case ..<0.8: "Plenty of room"
        case ..<0.92: "Filling up"
        default: "Almost full"
        }
    }

    var subtitle: LocalizedStringKey {
        switch usedFraction {
        case ..<0.8: "Nothing urgent. A clean now and then keeps it that way."
        case ..<0.92: "Worth a clean soon — macOS slows down when the disk gets tight."
        default: "macOS needs free space to work properly. Clean now, or move something off."
        }
    }

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
            VStack(alignment: .leading, spacing: Theme.sectionGap) {
                header
                hero
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

    /// The mockups lead with one number the size of a headline and a ring
    /// around it. That's the whole point of a dashboard: the state of the
    /// machine should land before you read a word.
    private var hero: some View {
        HStack(alignment: .center, spacing: 28) {
            DiskRing(usage: usage, diameter: 190)
            VStack(alignment: .leading, spacing: 10) {
                Text(usage.headline)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.onSurface)
                Text(usage.subtitle)
                    .font(.callout)
                    .foregroundStyle(Theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    metric("Free", usage.available, Theme.ok)
                    metric("Used", usage.used, Theme.primary)
                    if usage.purgeable > 0 {
                        metric("Purgeable", usage.purgeable, Theme.caution)
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func metric(_ title: LocalizedStringKey, _ bytes: Int64, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.outline)
                .textCase(.uppercase)
            DataValue(
                text: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                size: 16, weight: .semibold
            )
            .foregroundStyle(tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Theme.cardFill,
            in: RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
        )
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
            DiskRing(usage: usage)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            VStack(alignment: .leading, spacing: 4) {
                statRow("Used", usage.used)
                statRow("Free", usage.available)
                statRow("Purgeable", usage.purgeable)
                snapshotRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var background: some View {
        LinearGradient(
            colors: [Theme.primaryContainer.opacity(0.05), .clear],
            startPoint: .top,
            endPoint: .center
        )
        .ignoresSafeArea()
    }
}

/// Clean capacity ring: track + rounded arc colored by how full the disk
/// is, percentage front and center where it actually fits.
struct DiskRing: View {
    let usage: DiskUsage
    var diameter: CGFloat = 130

    private var color: Color {
        switch usage.usedFraction {
        case ..<0.8: Theme.ok
        case ..<0.92: Theme.caution
        default: Theme.danger
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.track, style: StrokeStyle(lineWidth: diameter * 0.075))
            Circle()
                .trim(from: 0, to: max(0.02, usage.usedFraction))
                .stroke(color, style: StrokeStyle(lineWidth: diameter * 0.075, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring, value: usage.usedFraction)
            VStack(spacing: 0) {
                Text(verbatim: "\(Int(usage.usedFraction * 100))%")
                    .font(.system(size: diameter * 0.26, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.onSurface)
                    .contentTransition(.numericText())
                Text("full")
                    .font(.system(size: max(10, diameter * 0.075), weight: .semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.outline)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel(Text("Disk \(Int(usage.usedFraction * 100)) percent full"))
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
                // Once the scan has found something, the obvious next move is
                // to act on it — "Scan Again" was a dead end that made the
                // user hunt for where the cleaning happens.
                HStack(spacing: 10) {
                    if appState.smartScanDone, appState.smartCleanableBytes > 0 {
                        Button {
                            appState.smartCleanConfirming = true
                        } label: {
                            if appState.smartCleaning {
                                ProgressView().controlSize(.small).frame(minWidth: 130)
                            } else {
                                Label(
                                    "Clean \(ByteCountFormatter.string(fromByteCount: appState.smartCleanableBytes, countStyle: .file))",
                                    systemImage: "sparkles"
                                )
                                .frame(minWidth: 130)
                            }
                        }
                        .buttonStyle(ActionButtonStyle())
                        .disabled(appState.smartCleaning)
                        Button("Scan again") { appState.smartScan() }
                            .buttonStyle(.link)
                            .disabled(appState.smartScanRunning || appState.smartCleaning)
                    } else {
                        Button {
                            appState.smartScan()
                        } label: {
                            if appState.smartScanRunning {
                                ProgressView().controlSize(.small).frame(minWidth: 110)
                            } else {
                                Label(appState.smartScanDone ? "Scan again" : "Smart Scan",
                                      systemImage: "sparkles")
                                    .frame(minWidth: 110)
                            }
                        }
                        .buttonStyle(ActionButtonStyle())
                        .disabled(appState.smartScanRunning)
                    }
                }
                // Three numbers on one card that don't add up read as a bug.
                // Both gaps get named: what the button doesn't cover, and
                // what it can't reach yet.
                if appState.smartScanDone, appState.smartFreedBytes == nil {
                    VStack(alignment: .leading, spacing: 2) {
                        if appState.smartBlockedByAppsBytes > 0 {
                            Text("Another \(ByteCountFormatter.string(fromByteCount: appState.smartBlockedByAppsBytes, countStyle: .file)) is safe junk from apps you have open — close them and scan again.")
                        }
                        Text("Docker and project artifacts aren't in that button; they have their own screens.")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320, alignment: .leading)
                }
                if let freed = appState.smartFreedBytes {
                    Label(
                        "Freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) — it's in the Trash if you need it back.",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(Theme.ok)
                }
            }
            if appState.smartScanDone {
                Divider().frame(height: 70)
                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.smartTotalBytes, format: .byteCount(style: .file))
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.primary)
                        .contentTransition(.numericText())
                    Text("found in total")
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .confirmationDialog(
            "Clean \(ByteCountFormatter.string(fromByteCount: appState.smartCleanableBytes, countStyle: .file))?",
            isPresented: Binding(
                get: { appState.smartCleanConfirming },
                set: { appState.smartCleanConfirming = $0 }
            ),
            titleVisibility: .visible
        ) {
            Button("Clean") { appState.smartClean() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(appState.smartCleanableItems.count) items go to the Trash — caches and logs your apps rebuild on their own. Docker and project artifacts aren't included; those have their own screens because they need a look first.")
        }
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
                            HStack(spacing: 8) {
                                Text("Level")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("", selection: Binding(
                                    get: { model.perfMode },
                                    set: { model.perfMode = $0 }
                                )) {
                                    Text("Auto").tag(TabSaverModel.PerfMode.auto)
                                    Text("Light").tag(TabSaverModel.PerfMode.light)
                                    Text("Balanced").tag(TabSaverModel.PerfMode.balanced)
                                    Text("Full speed").tag(TabSaverModel.PerfMode.full)
                                }
                                .pickerStyle(.segmented)
                                .fixedSize()
                                .labelsHidden()
                                .help("Light: maximum tab savings, aggressive energy saver, no page preloading — for Macs that struggle. Balanced: sensible middle. Full speed: keeps preloading and skips the energy saver — for Macs with headroom. Auto picks from your RAM and live memory pressure, and adapts while Everyday mode runs.")
                            }
                            if model.perfMode == .auto {
                                Text("Auto chose \"\(levelName(model.resolvedLevel))\" for this Mac (RAM + current memory pressure). It adapts over time with Everyday mode.")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text("Verify in chrome://settings/performance (Memory Saver on). Chrome may mention \"Managed by your organization\" — that's this switch, removable anytime.")
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

            Divider()

            // 3 — Tab Guard: per-tab smarts via the companion extension
            TabGuardSection()
        }
        .card()
        .onAppear { model.refresh() }
    }

    private func stepBadge(_ number: String) -> some View {
        Text(verbatim: number)
            .font(.caption.bold())
            .frame(width: 20, height: 20)
            .background(.indigo.opacity(0.15), in: Circle())
            .foregroundStyle(.indigo)
    }

    private func levelName(_ level: BrowserTuner.BrowserPerfLevel) -> String {
        switch level {
        case .light: String(localized: "Light")
        case .balanced: String(localized: "Balanced")
        case .full: String(localized: "Full speed")
        }
    }
}

struct AutoCleanCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var schedule = appState.schedule
        VStack(alignment: .leading, spacing: 10) {
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
            if schedule.isEnabled {
                Divider()
                HStack(spacing: 8) {
                    Picker(selection: $schedule.minimumFreedMB) {
                        ForEach(ScheduleModel.minimumFreedChoicesMB, id: \.self) { mb in
                            if mb == 0 {
                                Text("Always clean").tag(mb)
                            } else {
                                Text(verbatim: ByteCountFormatter.string(
                                    fromByteCount: Int64(mb) * 1_000_000, countStyle: .file
                                )).tag(mb)
                            }
                        }
                    } label: {
                        Text("Only clean when there's at least")
                            .font(.caption)
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    Text("Below that, Sunday passes in silence — no clean, no notification.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
        .card()
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
