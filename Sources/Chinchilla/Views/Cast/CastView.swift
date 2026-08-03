import SwiftUI
import AppKit
import CastKit

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
                devicesCard(model)
                if model.connected != nil {
                    NowPlayingCard()
                }
                ReceiverGuideCard()
            }
            .padding(24)
        }
        .navigationTitle("Cast")
        .onAppear { model.startDiscovery() }
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
                        Text("Checklist: the TV is ON and on the SAME Wi-Fi as this Mac (not a guest network); if your router has \"AP isolation\" or \"client isolation\", turn it off. Most smart TVs answer over DLNA without installing anything — if yours doesn't, install FCast Receiver (Android TV) or use the manual connection below.")
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
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
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
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
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
