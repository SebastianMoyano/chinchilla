import SwiftUI
import AppKit
import CastKit

struct CastView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let model = appState.cast
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.discoveryState == .waitingForLocalNetworkPermission {
                    localNetworkBanner
                }
                devicesCard(model)
                if model.connectedDevice != nil {
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
                if model.discoveryState == .browsing && model.devices.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
            if model.devices.isEmpty {
                Text("Searching for FCast receivers… Make sure the FCast Receiver app is OPEN on your TV (see the guide below) and both are on the same Wi-Fi.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.devices) { device in
                HStack {
                    Image(systemName: "tv")
                        .foregroundStyle(.indigo)
                    Text(verbatim: device.name)
                    Spacer()
                    if model.connectedDevice == device {
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
                            Button("Reconnect") { model.connect(to: device) }
                                .controlSize(.small)
                        }
                    } else {
                        Button("Connect") { model.connect(to: device) }
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
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
            Label("Get your TV ready", systemImage: "questionmark.circle")
                .font(.headline)
            guideRow(
                brand: "Android TV / Google TV",
                text: "Install \"FCast Receiver\" from the Play Store on the TV, open it, and it will appear above."
            )
            guideRow(
                brand: "Samsung / LG",
                text: "Honest tip: your TV has AirPlay 2 built in — for screen work, macOS can already mirror/extend to it natively (Control Center → Screen Mirroring). FCast receivers exist for these TVs but installing them is clunky."
            )
            Text("Everything here is free and account-less: your Mac serves the media directly to the TV over your Wi-Fi. Nothing goes through the internet.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private func guideRow(brand: String, text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: brand)
                .font(.callout.weight(.semibold))
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
