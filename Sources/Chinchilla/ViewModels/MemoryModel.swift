import SwiftUI
import Observation
import AppKit
import SystemKit

/// "Memory Doctor": explains memory health in plain language and offers the
/// only honest fixes — closing the real consumers, sleeping browser tabs,
/// trimming login items. No fake "free RAM" buttons.
@MainActor
@Observable
final class MemoryModel {
    enum Health {
        case fine       // pressure normal
        case tight      // warning
        case struggling // critical
        case unknown
    }

    var health: Health = .unknown
    var swapUsed: Int64 = 0
    var memoryTotal: Int64 = 0
    var topApps: [AppMemoryUsage] = []
    var refreshing = false

    struct Tip: Identifiable {
        /// Derived from the icon, which is unique across every branch that
        /// builds one. A `UUID()` default looked harmless, but `tips` is
        /// *computed*: every read minted fresh ids, so each render handed
        /// ForEach a wholly different identity set and the whole subtree was
        /// torn down and re-inserted instead of updated.
        var id: String { icon }
        let icon: String
        let text: LocalizedStringKey
        let destination: SidebarItem?
    }

    /// The in-flight refresh, kept so a follow-up (post-quit) can wait for it
    /// instead of racing a second process enumeration against it.
    private var refreshTask: Task<Void, Never>?

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        refreshTask = Task {
            let pressure = SystemSampler.memoryPressure()
            health = switch pressure {
            case .normal: .fine
            case .warning: .tight
            case .critical: .struggling
            case .unknown: .unknown
            }
            swapUsed = SystemSampler.swapUsed()
            var size: UInt64 = 0
            var length = MemoryLayout<UInt64>.size
            sysctlbyname("hw.memsize", &size, &length, nil, 0)
            memoryTotal = Int64(size)
            topApps = await Task.detached(priority: .userInitiated) {
                await ProcessMemory.topConsumersWithCPU()
            }.value
            appleIntelligenceBusy = await Task.detached {
                ProcessMemory.appleIntelligenceActive()
            }.value
            quittableNames = Set(
                NSWorkspace.shared.runningApplications
                    .filter { $0.activationPolicy == .regular }
                    .compactMap(\.localizedName)
            )
            refreshing = false
        }
    }

    var appleIntelligenceBusy = false

    /// The biggest actionable consumer (excluding the macOS bucket).
    var biggestApp: AppMemoryUsage? {
        topApps.first { $0.name != "macOS" }
    }

    /// Taken once per refresh. Asking `NSWorkspace` per row meant enumerating
    /// every process on the Mac four times for one card, on every render.
    private(set) var quittableNames: Set<String> = []

    func canQuit(_ app: AppMemoryUsage) -> Bool {
        quittableNames.contains(app.name)
    }

    func quit(_ app: AppMemoryUsage) {
        runningApplication(named: app.name)?.terminate()
        Task {
            // Give the app a moment to actually exit before re-reading.
            try? await Task.sleep(for: .seconds(2))
            // Force-clearing `refreshing` here defeated the re-entrancy
            // guard and let two full process enumerations race. Waiting the
            // in-flight one out keeps the guard honest and still delivers
            // the post-quit refresh.
            await refreshTask?.value
            refresh()
        }
    }

    private func runningApplication(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.localizedName == name
        }
    }

    private static let browserNames: Set<String> = [
        "Google Chrome", "Safari", "Microsoft Edge", "Brave Browser", "Arc", "Firefox",
    ]

    var tips: [Tip] {
        var tips: [Tip] = []
        if let biggest = biggestApp, Self.browserNames.contains(biggest.name) {
            tips.append(Tip(
                icon: "square.on.square.dashed",
                text: "Your browser is the biggest memory user. \"Put background tabs to sleep\" (below) helps a lot without closing anything.",
                destination: nil
            ))
        }
        if health != .fine, swapUsed > 2 << 30 {
            tips.append(Tip(
                icon: "arrow.left.arrow.right",
                text: "Your Mac is borrowing disk space as emergency memory (swap). Closing apps you're not using right now gives the biggest relief.",
                destination: nil
            ))
        }
        if memoryTotal <= 8 << 30, health != .fine {
            tips.append(Tip(
                icon: "memorychip",
                text: "With 8 GB of memory, 2–3 big apps at a time is the sweet spot. Check what launches automatically in Startup.",
                destination: .startup
            ))
        }
        if appleIntelligenceBusy, memoryTotal <= 16 << 30, health != .fine {
            tips.append(Tip(
                icon: "sparkle",
                text: "Apple Intelligence is working in the background right now. On smaller Macs it's a real memory/CPU user — if you don't use it, turning it off in System Settings → Apple Intelligence & Siri gives resources back.",
                destination: nil
            ))
        }
        if health == .fine, tips.isEmpty {
            tips.append(Tip(
                icon: "checkmark.circle",
                text: "Nothing to free: macOS deliberately keeps memory busy to make your apps faster. \"Used\" memory is not a problem — pressure is, and yours is fine.",
                destination: nil
            ))
        }
        return Array(tips.prefix(3))
    }
}
