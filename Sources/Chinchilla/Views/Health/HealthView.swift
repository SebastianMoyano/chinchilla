import SwiftUI
import AppKit
import SystemKit

/// Mac health: read-only checks in plain language, a small repair kit
/// (fixes, not speed), and the reversible snappy-UI toggle.
struct HealthView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let model = appState.health
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                checksCard(model)
                snappyCard(model)
                fixItCard(model)
                if !model.brewServices.isEmpty {
                    brewCard(model)
                }
            }
            .padding(24)
        }
        .navigationTitle("Health")
        .toolbar {
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.loading)
        }
        .onAppear { model.refresh() }
    }

    // MARK: Checks

    private func checksCard(_ model: HealthModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("How is this Mac doing?", systemImage: "stethoscope")
                    .font(.headline)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
            }

            checkRow(
                ok: model.report.smartStatus == "Verified",
                unknown: model.report.smartStatus == nil || model.report.smartStatus == "Not Supported",
                title: "Disk",
                detail: model.report.smartStatus == "Verified"
                    ? String(localized: "SMART says the disk is healthy.")
                    : String(localized: "SMART status: \(model.report.smartStatus ?? String(localized: "unknown")). If it says failing, back up NOW.")
            )
            if let cycles = model.report.batteryCycles {
                let health = model.report.batteryHealthPercent
                checkRow(
                    ok: (health ?? 100) >= 80,
                    unknown: false,
                    title: "Battery",
                    detail: String(localized: "\(cycles) charge cycles\(health.map { String(localized: " · holds \($0)% of its original capacity") } ?? "").")
                )
            }
            checkRow(
                ok: model.report.uptimeDays < 14,
                unknown: false,
                title: "Uptime",
                detail: model.report.uptimeDays < 14
                    ? String(localized: "\(model.report.uptimeDays) days since the last restart\(model.bootDateSuffix) — fine.")
                    // Naming the date matters: "29 days" reads as wrong to
                    // anyone who closes the lid every night and calls that
                    // turning it off. A date can be checked against memory.
                    : String(localized: "\(model.report.uptimeDays) days without a restart — running since \(model.bootDateText). Closing the lid or letting it sleep doesn't count; only Restart or Shut Down does. A reboot clears leaked memory — old-fashioned, but it works.")
            )
            checkRow(
                ok: model.report.zombieCount < 5,
                unknown: false,
                title: "Zombie processes",
                detail: model.report.zombieCount < 5
                    ? String(localized: "\(model.report.zombieCount) — harmless.")
                    : String(localized: "\(model.report.zombieCount) zombies. They use no resources, but many of them means some app is misbehaving; a restart clears them.")
            )
            if let managed = model.report.isMDMManaged {
                checkRow(
                    ok: !managed,
                    unknown: false,
                    title: "Management",
                    detail: managed
                        ? String(localized: "This Mac is managed (MDM) — an organization can set policies on it.")
                        : String(localized: "Not managed by any organization.")
                )
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func checkRow(ok: Bool, unknown: Bool, title: LocalizedStringKey, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: unknown ? "questionmark.circle" : (ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                .foregroundStyle(unknown ? Color.secondary : (ok ? .green : .orange))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: Snappy UI

    private func snappyCard(_ model: HealthModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Snappy interface", systemImage: "hare.fill")
                        .font(.headline)
                    Text("Much of \"slow\" is animations. This trims Dock delays and window effects — the Mac *feels* faster instantly. Fully reversible (the Dock restarts, that's normal).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.snappyBusy { ProgressView().controlSize(.small) }
                Toggle("", isOn: Binding(
                    get: { model.snappyOn },
                    set: { model.toggleSnappy($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(.orange)
                .disabled(model.snappyBusy)
            }
            HStack {
                Text("Want even fewer animations system-wide? macOS has \"Reduce motion\":")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button("Open Accessibility") {
                    if let url = URL(string: SnappyUI.reduceMotionSettingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Fix-it kit

    private func fixItCard(_ model: HealthModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Repair kit", systemImage: "cross.case")
                .font(.headline)
            Text("These fix problems — they don't add speed, and we won't pretend otherwise.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    model.runFix("dns", { try await FixIt.flushDNS() },
                                 success: String(localized: "DNS cache flushed. Sites that wouldn't load should resolve again."))
                } label: {
                    Label("Flush DNS cache", systemImage: "network.badge.shield.half.filled")
                }
                .help("Fixes \"this site won't load on my Mac but works on my phone\". Asks for your password (the DNS service belongs to the system).")
                Button {
                    model.runFix("fonts", { try await FixIt.rebuildFontCaches() },
                                 success: String(localized: "Font caches cleared — fully applied after you log out and back in."))
                } label: {
                    Label("Rebuild font caches", systemImage: "textformat")
                }
                .help("Fixes garbled or missing text in apps.")
                if model.fixRunning != nil { ProgressView().controlSize(.small) }
            }
            .disabled(model.fixRunning != nil)
            if let result = model.fixResult {
                Text(verbatim: result)
                    .font(.caption)
                    .foregroundStyle(.teal)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Brew services

    private func brewCard(_ model: HealthModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Homebrew background services", systemImage: "cup.and.saucer")
                .font(.headline)
            Text("Databases and servers installed with Homebrew keep running (and restarting at login) until told otherwise — a classic source of quiet resource drain.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(model.brewServices) { service in
                HStack {
                    Circle()
                        .fill(service.isRunning ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text(verbatim: service.name)
                        .font(.callout)
                    Text(verbatim: service.status)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if model.brewBusy.contains(service.name) {
                        ProgressView().controlSize(.mini)
                    } else if service.isRunning {
                        Button("Stop") { model.stopBrewService(service.name) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
