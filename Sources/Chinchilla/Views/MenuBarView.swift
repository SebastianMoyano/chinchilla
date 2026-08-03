import SwiftUI
import AppKit
import SystemKit

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @State private var freeSpace: Int64 = 0
    @State private var pressure: MemoryPressureLevel = .unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("Chinchilla")
                    .font(.headline)
                Spacer()
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Label("Free space", systemImage: "internaldrive")
                        .foregroundStyle(.secondary)
                    Text(freeSpace, format: .byteCount(style: .file))
                        .monospacedDigit().fontWeight(.medium)
                }
                GridRow {
                    Label("Memory pressure", systemImage: "memorychip")
                        .foregroundStyle(.secondary)
                    Text(pressureText.0)
                        .fontWeight(.medium)
                        .foregroundStyle(pressureText.1)
                }
            }
            .font(.callout)

            Divider()

            Toggle(isOn: Binding(
                get: { appState.dailyBoost.isEnabled },
                set: { appState.dailyBoost.toggle($0) }
            )) {
                Label("Everyday mode", systemImage: "bolt.heart.fill")
            }
            .toggleStyle(.switch)

            Toggle(isOn: Binding(
                get: { appState.gaming.isActive },
                set: { on in on ? appState.gaming.activate() : appState.gaming.deactivate() }
            )) {
                Label("Gaming mode", systemImage: "gamecontroller.fill")
            }
            .toggleStyle(.switch)

            Toggle(isOn: Binding(
                get: { appState.desktopWidget.isVisible },
                set: { _ in appState.desktopWidget.toggle() }
            )) {
                Label("Desktop widget", systemImage: "gauge.medium")
            }
            .toggleStyle(.switch)

            Toggle(isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: AppDelegate.keepInMenuBarKey) },
                set: { UserDefaults.standard.set($0, forKey: AppDelegate.keepInMenuBarKey) }
            )) {
                Label("Keep running when window closes", systemImage: "menubar.arrow.up.rectangle")
            }
            .toggleStyle(.switch)
            .help("Closing the main window keeps Chinchilla in the menu bar — gaming mode, the widget and the weekly clean stay alive.")

            Divider()

            HStack {
                Button {
                    openMain(.dashboard)
                    appState.smartScan()
                } label: {
                    Label("Smart Scan", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                Button {
                    openMain(appState.selection)
                } label: {
                    Label("Open", systemImage: "macwindow")
                }
            }

            Divider()

            // Version + updates, always visible and always tappable.
            HStack(spacing: 6) {
                Text(verbatim: "v\(appState.updates.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if appState.updates.installPhase == .downloading
                    || appState.updates.installPhase == .installing {
                    ProgressView().controlSize(.mini)
                    Text("Updating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let version = appState.updates.availableVersion {
                    Button {
                        appState.updates.installUpdate()
                    } label: {
                        Label("Update to \(version)", systemImage: "arrow.down.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                } else if let result = appState.updates.manualResult {
                    Text(verbatim: result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Check for updates") {
                        appState.updates.checkNow()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 260)
        .onAppear {
            let usage = DiskUsage.current()
            freeSpace = usage.available
            pressure = SystemSampler.memoryPressure()
            appState.updates.checkIfStale()
        }
    }

    private var pressureText: (LocalizedStringKey, Color) {
        switch pressure {
        case .normal: ("Normal", .green)
        case .warning: ("Warning", .orange)
        case .critical: ("Critical", .red)
        case .unknown: ("—", .secondary)
        }
    }

    private func openMain(_ target: SidebarItem) {
        appState.selection = target
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
