import Foundation

/// Decides what an everyday profile should actually do about memory, from this
/// Mac's own record.
///
/// Two things this deliberately does not do.
///
/// It never tries to "free RAM" by allocating a large block to evict everyone
/// else. That trick makes the free-memory counter look good by pushing the
/// working set of the apps you are using into swap, so the next click on each
/// of them waits on the disk. It raises swap, raises SSD writes, and is the
/// reason cleaning apps have the reputation they do.
///
/// It also doesn't treat pausing as reclamation. `SIGSTOP` stops a process from
/// running; its pages stay exactly where they were. Only three things give
/// memory back: discarding a browser tab (the renderer process dies), quitting
/// an app, and stopping a virtual machine.
public enum MemoryPlan {

    /// What an app is *for*, as far as memory policy is concerned. Decided by
    /// how it behaves over days, not by how big it is right now.
    public enum Role: String, Sendable {
        /// Always there and you're using it. Off limits.
        case essential
        /// Always there, and holds memory whether or not it is doing anything.
        /// This is where the honest wins are.
        case reclaimable
        /// Showed up once. Not a pattern, not worth a rule.
        case occasional
    }

    public struct Action: Sendable, Identifiable, Equatable {
        public enum Kind: String, Sendable {
            /// Reversible with no loss: the tab comes back when clicked.
            case sleepBackgroundTabs
            /// Reversible: the VM restarts in seconds when a container is run.
            case stopDockerVM
            /// Not reversible on its own — must be asked before it is done.
            case quitApp
        }

        public var id: String { kind.rawValue + ":" + target }
        public let kind: Kind
        /// App name, or empty for machine-wide actions.
        public let target: String
        /// Why this is being proposed, in the user's terms. An action without
        /// a reason is just an app being bossy; "holding 1.8 GB and hasn't
        /// done anything for 40 minutes" is something a person can judge.
        public let reason: String
        /// What this is expected to give back, from what it has actually been
        /// holding. An estimate, and the UI has to say so.
        public let estimatedBytes: Int64
        /// True when doing it costs the user nothing they can't undo by
        /// carrying on as normal.
        public var isReversible: Bool { kind != .quitApp }

        public init(kind: Kind, target: String, estimatedBytes: Int64, reason: String = "") {
            self.kind = kind
            self.target = target
            self.estimatedBytes = estimatedBytes
            self.reason = reason
        }
    }

    /// The whole judgement, in one value.
    public struct Plan: Sendable {
        /// Swap at which *this* Mac starts to drag, learned from its history.
        public let threshold: Int64
        public let isOverThreshold: Bool
        /// Memory this Mac's daily set asks for, against what it has.
        public let dailyDemandBytes: Int64
        public let installedBytes: Int64
        public let roles: [String: Role]
        /// Least disruptive first.
        public let actions: [Action]

        public var shortfallBytes: Int64 { max(0, dailyDemandBytes - installedBytes) }
        public var reversibleActions: [Action] { actions.filter(\.isReversible) }

        /// The same plan with one action spent. Acted-on offers have to
        /// disappear immediately, not linger until the next reading.
        public func removing(_ action: Action) -> Plan {
            Plan(
                threshold: threshold, isOverThreshold: isOverThreshold,
                dailyDemandBytes: dailyDemandBytes, installedBytes: installedBytes,
                roles: roles, actions: actions.filter { $0.id != action.id }
            )
        }
    }

    /// Apps that hold memory without being used, and are cheap to bring back.
    /// Kept as names because that is what the sampler records.
    public static let knownReclaimable: Set<String> = [
        // Docker Desktop runs a VM that holds its reservation whether or not a
        // container is running — the single biggest reversible win on a
        // developer's Mac.
        "Docker", "Docker Desktop", "com.docker.backend",
    ]

    /// Never proposed for quitting, whatever the numbers say: the user is
    /// either in it right now or it's us.
    static let neverQuit: Set<String> = [
        "Chinchilla", "Finder", "macOS", "loginwindow", "WindowServer",
    ]

    /// The swap level at which this Mac has historically felt slow.
    ///
    /// A fixed constant is wrong in both directions: 2 GB of swap is nothing on
    /// a 64 GB desktop that never pages in anger, and is a bad afternoon on an
    /// 8 GB laptop. So take this machine's own distribution — the point it
    /// passes in its worst quarter of readings — and floor it at the level
    /// below which macOS is simply doing its job.
    /// The band the learned threshold has to stay inside, as a share of
    /// installed memory. Learning happens *within* it.
    ///
    /// The ceiling exists because of a real 8 GB Mac. It swapped in 100% of its
    /// readings, so the 75th percentile of its own history came out at 4.9 GB —
    /// above what it was doing at that moment — and the plan concluded there
    /// was nothing to do. The history had taught it that permanent paging was
    /// this machine's normal. Adapting to a Mac is right; ratifying a Mac that
    /// is over budget every minute of the day is not.
    static func thresholdFloor(_ installedBytes: Int64) -> Int64 {
        max(1 << 30, installedBytes / 8)
    }

    static func thresholdCeiling(_ installedBytes: Int64) -> Int64 {
        max(thresholdFloor(installedBytes), installedBytes / 4)
    }

    public static func learnedThreshold(
        from samples: [MemorySample], installedBytes: Int64
    ) -> Int64 {
        let floor = thresholdFloor(installedBytes)
        let ceiling = thresholdCeiling(installedBytes)
        let swaps = samples.map(\.swapBytes).sorted()
        // Too few readings to have learned anything: sit at the floor.
        guard swaps.count >= 20 else { return floor }
        // 75th percentile: what a *bad* moment on this Mac looks like, without
        // letting one outlier set the bar.
        let index = min(swaps.count - 1, Int(Double(swaps.count) * 0.75))
        return min(ceiling, max(floor, swaps[index]))
    }

