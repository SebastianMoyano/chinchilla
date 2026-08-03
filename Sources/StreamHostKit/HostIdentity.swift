import Foundation
import Security

/// The host's self-signed certificate and key — GameStream pairing is built
/// around them. macOS has no API to mint an X.509, so we drive the bundled
/// openssl once and reuse the result forever.
/// SecKey/SecIdentity are thread-safe CF types that Swift can't prove
/// Sendable; the identity is created once and never mutated.
public struct HostIdentity: @unchecked Sendable {
    public let certificateDER: Data
    public let certificatePEM: String
    public let privateKey: SecKey
    /// TLS identity for the HTTPS listener.
    public let secIdentity: SecIdentity
    public let uniqueID: String

    public static var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Chinchilla/gamestream")
    }

    public static func loadOrCreate() throws -> HostIdentity {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let certURL = directory.appendingPathComponent("cert.pem")
        let keyURL = directory.appendingPathComponent("key.pem")
        let p12URL = directory.appendingPathComponent("identity.p12")

        if !fm.fileExists(atPath: certURL.path) || !fm.fileExists(atPath: p12URL.path) {
            try generate(certURL: certURL, keyURL: keyURL, p12URL: p12URL)
        }

        let pem = try String(contentsOf: certURL, encoding: .utf8)
        guard let der = pemToDER(pem) else {
            throw HostIdentityError.message("Certificate isn't valid PEM")
        }

        let p12Data = try Data(contentsOf: p12URL)
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: "chinchilla"] as CFDictionary
        guard SecPKCS12Import(p12Data as CFData, options, &items) == errSecSuccess,
              let array = items as? [[String: Any]],
              let first = array.first,
              let identityAny = first[kSecImportItemIdentity as String] else {
            throw HostIdentityError.message("Couldn't import the host identity")
        }
        let identity = identityAny as! SecIdentity
        var privateKey: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
              let privateKey else {
            throw HostIdentityError.message("Couldn't read the host private key")
        }

        // Stable per-install ID that Moonlight uses to recognise this host.
        let defaultsKey = "gamestream.uniqueID"
        let uniqueID: String
        if let stored = UserDefaults.standard.string(forKey: defaultsKey) {
            uniqueID = stored
        } else {
            uniqueID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).uppercased()
            UserDefaults.standard.set(uniqueID, forKey: defaultsKey)
        }

        return HostIdentity(
            certificateDER: der, certificatePEM: pem, privateKey: privateKey,
            secIdentity: identity, uniqueID: uniqueID
        )
    }

    private static func generate(certURL: URL, keyURL: URL, p12URL: URL) throws {
        func run(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let output = String(
                    data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
                ) ?? ""
                throw HostIdentityError.message("openssl failed: \(output)")
            }
        }
        try run([
            "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650", "-nodes",
            "-keyout", keyURL.path, "-out", certURL.path,
            "-subj", "/C=US/O=Chinchilla/OU=Chinchilla/CN=Chinchilla GameStream Host",
        ])
        try run([
            // macOS ships LibreSSL: no -legacy flag, and its default
            // export format is exactly what SecPKCS12Import accepts.
            "pkcs12", "-export", "-out", p12URL.path,
            "-inkey", keyURL.path, "-in", certURL.path,
            "-passout", "pass:chinchilla", "-name", "Chinchilla",
        ])
    }

    public static func pemToDER(_ pem: String) -> Data? {
        let base64 = pem
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        return Data(base64Encoded: base64)
    }
}

public enum HostIdentityError: Error, CustomStringConvertible {
    case message(String)
    public var description: String {
        if case .message(let text) = self { return text }
        return "unknown"
    }
}
