import Foundation
import DiskScanKit
import Network
import Security

/// GameStream host: what Moonlight talks to. Phase 1 implements discovery
/// (`_nvstream._tcp`), `/serverinfo` and the four-step PIN pairing over
/// HTTP 47989, plus the final `pairchallenge` over TLS on 47984.
public final class GameStreamHost: @unchecked Sendable {
    public static let httpPort: UInt16 = 47989
    public static let httpsPort: UInt16 = 47984

    private let identity: HostIdentity
    private let queue = DispatchQueue(label: "gamestream.host")
    private var httpListener: NWListener?
    private var httpsListener: NWListener?

    /// PIN the user types into Moonlight. Regenerated per pairing attempt.
    public private(set) var currentPIN: String?
    public var onLog: (@Sendable (String) -> Void)?
    public var onPaired: (@Sendable (String) -> Void)?
    /// Fires when a client asks for /serverinfo — i.e. Moonlight found us.
    public var onClientSeen: (@Sendable (String) -> Void)?

    private struct PairSession {
        var clientCertDER: Data?
        var aesKey: Data?
        var serverSecret = Data()
        var serverChallenge = Data()
        var clientHash = Data()
    }
    private let session = Locked(PairSession())
    private let pairedClients = Locked<[String: Data]>([:])   // uniqueid -> client cert
    /// Every accepted connection, so `stop()` can actually stop them.
    private let live = Locked<[NWConnection]>([])

    public init() throws {
        identity = try HostIdentity.loadOrCreate()
    }

    public var hostName: String {
        Host.current().localizedName ?? "Chinchilla"
    }

    // MARK: Lifecycle

