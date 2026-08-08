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
        guard browser == nil else { return }
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
    /// Service instance name → resolved IP. An Android TV in standby
    /// announces over mDNS but can be slow to accept the TCP connection
    /// that resolves its address — one missed 3-second window used to drop
    /// the TV from the list entirely. The cache outlives browse restarts
    /// (panel closed and reopened), so a TV resolved once stays listed.
    private let resolved = Locked<[String: String]>([:])
    private let resolveTask = Locked<Task<Void, Never>?>(nil)

    public init() {}

    public func start(onDevices: @escaping @Sendable ([GoogleCastDevice]) -> Void) {
        // Bonjour browsing is continuous: it keeps reporting as devices come
        // and go. Restarting it throws away everything already found and
        // makes the list empty out — which is exactly what "Refresh" looked
        // like it was doing wrong.
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjour(type: "_googlecast._tcp", domain: nil),
            using: NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        )
        let resolved = self.resolved
        let resolveTask = self.resolveTask
        browser.browseResultsChangedHandler = { results, _ in
            // One resolution task at a time: Bonjour fires change events in
            // bursts, and each used to spawn its own serial re-resolution of
            // every device — overlapping connection storms, with one
            // unreachable TV stalling each pass by its full timeout.
            let previous = resolveTask.withLock { current -> Task<Void, Never>? in
                let old = current
                current = nil
                return old
            }
            previous?.cancel()

            let entries: [(name: String, friendly: String, endpoint: NWEndpoint)] =
                results.compactMap { result in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    // TXT record carries the human-friendly name ("fn").
                    var friendly = Self.prettify(name)
                    if case .bonjour(let txt) = result.metadata,
                       let fn = txt["fn"], !fn.isEmpty {
                        friendly = fn
                    }
                    return (name, friendly, result.endpoint)
                }

            let task = Task {
                func emit() {
                    let hosts = resolved.withLock { $0 }
                    let devices = entries.compactMap { entry -> GoogleCastDevice? in
                        guard let host = hosts[entry.name] else { return nil }
                        return GoogleCastDevice(name: entry.friendly, host: host)
                    }
                    onDevices(devices.sorted { $0.name < $1.name })
                }
                // What's cached shows instantly; the rest is resolved in
                // parallel, and a device that misses one attempt gets two
                // more chances before waiting for the next mDNS event —
                // a TV waking from standby often takes a few seconds to
                // accept its first connection.
                emit()
                for attempt in 0..<3 {
                    let pending = resolved.withLock { hosts in
                        entries.filter { hosts[$0.name] == nil }
                    }
                    if pending.isEmpty || Task.isCancelled { return }
                    if attempt > 0 {
                        try? await Task.sleep(for: .seconds(5))
                        if Task.isCancelled { return }
                    }
                    await withTaskGroup(of: (String, String?).self) { group in
                        for entry in pending {
                            group.addTask {
                                (entry.name, await Self.resolveHost(entry.endpoint))
                            }
                        }
                        for await (name, host) in group {
                            if let host {
                                resolved.withLock { $0[name] = host }
                            }
                        }
                    }
                    emit()
                }
            }
            resolveTask.withLock { $0 = task }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        let task = resolveTask.withLock { current -> Task<Void, Never>? in
            let old = current
            current = nil
            return old
        }
        task?.cancel()
        // The `resolved` cache deliberately survives: IPs rarely change
        // within a session, and it's what makes the list repopulate
        // instantly when the panel reopens.
    }

    /// True when something is answering on the Cast port at this address —
    /// used to re-list remembered TVs that mDNS is currently blind to.
    public static func probeCastPort(host: String, timeout: Double = 1.5) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: 8009) else { return false }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        return await resolveHost(endpoint, timeout: timeout) != nil
    }

    /// One shared queue for resolution connections — a fresh queue per
    /// attempt was an allocation the resolver paid on every mDNS burst.
    private static let resolveQueue = DispatchQueue(label: "cast.resolve")

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
    static func resolveHost(_ endpoint: NWEndpoint, timeout: Double = 3) async -> String? {
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
            connection.start(queue: Self.resolveQueue)
            // Never hang the browse on one unreachable device.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }
}
