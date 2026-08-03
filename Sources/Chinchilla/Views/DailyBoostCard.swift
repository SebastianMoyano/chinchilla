import SwiftUI

/// The everyday sibling of Gaming Mode: one switch, three honest,
/// persistent optimizations. Plain language first.
struct DailyBoostCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let boost = appState.dailyBoost
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.heart.fill")
                    .font(.title2)
                    .foregroundStyle(boost.isEnabled ? .green : .secondary)
                    .symbolEffect(.bounce, value: boost.isEnabled)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Everyday mode")
                        .font(.headline)
                    Text("Keeps your Mac feeling quick, automatically. No magic — three real things:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { boost.isEnabled },
                    set: { boost.toggle($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(.green)
                .controlSize(.large)
            }
            HStack(spacing: 14) {
                chip(
                    on: boost.isEnabled && boost.tabsOn,
                    icon: "square.on.square.dashed",
                    text: "Browser tabs sleep"
                )
                chip(
                    on: boost.isEnabled && boost.weeklyOn,
                    icon: "calendar.badge.clock",
                    text: "Weekly safe clean"
                )
                chip(
                    on: boost.isEnabled && boost.watchdogOn,
                    icon: "bell.badge",
                    text: "Memory heads-up"
                )
                Spacer()
            }
            if boost.isEnabled {
                Text("Heads-ups are gentle: at most one memory alert every 2 hours (only when it's genuinely struggling), and a restart reminder past 14 days of uptime, at most weekly.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(
            boost.isEnabled ? AnyShapeStyle(.green.opacity(0.08)) : AnyShapeStyle(.regularMaterial),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(boost.isEnabled ? .green.opacity(0.3) : .clear, lineWidth: 1)
        )
    }

    private func chip(on: Bool, icon: String, text: LocalizedStringKey) -> some View {
        Label(text, systemImage: on ? "checkmark.circle.fill" : icon)
            .font(.caption)
            .foregroundStyle(on ? .green : .secondary)
    }
}
