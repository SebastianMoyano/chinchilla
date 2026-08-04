import SwiftUI
import Observation
import SystemKit

@MainActor
@Observable
final class TabSaverModel {
    struct BrowserState: Identifiable {
        let browser: TunableBrowser
        var memorySaverOn: Bool
        var id: String { browser.id }
    }

    var states: [BrowserState] = []
    var closingTabs = false
    var lastReport: String?

    /// User-chosen performance mode: "auto" adapts to the machine.
    enum PerfMode: String, CaseIterable {
        case auto, light, balanced, full
    }
    static let perfModeKey = "tabSaver.perfMode"

    var perfMode: PerfMode {
        get {
            PerfMode(rawValue: UserDefaults.standard.string(forKey: Self.perfModeKey) ?? "auto") ?? .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.perfModeKey)
            if anySaverOn { applyCurrentLevel() }
        }
    }

    /// Auto = judge how the Mac *feels*, not how much RAM it was sold with.
    ///
    /// The old rule sent every 8 GB machine to `.light` permanently and asked
    /// a single flapping sysctl for everything above that. Swap is the signal
    /// that matches the complaint: once macOS is paging, every click waits on
    /// the disk. See `BrowserPressurePolicy` — it also carries the hysteresis
    /// that stops a machine on the boundary from flipping every reading.
    static func autoLevel(current: BrowserTuner.BrowserPerfLevel? = nil) -> BrowserTuner.BrowserPerfLevel {
        let memory = SystemSampler.memoryUsage()
        let reading = BrowserPressurePolicy.Reading(
            totalBytes: memory.total,
            usedBytes: memory.used,
            swapBytes: SystemSampler.swapUsed(),
            pressure: SystemSampler.memoryPressure()
        )
        let decided = BrowserPressurePolicy.level(
            for: reading,
            current: current.flatMap { BrowserPressurePolicy.Level(rawValue: $0.rawValue) }
        )
        return BrowserTuner.BrowserPerfLevel(rawValue: decided.rawValue) ?? .balanced
    }

    var resolvedLevel: BrowserTuner.BrowserPerfLevel {
        switch perfMode {
        case .auto: Self.autoLevel(
            current: UserDefaults.standard.string(forKey: Self.lastAppliedKey)
                .flatMap(BrowserTuner.BrowserPerfLevel.init(rawValue:))
        )
        case .light: .light
        case .balanced: .balanced
        case .full: .full
        }
    }

    /// Rewrites the policies for the current mode; called when the mode
    /// changes and by the watchdog when auto's answer changes.
    static let lastAppliedKey = "tabSaver.lastAppliedLevel"

    /// True while a level is being written, so the `refresh()` at the end of
    /// that write can't start another one.
    ///
    /// The cycle is applyCurrentLevel → refresh → reevaluateAutoIfNeeded →
    /// applyCurrentLevel, and it was documented as terminating because "the
    /// level is the same the second time". It isn't: `autoLevel()` reads the
    /// pressure sysctl live, so a Mac hovering on the normal/warning boundary
    /// returns a different answer on consecutive reads and the cycle never
    /// closes. Reproduced with an alternating source: 20 001 nested calls
    /// before the harness cut it off, each one a cfprefsd round-trip per
    /// installed browser, all on the main actor.
    ///
    /// Skipping one adjustment costs nothing — the Everyday watchdog
    /// re-evaluates every five minutes, and so does opening the Dashboard.
    private var applyingLevel = false

    func applyCurrentLevel() {
        guard !applyingLevel else { return }
        applyingLevel = true
        defer { applyingLevel = false }
        let level = resolvedLevel
        for state in policyBrowsers {
            BrowserTuner.setPerformanceLevel(level, for: state.browser)
        }
        UserDefaults.standard.set(level.rawValue, forKey: Self.lastAppliedKey)
        refresh()
    }

    /// Cheap no-op unless auto's answer actually changed — called by the
    /// Everyday-mode watchdog every few minutes.
    func reevaluateAutoIfNeeded() {
        guard anySaverOn, perfMode == .auto else { return }
        let applied = UserDefaults.standard.string(forKey: Self.lastAppliedKey)
        let level = Self.autoLevel(
            current: applied.flatMap(BrowserTuner.BrowserPerfLevel.init(rawValue:))
        )
        guard level.rawValue != applied else { return }
        applyCurrentLevel()
    }

    /// Chromium browsers installed that support the Memory Saver policy.
    var policyBrowsers: [BrowserState] {
        states.filter { $0.browser.policyDomain != nil }
    }

    var anySaverOn: Bool {
        policyBrowsers.contains { $0.memorySaverOn }
    }

    func refresh() {
        states = BrowserTuner.browsers
            .filter { BrowserTuner.isInstalled($0) }
            .map {
                BrowserState(
                    browser: $0,
                    memorySaverOn: BrowserTuner.isMemorySaverManaged($0)
                )
            }
        // Auto stays live even without the Everyday-mode watchdog: every
        // Dashboard visit re-judges the machine. The lastApplied guard makes
        // this a no-op unless the answer actually changed (no recursion:
        // applyCurrentLevel → refresh → here → same level → stop).
        reevaluateAutoIfNeeded()
    }

    /// One switch for all installed Chromium browsers ("simple form").
    /// On = apply the current performance level; off = remove every policy.
    func setAllMemorySavers(_ enabled: Bool) {
        for state in policyBrowsers {
            BrowserTuner.setPerformanceLevel(enabled ? resolvedLevel : nil, for: state.browser)
        }
        refresh()
    }

    func closeDuplicates() {
        guard !closingTabs else { return }
        closingTabs = true
        BusyDeadline.arm("TabSaver.closing", .seconds(120)) { [weak self] in
            self?.closingTabs ?? false
        } clear: { [weak self] in self?.closingTabs = false }
        lastReport = nil
        Task {
            defer { closingTabs = false }
            var lines: [String] = []
            for state in states where state.browser.supportsDuplicateClose {
                do {
                    let report = try await BrowserTuner.closeDuplicateTabs(in: state.browser)
                    lines.append(String(localized: "\(report.browser): closed \(report.closed), kept \(report.remaining)"))
                } catch {
                    // Browser not running or Automation permission denied — skip quietly.
                    continue
                }
            }
            lastReport = lines.isEmpty
                ? String(localized: "No browser with open tabs found.")
                : lines.joined(separator: " · ")
        }
    }
}
