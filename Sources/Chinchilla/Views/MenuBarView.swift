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

            Button("Quit Chinchilla") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 260)
        .onAppear {
            let usage = DiskUsage.current()
            freeSpace = usage.available
            pressure = SystemSampler.memoryPressure()
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
