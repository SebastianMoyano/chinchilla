import SwiftUI
import AppKit
import CastKit
import SystemKit

/// The menu bar panel.
///
/// Deliberately short now. It carried five switches — two of them set-once
/// preferences — a stats grid and three rows of buttons, which its owner
/// summed up as "too many, and I don't even know what each one is for".
/// Things you flip often stay and say what they do; things you set once moved
/// behind a disclosure.
///
/// It's also split into small views instead of one long body. A single deeply
/// nested body compiles into one enormous generic type, and SwiftUI then
/// re-lays out the whole thing on any change — which is how this app kept
/// ending up pinned at 90% of a core after a few clicks.
struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @State private var freeSpace: Int64 = 0
    @State private var pressure: MemoryPressureLevel = .unknown
    @State private var showingSettings = false

    private var status: MenuBarStatus {
        .current(gaming: appState.gaming.isActive, daily: appState.dailyBoost.isEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MenuBarHeader(status: status)
            MenuBarStats(freeSpace: freeSpace, pressure: pressure)
            MenuBarMemoryOffer()

            Divider()
            MenuBarModes(openGamingScreen: { openMain(.gaming) })

            Divider()
            MenuBarCast(openCastScreen: { openMain(.cast) })

            Divider()
            MenuBarActions(
                startScan: { openMain(.dashboard); appState.smartScan() },
                openApp: { openMain(appState.selection) }
            )

            Divider()
            MenuBarFooter(showingSettings: $showingSettings)
        }
        .padding(14)
        .frame(width: 280)
        .onAppear {
            freeSpace = DiskUsage.current().available
            pressure = SystemSampler.memoryPressure()
            appState.updates.checkIfStale()
            // Opening the panel is a moment to have an answer ready, not to
            // start thinking — this only re-reads what's already recorded.
            appState.everydayPlan.refresh(samples: appState.memoryHistory.samples)
        }
    }

    private func openMain(_ target: SidebarItem) {
        appState.selection = target
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MenuBarHeader: View {
    let status: MenuBarStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: status.symbol)
                    .foregroundStyle(status.tint)
                Text("Chinchilla").font(.headline)
                Spacer()
            }
            Text(status.label)
                .font(.callout.weight(.medium))
                .foregroundStyle(status.tint)
        }
    }
}

private struct MenuBarStats: View {
    let freeSpace: Int64
    let pressure: MemoryPressureLevel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Free space").foregroundStyle(.secondary)
                Text(freeSpace, format: .byteCount(style: .file))
                    .monospacedDigit().fontWeight(.medium)
            }
            GridRow {
                Text("Memory").foregroundStyle(.secondary)
                Text(reading.0).fontWeight(.medium).foregroundStyle(reading.1)
            }
        }
        .font(.callout)
    }

    /// "Warning" is the kernel's word, not a person's.
    private var reading: (LocalizedStringKey, Color) {
        switch pressure {
        case .normal: ("Comfortable", Theme.ok)
        case .warning: ("Getting tight", Theme.caution)
        case .critical: ("Very tight", Theme.danger)
        case .unknown: ("—", .secondary)
        }
    }
}

