import Foundation
import DiskScanKit
import Security
import Testing
@testable import StreamHostKit

/// Acts as Moonlight: runs the full four-phase GameStream pairing against
/// our host, so the crypto is proven before anyone installs anything.
private struct FakeMoonlight {
    let certPEM: String
    let certDER: Data
    let privateKey: SecKey
    let base: String

    init(base: String) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moonlight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cert = dir.appendingPathComponent("client.pem")
        let key = dir.appendingPathComponent("client-key.pem")
        let p12 = dir.appendingPathComponent("client.p12")

        func openssl(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "openssl", code: Int(process.terminationStatus))
            }
        }
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "30", "-nodes",
                     "-keyout", key.path, "-out", cert.path, "-subj", "/CN=NVIDIA GameStream Client"])
        try openssl(["pkcs12", "-export", "-out", p12.path, "-inkey", key.path,
                     "-in", cert.path, "-passout", "pass:test"])

        certPEM = try String(contentsOf: cert, encoding: .utf8)
        certDER = HostIdentity.pemToDER(certPEM)!
        var items: CFArray?
        _ = SecPKCS12Import(try Data(contentsOf: p12) as CFData,
                            [kSecImportExportPassphrase as String: "test"] as CFDictionary, &items)
        let identity = (items as! [[String: Any]])[0][kSecImportItemIdentity as String] as! SecIdentity
        var pk: SecKey?
        SecIdentityCopyPrivateKey(identity, &pk)
        privateKey = pk!
        self.base = base
    }

    func get(_ query: String) async throws -> String {
        let url = URL(string: "\(base)/pair?devicename=test&updateState=1&\(query)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return String(decoding: data, as: UTF8.self)
    }

    func value(_ tag: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }
}

@Test(.timeLimit(.minutes(1))) func fullPairingHandshake() async throws {
    let host = try GameStreamHost()
    let logLines = Locked<[String]>([])
    host.onLog = { line in logLines.withLock { $0.append(line) } }
    try host.start()
    defer { host.stop() }
    let pin = host.newPIN()
    try await Task.sleep(for: .milliseconds(400))

    let client = try FakeMoonlight(base: "http://127.0.0.1:\(GameStreamHost.httpPort)")

    // Phase 1: exchange certificates, derive the shared AES key from the PIN.
    var salt = Data(count: 16)
    _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
    let key = GameStreamCrypto.aesKey(salt: salt, pin: pin)
    let certReply = try await client.get(
        "phrase=getservercert&salt=\(GameStreamCrypto.hex(salt))" +
        "&clientcert=\(GameStreamCrypto.hex(Data(client.certPEM.utf8)))"
    )
    #expect(client.value("paired", in: certReply) == "1")
    let serverCertPEM = String(decoding: GameStreamCrypto.data(hex: client.value("plaincert", in: certReply) ?? "")!, as: UTF8.self)
    let serverCertDER = HostIdentity.pemToDER(serverCertPEM)!

    // Phase 2: client challenge.
    var clientChallenge = Data(count: 16)
    _ = clientChallenge.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
    let challengeReply = try await client.get(
        "clientchallenge=\(GameStreamCrypto.hex(GameStreamCrypto.aesECB(clientChallenge, key: key, encrypt: true)!))"
    )
    let encryptedResponse = GameStreamCrypto.data(hex: client.value("challengeresponse", in: challengeReply) ?? "")
    let decrypted = GameStreamCrypto.aesECB(encryptedResponse!, key: key, encrypt: false)!
    #expect(decrypted.count >= 48)
    let serverChallenge = Data(decrypted[decrypted.startIndex + 32..<decrypted.startIndex + 48])

    // Phase 3: prove we know the PIN by hashing the server's challenge.
    var clientSecret = Data(count: 16)
    _ = clientSecret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
    var material = serverChallenge
    material.append(GameStreamCrypto.certificateSignature(der: client.certDER)!)
    material.append(clientSecret)
    let clientHash = GameStreamCrypto.sha256(material)
    let secretReply = try await client.get(
        "serverchallengeresp=\(GameStreamCrypto.hex(GameStreamCrypto.aesECB(clientHash, key: key, encrypt: true)!))"
    )
    let pairingSecret = GameStreamCrypto.data(hex: client.value("pairingsecret", in: secretReply) ?? "")!
    #expect(pairingSecret.count > 16)
    // The server's signature over its secret must verify against its cert.
    let serverSecret = pairingSecret.prefix(16)
    let serverSignature = pairingSecret.dropFirst(16)
    #expect(GameStreamCrypto.verifyRSA(Data(serverSecret), signature: Data(serverSignature),
                                       certificateDER: serverCertDER))

    // Phase 4: hand over our secret, signed.
    var finalBlob = clientSecret
    finalBlob.append(GameStreamCrypto.signRSA(clientSecret, privateKey: client.privateKey)!)
    let finalReply = try await client.get("clientpairingsecret=\(GameStreamCrypto.hex(finalBlob))&uniqueid=TESTCLIENT")
    #expect(client.value("paired", in: finalReply) == "1", "pairing rejected: \(finalReply)")

    logLines.withLock { print("HOST LOG:\n" + $0.joined(separator: "\n")) }
}
