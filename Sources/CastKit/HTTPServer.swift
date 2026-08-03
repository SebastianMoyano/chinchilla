import Foundation
import Network
import UniformTypeIdentifiers
import DiskScanKit

/// Minimal HTTP/1.1 file server (GET/HEAD) with Range support — just enough
/// to feed a TV's media player. Files are exposed by opaque tokens, never
/// by path. All disk reads go through Blocking.run (project rule).
public final class CastHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cast.http")
    private var listener: NWListener?
    private let files = NSMutableDictionary()  // token -> file URL (queue-confined)
    public private(set) var port: UInt16 = 0

    public init() {}

    public func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = self?.listener?.port {
                self?.port = port.rawValue
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stopAll() {
        listener?.cancel()
        listener = nil
        queue.sync { files.removeAllObjects() }
        port = 0
    }

    /// Registers a local file; returns the URL path component (/media/<token>).
    public func register(file url: URL) -> String {
        let token = UUID().uuidString
        queue.sync { files[token] = url }
        return "/media/\(token)"
    }

    /// LAN IPv4 of the Mac (en0 preferred) for building URLs the TV can reach.
    public static func lanAddress() -> String? {
        var addresses: [(name: String, ip: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            addresses.append((String(cString: current.pointee.ifa_name), String(cString: host)))
        }
        return (addresses.first { $0.name == "en0" } ?? addresses.first)?.ip
    }

    // MARK: - Request handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffered: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, error == nil, !isComplete else {
                connection.cancel()
                return
            }
            var buffer = buffered
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                // Anything already received past this request belongs to the
                // next one (pipelining / coalesced sends).
                let leftover = Data(buffer[headerEnd.upperBound...])
                self.respond(connection, head: head) {
                    // Keep-alive: we advertise it, so we must keep reading.
                    // Without this a client reusing the connection (any TV,
                    // URLSession.shared) hangs forever on its next request.
                    self.receiveRequest(connection, buffered: leftover)
                }
            } else if buffer.count < 64 * 1024 {
                self.receiveRequest(connection, buffered: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String, completion: @escaping @Sendable () -> Void) {
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            connection.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }
        let method = String(parts[0])
        let path = String(parts[1])
        guard method == "GET" || method == "HEAD" else {
            sendSimple(connection, status: "405 Method Not Allowed")
            completion()
            return
        }
        let rangeHeader = lines
            .first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces) }

        if path.hasPrefix("/media/") {
            let token = String(path.dropFirst("/media/".count))
            guard let fileURL = files[token] as? URL else {
                sendSimple(connection, status: "404 Not Found")
                completion()
                return
            }
            serveFile(connection, url: fileURL, range: rangeHeader,
                      headOnly: method == "HEAD", completion: completion)
        } else if let route = dynamicRoutes[path] {
            let (contentType, data) = route()
            sendData(connection, status: "200 OK", contentType: contentType, body: data,
                     headOnly: method == "HEAD",
                     extraHeaders: ["Cache-Control": "no-store"])
            completion()
        } else {
            sendSimple(connection, status: "404 Not Found")
            completion()
        }
    }

    /// Dynamic in-memory routes (Phase B: HLS playlist + segments).
    private var dynamicRoutes: [String: () -> (String, Data)] = [:]

    public func setRoute(_ path: String, provider: (() -> (String, Data))?) {
        queue.async { [weak self] in
            if let provider {
                self?.dynamicRoutes[path] = provider
            } else {
                self?.dynamicRoutes.removeValue(forKey: path)
            }
        }
    }

    // MARK: - File serving with Range

    private func serveFile(
        _ connection: NWConnection, url: URL, range: String?,
        headOnly: Bool, completion: @escaping @Sendable () -> Void
    ) {
        Task {
            defer { completion() }
            let total = await Blocking.run { () -> Int64? in
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                return (attributes?[.size] as? NSNumber)?.int64Value
            }
            guard let total else {
                self.sendSimple(connection, status: "404 Not Found")
                return
            }
            let contentType = UTType(filenameExtension: url.pathExtension)?
                .preferredMIMEType ?? "application/octet-stream"

            var start: Int64 = 0
            var end: Int64 = total - 1
            var status = "200 OK"
            var extra: [String: String] = ["Accept-Ranges": "bytes"]

            if let range, range.hasPrefix("bytes=") {
                let spec = range.dropFirst("bytes=".count)
                let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
                let lower = bounds.count > 0 ? Int64(bounds[0]) : nil
                let upper = bounds.count > 1 ? Int64(bounds[1]) : nil
                if let lower {
                    start = lower
                    end = upper ?? (total - 1)
                } else if let upper {  // suffix: bytes=-N
                    start = max(0, total - upper)
                    end = total - 1
                }
                guard start <= end, start < total else {
                    self.sendSimple(connection, status: "416 Range Not Satisfiable",
                                    extraHeaders: ["Content-Range": "bytes */\(total)"])
                    return
                }
                end = min(end, total - 1)
                status = "206 Partial Content"
                extra["Content-Range"] = "bytes \(start)-\(end)/\(total)"
            }

            let length = end - start + 1
            let header = self.header(
                status: status, contentType: contentType,
                contentLength: length, extraHeaders: extra
            )
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
            if headOnly {
                return
            }
            await self.streamFile(connection, url: url, from: start, length: length)
        }
    }

    private func streamFile(_ connection: NWConnection, url: URL, from offset: Int64, length: Int64) async {
        guard let handle = await Blocking.run({ try? FileHandle(forReadingFrom: url) }) else {
            connection.cancel()
            return
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset))
        var remaining = length
        while remaining > 0 {
            let chunkSize = Int(min(remaining, 256 * 1024))
            let chunk = await Blocking.run { try? handle.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            remaining -= Int64(chunk.count)
            // Backpressure: wait for the send to be accepted before reading more.
            let sent: Bool = await withCheckedContinuation { continuation in
                connection.send(content: chunk, completion: .contentProcessed { error in
                    continuation.resume(returning: error == nil)
                })
            }
            guard sent else { break }
        }
    }

    // MARK: - Response helpers

    private func header(
        status: String, contentType: String, contentLength: Int64,
        extraHeaders: [String: String] = [:]
    ) -> String {
        var lines = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(contentLength)",
            "Connection: keep-alive",
        ]
        for (key, value) in extraHeaders {
            lines.append("\(key): \(value)")
        }
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    private func sendSimple(_ connection: NWConnection, status: String, extraHeaders: [String: String] = [:]) {
        let head = header(status: status, contentType: "text/plain", contentLength: 0, extraHeaders: extraHeaders)
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
    }

    private func sendData(
        _ connection: NWConnection, status: String, contentType: String,
        body: Data, headOnly: Bool, extraHeaders: [String: String]
    ) {
        let head = header(status: status, contentType: contentType,
                          contentLength: Int64(body.count), extraHeaders: extraHeaders)
        var payload = Data(head.utf8)
        if !headOnly { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in })
    }
}