/// "Memory: getting tight" is a fact with no next step in it, and its owner
/// said so: *de qué me sirve, si no sé qué hacer*. When there is something
/// worth doing, the offer goes right here, next to the reading that prompted
/// it, with the reason attached.
private struct MenuBarMemoryOffer: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let everyday = appState.everydayPlan
        if let action = everyday.plan?.actions.first(where: { $0.kind == .quitApp }) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: action.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Close \(action.target)") { everyday.confirmQuit(action) }
                        .controlSize(.small)
                    Button("Never ask") { everyday.refuseQuit(action) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.caution.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// The two switches worth flipping day to day, each saying what it does to
/// the Mac rather than just naming itself.
private struct MenuBarModes: View {
    @Environment(AppState.self) private var appState
    let openGamingScreen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { appState.dailyBoost.isEnabled },
                set: { appState.dailyBoost.toggle($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Everyday mode")
                    Text("Sleeps background tabs, watches memory")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(
                get: { appState.gaming.isActive },
                set: { on in
                    guard on else { return appState.gaming.deactivate() }
                    // Same gate as the main window's toggle: this closes and
                    // pauses apps, so it confirms first unless the user opted
                    // out. The sheet lives on the gaming screen — open it.
                    appState.gaming.requestActivate()
                    if appState.gaming.pendingConfirmation { openGamingScreen() }
                }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Gaming mode")
                    Text("Pauses background apps while you play")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
    }
}

/// Casting from here lists the televisions it found and casts on click.
/// Sending the user to the window to pick one defeated the point of the
/// button being in the menu bar at all.
private struct MenuBarCast: View {
    @Environment(AppState.self) private var appState
    let openCastScreen: () -> Void

    var body: some View {
        let cast = appState.cast
        VStack(alignment: .leading, spacing: 6) {
            if cast.mirroring {
                HStack {
                    Label(cast.castingName ?? String(localized: "Casting"),
                          systemImage: "rectangle.on.rectangle.fill")
                        .font(.callout)
                        .foregroundStyle(Theme.action)
                    Spacer()
                    Button("Stop") { cast.stopMirroring() }
                        .controlSize(.small)
                }
            } else {
                HStack {
                    Text("Send this screen to").font(.callout)
                    Spacer()
                    if cast.mirrorStarting { ProgressView().controlSize(.small) }
                }
                let usable = cast.targets.filter(\.canMirror)
                if usable.isEmpty {
                    Button("Look for a TV", action: openCastScreen)
                        .controlSize(.small)
                } else {
                    ForEach(usable) { target in
                        Button {
                            cast.startCasting(to: target)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: cast.castMode.symbol)
                                Text(verbatim: target.name).lineLimit(1)
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(cast.mirrorStarting)
                    }
                    Button("More options…", action: openCastScreen)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        // Opening the panel is the moment the answer is needed; closing it
        // is the moment the browses can stop. The one-shot SSDP sweep stays
        // rate-limited across opens.
        .onAppear { cast.discoveryViewAppeared() }
        .onDisappear { cast.discoveryViewDisappeared() }
    }
}

private struct MenuBarActions: View {
    let startScan: () -> Void
    let openApp: () -> Void

    var body: some View {
        HStack {
            Button(action: startScan) {
                Label("Smart Scan", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.action)
            Button(action: openApp) {
                Label("Open", systemImage: "macwindow")
            }
        }
    }
}

/// Version, updates, and the switches you touch once — behind a disclosure,
/// because a panel opened twenty times a day shouldn't give "start at login"
/// the same weight as "stop casting".
private struct MenuBarFooter: View {
    @Environment(AppState.self) private var appState
    @Binding var showingSettings: Bool
    /// Held rather than asked for: `LoginItem.isEnabled` is an XPC query to
    /// `SMAppService`, and inside a binding's getter it runs on every render.
    @State private var startsAtLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showingSettings { settings }
            HStack(spacing: 6) {
                Button(showingSettings ? "Hide settings" : "Settings") {
                    showingSettings.toggle()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                MenuBarUpdate()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: AppDelegate.keepInMenuBarKey) },
                set: { UserDefaults.standard.set($0, forKey: AppDelegate.keepInMenuBarKey) }
            )) {
                Text("Keep running when the window closes")
            }
            Toggle(isOn: Binding(
                get: { startsAtLogin },
                set: { wanted in
                    guard LoginItem.set(wanted) else { return }
                    startsAtLogin = wanted
                }
            )) {
                Text("Start at login")
            }
            .onAppear { startsAtLogin = LoginItem.isEnabled }
            Toggle(isOn: Binding(
                get: { appState.desktopWidget.isVisible },
                set: { _ in appState.desktopWidget.toggle() }
            )) {
                Text("Free-space ring on the desktop")
            }
        }
        .toggleStyle(.checkbox)
        .font(.caption)
    }
}

private struct MenuBarUpdate: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let updates = appState.updates
        if updates.installPhase == .downloading || updates.installPhase == .installing {
            ProgressView().controlSize(.mini)
        } else if let version = updates.availableVersion {
            Button {
                updates.installUpdate()
            } label: {
                Text("Update to \(version)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.ok)
            }
            .buttonStyle(.plain)
        } else {
            Text(verbatim: "v\(updates.currentVersion)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
