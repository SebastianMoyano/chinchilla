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
            ToolbarItem(id: "screen", placement: .primaryAction) {
                ScreenToolbarItem()
            }
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

/// The per-screen action, as one toolbar item that always exists — the same
/// rule as UpdateToolbarItem below. Four screens used to attach their own
/// `.toolbar { Button }`, so switching tabs changed the window's item set,
/// AppKit rebuilt the whole toolbar, and the rebuild locked into the exact
/// menu-form-representation loop this toolbar was already reworked once to
/// escape. One constant item whose *contents* switch on the tab keeps the
/// set stable; a bare symbol image keeps the menu-form representation cheap.
private struct ScreenToolbarItem: View {
    @Environment(AppState.self) private var appState
    @State private var showExclusions = false

    var body: some View {
        switch appState.selection {
        case .deepClean:
            Button {
                showExclusions = true
            } label: {
                Image(systemName: "lock.shield")
            }
            .help("Protected Folders — folders Chinchilla will never touch")
            .accessibilityLabel("Protected Folders")
            .sheet(isPresented: $showExclusions) { ExclusionsView() }
        case .health:
            Button {
                appState.health.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(appState.health.loading)
        case .uninstaller:
            Button {
                appState.uninstaller.scan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(appState.uninstaller.scanning)
        case .startup:
            Button {
                appState.startup.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(appState.startup.loading)
        default:
            // Something has to occupy the slot, or the item set changes
            // the moment a screen with an action appears.
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

/// The update state, as one toolbar item that always exists. Keeping the item
/// itself constant is the point: SwiftUI rebuilds AppKit's toolbar whenever the
/// set of items changes, and that rebuild is what the app was drowning in.
private struct UpdateToolbarItem: View {
    @Environment(AppState.self) private var appState
    @State private var confirming = false

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
                // Asks first, with the release notes in plain words — an
                // update that installs itself the instant you touch the
                // button reads as the app deciding for you.
                Button {
                    confirming = true
                } label: {
                    Label("Update to \(version)", systemImage: "arrow.down.circle")
                }
                .help("Shows what's new and asks before installing anything.")
                .popover(isPresented: $confirming, arrowEdge: .bottom) {
                    UpdateConfirmView(
                        version: version,
                        notes: updates.availableNotes
                    ) {
                        confirming = false
                        updates.installUpdate()
                    } later: {
                        confirming = false
                    }
                }
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

/// The pre-update question: version, what's new in plain words, and two
/// buttons. The notes come straight from the GitHub release body, whose
/// leading section is written in simple Spanish for exactly this dialog.
private struct UpdateConfirmView: View {
    let version: String
    let notes: String?
    let install: () -> Void
    let later: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update to version \(version)?")
                .font(.headline)
            if let notes {
                ScrollView {
                    Text(verbatim: notes)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 190)
            }
            Text("Downloads the new version, verifies its signature and reopens the app. Under a minute.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not now", action: later)
                Button("Update Now", action: install)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
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
