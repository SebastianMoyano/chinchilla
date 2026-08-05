import Foundation
import VideoToolbox
import CoreMedia
import AVFoundation

/// H.264 encoding tuned for mirroring rather than for a file.
///
/// Three deliberate differences from `HLSSegmenter`: no container (RTP wants
/// raw NAL units), no frame reordering (a B-frame would hold a frame back to
/// wait for a future one), and a long key-frame interval with key frames on
/// demand — a static screen then costs almost nothing, and the receiver asks
/// for a fresh one when it actually needs it.
public final class RealtimeH264Encoder: @unchecked Sendable {
    public struct EncodedSample: Sendable {
        public let annexB: Data
        public let isKeyFrame: Bool
        public let presentationTime: CMTime
    }

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var forceKeyFrame = true
    public var onSample: (@Sendable (EncodedSample) -> Void)?

    public init(width: Int, height: Int, bitrate: Int, frameRate: Int) throws {
        var session: VTCompressionSession?
        let encoderSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            // Apple's dedicated low-latency path: no frame reordering and a
            // rate controller that reacts within a frame or two.
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            throw NSError(domain: "CastKit", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Couldn't create the video encoder (\(status))",
            ])
        }
        self.session = session

        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, frameRate as CFNumber)
        // A ceiling as well as an average, so a scene change can't burst into
        // a multi-second queue on the receiver.
        set(kVTCompressionPropertyKey_DataRateLimits,
            [bitrate / 8 * 2, 1] as CFArray)
        // Long GOP: on an idle desktop this is the difference between ~1.7 Mbps
        // and ~150 kbps, because a key frame every half second is what costs.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 600 as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 20 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    /// Changes the target bitrate live — the low-latency rate controller
    /// reacts within a frame or two, so a session rebuild (and the IDR it
    /// would cost) is only needed when the *resolution* changes.
    public func setBitrate(_ bitrate: Int) {
        lock.lock()
        let session = self.session
        lock.unlock()
        guard let session else { return }
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_AverageBitRate,
            value: bitrate as CFNumber
        )
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_DataRateLimits,
            value: [bitrate / 8 * 2, 1] as CFArray
        )
    }

    /// Asks for an IDR on the next frame — used when the receiver reports it
    /// lost too much to recover, and once at the start of a session.
    public func requestKeyFrame() {
        lock.lock()
        forceKeyFrame = true
        lock.unlock()
    }

    public func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)

        // Frames arrive on the capture queue while `finish()` may be
        // invalidating the session from another thread — read it under the
        // same lock that clears it.
        lock.lock()
        guard let session else { lock.unlock(); return }
        let wantsKey = forceKeyFrame
        forceKeyFrame = false
        lock.unlock()

        let properties: CFDictionary? = wantsKey
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            : nil

        let handler = onSample
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: imageBuffer, presentationTimeStamp: time,
            duration: duration, frameProperties: properties,
            infoFlagsOut: nil
        ) { status, _, buffer in
            guard status == noErr, let buffer, let handler else { return }
            guard let sample = Self.annexB(from: buffer) else { return }
            handler(sample)
        }
    }

    public func finish() {
        lock.lock()
        let session = self.session
        self.session = nil
        onSample = nil
        lock.unlock()
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    deinit { finish() }

    /// VideoToolbox hands back length-prefixed NAL units and keeps the
    /// parameter sets on the side. Decoders on the far end expect the Annex B
    /// byte stream, with the parameter sets inline ahead of every key frame —
    /// otherwise a receiver that joins late has nothing to configure itself with.
    static func annexB(from sampleBuffer: CMSampleBuffer) -> EncodedSample? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var isKeyFrame = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[CFString: Any]], let first = attachments.first {
            isKeyFrame = !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        }

        let startCode = Data([0, 0, 0, 1])
        var output = Data()

        if isKeyFrame, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var count = 0
            var naluHeaderLength: Int32 = 4
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &naluHeaderLength
            )
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                ) == noErr, let pointer else { continue }
                output.append(startCode)
                output.append(pointer, count: size)
            }
        }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength, dataPointerOut: &dataPointer
        ) == noErr, let dataPointer else { return nil }

        let bytes = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + 4 <= totalLength {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length > 0, offset + 4 + length <= totalLength else { break }
            output.append(startCode)
            output.append(bytes + offset + 4, count: length)
            offset += 4 + length
        }

        return EncodedSample(
            annexB: output, isKeyFrame: isKeyFrame,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
    }
}
