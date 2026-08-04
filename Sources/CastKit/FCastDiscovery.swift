import Foundation
import DiskScanKit
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

/// Browses _googlecast._tcp (Chromecast built-in — most Android TVs).
/// Resolving to an IP needs a connection attempt, so we hand back the
/// endpoint and let the session resolve it.
public final class GoogleCastDiscovery: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cast.googlecast.discovery")
    private var browser: NWBrowser?

    public init() {}

    public func start(onDevices: @escaping @Sendable ([GoogleCastDevice]) -> Void) {
        stop()
        let browser = NWBrowser(
            for: .bonjour(type: "_googlecast._tcp", domain: nil),
            using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        )
        browser.browseResultsChangedHandler = { results, _ in
            Task {
                var devices: [GoogleCastDevice] = []
                for result in results {
                    guard case .service(let name, _, _, _) = result.endpoint else { continue }
                    // TXT record carries the human-friendly name ("fn").
                    var friendly = Self.prettify(name)
                    if case .bonjour(let txt) = result.metadata,
                       let fn = txt["fn"], !fn.isEmpty {
                        friendly = fn
                    }
                    if let host = await Self.resolveHost(result.endpoint) {
                        devices.append(GoogleCastDevice(name: friendly, host: host))
                    }
                }
                onDevices(devices.sorted { $0.name < $1.name })
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    /// mDNS instance names look like "4K-SMART-TV-24b1993e381d…" — drop the
    /// trailing UUID and restore spaces.
    static func prettify(_ instanceName: String) -> String {
        var name = instanceName
        if let dash = name.lastIndex(of: "-"),
           name[name.index(after: dash)...].count >= 24 {
            name = String(name[..<dash])
        }
        return name.replacingOccurrences(of: "-", with: " ")
    }

    /// Resolves a Bonjour endpoint to an IPv4 literal by opening (and
    /// immediately cancelling) a connection — Network.framework exposes the
    /// resolved path this way.
    static func resolveHost(_ endpoint: NWEndpoint) async -> String? {
        // One-shot guard shared by the state handler and the timeout.
        let resumed = Locked(false)
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            @Sendable func finish(_ host: String?) {
                let first = resumed.withLock { value -> Bool in
                    guard !value else { return false }
                    value = true
                    return true
                }
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: host)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var host: String?
                    if case .hostPort(let remote, _) = connection.currentPath?.remoteEndpoint,
                       case .ipv4(let address) = remote {
                        host = "\(address)".components(separatedBy: "%").first
                    }
                    finish(host)
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "cast.resolve"))
            // Never hang the browse on one unreachable device.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
    }
}
