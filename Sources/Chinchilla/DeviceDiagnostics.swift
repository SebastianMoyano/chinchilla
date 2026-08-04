import Foundation
import CastKit

/// `Chinchilla devices` — runs every discovery path the app uses and prints
/// what each one returned, separately.
///
/// Exists because "the app only shows one of my TVs" is impossible to act on
/// otherwise: four mechanisms feed that list, and knowing which one came back
/// empty is the whole diagnosis.
enum DeviceDiagnostics {
    static func run(seconds: Int) async -> Int32 {
        print("Looking for \(seconds)s on every path…\n")

        let airplay = AirPlayDiscovery()
        let cast = GoogleCastDiscovery()
        let fcast = FCastDiscovery()

        nonisolated(unsafe) var airplayFound: [AirPlayDevice] = []
        nonisolated(unsafe) var castFound: [GoogleCastDevice] = []
        nonisolated(unsafe) var fcastFound: [FCastDevice] = []

        airplay.start { airplayFound = $0 }
        cast.start { castFound = $0 }
        fcast.start(onDevices: { fcastFound = $0 }, onState: { _ in })

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
            print("\(title): \(lines.isEmpty ? "nothing" : "\(lines.count)")")
            for line in lines { print("   • \(line)") }
        }
        section("AirPlay (Bonjour _airplay._tcp)",
                airplayFound.map(\.name))
        section("Chromecast (Bonjour _googlecast._tcp)", castFound.map { "\($0.name) @ \($0.host)" })
        section("FCast (Bonjour _fcast._tcp)", fcastFound.map(\.name))
        section("DLNA (SSDP)", dlnaFound.map { "\($0.name) @ \($0.avTransportURL.host ?? "?")" })

        let total = airplayFound.count + castFound.count + fcastFound.count + dlnaFound.count
        print("\ntotal: \(total)")
        return total > 0 ? 0 : 1
    }
}
