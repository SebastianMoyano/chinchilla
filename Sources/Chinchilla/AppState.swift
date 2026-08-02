import SwiftUI
import Observation
import CleanCore
import SystemKit

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard
    case deepClean
    case uninstaller
    case diskAnalyzer
    case gaming
    case startup
    case devTools

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .dashboard: "Dashboard"
        case .deepClean: "Deep Clean"
        case .uninstaller: "Uninstaller"
        case .diskAnalyzer: "Disk Space"
        case .gaming: "Gaming Mode"
        case .startup: "Startup"
        case .devTools: "Docker & Dev"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.50percent"
        case .deepClean: "sparkles"
        case .uninstaller: "trash.square"
        case .diskAnalyzer: "chart.pie.fill"
        case .gaming: "gamecontroller.fill"
        case .startup: "power"
        case .devTools: "shippingbox.fill"
        }
    }

    var tint: Color {
        switch self {
        case .dashboard: .blue
        case .deepClean: .purple
        case .uninstaller: .red
        case .diskAnalyzer: .orange
        case .gaming: .green
        case .startup: .yellow
        case .devTools: .cyan
        }
    }
}

@MainActor
@Observable
final class AppState {
    var selection: SidebarItem = .dashboard
    let diskAnalyzer = DiskAnalyzerModel()
    let deepClean = DeepCleanModel()
    let devTools = DevToolsModel()
    let gaming = GamingModel()
    let uninstaller = UninstallerModel()
    let startup = StartupModel()
    let schedule = ScheduleModel()
    let desktopWidget = DesktopWidgetModel()
    let tabSaver = TabSaverModel()

    // MARK: Smart Scan — one click, three sweeps, one number.

    var smartScanRunning = false
    var smartScanDone = false

    /// Bytes of `safe` clean items found by the last deep-clean scan.
    var smartCleanBytes: Int64 {
        deepClean.report.items.filter { $0.safety == .safe }.reduce(0) { $0 + $1.size }
    }

    var smartDockerBytes: Int64 {
        devTools.dockerUsage.reduce(0) { $0 + $1.reclaimableBytes }
    }

    var smartArtifactBytes: Int64 {
        devTools.artifacts.reduce(0) { $0 + $1.size }
    }

    var smartTotalBytes: Int64 {
        smartCleanBytes + smartDockerBytes + smartArtifactBytes
    }

    func smartScan() {
        guard !smartScanRunning else { return }
        smartScanRunning = true
        smartScanDone = false
        deepClean.scan()
        devTools.refreshDocker()
        devTools.scanArtifacts()
        Task {
            // The three sweeps report through their own models; wait for all.
            while deepClean.phase == .scanning
                || devTools.dockerPhase == .loading
                || devTools.artifactsScanning {
                try? await Task.sleep(for: .milliseconds(200))
            }
            smartScanRunning = false
            withAnimation(.spring) { smartScanDone = true }
        }
    }
}
