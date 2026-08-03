import Foundation
import Network

public struct FCastDevice: Sendable, Identifiable, Hashable {
    public let name: String
    public let endpoint: NWEndpoint

    public var id: String { name }

    public init(name: String, endpoint: NWEndpoint) {
        self.name = name
        self.endpoint = endpoint
    }
}

public enum DiscoveryState: Sendable, Equatable {
    case idle
    case browsing
    /// macOS 15 local-network permission denied (or NSBonjourServices
    /// missing) — surfaced so the UI can guide instead of showing an
    /// eternally empty list.
    case waitingForLocalNetworkPermission
    case failed(String)
}

/// Browses _fcast._tcp receivers on the LAN.
public final class FCastDiscovery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cast.discovery")
    private var browser: NWBrowser?

    public init() {}

    /// Starts browsing; callbacks fire on an arbitrary queue — hop to
    /// MainActor in the caller.
    public func start(
        onDevices: @escaping @Sendable ([FCastDevice]) -> Void,
        onState: @escaping @Sendable (DiscoveryState) -> Void
    ) {
        stop()
        let browser = NWBrowser(
            for: .bonjour(type: "_fcast._tcp", domain: nil),
            using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        )
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                onState(.browsing)
            case .waiting:
                onState(.waitingForLocalNetworkPermission)
            case .failed(let error):
                onState(.failed(String(describing: error)))
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { results, _ in
            let devices = results.compactMap { result -> FCastDevice? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return FCastDevice(name: name, endpoint: result.endpoint)
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
}
