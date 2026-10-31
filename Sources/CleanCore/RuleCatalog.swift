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
        // Developer rules below name these explicitly. Without the skip the
        // caches.user glob sizes each tree a second time — Homebrew and
        // go-build run to multiple GB — only for the path-dedupe in
        // CleanScanner to throw one of the two results away.
        "Yarn", "Homebrew", "org.swift.swiftpm", "CocoaPods", "pip", "go-build",
        // Not caches despite the address: llama.cpp keeps the models it
        // downloaded here (gigabytes nobody wants to fetch twice), and kitty's
        // graphics cache backs images on screen in open terminals.
        "llama.cpp", "kitty",
        // Playwright MCP keeps whole browser profiles here (logins included),
        // and the browser builds get their own rule that waits for them.
        "ms-playwright", "ms-playwright-go", "ms-playwright-mcp",
    ]

    /// Every way a simulator can be running: the Simulator app, or a device
    /// booted headless by `simctl`/Xcode, which shows up as `launchd_sim`.
    static let simulatorBundleIDs = ["com.apple.dt.Xcode", "com.apple.iphonesimulator"]
    static let simulatorProcesses = ["launchd_sim"]

    /// Chromium-style caches an Electron app keeps next to its data.
    static func electronCaches(_ appSupportFolder: String) -> [String] {
        let base = "~/Library/Application Support/" + appSupportFolder
        return [base + "/Cache", base + "/Code Cache", base + "/GPUCache"]
    }

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

        // ── Apps that cache like a browser ────────────────────────────
        CleanRule(
            id: "apps.discord",
            category: .userCaches,
            title: "Discord Cache",
            patterns: electronCaches("discord"),
            safety: .safe,
            contentsOnly: true,
            conflictingBundleIDs: ["com.hnc.Discord"]
        ),
        CleanRule(
            id: "apps.vesktop",
            category: .userCaches,
            title: "Vesktop Cache",
            patterns: electronCaches("vesktop"),
            safety: .safe,
            contentsOnly: true,
            conflictingBundleIDs: ["dev.vencord.vesktop"]
        ),
        CleanRule(
            id: "apps.slack",
            category: .userCaches,
            title: "Slack Cache",
            patterns: electronCaches("Slack"),
            safety: .safe,
            contentsOnly: true,
            conflictingBundleIDs: ["com.tinyspeck.slackmacgap"]
        ),
        CleanRule(
            id: "apps.adobe.mediacache",
            category: .userCaches,
            title: "Adobe Media Cache",
            patterns: [
                "~/Library/Application Support/Adobe/Common/Media Cache Files",
                "~/Library/Application Support/Adobe/Common/Media Cache",
            ],
            // Conformed audio and peak files: Premiere rebuilds them on the
            // next open, but not while it is reading them. Adobe puts the
            // year in each bundle ID, hence the prefixes.
            safety: .safe,
            contentsOnly: true,
            conflictingBundleIDs: [
                "com.adobe.PremierePro*", "com.adobe.AfterEffects*",
                "com.adobe.Audition*", "com.adobe.ame*", "com.adobe.PremiereRush*",
            ]
        ),
        CleanRule(
            id: "apps.mail.attachments",
            category: .userCaches,
            title: "Mail Attachments Opened from Messages",
            patterns: ["~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/*"],
            // Copies Mail made when an attachment was opened; the message
            // still has the original. One folder per attachment — only those
            // nobody edited go, since an edited copy may be the only one with
            // the user's changes. To the Trash, and never pre-selected.
            safety: .moderate,
            deleteMode: .trash,
            minAgeHours: 24 * 7,
            requiresFullDiskAccess: true,
            conflictingBundleIDs: ["com.apple.mail"],
            untouchedOnly: true
        ),

        // ── Logs ──────────────────────────────────────────────────────
        CleanRule(
            id: "logs.user",
            category: .logs,
            title: "User Logs",
            patterns: ["~/Library/Logs/*"],
            safety: .safe,
            // "Chinchilla" holds our own audit log — never eat it.
            skipNames: ["DiagnosticReports", "Chinchilla"]
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
            safety: .safe,
            // Booted simulators map the dyld caches in here.
            conflictingBundleIDs: simulatorBundleIDs,
            conflictingProcessNames: simulatorProcesses
        ),
        CleanRule(
            id: "dev.xcode.devicesupport",
            category: .developer,
            title: "Xcode Device Support (symbols from connected devices)",
            patterns: [
                "~/Library/Developer/Xcode/iOS DeviceSupport/*",
                "~/Library/Developer/Xcode/watchOS DeviceSupport/*",
                "~/Library/Developer/Xcode/tvOS DeviceSupport/*",
                "~/Library/Developer/Xcode/visionOS DeviceSupport/*",
            ],
            // Xcode copies these back off the device the next time you plug it
            // in — free again, but only while you still have that device.
            safety: .moderate,
            conflictingBundleIDs: ["com.apple.dt.Xcode"]
        ),
        CleanRule(
            id: "dev.xcode.archives",
            category: .developer,
            title: "Xcode Archives (builds you shipped — keeps crash symbols)",
            patterns: ["~/Library/Developer/Xcode/Archives/*"],
            // Without the archive, crash reports from that build never
            // symbolicate again. To the Trash, and never pre-selected.
            safety: .caution,
            deleteMode: .trash,
            conflictingBundleIDs: ["com.apple.dt.Xcode"]
        ),
        CleanRule(
            id: "dev.simulator.devices",
            category: .developer,
            title: "Simulator Devices (erases apps and data inside them)",
            patterns: ["~/Library/Developer/CoreSimulator/Devices/*"],
            // One folder = one simulated iPhone with everything installed on
            // it. `simctl delete unavailable` is the surgical version; a file
            // rule can't tell which are unavailable, so it goes to the Trash
            // as caution and the user picks.
            safety: .caution,
            deleteMode: .trash,
            skipNames: ["device_set.plist"],
            conflictingBundleIDs: simulatorBundleIDs,
            conflictingProcessNames: simulatorProcesses
        ),
        CleanRule(
            id: "dev.simulator.runtimes",
            category: .developer,
            title: "Simulator Runtimes (re-downloadable, several GB each)",
            patterns: ["~/Library/Developer/CoreSimulator/Profiles/Runtimes/*"],
            // Xcode re-downloads a runtime on demand; deleting one that a
            // device still points at makes that device unavailable.
            safety: .caution,
            conflictingBundleIDs: simulatorBundleIDs,
            conflictingProcessNames: simulatorProcesses
        ),
        CleanRule(
            id: "dev.xcode.devicelogs",
            category: .developer,
            title: "Xcode Device Logs",
            patterns: [
                "~/Library/Developer/Xcode/iOS Device Logs/*",
                "~/Library/Developer/Xcode/watchOS Device Logs/*",
            ],
            safety: .safe,
            conflictingBundleIDs: ["com.apple.dt.Xcode"]
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
        CleanRule(
            id: "dev.uv",
            category: .developer,
            title: "uv Cache",
            patterns: ["~/.cache/uv"],
            // Installed environments hold clones of these files, not links
            // into them — but a running `uv`/`uvx` (an MCP server, a script)
            // may be reading its environment straight out of the cache.
            safety: .safe,
            contentsOnly: true,
            conflictingProcessNames: ["uv", "uvx"],
            sizeByReclaimable: true
        ),
        CleanRule(
            id: "dev.bun",
            category: .developer,
            title: "Bun Install Cache",
            patterns: ["~/.bun/install/cache"],
            // Same deal: node_modules are clones, a live `bun install` is not.
            safety: .safe,
            contentsOnly: true,
            conflictingProcessNames: ["bun"],
            sizeByReclaimable: true
        ),
        CleanRule(
            id: "dev.go.modcache",
            category: .developer,
            title: "Go Module Cache",
            patterns: ["~/go/pkg/mod"],
            // Every module any project downloaded; `go` fetches them again on
            // the next build, which an offline Mac can't do — so not
            // pre-selected. Go makes the tree read-only to stop edits.
            safety: .moderate,
            contentsOnly: true,
            conflictingProcessNames: ["go"],
            unlockReadOnlyTree: true
        ),
        CleanRule(
            id: "dev.playwright.browsers",
            category: .developer,
            title: "Playwright Browsers",
            patterns: [
                "~/Library/Caches/ms-playwright/chromium*",
                "~/Library/Caches/ms-playwright/firefox-*",
                "~/Library/Caches/ms-playwright/webkit-*",
                "~/Library/Caches/ms-playwright/ffmpeg-*",
                "~/Library/Caches/ms-playwright-go/*/chromium*",
                "~/Library/Caches/ms-playwright-go/*/firefox-*",
                "~/Library/Caches/ms-playwright-go/*/webkit-*",
            ],
            // Re-downloaded by `playwright install`; until then tests can't
            // start, so not pre-selected — and never under a running browser.
            safety: .moderate,
            conflictingProcessNames: [
                "Google Chrome for Testing", "chrome-headless-shell",
                "headless_shell", "Chromium", "firefox", "Playwright",
            ]
        ),
        CleanRule(
            id: "dev.claude.versions",
            category: .developer,
            title: "Old Claude Code Versions",
            patterns: ["~/.local/share/claude/versions/*"],
            // The installer keeps every release it ever updated to. The one
            // `claude` points at stays, and so does any older one a session
            // that hasn't been restarted is still running on.
            safety: .safe,
            keepTargetsOf: ["~/.local/bin/claude"],
            keepRunningExecutables: true
        ),
    ]
}
