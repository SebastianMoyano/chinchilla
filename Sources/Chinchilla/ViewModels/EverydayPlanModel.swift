import SwiftUI
import Observation
import AppKit
import SystemKit
import DiskScanKit

/// Runs the everyday memory plan: acts on its own only where the user can undo
/// it by carrying on as normal, and asks — once per app, ever — for anything
/// else.
///
/// Deliberately absent: any "free RAM" button. Allocating a big block to evict
/// everyone else makes the free-memory counter look good by pushing the working
/// set of the apps you're using into swap, so your next click on each of them
/// waits on the disk. It raises swap and SSD writes and lowers nothing anyone
/// can feel.
@MainActor
@Observable
final class EverydayPlanModel {
    private static let refusedKey = "everyday.refusedQuits"
    private static let lastActionKey = "everyday.lastAction"
    /// Acting more often than this is nagging, not helping — and each action
    /// takes time to show up in the readings anyway.
    private static let cooldown: TimeInterval = 30 * 60

    private(set) var plan: MemoryPlan.Plan?
    private(set) var lastOutcome: String?
    private(set) var working = false
    /// The app the plan wants to close, waiting on an answer. Set only when
    /// the user hasn't already refused it.
    var pendingQuit: MemoryPlan.Action?

    weak var appState: AppState?

    var refusedQuits: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.refusedKey) ?? [])
    }

    /// Recomputes the plan. Cheap, and reads nothing from disk.
    func refresh(samples: [MemorySample]) {
        let memory = SystemSampler.memoryUsage()
        plan = MemoryPlan.make(
            samples: samples,
            currentSwapBytes: SystemSampler.swapUsed(),
            installedBytes: memory.total,
            browserTabsAsleep: appState?.tabSaver.anySaverOn ?? false,
            dockerIdle: dockerIdle,
            refusedQuits: refusedQuits
        )
    }

    /// Whether Docker's VM is holding memory for nothing. Unknown counts as
    /// busy: an unreachable daemon is not permission to stop anything.
    private(set) var dockerIdle = false

    private var lastDockerProbe: Date?

    /// Rate-limited: the probe spawns the docker CLI, and the Memory tab
    /// asked on every visit. Plan *building* can live with a two-minute-old
    /// answer — anything that acts on it re-checks with `force` first.
    func refreshDockerIdle(force: Bool = false) async {
        if !force, let lastDockerProbe, Date().timeIntervalSince(lastDockerProbe) < 120 { return }
        lastDockerProbe = Date()
        let count = await DockerClient.runningContainerCount()
        dockerIdle = count == 0
    }

    /// Does the reversible actions and then asks about the rest.
    ///
    /// The question used to be gated behind a reversible action having
    /// succeeded first, which got it exactly backwards: on a Mac where there is
    /// nothing free left to do — tabs already asleep, no Docker — the app went
    /// quiet at precisely the moment it had something useful to say.
    func apply() async {
        guard let plan, plan.isOverThreshold, !working else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastActionKey)
        guard Date.now.timeIntervalSince1970 - last > Self.cooldown else { return }

        working = true
        defer { working = false }
        var done: [String] = []

        for action in plan.reversibleActions {
            switch action.kind {
            case .sleepBackgroundTabs:
                appState?.tabSaver.setAllMemorySavers(true)
                done.append(String(localized: "put background tabs to sleep"))
            case .stopDockerVM:
                // Checked again here, not just when the plan was built: a
                // container may have started in between, and stopping the VM
                // under a running build is not a reversible act. Forced past
                // the rate limit — this answer must be current.
                await refreshDockerIdle(force: true)
                guard dockerIdle else { continue }
                do {
                    try await DockerClient.stopDesktop()
                    done.append(String(localized: "stopped Docker's virtual machine"))
                } catch {
                    // Docker not being stoppable is not worth a message.
                    continue
                }
            case .quitApp:
                continue  // never automatic
            }
        }

        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: Self.lastActionKey)
        if !done.isEmpty {
            lastOutcome = String(localized: "Chinchilla \(done.joined(separator: " and ")).")
        }

        // With the free ones spent, whatever is left is worth a question —
        // asked wherever the user happens to be, not only if they are looking
        // at this screen.
        if let quit = plan.actions.first(where: { $0.kind == .quitApp }) {
            pendingQuit = quit
            await MemoryNotifier.ask(about: quit)
        }
    }

    /// The user said yes to closing this app. Asked politely — an application
    /// with unsaved work gets to put its own dialog up, and a plain process
    /// gets SIGTERM rather than SIGKILL.
    func confirmQuit(_ action: MemoryPlan.Action) {
        pendingQuit = nil
        // The plan named this app; with it gone the offer must go too, rather
        // than sit there until the next reading.
        plan = plan.map { $0.removing(action) }
        Task {
            let outcome = await AppTerminator.close(name: action.target)
            lastOutcome = AppTerminator.describe(outcome, target: action.target)
        }
    }

    /// The user said no. Remembered for good — being asked twice about the
    /// same app is how a helpful prompt turns into a nuisance.
    func refuseQuit(_ action: MemoryPlan.Action) {
        pendingQuit = nil
        plan = plan.map { $0.removing(action) }
        var refused = refusedQuits
        refused.insert(action.target)
        UserDefaults.standard.set(Array(refused), forKey: Self.refusedKey)
    }

    func forgetRefusals() {
        UserDefaults.standard.removeObject(forKey: Self.refusedKey)
    }
}
