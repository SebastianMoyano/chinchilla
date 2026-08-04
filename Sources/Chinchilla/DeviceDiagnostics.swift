import Foundation
import CastKit

/// `Chinchilla devices` — runs every discovery path the app uses and prints
/// what each one returned, separately.
///
/// Exists because "the app only shows one of my TVs" is impossible to act on
/// otherwise: four mechanisms feed that list, and knowing which one came back
/// empty is the whole diagnosis.
enum DeviceDiagnostics {
    static let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Chinchilla/devices.log")

    /// Written to a file as well as stdout: run from the bundle
    /// (`open -a Chinchilla --args devices`) and the Local Network permission
    /// is attributed to Chinchilla rather than to the terminal, which is the
    /// only way to see what the app itself is allowed to find.
    nonisolated(unsafe) private static var transcript = ""

    private static func emit(_ line: String) {
        print(line)
        transcript += line + "\n"
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? transcript.write(to: logURL, atomically: true, encoding: .utf8)
    }

    static func run(seconds: Int) async -> Int32 {
        transcript = ""
        emit("Looking for \(seconds)s on every path…\n")

        let airplay = AirPlayDiscovery()
        let cast = GoogleCastDiscovery()
        let fcast = FCastDiscovery()

        nonisolated(unsafe) var airplayFound: [AirPlayDevice] = []
        nonisolated(unsafe) var castFound: [GoogleCastDevice] = []
        nonisolated(unsafe) var fcastFound: [FCastDevice] = []

        airplay.start { airplayFound = $0 }
        cast.start { castFound = $0 }
        // The browser's own state is the tell: macOS reports `.waiting` when
        // Local Network access hasn't been granted, and simply returns nothing
        // rather than failing.
        nonisolated(unsafe) var lastState = "unknown"
        fcast.start(onDevices: { fcastFound = $0 }, onState: { state in
            lastState = "\(state)"
        })

        // DLNA is a one-shot sweep rather than a continuous browse.
        async let dlna: [DLNARenderer] = {
            var renderers: [DLNARenderer] = []
            for location in await SSDP.discoverRenderers() {
                if let renderer = await UPnPDescription.fetchRenderer(from: location) {
                    renderers.append(renderer)
                }
            }
            return renderers
        }()

        try? await Task.sleep(for: .seconds(seconds))
        let dlnaFound = await dlna
        airplay.stop(); cast.stop(); fcast.stop()

        func section(_ title: String, _ lines: [String]) {
            emit("\(title): \(lines.isEmpty ? "nothing" : "\(lines.count)")")
            for line in lines { emit("   • \(line)") }
        }
        section("AirPlay (Bonjour _airplay._tcp)",
                airplayFound.map(\.name))
        section("Chromecast (Bonjour _googlecast._tcp)", castFound.map { "\($0.name) @ \($0.host)" })
        section("FCast (Bonjour _fcast._tcp)", fcastFound.map(\.name))
        section("DLNA (SSDP)", dlnaFound.map { "\($0.name) @ \($0.avTransportURL.host ?? "?")" })

        emit("\nbrowser state: \(lastState)")
        if lastState.contains("waitingForLocalNetworkPermission") {
            emit("→ macOS hasn't granted Chinchilla Local Network access.")
            emit("  System Settings → Privacy & Security → Local Network → enable Chinchilla.")
        }
        let total = airplayFound.count + castFound.count + fcastFound.count + dlnaFound.count
        emit("\ntotal: \(total)")
        return total > 0 ? 0 : 1
    }
}
