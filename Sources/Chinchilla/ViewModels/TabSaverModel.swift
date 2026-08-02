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
    }

    /// One switch for all installed Chromium browsers ("simple form").
    func setAllMemorySavers(_ enabled: Bool) {
        for state in policyBrowsers {
            BrowserTuner.setMemorySaver(enabled, for: state.browser)
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
