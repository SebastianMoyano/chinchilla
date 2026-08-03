import Foundation
import CoreFoundation

public struct TunableBrowser: Sendable, Identifiable {
    public let id: String            // bundle ID
    public let name: String
    /// Preference domain Chrome-family policies are read from (user level,
    /// per https://www.chromium.org/administrators/mac-quick-start/).
    public let policyDomain: String?
    public let supportsDuplicateClose: Bool
    /// AppleScript application name for tab enumeration.
    public let scriptName: String?
}

/// Makes tab-hoarder browsers lighter:
/// 1. Memory Saver (Chromium's own tab discarding — background tabs stop
///    rendering and free their memory) enabled via user-level policy.
/// 2. Closing duplicate tabs via AppleScript.
/// Everything is reversible; Chrome shows "Managed by your organization"
/// while any policy key is set — we disclose that in the UI.
public enum BrowserTuner {
    public static let browsers: [TunableBrowser] = [
        TunableBrowser(
            id: "com.google.Chrome", name: "Chrome",
            policyDomain: "com.google.Chrome",
            supportsDuplicateClose: true, scriptName: "Google Chrome"
        ),
        TunableBrowser(
            id: "com.microsoft.edgemac", name: "Edge",
            policyDomain: "com.microsoft.Edge",
            supportsDuplicateClose: false, scriptName: nil
        ),
        TunableBrowser(
            id: "com.brave.Browser", name: "Brave",
            policyDomain: "com.brave.Browser",
            supportsDuplicateClose: false, scriptName: nil
        ),
        TunableBrowser(
            id: "com.apple.Safari", name: "Safari",
            policyDomain: nil,  // Safari has no discard policy; macOS manages it
            supportsDuplicateClose: true, scriptName: "Safari"
        ),
    ]

    public static func isInstalled(_ browser: TunableBrowser) -> Bool {
        if browser.id == "com.apple.Safari" { return true }
        let fm = FileManager.default
        return fm.fileExists(atPath: "/Applications/\(appName(browser)).app")
            || fm.fileExists(atPath: NSHomeDirectory() + "/Applications/\(appName(browser)).app")
    }

    private static func appName(_ browser: TunableBrowser) -> String {
        switch browser.id {
        case "com.google.Chrome": "Google Chrome"
        case "com.microsoft.edgemac": "Microsoft Edge"
        case "com.brave.Browser": "Brave Browser"
        default: browser.name
        }
    }

    // MARK: - Performance level policies

    /// Three real levers Chrome exposes as (recommended-level) policies:
    /// - MemorySaverModeSavings: 0 off · 1 moderate · 2 maximum savings
    /// - BatterySaverModeAvailability: 0 off · 1 at ≤20% battery · 2 whenever on battery
    /// - NetworkPredictionOptions: 0 allow preloading · 2 never preload
    /// HighEfficiencyModeEnabled is the older boolean spelling of Memory
    /// Saver, kept for Chromium builds that still read it.
    public enum BrowserPerfLevel: String, Sendable, CaseIterable {
        /// Struggling machine: maximum tab savings, aggressive energy saver,
        /// no page preloading (spends CPU/RAM/network on guesses).
        case light
        /// Sensible default: moderate savings, energy saver on low battery,
        /// preloading allowed.
        case balanced
        /// Plenty of headroom: keep the browser snappy — moderate memory
        /// saver still on (it helps everyone), preloading fully allowed.
        case full

        var memorySaver: Int {
            switch self {
            case .light: 2
            case .balanced, .full: 1
            }
        }

        var batterySaver: Int {
            switch self {
            case .light: 2
            case .balanced: 1
            case .full: 0
            }
        }

        var networkPrediction: Int {
            switch self {
            case .light: 2
            case .balanced, .full: 0
            }
        }
    }

    public static func isMemorySaverManaged(_ browser: TunableBrowser) -> Bool {
        guard let domain = browser.policyDomain else { return false }
        return CFPreferencesCopyAppValue("MemorySaverModeSavings" as CFString, domain as CFString) != nil
    }

    /// Applies a performance level (nil = remove all our policies).
    public static func setPerformanceLevel(_ level: BrowserPerfLevel?, for browser: TunableBrowser) {
        guard let domain = browser.policyDomain else { return }
        let appID = domain as CFString
        if let level {
            CFPreferencesSetAppValue("MemorySaverModeSavings" as CFString, level.memorySaver as CFNumber, appID)
            CFPreferencesSetAppValue("HighEfficiencyModeEnabled" as CFString, kCFBooleanTrue, appID)
            CFPreferencesSetAppValue("BatterySaverModeAvailability" as CFString, level.batterySaver as CFNumber, appID)
            CFPreferencesSetAppValue("NetworkPredictionOptions" as CFString, level.networkPrediction as CFNumber, appID)
            if domain == "com.microsoft.Edge" {
                CFPreferencesSetAppValue("SleepingTabsEnabled" as CFString, kCFBooleanTrue, appID)
            }
        } else {
            for key in ["MemorySaverModeSavings", "HighEfficiencyModeEnabled",
                        "BatterySaverModeAvailability", "NetworkPredictionOptions"] {
                CFPreferencesSetAppValue(key as CFString, nil, appID)
            }
            if domain == "com.microsoft.Edge" {
                CFPreferencesSetAppValue("SleepingTabsEnabled" as CFString, nil, appID)
            }
        }
        CFPreferencesAppSynchronize(appID)
    }

    /// Back-compat convenience used by the simple on/off toggle.
    public static func setMemorySaver(_ enabled: Bool, for browser: TunableBrowser) {
        setPerformanceLevel(enabled ? .balanced : nil, for: browser)
    }

    // MARK: - Duplicate tabs

    public struct TabReport: Sendable {
        public let browser: String
        public let closed: Int
        public let remaining: Int
    }

    /// Closes tabs whose URL already appears in an earlier window/tab.
    /// Requires the Automation permission (macOS prompts on first use).
    public static func closeDuplicateTabs(in browser: TunableBrowser) async throws -> TabReport {
        guard let scriptName = browser.scriptName else {
            throw ShellError(exitCode: -1, stderr: "unsupported browser")
        }
        // Two passes: scan forward so the FIRST (oldest) copy of each URL is
        // the one we keep, then close collected duplicates from the highest
        // indices down so earlier indices stay valid even when a window
        // empties and closes itself. Blank/new tabs (missing value) are never
        // treated as duplicates of each other.
        let script = """
        tell application "\(scriptName)"
            set seen to {}
            set dupWins to {}
            set dupTabs to {}
            set keptCount to 0
            set winCount to count of windows
            repeat with wi from 1 to winCount
                set tabCount to count of tabs of window wi
                repeat with ti from 1 to tabCount
                    set u to URL of tab ti of window wi
                    if u is missing value then
                        set keptCount to keptCount + 1
                    else if u is in seen then
                        set beginning of dupWins to wi
                        set beginning of dupTabs to ti
                        else
                        set end of seen to u
                        set keptCount to keptCount + 1
                    end if
                end repeat
            end repeat
            repeat with i from 1 to count of dupWins
                try
                    close tab (item i of dupTabs) of window (item i of dupWins)
                end try
            end repeat
            return ((count of dupWins) as string) & "," & (keptCount as string)
        end tell
        """
        let output = try await ShellRunner.run(
            "/usr/bin/osascript", ["-e", script], timeout: .seconds(60)
        )
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
        return TabReport(
            browser: browser.name,
            closed: Int(parts.first ?? "0") ?? 0,
            remaining: Int(parts.last ?? "0") ?? 0
        )
    }
}
