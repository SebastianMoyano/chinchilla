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
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if appState.updates.installPhase == .downloading
                    || appState.updates.installPhase == .installing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(appState.updates.installPhase == .downloading ? "Downloading…" : "Installing…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if let version = appState.updates.availableVersion {
                    // Passive capsule; one click downloads, verifies,
                    // installs and relaunches — no dialogs ever.
                    Button {
                        appState.updates.installUpdate()
                    } label: {
                        Label("Update to \(version)", systemImage: "arrow.down.circle.fill")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    .help("One click: downloads the new version, verifies its signature, installs it and relaunches. No rush.")
                } else if let result = appState.updates.manualResult {
                    Text(verbatim: result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Link(destination: UpdateModel.sponsorURL) {
                    Label("Sponsor", systemImage: "heart.fill")
                        .foregroundStyle(.pink)
                }
                .help("Enjoying Chinchilla? Support its development ♥")
            }
        }
        .onAppear {
            appState.desktopWidget.restoreIfEnabled()
            appState.updates.checkIfStale()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.selection {
        case .dashboard: DashboardView()
        case .deepClean: DeepCleanView()
        case .uninstaller: UninstallerView()
        case .diskAnalyzer: DiskAnalyzerView()
        case .gaming: GamingModeView()
        case .startup: StartupView()
        case .health: HealthView()
        case .cast: CastView()
        case .devTools: DevToolsView()
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
