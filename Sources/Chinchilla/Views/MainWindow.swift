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
        .onAppear {
            appState.desktopWidget.restoreIfEnabled()
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