    /// Classifies each app from how constantly it is around.
    public static func roles(
        for offenders: [MemoryOffender], reclaimable: Set<String> = knownReclaimable
    ) -> [String: Role] {
        var roles: [String: Role] = [:]
        for offender in offenders {
            if reclaimable.contains(offender.name) {
                roles[offender.name] = .reclaimable
            } else if offender.presence >= 0.5 {
                roles[offender.name] = .essential
            } else {
                roles[offender.name] = .occasional
            }
        }
        return roles
    }

    /// What this Mac's normal working set asks for: the typical size of every
    /// app that is around at least half the time, added up.
    public static func dailyDemand(for offenders: [MemoryOffender]) -> Int64 {
        offenders.filter { $0.presence >= 0.5 }.reduce(0) { $0 + $1.averageBytes }
    }

    /// The plan itself.
    ///
    /// - Parameters:
    ///   - dockerIdle: whether Docker has had no containers running for long
    ///     enough that stopping its VM costs nothing.
    ///   - refusedQuits: apps the user has already said no to. Asked once, per
    ///     app, and never again.
    public static func make(
        samples: [MemorySample],
        currentSwapBytes: Int64,
        installedBytes: Int64,
        browserTabsAsleep: Bool,
        dockerIdle: Bool,
        refusedQuits: Set<String> = []
    ) -> Plan {
        let offenders = MemoryHistory.offenders(in: samples)
        let threshold = learnedThreshold(from: samples, installedBytes: installedBytes)
        let roles = roles(for: offenders)
        let over = currentSwapBytes > threshold

        var actions: [Action] = []
        guard over else {
            return Plan(
                threshold: threshold, isOverThreshold: false,
                dailyDemandBytes: dailyDemand(for: offenders),
                installedBytes: installedBytes, roles: roles, actions: []
            )
        }

        // 1. Reversible, invisible, and it genuinely frees: a discarded tab's
        //    process is gone until you click it.
        if !browserTabsAsleep, let browser = offenders.first(where: { isBrowser($0.name) }) {
            actions.append(Action(
                kind: .sleepBackgroundTabs, target: browser.name,
                // Only background tabs go, so a share of it — not the lot.
                estimatedBytes: browser.averageBytes / 3
            ))
        }

        // 2. Reversible, and the biggest single win on a developer's Mac.
        if dockerIdle, let docker = offenders.first(where: { roles[$0.name] == .reclaimable }) {
            actions.append(Action(
                kind: .stopDockerVM, target: docker.name,
                estimatedBytes: docker.averageBytes
            ))
        }

        // 3. Only now, and only as a question. Ranked by what it would give
        //    back while the Mac is actually swapping, which is the number that
        //    matters — not by who is biggest on a good day.
        //
        //    Drawn from a wider net than the rest of the plan on purpose: the
        //    offenders list answers "what holds memory constantly", and by
        //    construction an app that is only around sometimes never appears in
        //    it. But "around sometimes, huge, and idle" is exactly the app
        //    worth asking about. Two questions, two lists.
        //    The candidate is an app that is *doing nothing with* the memory it
        //    holds — measured, not assumed. Size alone was never a reason to
        //    close anything; an editor at 3 GB that you're typing in is not a
        //    problem, and a chat app at 1.8 GB that hasn't moved in forty
        //    minutes is the whole point of asking.
        let candidates = MemoryHistory.idleHogs(in: samples)
            .filter { !knownReclaimable.contains($0.name) }
            .filter { !neverQuit.contains($0.name) && !refusedQuits.contains($0.name) }
            // Browsers get their tabs slept instead; closing one loses the
            // user's place in a way a chat app doesn't.
            .filter { !isBrowser($0.name) }
        if let idlest = candidates.first {
            actions.append(Action(
                kind: .quitApp, target: idlest.name,
                estimatedBytes: idlest.bytes,
                reason: idleReason(idlest)
            ))
        }

        return Plan(
            threshold: threshold, isOverThreshold: true,
            dailyDemandBytes: dailyDemand(for: offenders),
            installedBytes: installedBytes, roles: roles, actions: actions
        )
    }

    /// The sentence the user actually reads. One reading a minute, so the
    /// count of idle readings is a count of minutes.
    public static func idleReason(_ hog: MemoryHistory.IdleHog) -> String {
        let size = ByteCountFormatter.string(fromByteCount: hog.bytes, countStyle: .memory)
        let minutes = hog.idleSamples
        let span = minutes >= 120
            ? String(localized: "\(minutes / 60) hours")
            : String(localized: "\(minutes) minutes")
        // The app is named in the sentence, not just in a title somewhere
        // above it — a body that says "it" gets read against whatever name
        // is nearest, which in a notification is the *sender's*.
        return String(localized: "\(hog.name) is holding \(size) and hasn't done anything for \(span).")
    }

    static let browserNames: Set<String> = [
        "Google Chrome", "Chrome", "Safari", "Microsoft Edge", "Edge",
        "Brave Browser", "Brave", "Arc", "Firefox", "Chromium", "Vivaldi", "Opera",
    ]

    static func isBrowser(_ name: String) -> Bool {
        if browserNames.contains(name) { return true }
        // Beta and canary channels ship as "Google Chrome Canary",
        // "Firefox Developer Edition", "Safari Technology Preview" — all of
        // them the same thing for these purposes.
        return browserNames.contains { name.hasPrefix($0 + " ") }
    }
}
