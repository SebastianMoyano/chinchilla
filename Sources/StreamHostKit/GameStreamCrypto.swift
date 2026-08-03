import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Crypto primitives the GameStream pairing handshake needs.
/// (ECB is required by the protocol — it's what Moonlight speaks.)
public enum GameStreamCrypto {
    /// AES-128 key = first 16 bytes of SHA-256(salt ‖ PIN).
    public static func aesKey(salt: Data, pin: String) -> Data {
        var input = salt
        input.append(Data(pin.utf8))
        return Data(SHA256.hash(data: input).prefix(16))
    }

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func aesECB(_ data: Data, key: Data, encrypt: Bool) -> Data? {
        var buffer = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = buffer.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),  // no padding: sizes are block-aligned
                        keyBytes.baseAddress, key.count,
                        nil,
                        inBytes.baseAddress, data.count,
                        outBytes.baseAddress, outBytes.count,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(buffer.prefix(moved))
    }

    /// The signature bytes of an X.509 certificate: third element of the
    /// outer DER SEQUENCE (a BIT STRING, minus its unused-bits byte).
    public static func certificateSignature(der: Data) -> Data? {
        var cursor = der.startIndex
        guard let outer = readTLV(der, &cursor), outer.tag == 0x30 else { return nil }
        var inner = outer.valueRange.lowerBound
        guard readTLV(der, &inner) != nil else { return nil }        // tbsCertificate
        guard readTLV(der, &inner) != nil else { return nil }        // signatureAlgorithm
        guard let signature = readTLV(der, &inner), signature.tag == 0x03 else { return nil }
        // BIT STRING: skip the leading "unused bits" byte.
        return Data(der[der.index(after: signature.valueRange.lowerBound)..<signature.valueRange.upperBound])
    }

    private static func readTLV(
        _ data: Data, _ cursor: inout Data.Index
    ) -> (tag: UInt8, valueRange: Range<Data.Index>)? {
        guard cursor < data.endIndex else { return nil }
        let tag = data[cursor]
        var index = data.index(after: cursor)
        guard index < data.endIndex else { return nil }
        var length = Int(data[index])
        index = data.index(after: index)
        if length & 0x80 != 0 {
            let byteCount = length & 0x7F
            guard byteCount > 0, byteCount <= 4,
                  data.index(index, offsetBy: byteCount, limitedBy: data.endIndex) != nil else { return nil }
            length = 0
            for _ in 0..<byteCount {
                length = (length << 8) | Int(data[index])
                index = data.index(after: index)
            }
        }
        guard let end = data.index(index, offsetBy: length, limitedBy: data.endIndex) else { return nil }
        cursor = end
        return (tag, index..<end)
    }

    public static func signRSA(_ data: Data, privateKey: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        let signature = SecKeyCreateSignature(
            privateKey, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error
        )
        return signature as Data?
    }

    public static func verifyRSA(_ data: Data, signature: Data, certificateDER: Data) -> Bool {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
              let publicKey = SecCertificateCopyKey(certificate) else { return false }
        var error: Unmanaged<CFError>?
        return SecKeyVerifySignature(
            publicKey, .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData, signature as CFData, &error
        )
    }

    // MARK: Hex helpers (the protocol speaks hex strings)

    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    public static func data(hex: String) -> Data? {
        let characters = Array(hex)
        guard characters.count % 2 == 0 else { return nil }
        var bytes = Data(capacity: characters.count / 2)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }
}
