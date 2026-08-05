import SwiftUI

struct MainWindow: View {
    @Environment(AppState.self) private var appState
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "onboarded")

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            SidebarView(selection: $appState.selection)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding)
        }
        // Two rules here, both learned from a sample of the app frozen at
        // 100% of a core with not one frame of our own code on the stack:
        //
        // 1. The item set never changes. It used to be an if/else-if chain
        //    that swapped a progress view for a capsule button for a label,
        //    so every update rebuilt the toolbar's items. Now there are
        //    always exactly two items with fixed ids, and only what's *inside*
        //    them changes.
        // 2. Nothing in a toolbar item is custom-styled. AppKit builds a menu
        //    form representation for each item, and for a custom label that
        //    means re-resolving its image through CUICatalog — locale fallback
        //    and all — on every pass. That resolution alone was a quarter of
        //    the frozen CPU.
        .toolbar(id: "main") {
            ToolbarItem(id: "update", placement: .primaryAction) {
                UpdateToolbarItem()
            }
            ToolbarItem(id: "sponsor", placement: .primaryAction) {
                Link(destination: UpdateModel.sponsorURL) {
                    Label("Sponsor", systemImage: "heart")
                }
                .help("Enjoying Chinchilla? Support its development ♥")
            }
        }
        .onAppear {
            appState.desktopWidget.restoreIfEnabled()
            appState.updates.checkIfStale()
            appState.refreshStallContext()
        }
        .onChange(of: appState.selection) { _, _ in appState.refreshStallContext() }
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.selection {
        case .dashboard: DashboardView()
        case .deepClean: DeepCleanView()
        case .uninstaller: UninstallerView()
        case .diskAnalyzer: DiskAnalyzerView()
        case .memory: MemoryView()
        case .gaming: GamingModeView()
        case .startup: StartupView()
        case .health: HealthView()
        case .cast: CastView()
        case .devTools: DevToolsView()
        }
    }
}

/// The update state, as one toolbar item that always exists. Keeping the item
/// itself constant is the point: SwiftUI rebuilds AppKit's toolbar whenever the
/// set of items changes, and that rebuild is what the app was drowning in.
private struct UpdateToolbarItem: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let updates = appState.updates
        switch updates.installPhase {
        case .downloading, .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(updates.installPhase == .downloading ? "Downloading…" : "Installing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        default:
            if let version = updates.availableVersion {
                // One click downloads, verifies, installs and relaunches —
                // no dialogs ever.
                Button {
                    updates.installUpdate()
                } label: {
                    Label("Update to \(version)", systemImage: "arrow.down.circle")
                }
                .help("One click: downloads the new version, verifies its signature, installs it and relaunches. No rush.")
            } else if let result = updates.manualResult {
                Text(verbatim: result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Something has to occupy the slot, or the item set changes
                // again the moment an update appears.
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(SidebarItem.allCases) { item in
                    Label {
                        Text(item.title)
                    } icon: {
                        Image(systemName: item.icon)
                            .foregroundStyle(item.tint)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .tag(item)
                }
            } header: {
                Text("Chinchilla")
                    .font(.headline)
            }
        }
        .listStyle(.sidebar)
    }
}

struct PlaceholderView: View {
    let item: SidebarItem

    var body: some View {
        ContentUnavailableView {
            Label(item.title, systemImage: item.icon)
        } description: {
            Text("Coming soon")
        }
    }
}
