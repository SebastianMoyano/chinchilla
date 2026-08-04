import Foundation
import Testing
@testable import SystemKit

@Test func topConsumersAggregatesHelpers() {
    let apps = ProcessMemory.topConsumers(limit: 10, minFootprint: 1)
    #expect(!apps.isEmpty)
    // Helper processes must be folded into their host app.
    #expect(!apps.contains { $0.name.hasSuffix("Helper") || $0.name.contains("Helper (") })
    // Sorted descending.
    #expect(apps == apps.sorted { $0.footprint > $1.footprint })
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

@Test func runTogetherHelperNamesAreFolded() {
    #expect(ProcessMemory.hostAppName(for: "AirPlayXPCHelper") == "AirPlay")
    #expect(ProcessMemory.hostAppName(for: "ControlCenterHelper") == "ControlCenter")
    #expect(ProcessMemory.hostAppName(for: "AppPredictionIntentsHelperService") == "AppPredictionIntents")
    // A name that is only the suffix must survive intact.
    #expect(ProcessMemory.hostAppName(for: "Helper") == "Helper")
}
