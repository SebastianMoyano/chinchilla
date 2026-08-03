import Foundation
import Darwin
import DiskScanKit

/// DLNA/UPnP MediaRenderer support — the "works with the TV you already
/// own" path: virtually every smart TV (Samsung, LG, Sony, TCL, Philips…)
/// ships a MediaRenderer, so nothing has to be installed on the TV.
public struct DLNARenderer: Sendable, Hashable {
    public let name: String
    public let avTransportURL: URL
    public let renderingControlURL: URL?
    public let modelDescription: String?
}

// MARK: - SSDP discovery

public enum SSDP {
    private static let address = "239.255.255.250"
    private static let port: UInt16 = 1900

    /// Sends an M-SEARCH for MediaRenderers and collects LOCATION URLs.
    /// Uses a BSD socket (multicast UDP) on a background thread — no
    /// blocking work ever reaches the cooperative pool.
    public static func discoverRenderers(timeout: TimeInterval = 4) async -> [URL] {
        await Blocking.run {
            var found = Set<String>()
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return [] }
            defer { close(fd) }

            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var ttl: Int32 = 4
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            var local = sockaddr_in()
            local.sin_family = sa_family_t(AF_INET)
            local.sin_addr.s_addr = INADDR_ANY
            local.sin_port = 0
            _ = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            var destination = sockaddr_in()
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = port.bigEndian
            inet_pton(AF_INET, address, &destination.sin_addr)

            // Ask for MediaRenderers, and also for root devices (some TVs
            // only answer the broader query).
            let targets = [
                "urn:schemas-upnp-org:device:MediaRenderer:1",
                "upnp:rootdevice",
            ]
            for target in targets {
                let request = """
                M-SEARCH * HTTP/1.1\r
                HOST: \(address):\(port)\r
                MAN: "ssdp:discover"\r
                MX: 2\r
                ST: \(target)\r
                \r

                """
                let payload = [UInt8](request.utf8)
                _ = withUnsafePointer(to: &destination) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addr in
                        payload.withUnsafeBufferPointer {
                            sendto(fd, $0.baseAddress, $0.count, 0, addr,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }

            let deadline = Date().addingTimeInterval(timeout)
            var buffer = [UInt8](repeating: 0, count: 4096)
            while Date() < deadline {
                let received = recv(fd, &buffer, buffer.count, 0)
                guard received > 0 else { continue }
                let response = String(decoding: buffer[0..<received], as: UTF8.self)
                guard let location = header("LOCATION", in: response) else { continue }
                // Only keep renderers (or unknown — verified when fetched).
                found.insert(location)
            }
            return found.compactMap(URL.init(string:))
        }
    }

    static func header(_ name: String, in response: String) -> String? {
        for line in response.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).uppercased() == name else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

// MARK: - Device description

public enum UPnPDescription {
    /// Fetches and parses a device description into a renderer, or nil if
    /// the device has no AVTransport service (i.e. can't play media).
    public static func fetchRenderer(from location: URL) async -> DLNARenderer? {
        var request = URLRequest(url: location)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let xml = String(data: data, encoding: .utf8) else { return nil }

        let name = value(of: "friendlyName", in: xml) ?? location.host ?? "TV"
        let model = value(of: "modelDescription", in: xml) ?? value(of: "modelName", in: xml)

        var avTransport: URL?
        var renderingControl: URL?
        for block in blocks(named: "service", in: xml) {
            guard let type = value(of: "serviceType", in: block),
                  let control = value(of: "controlURL", in: block),
                  let resolved = URL(string: control, relativeTo: location)?.absoluteURL else { continue }
            if type.contains("AVTransport") { avTransport = resolved }
            if type.contains("RenderingControl") { renderingControl = resolved }
        }
        guard let avTransport else { return nil }
        return DLNARenderer(
            name: name, avTransportURL: avTransport,
            renderingControlURL: renderingControl, modelDescription: model
        )
    }

    /// Minimal XML text extraction — device descriptions are simple and
    /// this avoids a delegate-based parser for a handful of fields.
    static func value(of tag: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func blocks(named tag: String, in xml: String) -> [String] {
        var blocks: [String] = []
        var cursor = xml.startIndex
        while let start = xml.range(of: "<\(tag)>", range: cursor..<xml.endIndex),
              let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) {
            blocks.append(String(xml[start.upperBound..<end.lowerBound]))
            cursor = end.upperBound
        }
        return blocks
    }
}

// MARK: - Control (SOAP)

public enum DLNAControl {
    public struct PositionInfo: Sendable {
        public var duration: Double = 0
        public var position: Double = 0
    }

    static func soap(
        action: String, service: String, controlURL: URL, arguments: String
    ) async throws -> String {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:\(action) xmlns:u="\(service)">\(arguments)</u:\(action)></s:Body>
        </s:Envelope>
        """
        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(data: data, encoding: .utf8) ?? ""
    }

    static let avTransport = "urn:schemas-upnp-org:service:AVTransport:1"
    static let renderingControl = "urn:schemas-upnp-org:service:RenderingControl:1"

    /// Some TVs reject an empty metadata field, so send minimal DIDL-Lite.
    static func didl(title: String, url: String, mime: String) -> String {
        let didl = """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">\
        <item id="0" parentID="-1" restricted="1">\
        <dc:title>\(escape(title))</dc:title>\
        <upnp:class>object.item.videoItem</upnp:class>\
        <res protocolInfo="http-get:*:\(mime):*">\(escape(url))</res>\
        </item></DIDL-Lite>
        """
        return escape(didl)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    public static func play(
        _ renderer: DLNARenderer, url: String, title: String, mime: String
    ) async throws {
        let arguments = """
        <InstanceID>0</InstanceID>\
        <CurrentURI>\(escape(url))</CurrentURI>\
        <CurrentURIMetaData>\(didl(title: title, url: url, mime: mime))</CurrentURIMetaData>
        """
        _ = try await soap(action: "SetAVTransportURI", service: avTransport,
                           controlURL: renderer.avTransportURL, arguments: arguments)
        _ = try await soap(action: "Play", service: avTransport,
                           controlURL: renderer.avTransportURL,
                           arguments: "<InstanceID>0</InstanceID><Speed>1</Speed>")
    }

    public static func pause(_ renderer: DLNARenderer) async throws {
        _ = try await soap(action: "Pause", service: avTransport,
                           controlURL: renderer.avTransportURL,
                           arguments: "<InstanceID>0</InstanceID>")
    }

    public static func resume(_ renderer: DLNARenderer) async throws {
        _ = try await soap(action: "Play", service: avTransport,
                           controlURL: renderer.avTransportURL,
                           arguments: "<InstanceID>0</InstanceID><Speed>1</Speed>")
    }

    public static func stop(_ renderer: DLNARenderer) async throws {
        _ = try await soap(action: "Stop", service: avTransport,
                           controlURL: renderer.avTransportURL,
                           arguments: "<InstanceID>0</InstanceID>")
    }

    public static func seek(_ renderer: DLNARenderer, to seconds: Double) async throws {
        _ = try await soap(action: "Seek", service: avTransport,
                           controlURL: renderer.avTransportURL,
                           arguments: "<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>\(timeString(seconds))</Target>")
    }

    public static func setVolume(_ renderer: DLNARenderer, volume: Double) async throws {
        guard let controlURL = renderer.renderingControlURL else { return }
        let level = Int((volume * 100).rounded())
        _ = try await soap(action: "SetVolume", service: renderingControl,
                           controlURL: controlURL,
                           arguments: "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>\(level)</DesiredVolume>")
    }

    public static func positionInfo(_ renderer: DLNARenderer) async -> PositionInfo? {
        guard let response = try? await soap(
            action: "GetPositionInfo", service: avTransport,
            controlURL: renderer.avTransportURL, arguments: "<InstanceID>0</InstanceID>"
        ) else { return nil }
        var info = PositionInfo()
        if let duration = UPnPDescription.value(of: "TrackDuration", in: response) {
            info.duration = seconds(from: duration)
        }
        if let position = UPnPDescription.value(of: "RelTime", in: response) {
            info.position = seconds(from: position)
        }
        return info
    }

    static func timeString(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func seconds(from text: String) -> Double {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}