    public func start() throws {
        guard httpListener == nil else { return }

        let httpParams = NWParameters.tcp
        httpParams.allowLocalEndpointReuse = true
        let http = try NWListener(using: httpParams, on: NWEndpoint.Port(rawValue: Self.httpPort)!)
        // Moonlight discovers hosts over Bonjour.
        http.service = NWListener.Service(name: hostName, type: "_nvstream._tcp")
        http.newConnectionHandler = { [weak self] connection in
            self?.handle(connection, secure: false)
        }
        http.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.log("http listener ready on \(Self.httpPort)")
            case .failed(let error): self?.log("http listener FAILED: \(error)")
            case .waiting(let error): self?.log("http listener waiting: \(error)")
            default: break
            }
        }
        http.start(queue: queue)
        httpListener = http

        let tlsOptions = NWProtocolTLS.Options()
        let secIdentity = sec_identity_create(identity.secIdentity)!
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)
        // Moonlight presents its own self-signed client certificate.
        sec_protocol_options_set_peer_authentication_required(tlsOptions.securityProtocolOptions, false)
        let httpsParams = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        httpsParams.allowLocalEndpointReuse = true
        let https = try NWListener(using: httpsParams, on: NWEndpoint.Port(rawValue: Self.httpsPort)!)
        https.newConnectionHandler = { [weak self] connection in
            self?.handle(connection, secure: true)
        }
        https.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.log("https listener ready on \(Self.httpsPort)")
            case .failed(let error): self?.log("https listener FAILED: \(error)")
            case .waiting(let error): self?.log("https listener waiting: \(error)")
            default: break
            }
        }
        https.start(queue: queue)
        httpsListener = https

        log("host listening on \(Self.httpPort)/\(Self.httpsPort) as \"\(hostName)\"")
    }

    public func stop() {
        httpListener?.cancel()
        httpsListener?.cancel()
        httpListener = nil
        httpsListener = nil
        // Cancel what the listeners handed out too. Moonlight polls
        // /serverinfo over keep-alive connections and each one re-arms its
        // receive loop forever — cancelling only the listeners left every
        // accepted connection alive and accumulating.
        let open = live.withLock { connections -> [NWConnection] in
            let all = connections
            connections.removeAll()
            return all
        }
        for connection in open { connection.cancel() }
        currentPIN = nil
    }

    /// New PIN for the next pairing attempt (Moonlight prompts for it).
    @discardableResult
    public func newPIN() -> String {
        let pin = String(format: "%04d", Int.random(in: 0...9999))
        currentPIN = pin
        session.withLock { $0 = PairSession() }
        log("pairing PIN: \(pin)")
        return pin
    }

    private func log(_ message: String) {
        onLog?(message)
    }

    // MARK: HTTP plumbing

    private func handle(_ connection: NWConnection, secure: Bool) {
        live.withLock { $0.append(connection) }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.live.withLock { $0.removeAll { $0 === connection } }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(connection, buffered: Data(), secure: secure)
    }

    private func receive(_ connection: NWConnection, buffered: Data, secure: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, error == nil, !isComplete else {
                connection.cancel()
                return
            }
            var buffer = buffered
            if let data { buffer.append(data) }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count < 128 * 1024 {
                    self.receive(connection, buffered: buffer, secure: secure)
                } else {
                    connection.cancel()
                }
                return
            }
            let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            let leftover = Data(buffer[headerEnd.upperBound...])
            self.respond(connection, head: head, secure: secure)
            self.receive(connection, buffered: leftover, secure: secure)
        }
    }

    private func respond(_ connection: NWConnection, head: String, secure: Bool) {
        guard let requestLine = head.split(separator: "\r\n").first else { return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let target = String(parts[1])
        let path = target.components(separatedBy: "?").first ?? target
        let query = parseQuery(target)

        log("\(secure ? "https" : "http") \(path) \(query["phrase"].map { "phrase=\($0)" } ?? "")")

        let body: String
        switch path {
        case "/serverinfo", "/applist":
            if path == "/serverinfo" {
                onClientSeen?(query["uniqueid"] ?? "unknown")
                body = serverInfoXML(clientID: query["uniqueid"])
            } else {
                body = appListXML()
            }
        case "/pair":
            body = handlePair(query: query)
        case "/unpair":
            pairedClients.withLock { $0.removeAll() }
            body = xml("<paired>0</paired>")
        default:
            body = xml("")
        }
        send(connection, body: body)
    }

    private func parseQuery(_ target: String) -> [String: String] {
        guard let queryPart = target.components(separatedBy: "?").dropFirst().first else { return [:] }
        var result: [String: String] = [:]
        for pair in queryPart.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            guard kv.count == 2 else { continue }
            result[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
        }
        return result
    }

    private func send(_ connection: NWConnection, body: String) {
        let payload = Data(body.utf8)
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: application/xml\r
        Content-Length: \(payload.count)\r
        Connection: keep-alive\r
        \r

        """
        var response = Data(header.utf8)
        response.append(payload)
        connection.send(content: response, completion: .contentProcessed { _ in })
    }

    private func xml(_ inner: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <root protocol_version="0.1" status_code="200">\(inner)</root>
        """
    }

    // MARK: Endpoints

    private func serverInfoXML(clientID: String?) -> String {
        let paired = pairedClients.withLock { clients in
            guard let clientID, !clientID.isEmpty else { return !clients.isEmpty }
            return clients[clientID] != nil
        }
        return xml("""
        <hostname>\(hostName)</hostname>\
        <appversion>7.1.431.-1</appversion>\
        <GfeVersion>3.23.0.74</GfeVersion>\
        <uniqueid>\(identity.uniqueID)</uniqueid>\
        <HttpsPort>\(Self.httpsPort)</HttpsPort>\
        <ExternalPort>\(Self.httpPort)</ExternalPort>\
        <mac>00:00:00:00:00:00</mac>\
        <MaxLumaPixelsHEVC>0</MaxLumaPixelsHEVC>\
        <LocalIP>\(localIP() ?? "127.0.0.1")</LocalIP>\
        <ServerCodecModeSupport>3</ServerCodecModeSupport>\
        <PairStatus>\(paired ? 1 : 0)</PairStatus>\
        <currentgame>0</currentgame>\
        <state>SUNSHINE_SERVER_FREE</state>
        """)
    }

    private func appListXML() -> String {
        // One "app": the Mac's screen.
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <root protocol_version="0.1" status_code="200">\
        <App><IsHdrSupported>0</IsHdrSupported><AppTitle>Desktop</AppTitle><ID>1</ID></App>\
        </root>
        """
    }

    private func localIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var pointer = ifaddr
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if name == "en0" { return ip }
            if address == nil { address = ip }
        }
        return address
    }

    // MARK: Pairing state machine

    private func handlePair(query: [String: String]) -> String {
        if let phrase = query["phrase"], phrase == "getservercert" {
            return phaseServerCert(query: query)
        }
        if let challenge = query["clientchallenge"] {
            return phaseClientChallenge(hex: challenge)
        }
        if let response = query["serverchallengeresp"] {
            return phaseServerChallengeResponse(hex: response)
        }
        if let secret = query["clientpairingsecret"] {
            return phaseClientPairingSecret(hex: secret, clientID: query["uniqueid"] ?? "client")
        }
        if let phrase = query["phrase"], phrase == "pairchallenge" {
            // Final handshake over TLS: reaching here means we're paired.
            log("pairchallenge OK — paired")
            onPaired?(query["uniqueid"] ?? "client")
            return xml("<paired>1</paired>")
        }
        return xml("<paired>0</paired>")
    }

    private func failPair(_ reason: String) -> String {
        log("pairing failed: \(reason)")
        return xml("<paired>0</paired>")
    }

    private func phaseServerCert(query: [String: String]) -> String {
        guard let pin = currentPIN else { return failPair("no PIN active") }
        guard let saltHex = query["salt"], let salt = GameStreamCrypto.data(hex: saltHex),
              salt.count >= 16 else { return failPair("bad salt") }
        guard let clientCertHex = query["clientcert"],
              let clientCertPEM = GameStreamCrypto.data(hex: clientCertHex) else {
            return failPair("no client cert")
        }
        let key = GameStreamCrypto.aesKey(salt: salt.prefix(16), pin: pin)
        session.withLock {
            $0 = PairSession()
            $0.aesKey = key
            $0.clientCertDER = HostIdentity.pemToDER(String(decoding: clientCertPEM, as: UTF8.self))
        }
        // The client expects our certificate as hex-encoded PEM.
        let certHex = GameStreamCrypto.hex(Data(identity.certificatePEM.utf8))
        return xml("<paired>1</paired><plaincert>\(certHex)</plaincert>")
    }

    private func phaseClientChallenge(hex: String) -> String {
        guard let encrypted = GameStreamCrypto.data(hex: hex) else { return failPair("bad challenge") }
        let state = session.withLock { $0 }
        guard let key = state.aesKey else { return failPair("no key") }
        guard let clientChallenge = GameStreamCrypto.aesECB(encrypted, key: key, encrypt: false),
              let certSignature = GameStreamCrypto.certificateSignature(der: identity.certificateDER) else {
            return failPair("decrypt failed")
        }
        var serverSecret = Data(count: 16)
        _ = serverSecret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        var serverChallenge = Data(count: 16)
        _ = serverChallenge.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }

        var material = clientChallenge
        material.append(certSignature)
        material.append(serverSecret)
        var plaintext = GameStreamCrypto.sha256(material)
        plaintext.append(serverChallenge)

        guard let encryptedResponse = GameStreamCrypto.aesECB(plaintext, key: key, encrypt: true) else {
            return failPair("encrypt failed")
        }
        session.withLock {
            $0.serverSecret = serverSecret
            $0.serverChallenge = serverChallenge
        }
        return xml("<paired>1</paired><challengeresponse>\(GameStreamCrypto.hex(encryptedResponse))</challengeresponse>")
    }

    private func phaseServerChallengeResponse(hex: String) -> String {
        guard let encrypted = GameStreamCrypto.data(hex: hex) else { return failPair("bad response") }
        let state = session.withLock { $0 }
        guard let key = state.aesKey,
              let decrypted = GameStreamCrypto.aesECB(encrypted, key: key, encrypt: false) else {
            return failPair("decrypt failed")
        }
        session.withLock { $0.clientHash = decrypted }

        var payload = state.serverSecret
        guard let signature = GameStreamCrypto.signRSA(state.serverSecret, privateKey: identity.privateKey) else {
            return failPair("signing failed")
        }
        payload.append(signature)
        return xml("<paired>1</paired><pairingsecret>\(GameStreamCrypto.hex(payload))</pairingsecret>")
    }

    private func phaseClientPairingSecret(hex: String, clientID: String) -> String {
        guard let blob = GameStreamCrypto.data(hex: hex), blob.count > 16 else {
            return failPair("secret too short")
        }
        let state = session.withLock { $0 }
        let clientSecret = blob.prefix(16)
        let clientSignature = blob.dropFirst(16)
        guard let clientCert = state.clientCertDER,
              let clientCertSignature = GameStreamCrypto.certificateSignature(der: clientCert) else {
            return failPair("no client cert")
        }

        var expected = state.serverChallenge
        expected.append(clientCertSignature)
        expected.append(clientSecret)
        let hash = GameStreamCrypto.sha256(expected)
        guard hash == state.clientHash else { return failPair("hash mismatch (wrong PIN?)") }
        guard GameStreamCrypto.verifyRSA(
            Data(clientSecret), signature: Data(clientSignature), certificateDER: clientCert
        ) else {
            return failPair("client signature invalid")
        }

        pairedClients.withLock { $0[clientID] = clientCert }
        log("paired with \(clientID)")
        onPaired?(clientID)
        return xml("<paired>1</paired>")
    }
}
