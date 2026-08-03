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

    /// Auto = judge the machine honestly: ≤8 GB of RAM or non-normal memory
    /// pressure → light; otherwise balanced. Re-evaluated on refresh and by
    /// the Everyday-mode watchdog, so a Mac having a bad day gets relief.
    static func autoLevel() -> BrowserTuner.BrowserPerfLevel {
        var size: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &length, nil, 0)
        if size <= 8 << 30 { return .light }
        return SystemSampler.memoryPressure() == .normal ? .balanced : .light
    }

    var resolvedLevel: BrowserTuner.BrowserPerfLevel {
        switch perfMode {
        case .auto: Self.autoLevel()
        case .light: .light
        case .balanced: .balanced
        case .full: .full
        }
    }

    /// Rewrites the policies for the current mode; called when the mode
    /// changes and by the watchdog when auto's answer changes.
    static let lastAppliedKey = "tabSaver.lastAppliedLevel"

    func applyCurrentLevel() {
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
        let level = Self.autoLevel()
        guard level.rawValue != UserDefaults.standard.string(forKey: Self.lastAppliedKey) else { return }
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
