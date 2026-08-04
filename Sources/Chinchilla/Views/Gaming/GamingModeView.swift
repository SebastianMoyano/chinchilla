import SwiftUI
import SystemKit

struct GamingModeView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let model = appState.gaming
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                toggleCard(model)
                statsCard(model)
                if !model.isActive {
                    candidatesCard(model)
                }
                if !model.terminatedAppPaths.isEmpty {
                    relaunchCard(model)
                }
                honestyCard
            }
            .padding(24)
        }
        .navigationTitle("Gaming Mode")
        .onAppear {
            model.refreshCandidates()
            model.startSampling()
        }
        .onDisappear {
            model.stopSampling()
        }
    }

    private func toggleCard(_ model: GamingModel) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 34))
                .foregroundStyle(model.isActive ? .green : .secondary)
                .symbolEffect(.bounce, value: model.isActive)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.isActive ? "Gaming mode is on" : "Gaming mode is off")
                    .font(.title3.bold())
                Text("Keeps the Mac awake, stops Time Machine backups and closes the apps you pick.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.toggleOverlay()
            } label: {
                Label("Overlay", systemImage: model.overlayVisible ? "eye.fill" : "eye")
            }
            .help("Floating performance panel that stays above your game.")
            Toggle("", isOn: Binding(
                get: { model.isActive },
                set: { on in on ? model.requestActivate() : model.deactivate() }
            ))
            .toggleStyle(.switch)
            .controlSize(.large)
            .labelsHidden()
            .tint(.green)
        }
        .card()
        .sheet(isPresented: Binding(
            get: { model.pendingConfirmation },
            set: { model.pendingConfirmation = $0 }
        )) {
            GamingConfirmSheet(model: model)
        }
    }

    private func statsCard(_ model: GamingModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Performance", systemImage: "waveform.path.ecg")
                .font(.headline)
            HStack(spacing: 14) {
                StatTile(
                    title: "CPU",
                    value: model.snapshot.cpuUsage.map { "\(Int($0 * 100))%" } ?? "—",
                    history: model.cpuHistory,
                    color: .blue
                )
                StatTile(
                    title: "GPU",
                    value: model.snapshot.gpuUtilization.map { "\(Int($0 * 100))%" } ?? "—",
                    history: model.gpuHistory,
                    color: .purple
                )
                VStack(alignment: .leading, spacing: 6) {
                    pressureRow(model)
                    memoryRow(model)
                    swapRow(model)
                    thermalRow(model)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card()
    }

    private func pressureRow(_ model: GamingModel) -> some View {
        let (text, color): (LocalizedStringKey, Color) = switch model.snapshot.memoryPressure {
        case .normal: ("Normal", .green)
        case .warning: ("Warning", .orange)
        case .critical: ("Critical", .red)
        case .unknown: ("—", .secondary)
        }
        return HStack {
            Label("Memory pressure", systemImage: "memorychip")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
    }

    private func memoryRow(_ model: GamingModel) -> some View {
        HStack {
            Label("Memory used", systemImage: "gauge.medium")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(model.snapshot.memoryUsed, format: .byteCount(style: .memory))
                .font(.caption.monospacedDigit())
        }
    }

    private func swapRow(_ model: GamingModel) -> some View {
        HStack {
            Label("Swap", systemImage: "arrow.left.arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(model.snapshot.swapUsed, format: .byteCount(style: .memory))
                .font(.caption.monospacedDigit())
        }
    }

    private func thermalRow(_ model: GamingModel) -> some View {
        let (text, color): (LocalizedStringKey, Color) = switch model.snapshot.thermalState {
        case .nominal: ("Cool", .green)
        case .fair: ("Warm", .yellow)
        case .serious: ("Hot", .orange)
        case .critical: ("Critical", .red)
        @unknown default: ("—", .secondary)
        }
        return HStack {
            Label("Thermals", systemImage: "thermometer.medium")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
    }

    private func candidatesCard(_ model: GamingModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Apps to close when activating", systemImage: "xmark.circle")
                    .font(.headline)
                Spacer()
                Button {
                    model.refreshCandidates()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            Text("Closed gracefully — apps can save their work. They're relaunched with one click when you're done playing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.candidates.isEmpty {
                Text("No background apps running.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            }
            ForEach(model.candidates) { candidate in
                HStack(spacing: 8) {
                    Text(verbatim: candidate.name)
                    if let warning = candidate.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { model.rowActions[candidate.pid] ?? .keep },
                        set: { model.setAction($0, for: candidate) }
                    )) {
                        Text("Keep").tag(GamingAppAction.keep)
                        if candidate.canPause {
                            Text("Pause").tag(GamingAppAction.pause)
                        }
                        Text("Close").tag(GamingAppAction.close)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .labelsHidden()
                    .help(candidate.canPause
                        ? "Pause freezes it in place and resumes it instantly when you're done. If you click a paused app it will look stuck — that's the freeze."
                        : "Pause isn't offered for browsers, media or chat apps — they don't freeze cleanly. Closing is honest; it can save first.")
                }
            }
            Text("Your choices are remembered per app for next time.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            focusShortcutRow(model)
        }
        .card()
    }

    @State private var availableShortcuts: [String] = []

    private func focusShortcutRow(_ model: GamingModel) -> some View {
        HStack(spacing: 8) {
            Label("Focus shortcut", systemImage: "moon.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("macOS gives apps no direct Do Not Disturb switch. Create a Shortcut with the \"Set Focus\" action and pick it here — Chinchilla runs it when gaming starts/ends.")
            Picker("", selection: Binding(
                get: { UserDefaults.standard.string(forKey: GamingModel.focusShortcutOnKey) ?? "" },
                set: { UserDefaults.standard.set($0, forKey: GamingModel.focusShortcutOnKey) }
            )) {
                Text("None").tag("")
                ForEach(availableShortcuts, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            .fixedSize()
            .labelsHidden()
            Text("on start ·")
                .font(.caption2).foregroundStyle(.tertiary)
            Picker("", selection: Binding(
                get: { UserDefaults.standard.string(forKey: GamingModel.focusShortcutOffKey) ?? "" },
                set: { UserDefaults.standard.set($0, forKey: GamingModel.focusShortcutOffKey) }
            )) {
                Text("None").tag("")
                ForEach(availableShortcuts, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            .fixedSize()
            .labelsHidden()
            Text("on end")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
        }
        .task {
            availableShortcuts = await ShortcutsRunner.list()
        }
    }

    private func relaunchCard(_ model: GamingModel) -> some View {
        HStack {
            Label("\(model.terminatedAppPaths.count) apps were closed", systemImage: "arrow.uturn.backward.circle")
            Spacer()
            Button("Forget") { model.clearTerminatedApps() }
            Button("Relaunch All") { model.relaunchTerminatedApps() }
                .buttonStyle(.borderedProminent)
                .tint(.green)
        }
        .padding(16)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var honestyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("What we don't do (on purpose)", systemImage: "hand.raised")
                .font(.headline)
            Text("• No RAM \"purge\": it empties disk caches and makes things slower — macOS already manages memory well.\n• No Spotlight toggling: turning it off needs admin rights and stays off if anything crashes.\n• No FPS counter: macOS doesn't expose other apps' frame rates; anyone showing one is guessing.\n• No per-app bandwidth throttling: it needs root firewall rules that outlive crashes. Sleeping browser tabs and pausing background videos (Tab Guard) cuts the real traffic instead.\n• No YouTube quality forcing: it relies on private player internals that break without notice.\n• Focus/Do Not Disturb only via a Shortcut you create — Apple gives apps no direct switch.\n• macOS Sequoia's own Game Mode kicks in automatically when a game goes fullscreen — Chinchilla complements it instead of fighting it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct StatTile: View {
    let title: LocalizedStringKey
    let value: String
    let history: [Double]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.title2.bold().monospacedDigit())
                .contentTransition(.numericText())
            SparklineView(values: history, color: color)
                .frame(height: 30)
        }
        .frame(width: 120, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Canvas sparkline — no Charts dependency needed for a 60-point line.
struct SparklineView: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let stepX = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(
                    x: CGFloat(index) * stepX,
                    y: size.height * (1 - CGFloat(min(1, max(0, value))))
                )
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            context.stroke(line, with: .color(color), lineWidth: 1.5)

            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [color.opacity(0.3), .clear]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            ))
        }
    }
}

/// Compact floating HUD hosted in the overlay NSPanel.
struct OverlayView: View {
    let model: GamingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "gamecontroller.fill")
                    .foregroundStyle(.green)
                Text("Chinchilla")
                    .font(.caption.bold())
                Spacer()
                Button {
                    model.toggleOverlay()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                overlayStat("CPU", model.snapshot.cpuUsage)
                overlayStat("GPU", model.snapshot.gpuUtilization)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MEM")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Circle()
                        .fill(pressureColor)
                        .frame(width: 10, height: 10)
                }
            }
            SparklineView(values: model.cpuHistory, color: .green)
                .frame(height: 24)
        }
        .padding(12)
        .frame(width: 240)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var pressureColor: Color {
        switch model.snapshot.memoryPressure {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        case .unknown: .gray
        }
    }

    private func overlayStat(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: value.map { "\(Int($0 * 100))%" } ?? "—")
                .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
        }
        .frame(minWidth: 44, alignment: .leading)
    }
}
