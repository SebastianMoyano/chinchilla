import SwiftUI
import Charts
import SystemKit

/// Memory, over time.
///
/// Every other memory reading in this app is a snapshot, and a snapshot can't
/// answer the question people actually have — *which apps keep doing this to my
/// Mac?* A browser at 6 GB while you read in it is fine. A sync agent at 3 GB
/// all day, every day, is the thing worth knowing about, and it never wins a
/// "biggest right now" list.
///
/// Split into small views on purpose: one big body is what put this app's view
/// tree 548 levels deep and pinned a core.
struct MemoryView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var history = appState.memoryHistory
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MemoryCard()
                if history.hasEnoughHistory {
                    MemoryPlanCard()
                    MemorySwapChart(model: history, window: $history.windowHours)
                    MemoryOffendersCard(model: history)
                    MemoryWorstMomentCard(model: history)
                } else {
                    MemoryCollectingCard(model: history)
                }
            }
            .padding(20)
        }
        .navigationTitle("Memory")
        .onAppear {
            appState.memoryHistory.load()
            appState.everydayPlan.refresh(samples: appState.memoryHistory.samples)
            Task { await appState.everydayPlan.refreshDockerIdle() }
        }
    }
}

/// The budget, and what to do about it.
///
/// The honest framing for a Mac that's short of memory isn't a button that
/// claims to free some — it's arithmetic. Your daily set asks for X, the
/// machine has Y, and here is what closing the gap actually costs you.
private struct MemoryPlanCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var everyday = appState.everydayPlan
        if let plan = everyday.plan {
            VStack(alignment: .leading, spacing: 10) {
                Label("Your daily memory budget", systemImage: "chart.bar.doc.horizontal")
                    .font(.headline)
                MemoryBudgetLine(plan: plan)

                if plan.isOverThreshold {
                    Text("Your Mac is past the point where it has historically started to drag (\(Formatters.bytes(plan.threshold)) of swap). That figure comes from this Mac's own record, not a number we picked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(plan.actions) { action in
                        MemoryActionRow(action: action, everyday: everyday)
                    }
                } else {
                    Label("Nothing worth doing right now.", systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(Theme.ok)
                }

                if let outcome = everyday.lastOutcome {
                    Text(verbatim: outcome)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            .confirmationDialog(
                everyday.pendingQuit.map { "Close \($0.target)?" } ?? "",
                isPresented: Binding(
                    get: { everyday.pendingQuit != nil },
                    set: { if !$0 { everyday.pendingQuit = nil } }
                ),
                titleVisibility: .visible,
                presenting: everyday.pendingQuit
            ) { action in
                Button("Close it") { everyday.confirmQuit(action) }
                Button("Never ask about this app", role: .destructive) {
                    everyday.refuseQuit(action)
                }
                Button("Not now", role: .cancel) { everyday.pendingQuit = nil }
            } message: { action in
                // The accused is named in the sentence itself. "It's holding…"
                // relied on the title for the antecedent, and a user reading
                // just the body concluded Chinchilla was offering to close
                // *itself* — the only name anywhere near the text was ours.
                Text("\(action.target) is holding about \(Formatters.bytes(action.estimatedBytes)) while your Mac is swapping, and you haven't had it open all day. \(action.target) will be asked to close, so anything unsaved still gets its own prompt.")
            }
        }
    }
}

private struct MemoryBudgetLine: View {
    let plan: MemoryPlan.Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: Formatters.bytes(plan.dailyDemandBytes))
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(plan.shortfallBytes > 0 ? Theme.caution : Theme.ok)
                Text("asked for by the apps you keep open, against \(Formatters.bytes(plan.installedBytes)) installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if plan.shortfallBytes > 0 {
                Text("You're about \(Formatters.bytes(plan.shortfallBytes)) over. No amount of cleaning changes that — it's arithmetic. What helps is not keeping all of it resident at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MemoryActionRow: View {
    let action: MemoryPlan.Action
    let everyday: EverydayPlanModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(action.isReversible ? Theme.ok : Theme.caution)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text("~\(Formatters.bytes(action.estimatedBytes))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch action.kind {
        case .sleepBackgroundTabs: "moon.zzz"
        case .stopDockerVM: "shippingbox"
        case .quitApp: "xmark.circle"
        }
    }

    private var title: LocalizedStringKey {
        switch action.kind {
        case .sleepBackgroundTabs: "Sleep background tabs"
        case .stopDockerVM: "Stop Docker's virtual machine"
        case .quitApp: "Close \(action.target)"
        }
    }

    /// Every row says what it costs you, because "reversible" is the whole
    /// reason two of these happen without asking.
    private var subtitle: LocalizedStringKey {
        switch action.kind {
        case .sleepBackgroundTabs: "Automatic — a tab wakes up when you click it"
        case .stopDockerVM: "Automatic while no containers are running — starts again on your next docker command"
        case .quitApp: "Only if you say so, and only asked once"
        }
    }
}

/// Says what's happening instead of showing an empty chart. A blank graph
/// reads as broken; "I have four minutes of data" reads as honest.
private struct MemoryCollectingCard: View {
    let model: MemoryHistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Still watching", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(.headline)
            Text("Chinchilla takes a reading every minute while it's running, and keeps a few days of them. Once there's enough, this screen shows which apps hold memory constantly — and which were around when your Mac started using swap.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(model.chartSamples.count) readings so far.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct MemorySwapChart: View {
    let model: MemoryHistoryModel
    @Binding var window: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Swap over time", systemImage: "arrow.left.arrow.right")
                    .font(.headline)
                Spacer()
                Picker("", selection: $window) {
                    Text("6h").tag(6.0)
                    Text("24h").tag(24.0)
                    Text("3d").tag(72.0)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            Text("Swap is disk borrowed as memory. When this line climbs, every click starts waiting on the disk — that's the \"my Mac feels stuck\" feeling, and it's the honest measure of being short on RAM.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Chart(model.chartSamples, id: \.at) { sample in
                AreaMark(
                    x: .value("Time", sample.at),
                    y: .value("Swap", Double(sample.swapBytes) / Double(1 << 30))
                )
                .foregroundStyle(Theme.action.opacity(0.25))
                LineMark(
                    x: .value("Time", sample.at),
                    y: .value("Swap", Double(sample.swapBytes) / Double(1 << 30))
                )
                .foregroundStyle(Theme.action)
            }
            .chartYAxisLabel("GB")
            .frame(height: 160)

            MemorySwapVerdict(share: model.swappingShare, coverage: model.coverage)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct MemorySwapVerdict: View {
    let share: Double
    let coverage: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(verdict).font(.callout)
            Spacer()
            if let coverage {
                Text("over \(coverage)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var percent: Int { Int((share * 100).rounded()) }

    private var verdict: LocalizedStringKey {
        switch share {
        case ..<0.05: "Your Mac has hardly touched swap. Memory is not your bottleneck."
        case ..<0.25: "Swapping \(percent)% of the time — occasional, and usually under a heavy load."
        case ..<0.6: "Swapping \(percent)% of the time. This is where the Mac starts feeling slow for no visible reason."
        default: "Swapping \(percent)% of the time. This Mac is short of memory for how it's being used."
        }
    }

    private var symbol: String {
        share < 0.05 ? "checkmark.circle.fill"
            : share < 0.25 ? "info.circle.fill"
            : share < 0.6 ? "exclamationmark.triangle.fill" : "exclamationmark.octagon.fill"
    }

    private var tint: Color {
        share < 0.05 ? Theme.ok : share < 0.25 ? Theme.primary
            : share < 0.6 ? Theme.caution : Theme.danger
    }
}

private struct MemoryOffendersCard: View {
    let model: MemoryHistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("What holds your memory", systemImage: "list.number")
                .font(.headline)
            Text("Ranked by how much they hold *and* how constantly — not by who happens to be biggest this second.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(model.offenders.prefix(8)) { offender in
                MemoryOffenderRow(offender: offender)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct MemoryOffenderRow: View {
    let offender: MemoryOffender

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: offender.name)
                    .fontWeight(.medium)
                Text(presence)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: Formatters.bytes(offender.averageBytes))
                    .monospacedDigit()
                Text("peak \(Formatters.bytes(offender.peakBytes))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            if let swapping = offender.averageWhileSwapping {
                Divider().frame(height: 26)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: Formatters.bytes(swapping))
                        .monospacedDigit()
                        .foregroundStyle(Theme.caution)
                    Text("while swapping")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 110, alignment: .trailing)
            } else {
                Spacer().frame(width: 110)
            }
        }
        .padding(.vertical, 3)
    }

    /// "Constantly" turned into something checkable.
    private var presence: LocalizedStringKey {
        let percent = Int((offender.presence * 100).rounded())
        return percent >= 95
            ? "running the whole time"
            : "up \(percent)% of the time"
    }
}

private struct MemoryWorstMomentCard: View {
    let model: MemoryHistoryModel

    var body: some View {
        if let worst = model.worstSwap {
            VStack(alignment: .leading, spacing: 8) {
                Label("Worst moment", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text("\(Formatters.bytes(worst.swapBytes)) of swap on \(worst.at.formatted(date: .abbreviated, time: .shortened)). These were the biggest apps running then:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(worst.apps, id: \.name) { app in
                    HStack {
                        Text(verbatim: app.name)
                        Spacer()
                        Text(verbatim: Formatters.bytes(app.bytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                Text("They were present, which isn't the same as at fault — but it's where to look first.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }
}
