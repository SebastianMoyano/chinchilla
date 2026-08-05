import Foundation
import Testing
@testable import SystemKit

/// Runs against whatever is live on the machine, so it asserts only what is
/// true of any machine. Whether a given name gets folded is decided by
/// `hostAppName`, which is tested against fixed input below — asserting it
/// here made the suite fail whenever an unlucky process happened to be big.
@Test func topConsumersAggregatesHelpers() {
    let apps = ProcessMemory.topConsumers(limit: 10, minFootprint: 1)
    #expect(!apps.isEmpty)
    #expect(apps == apps.sorted { $0.footprint > $1.footprint })
    // Grouping means one row per app: a duplicate name would mean two
    // processes of the same app were counted separately.
    #expect(Set(apps.map(\.name)).count == apps.count)
    #expect(apps.allSatisfy { !$0.name.isEmpty && $0.footprint > 0 })
}

@Test func hostAppNameGrouping() {
    #expect(ProcessMemory.hostAppName(for: "Google Chrome Helper (Renderer)") == "Google Chrome")
    #expect(ProcessMemory.hostAppName(for: "com.apple.WebKit.WebContent") == "Safari")
    #expect(ProcessMemory.hostAppName(for: "WindowServer") == "macOS")
    #expect(ProcessMemory.hostAppName(for: "kernel_task") == "macOS")
    #expect(ProcessMemory.hostAppName(for: "Spotify") == "Spotify")
}

@Test func pathBeatsNameForGrouping() {
    // Apple's own helpers are macOS, whatever they're called.
    #expect(ProcessMemory.hostAppName(
        for: "AirPlayXPCHelper", path: "/usr/libexec/AirPlayXPCHelper") == "macOS")
    #expect(ProcessMemory.hostAppName(
        for: "ControlCenterHelper",
        path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenterHelper"
    ) == "macOS")

    // A helper nested inside an app belongs to the OUTERMOST bundle.
    #expect(ProcessMemory.hostAppName(
        for: "Google Chrome Helper (Renderer)",
        path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
    ) == "Google Chrome")

    // A process whose name says nothing still lands on its app.
    #expect(ProcessMemory.hostAppName(
        for: "LeagueClientUx",
        path: "/Applications/League of Legends.app/Contents/LoL/LeagueClientUx.app/Contents/MacOS/LeagueClientUx"
    ) == "League of Legends")

    // No path: fall back to the name rules.
    #expect(ProcessMemory.hostAppName(for: "Spotify Helper", path: "") == "Spotify")
}

/// Self-updating command-line tools install as `.../name/versions/2.1.220`,
/// with no bundle anywhere. Taking the file name put a row called "2.1.220"
/// holding 2 GB at the top of the memory list — true, and no use to anyone.
@Test func aVersionNumberIsNeverAnAppName() {
    #expect(ProcessMemory.hostAppName(
        for: "2.1.220", path: "/Users/admin/.local/share/claude/versions/2.1.220"
    ) == "claude")
    // Two versions of the same tool collapse onto one row.
    #expect(ProcessMemory.hostAppName(
        for: "2.1.221", path: "/Users/admin/.local/share/claude/versions/2.1.221"
    ) == "claude")
    // Homebrew's Cellar layout.
    #expect(ProcessMemory.hostAppName(
        for: "3.14.6", path: "/opt/homebrew/Cellar/python@3.14/3.14.6"
    ) == "python@3.14")
    // A `v` prefix is still a version.
    #expect(ProcessMemory.hostAppName(
        for: "v18.20.4", path: "/Users/admin/.nvm/versions/node/v18.20.4"
    ) == "node")
}

@Test func versionDetectionDoesNotSwallowRealNames() {
    #expect(ProcessMemory.looksLikeVersion("2.1.220"))
    #expect(ProcessMemory.looksLikeVersion("v3.2"))
    #expect(ProcessMemory.looksLikeVersion("18") == false)      // no dot
    #expect(ProcessMemory.looksLikeVersion("node") == false)
    #expect(ProcessMemory.looksLikeVersion("com.apple.WebKit") == false)
    #expect(ProcessMemory.looksLikeVersion("") == false)
    // A plain binary keeps its own name.
    #expect(ProcessMemory.hostAppName(for: "node", path: "/opt/homebrew/bin/node") == "node")
}

@Test func aPathOfNothingButStructureGivesUpRatherThanGuess() {
    // Every parent is structural, so there is no better answer than the
    // fallback — and inventing one would be worse.
    #expect(ProcessMemory.nameFromVersionedPath("/usr/local/bin/1.2.3") == nil)
    #expect(ProcessMemory.nameFromVersionedPath("/opt/homebrew/bin/node") == nil)
}

@Test func runTogetherHelperNamesAreFolded() {
    #expect(ProcessMemory.hostAppName(for: "AirPlayXPCHelper") == "AirPlay")
    #expect(ProcessMemory.hostAppName(for: "ControlCenterHelper") == "ControlCenter")
    #expect(ProcessMemory.hostAppName(for: "AppPredictionIntentsHelperService") == "AppPredictionIntents")
    // A name that is only the suffix must survive intact.
    #expect(ProcessMemory.hostAppName(for: "Helper") == "Helper")
}
