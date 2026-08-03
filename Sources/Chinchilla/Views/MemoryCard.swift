import SwiftUI
import SystemKit

/// Plain-language memory health for the Dashboard. Default wording targets
/// non-technical users; the technical detail lives in tooltips.
struct MemoryCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let model = appState.memory
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor(model))
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle(model))
                        .font(.headline)
                    Text(statusCaption(model))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help(technicalDetail(model))
                Spacer()
                if model.refreshing {
                    ProgressView().controlSize(.small)
                }
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.refreshing)
            }

            if !model.topApps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Using the most memory right now")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(model.topApps.prefix(4)) { app in
                        AppUsageRow(
                            model: model,
                            app: app,
                            maxFootprint: model.topApps.first?.footprint ?? 1,
                            color: statusColor(model)
                        )
                    }
                }
            }

            ForEach(model.tips) { tip in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: tip.icon)
                        .foregroundStyle(.teal)
                        .frame(width: 18)
                    Text(tip.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let destination = tip.destination {
                        Button {
                            appState.selection = destination
                        } label: {
                            Image(systemName: "chevron.right.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.teal)
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onAppear { model.refresh() }
    }

    private func statusColor(_ model: MemoryModel) -> Color {
        switch model.health {
        case .fine: .green
        case .tight: .orange
        case .struggling: .red
        case .unknown: .gray
        }
    }

    private func statusTitle(_ model: MemoryModel) -> LocalizedStringKey {
        switch model.health {
        case .fine: "Memory: all good"
        case .tight: "Memory: getting tight"
        case .struggling: "Memory: struggling — this is why it feels slow"
        case .unknown: "Memory"
        }
    }

    private func statusCaption(_ model: MemoryModel) -> LocalizedStringKey {
        switch model.health {
        case .fine:
            "Your Mac has all the memory it needs right now."
        case .tight:
            "It's squeezing memory to keep up. If things feel slow, close a big app below."
        case .struggling:
            "There isn't enough memory, so your Mac is using the disk as a slow backup. Close the biggest apps below."
        case .unknown:
            "Tap refresh to check."
        }
    }

    private func technicalDetail(_ model: MemoryModel) -> Text {
        Text("Memory pressure: \(String(describing: model.health)) · swap \(Text(model.swapUsed, format: .byteCount(style: .memory))) · total \(Text(model.memoryTotal, format: .byteCount(style: .memory)))")
    }

}

private struct AppUsageRow: View {
    let model: MemoryModel
    let app: AppMemoryUsage
    let maxFootprint: Int64
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: app.name)
                .font(.callout)
                .frame(width: 150, alignment: .leading)
                .lineLimit(1)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2)
                    .fill(app.name == "macOS" ? Color.gray.opacity(0.6) : color.opacity(0.75))
                    .frame(
                        width: max(3, geo.size.width * CGFloat(app.footprint) / CGFloat(max(maxFootprint, 1))),
                        height: 6
                    )
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            Text(app.footprint, format: .byteCount(style: .memory))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            if let cpu = app.cpuPercent {
                Text(verbatim: cpu >= 1 ? "\(Int(cpu))% CPU" : "·")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(cpu >= 50 ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .frame(width: 58, alignment: .trailing)
                    .help("CPU over the last second, all of the app's processes combined. 100% = one full core.")
            }
            if model.canQuit(app) {
                Button("Close") { model.quit(app) }
                    .controlSize(.mini)
                    .help("Quits the app the normal way — it can ask you to save first.")
            } else {
                Text(verbatim: " ")
                    .frame(width: 40)
            }
        }
        .frame(height: 20)
    }
}
