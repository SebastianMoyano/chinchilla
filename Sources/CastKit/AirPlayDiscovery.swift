import Foundation
import Network

public struct AirPlayDevice: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

/// Finds AirPlay receivers so they appear in the list — nothing more.
///
/// Chinchilla can't drive them, and shouldn't want to. macOS has no public API
/// for an app to start AirPlay screen mirroring: it's a system-level route,
/// which is exactly why it beats what this app can do — lower latency, and the
/// sound genuinely moved rather than copied and the Mac muted by hand.
/// Reimplementing the protocol isn't an option either; AirPlay 2 requires
/// Apple's pairing handshake and receivers refuse unauthorised senders.
///
/// So they're listed and handed back to macOS. Leaving them out was the worse
/// option: an Apple TV owner opened Cast, saw nothing, and concluded the app
/// couldn't find their television.
public final class AirPlayDiscovery: @unchecked Sendable {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "cast.airplay.discovery")

    public init() {}

    public func start(onDevices: @escaping @Sendable ([AirPlayDevice]) -> Void) {
        // Bonjour browsing is continuous: it keeps reporting as devices come
        // and go. Restarting it throws away everything already found and
        // makes the list empty out — which is exactly what "Refresh" looked
        // like it was doing wrong.
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjour(type: "_airplay._tcp", domain: nil),
            using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        )
        browser.browseResultsChangedHandler = { results, _ in
            // This Mac advertises AirPlay too, and offering to cast a screen
            // to itself is nonsense that also crowds out the real answer.
            let ownName = Host.current().localizedName
            var devices: [AirPlayDevice] = []
            var seen = Set<String>()
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint else { continue }
                let friendly = Self.prettify(name)
                guard friendly != ownName else { continue }
                guard seen.insert(friendly).inserted else { continue }
                devices.append(AirPlayDevice(name: friendly))
            }
            onDevices(devices.sorted { $0.name < $1.name })
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Bonjour escapes spaces as `\032`.
    static func prettify(_ name: String) -> String {
        name.replacingOccurrences(of: "\\032", with: " ")
            .replacingOccurrences(of: "\\ ", with: " ")
    }

    /// Where macOS keeps the real control. Displays settings is the closest
    /// thing to a deep link — Control Center's mirroring popover can't be
    /// opened by a URL.
    public static let screenMirroringSettingsURL =
        "x-apple.systempreferences:com.apple.Displays-Settings.extension"
}
