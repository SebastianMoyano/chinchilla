import Foundation

/// The built-in cleanup catalog. Paths and skip lists follow the plan's
/// domain spec; SafetyPolicy independently re-checks every deletion.
public enum RuleCatalog {
    /// Sync/auth state inside ~/Library/Caches that must never be swept.
    /// (SafetyPolicy also blocks these by substring — double protection.)
    static let cachesSkipNames: Set<String> = [
        "CloudKit", "com.apple.bird", "FamilyCircle", "com.apple.FamilyCircle",
        "com.apple.akd", "com.apple.aked", "com.apple.HomeKit", "com.apple.homed",
        "com.apple.passd", "com.apple.containermanagerd", "com.apple.iconservices",
        "com.apple.iconservices.store", "GeoServices", "com.apple.GeoServices",
        "com.apple.Safari", "com.apple.WebKit.Networking", "com.apple.osanalytics",
        "Google", "Firefox", "Arc", "Microsoft Edge", "BraveSoftware",  // browser category owns these
    ]

    static let appleCachesAllowlist: Set<String> = [
        "com.apple.dt.Xcode", "com.apple.python",
    ]

    public static let rules: [CleanRule] = [
        // ── User caches ───────────────────────────────────────────────
        CleanRule(
            id: "caches.user",
            category: .userCaches,
            title: "App Caches",
            patterns: ["~/Library/Caches/*"],
            safety: .safe,
            contentsOnly: true,
            skipNames: cachesSkipNames,
            applePolicy: .skipUnlessAllowlisted(appleCachesAllowlist)
        ),

        // ── Browsers (Chromium layout per profile) ────────────────────
        CleanRule(
            id: "browsers.chrome",
            category: .browsers,
            title: "Chrome Cache",
            patterns: [
                "~/Library/Caches/Google/Chrome/*/Cache",
                "~/Library/Caches/Google/Chrome/*/Code Cache",
                "~/Library/Application Support/Google/Chrome/*/GPUCache",
                "~/Library/Application Support/Google/Chrome/GrShaderCache",
                "~/Library/Application Support/Google/Chrome/ShaderCache",
            ],
            safety: .safe,
            contentsOnly: true,
            conflictingBundleIDs: ["com.google.Chrome"]
        ),
        CleanRule(
            id: "browsers.edge",
            category: .browsers,
            title: "Edge Cache",
            patterns: [
                "~/Library/Caches/Microsoft Edge/*/Cache",
                "~/Library/Caches/Microsoft Edge/*/Code Cache",
                "~/Library/Application Support/Microsoft Edge/*/GPUCache",
            ],
            safety: .safe,
            contentsOnly: true,
            conflictingBundleIDs: ["com.microsoft.edgemac"]
        ),
        CleanRule(
            id: "browsers.arc",
            category: .browsers,
            title: "Arc Cache",
            patterns: [
                "~/Library/Caches/Arc/User Data/*/Cache",
                "~/Library/Caches/Arc/User Data/*/Code Cache",
                "~/Library/Application Support/Arc/User Data/*/GPUCache",
            ],
            safety: .safe,
            contentsOnly: true,
            conflictingBundleIDs: ["company.thebrowser.Browser"]
        ),
        CleanRule(
            id: "browsers.brave",
            category: .browsers,
            title: "Brave Cache",
            patterns: [
                "~/Library/Caches/BraveSoftware/Brave-Browser/*/Cache",
                "~/Library/Caches/BraveSoftware/Brave-Browser/*/Code Cache",
            ],
            safety: .safe,
            contentsOnly: true,
            conflictingBundleIDs: ["com.brave.Browser"]
        ),
        CleanRule(
            id: "browsers.firefox",
            category: .browsers,
            title: "Firefox Cache",
            patterns: [
                "~/Library/Caches/Firefox/Profiles/*/cache2",
                "~/Library/Caches/Firefox/Profiles/*/startupCache",
                "~/Library/Caches/Firefox/Profiles/*/shader-cache",
            ],
            safety: .safe,
            contentsOnly: true,
            conflictingBundleIDs: ["org.mozilla.firefox"]
        ),
        CleanRule(
            id: "browsers.safari",
            category: .browsers,
            title: "Safari Cache",
            patterns: [
                "~/Library/Caches/com.apple.Safari",
                "~/Library/Containers/com.apple.Safari/Data/Library/Caches",
            ],
            safety: .safe,
            requiresFullDiskAccess: true,
            contentsOnly: true,
            conflictingBundleIDs: ["com.apple.Safari"]
        ),

        // ── Logs ──────────────────────────────────────────────────────
        CleanRule(
            id: "logs.user",
            category: .logs,
            title: "User Logs",
            patterns: ["~/Library/Logs/*"],
            safety: .safe,
            skipNames: ["DiagnosticReports"]
        ),
        CleanRule(
            id: "logs.diagnostics",
            category: .logs,
            title: "Crash Reports (older than 7 days)",
            patterns: ["~/Library/Logs/DiagnosticReports/*"],
            safety: .moderate,
            minAgeHours: 24 * 7
        ),

        // ── Installer leftovers ───────────────────────────────────────
        CleanRule(
            id: "installers.downloads",
            category: .installers,
            title: "Installers in Downloads",
            patterns: ["~/Downloads/*"],
            safety: .caution,
            deleteMode: .trash,
            minAgeHours: 24 * 7,
            extensions: ["dmg", "pkg", "mpkg", "xip", "iso"]
        ),

        // ── Trash ─────────────────────────────────────────────────────
        CleanRule(
            id: "trash.user",
            category: .trash,
            title: "Trash",
            patterns: ["~/.Trash/*"],
            safety: .moderate,
            minAgeHours: 0,
            requiresFullDiskAccess: true
        ),

        // ── Developer caches ──────────────────────────────────────────
        CleanRule(
            id: "dev.xcode.derived",
            category: .developer,
            title: "Xcode DerivedData",
            patterns: ["~/Library/Developer/Xcode/DerivedData/*"],
            safety: .safe,
            conflictingBundleIDs: ["com.apple.dt.Xcode"]
        ),
        CleanRule(
            id: "dev.simulator.caches",
            category: .developer,
            title: "Simulator Caches",
            patterns: ["~/Library/Developer/CoreSimulator/Caches/*"],
            safety: .safe
        ),
        CleanRule(
            id: "dev.npm",
            category: .developer,
            title: "npm Cache",
            patterns: ["~/.npm/_cacache"],
            safety: .safe,
            contentsOnly: true
        ),
        CleanRule(
            id: "dev.yarn",
            category: .developer,
            title: "Yarn Cache",
            patterns: ["~/Library/Caches/Yarn"],
            safety: .safe,
            contentsOnly: true
        ),
        CleanRule(
            id: "dev.homebrew",
            category: .developer,
            title: "Homebrew Cache",
            patterns: ["~/Library/Caches/Homebrew"],
            safety: .safe,
            contentsOnly: true
        ),
        CleanRule(
            id: "dev.swiftpm",
            category: .developer,
            title: "SwiftPM Cache",
            patterns: ["~/Library/Caches/org.swift.swiftpm"],
            safety: .safe,
            contentsOnly: true
        ),
        CleanRule(
            id: "dev.cocoapods",
            category: .developer,
            title: "CocoaPods Cache",
            patterns: ["~/Library/Caches/CocoaPods"],
            safety: .safe,
            contentsOnly: true
        ),
        CleanRule(
            id: "dev.pip",
            category: .developer,
            title: "pip Cache",
            patterns: ["~/Library/Caches/pip"],
            safety: .safe,
            contentsOnly: true
        ),
        CleanRule(
            id: "dev.gradle",
            category: .developer,
            title: "Gradle Caches",
            patterns: ["~/.gradle/caches", "~/.gradle/wrapper/dists"],
            safety: .moderate,
            contentsOnly: true
        ),
        CleanRule(
            id: "dev.cargo",
            category: .developer,
            title: "Cargo Registry Cache",
            patterns: ["~/.cargo/registry/cache", "~/.cargo/registry/src"],
            safety: .safe,
            contentsOnly: true
        ),
        CleanRule(
            id: "dev.gobuild",
            category: .developer,
            title: "Go Build Cache",
            patterns: ["~/Library/Caches/go-build"],
            safety: .safe,
            contentsOnly: true
        ),
    ]
}
