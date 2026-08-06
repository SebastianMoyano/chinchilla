import SwiftUI
import AppKit
import CastKit

extension MirrorPreset {
    var title: LocalizedStringKey {
        switch self {
        case .bestPicture: "Best picture"
        case .balanced: "Balanced"
        case .responsive: "Responsive"
        case .ultra: "Ultra"
        }
    }

    /// What the level actually means, in the units that matter: sharpness,
    /// bandwidth it will ask of the Wi-Fi, and how far behind the TV runs.
    var detail: LocalizedStringKey {
        switch self {
        case .bestPicture: "1080p · up to 8 Mbps · the TV runs ~0.4 s behind"
        case .balanced: "1080p · up to 6 Mbps · ~0.2 s behind"
        case .responsive: "720p · up to 4 Mbps · ~0.1 s behind — for using the TV like a monitor"
        case .ultra: "720p · up to 2 Mbps · ~0.05 s behind — lean and immediate; text stays readable, fast motion may briefly block up"
        }
    }
}

struct CastView: View {
    @Environment(AppState.self) private var appState
    @State private var manualIP = ""

    var body: some View {
        let model = appState.cast
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.discoveryState == .waitingForLocalNetworkPermission {
                    localNetworkBanner
                }
                modeCard(model)
                devicesCard(model)
                if model.connected != nil {
                    MirrorCard()
                    NowPlayingCard()
                }
                ReceiverGuideCard()
            }
            .padding(24)
        }
        .navigationTitle("Cast")
        // Paired: discovery runs while someone can see the list, and the
        // browsers come down when nobody can. The rate-limited variant keeps
        // a quick tab-switch from re-sweeping SSDP every time.
        .onAppear { model.discoveryViewAppeared() }
        .onDisappear { model.discoveryViewDisappeared() }
    }

    private var localNetworkBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text("Local network access is off")
                    .font(.callout.weight(.semibold))
                Text("Chinchilla needs it to find TVs on your network. Enable it and reopen this section.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    /// The first question, because the answer decides which TVs can even do
    /// the job. Asking "which TV" first means offering sets that then refuse.
    private func modeCard(_ model: CastModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What do you want to send?")
                .font(.headline)
            HStack(spacing: 10) {
                ForEach(CastModel.CastMode.allCases) { mode in
                    let selected = model.castMode == mode
                    Button {
                        model.castMode = mode
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            IconTile(
                                symbol: mode.symbol,
                                tint: selected ? Theme.action : Theme.outline,
                                size: 34
                            )
                            Text(mode.title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(selected ? Theme.onSurface : Theme.onSurfaceVariant)
                            Text(mode.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                                .fill(selected ? Theme.action.opacity(0.12) : Theme.cardFill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                                .strokeBorder(
                                    selected ? Theme.action.opacity(0.5) : Color.clear,
                                    lineWidth: 1.5
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if model.castMode == .extendDisplay {
                HStack(spacing: 10) {
                    Text("Where should it sit?")
                        .font(.callout)
                    Picker("", selection: Binding(
                        get: { model.extendedSide },
                        set: { model.extendedSide = $0 }
                    )) {
                        ForEach(ExtendedSide.allCases) { side in
                            Text(LocalizedStringKey(side.labelKey)).tag(side)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 230)
                    Spacer()
                }
                Text("Pick the side the TV actually stands on, so the pointer crosses over the right edge.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if model.castMode == .window {
                HStack(spacing: 10) {
                    Picker("Window", selection: Binding(
                        get: { model.mirrorSource },
                        set: { model.mirrorSource = $0 }
                    )) {
                        ForEach(model.availableWindows, id: \.self) { window in
                            Text(verbatim: window.label).tag(window)
                        }
                    }
                    .frame(maxWidth: 340)
                    Button { model.refreshWindows() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    Spacer()
                }
            }

            // One level instead of quality + responsiveness as separate axes:
            // wanting "responsive" means wanting the lighter stream that makes
            // low delay survivable. Always visible, applies live mid-stream.
            HStack(spacing: 12) {
                Picker("Level", selection: Binding(
                    get: { model.mirrorLevel },
                    set: { model.mirrorLevel = $0 }
                )) {
                    ForEach(MirrorPreset.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Toggle(isOn: Binding(
                    get: { model.adaptiveMirrorQuality },
                    set: { model.adaptiveMirrorQuality = $0 }
                )) {
                    Text("Adapt to Wi-Fi")
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Watches how the TV is receiving the stream and steps the quality down before it stutters, then climbs back when the network recovers. The level sets the ceiling.")
                Spacer()
            }
            Text(model.mirrorLevel.detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if model.mirroring, let status = model.mirrorQualityStatus {
                Label {
                    Text("Now sending \(status)")
                } icon: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // Sound follows the picture, except when you're still the one
            // watching — which is exactly what extending means.
            Toggle(isOn: Binding(
                get: { model.mirrorAudio },
                set: { model.mirrorAudio = $0 }
            )) {
                Text("Send the sound too")
            }
            .toggleStyle(.checkbox)
            if model.mirrorAudio {
                Toggle(isOn: Binding(
                    get: { model.muteMacWhileCasting },
                    set: { model.muteMacWhileCasting = $0 }
                )) {
                    Text("Mute this Mac while it plays there")
                }
                .toggleStyle(.checkbox)
                Text("macOS copies sound rather than moving it, so without this you hear everything twice. The Mac gets its sound back when you stop.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func devicesCard(_ model: CastModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("TVs on your network", systemImage: "tv.badge.wifi")
                    .font(.headline)
                Spacer()
                if model.targets.isEmpty && !model.searchedAndEmpty {
                    ProgressView().controlSize(.small)
                }
                Button {
                    model.startDiscovery()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Search again")
            }

            if model.targets.isEmpty {
                if model.searchedAndEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("No TVs found", systemImage: "questionmark.circle")
                            .font(.callout.weight(.medium))
                        Text("Checklist: the TV is ON and on the SAME network as this Mac (not a guest one); if your router has \"AP isolation\" or \"client isolation\", turn it off. If this Mac is on Ethernet and the TV is on Wi-Fi, many routers won't pass the discovery traffic between the two — Apple TV and Chromecast are found that way, so they go missing while DLNA sets still appear. Otherwise use the manual connection below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Looking for TVs — both FCast receivers and any DLNA-capable smart TV (most of them, nothing to install).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(model.targets) { target in
                HStack(spacing: 8) {
                    Image(systemName: "tv")
                        .foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(verbatim: target.name)
                            Text(target.protocolLabel)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.indigo.opacity(0.15), in: Capsule())
                                .foregroundStyle(.indigo)
                        }
                        HStack(spacing: 4) {
                            Image(systemName: target.canMirror
                                  ? "rectangle.on.rectangle" : "doc")
                            Text(target.capabilityLabel)
                        }
                        .font(.caption2)
                        .foregroundStyle(target.capabilityTint)
                        if let note = target.airplayNote {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(Theme.primary)
                        }
                        if let subtitle = target.subtitle {
                            Text(verbatim: subtitle)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if model.connected == target {
                        switch model.sessionState {
                        case .ready:
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Button("Disconnect") { model.disconnect() }
                                .controlSize(.small)
                        case .connecting:
                            ProgressView().controlSize(.small)
                        default:
                            Button("Reconnect") { model.connect(to: target) }
                                .controlSize(.small)
                        }
                    } else if target.handledByMacOS {
                        Button("Open Screen Mirroring") {
                            if let url = URL(string: AirPlayDiscovery.screenMirroringSettingsURL) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    } else if target.canMirror {
                        Button(model.castMode.title) { model.startCasting(to: target) }
                            .buttonStyle(ActionButtonStyle())
                            .disabled(model.mirrorStarting)
                    } else {
                        Button("Connect") { model.connect(to: target) }
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 8) {
                Text("Connect to a TV by IP:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("TV's IP address", text: $manualIP)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onSubmit { connectManual(model) }
                Button("Connect") { connectManual(model) }
                    .controlSize(.small)
                    .disabled(manualIP.isEmpty)
                Spacer()
            }
            .help("The TV's address, for FCast receivers on networks where automatic discovery is blocked.")

            if let mac = model.macAddressForDisplay {
                Text("This Mac serves from \(mac) — the TV must be able to reach that address.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let error = model.lastError {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .card()
    }

    private func connectManual(_ model: CastModel) {
        let host = manualIP.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        model.connectManually(host: host)
    }
}

struct NowPlayingCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let model = appState.cast
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.castingName != nil ? "Now casting" : "Cast something", systemImage: "play.rectangle.on.rectangle")
                    .font(.headline)
                if let name = model.castingName {
                    Text(verbatim: name)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    model.pickAndCastFile()
                } label: {
                    Label("Cast a file…", systemImage: "film")
                }
            }

            if model.firewallHint {
                Label("The TV connected but never fetched the video — the macOS firewall may be blocking Chinchilla. Check System Settings → Network → Firewall.", systemImage: "flame")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if model.castingName != nil {
                HStack(spacing: 14) {
                    Button {
                        model.togglePlayPause()
                    } label: {
                        Image(systemName: model.playbackState == 2 ? "play.fill" : "pause.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)

                    // Scrubber
                    Slider(
                        value: Binding(
                            get: { model.playbackTime },
                            set: { model.seek(to: $0) }
                        ),
                        in: 0...max(model.playbackDuration, 1)
                    )
                    Text(verbatim: timeString(model.playbackTime) + " / " + timeString(model.playbackDuration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Image(systemName: "speaker.wave.2")
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { model.volume },
                            set: { model.setVolume($0) }
                        ),
                        in: 0...1
                    )
                    .frame(width: 90)

                    Button {
                        model.stopCasting()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }
        }
        .card()
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct ReceiverGuideCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Which TVs work?", systemImage: "questionmark.circle")
                .font(.headline)
            guideRow(
                brand: "Most smart TVs — nothing to install",
                text: "Samsung, LG, Sony, TCL, Philips and friends answer over DLNA out of the box. They show up here on their own; just make sure the TV is on and on the same Wi-Fi."
            )
            guideRow(
                brand: "Android TV / Google TV — nothing to install either",
                text: "Most of them have Chromecast built in, so they show up here on their own. Installing \"FCast Receiver\" from the Play Store is optional — it unlocks the FCast path (and, later, screen mirroring)."
            )
            guideRow(
                brand: "Screen mirroring today",
                text: "Honest tip while our mirroring is in the oven: Samsung and LG TVs have AirPlay 2 built in — macOS can already mirror or extend to them natively from Control Center → Screen Mirroring."
            )
            Text("Everything here is free and account-less: your Mac serves the media straight to the TV over your Wi-Fi. Nothing goes through the internet.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private func guideRow(brand: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(brand)
                .font(.callout.weight(.semibold))
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}


/// Screen mirroring: capture → hardware H.264 → live HLS → the TV.
struct MirrorCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let model = appState.cast
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "macbook.and.iphone")
                    .font(.title2)
                    .foregroundStyle(model.mirroring ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mirror this screen")
                        .font(.headline)
                    Text(model.supportsFastMirror && model.mirrorFastPath
                         ? "Your whole desktop, live on the TV. This Chromecast supports the fast receiver, so the delay is a fraction of a second instead of several — close enough to point at things while you talk."
                         : "Your whole desktop, live on the TV — about 1–3 seconds behind. Great for videos, photos and presenting; not for using the TV as an interactive monitor. (TVs buffer before they show anything; that floor is the receiver's, not ours.)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.mirrorStarting {
                    ProgressView().controlSize(.small)
                }
                Toggle("", isOn: Binding(
                    get: { model.mirroring },
                    set: { on in on ? model.startMirroring() : model.stopMirroring() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(.green)
                .disabled(!model.canMirrorToConnectedDevice || model.mirrorStarting)
            }

            if !model.canMirrorToConnectedDevice {
                Label("This TV is connected over DLNA, which only plays files. Mirroring needs a Chromecast or FCast connection.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !model.screenPermissionGranted {
                HStack(spacing: 8) {
                    Label("Screen Recording permission is needed — and macOS asks again after every app update", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Grant…") { model.requestScreenPermission() }
                        .controlSize(.small)
                    Button("Open Settings") {
                        if let url = URL(string: ScreenRecordingPermission.settingsURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            } else if !model.mirroring {
                HStack(spacing: 12) {
                    Picker("Send", selection: Binding(
                        get: { model.mirrorSource },
                        set: { model.mirrorSource = $0 }
                    )) {
                        Text("Whole screen").tag(MirrorSource.wholeScreen)
                        Text("Extended display (second desktop)")
                            .tag(MirrorSource.extendedDisplay)
                        ForEach(model.availableWindows, id: \.self) { window in
                            Text(verbatim: window.label).tag(window)
                        }
                    }
                    .frame(maxWidth: 320)
                    if model.loadingWindows { ProgressView().controlSize(.mini) }
                    Button {
                        model.refreshWindows()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .help("Refresh the list of open windows")
                    Spacer()
                }
                .onAppear { model.refreshWindows() }

                if case .window = model.mirrorSource {
                    Label("Only that window goes to the TV — you can keep using the Mac for anything else.", systemImage: "macwindow.on.rectangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .extendedDisplay = model.mirrorSource {
                    Label("The TV becomes a real second desktop: drag windows onto it, and macOS treats it like any monitor. It disappears when you stop — no driver, nothing installed.", systemImage: "rectangle.on.rectangle.angled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            }

            if model.mirroring && model.mirrorUsingFallback {
                Label("This TV wouldn't take the fast stream, so we're using the slower one. Expect a second or two of delay.", systemImage: "tortoise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = model.mirrorError {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(18)
        .background(
            model.mirroring ? AnyShapeStyle(.green.opacity(0.08)) : AnyShapeStyle(.regularMaterial),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .onAppear { model.refreshScreenPermission() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            model.refreshScreenPermission()
        }
    }
}
