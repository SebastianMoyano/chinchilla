import Foundation
import CommonCrypto

/// Payload encryption for Cast Streaming: AES-128-CTR, with a nonce derived
/// from the frame ID so every frame decrypts independently — a receiver that
/// misses a frame can still decode the next one.
///
/// The nonce is a zero block carrying the frame ID big-endian at offset 8,
/// XORed with the per-session IV mask sent in the OFFER.
public struct CastFrameCrypto: Sendable {
    private let key: Data
    private let ivMask: Data

    public init(key: Data, ivMask: Data) {
        self.key = key
        self.ivMask = ivMask
    }

    public init(keys: CastStreaming.StreamKeys) {
        self.init(key: keys.aesKey, ivMask: keys.aesIvMask)
    }

    public func nonce(frameID: UInt32) -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[8] = UInt8(truncatingIfNeeded: frameID >> 24)
        bytes[9] = UInt8(truncatingIfNeeded: frameID >> 16)
        bytes[10] = UInt8(truncatingIfNeeded: frameID >> 8)
        bytes[11] = UInt8(truncatingIfNeeded: frameID)
        let mask = [UInt8](ivMask)
        for index in 0..<16 { bytes[index] ^= mask[index] }
        return Data(bytes)
    }

    /// CTR is its own inverse, so this both encrypts and decrypts.
    public func crypt(_ input: Data, frameID: UInt32) -> Data? {
        guard key.count == 16, ivMask.count == 16 else { return nil }
        let iv = nonce(frameID: frameID)
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBytes.baseAddress,
                    keyBytes.baseAddress, key.count,
                    nil, 0, 0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }
        guard status == kCCSuccess, let cryptor else { return nil }
        defer { CCCryptorRelease(cryptor) }

        let length = input.count
        var output = [UInt8](repeating: 0, count: length)
        var moved = 0
        let updateStatus = output.withUnsafeMutableBytes { outBytes in
            input.withUnsafeBytes { inBytes in
                CCCryptorUpdate(
                    cryptor, inBytes.baseAddress, length,
                    outBytes.baseAddress, length, &moved
                )
            }
        }
        guard updateStatus == kCCSuccess, moved == input.count else { return nil }
        return Data(output)
    }
}
