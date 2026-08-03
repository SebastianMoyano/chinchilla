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
