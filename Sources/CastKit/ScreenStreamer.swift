import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics

public enum MirrorQuality: String, Sendable, CaseIterable {
    case p720, p1080

    var size: (width: Int, height: Int) {
        switch self {
        case .p720: (1280, 720)
        case .p1080: (1920, 1080)
        }
    }

    var bitrate: Int {
        switch self {
        case .p720: 4_000_000
        case .p1080: 8_000_000
        }
    }
}

/// Screen Recording permission — the same probe/guide pattern as Full Disk
/// Access elsewhere in the app.
public enum ScreenRecordingPermission {
    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the one-shot system prompt. macOS only re-reads the grant
    /// after a relaunch, which the UI explains.
    @discardableResult
    public static func request() -> Bool { CGRequestScreenCaptureAccess() }

    public static let settingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
}

/// Captures a display with ScreenCaptureKit and feeds the HLS segmenter.
public final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public let store = HLSSegmentStore()
    private let videoQueue = DispatchQueue(label: "cast.capture.video")
    private let audioQueue = DispatchQueue(label: "cast.capture.audio")
    private var stream: SCStream?
    private var segmenter: HLSSegmenter?
    public private(set) var isRunning = false
    /// Set when the stream dies on its own (display disconnected, etc.).
    public var onStopped: (@Sendable (String?) -> Void)?

    public override init() { super.init() }

    public func start(quality: MirrorQuality, includeAudio: Bool) async throws {
        guard !isRunning else { return }
        store.reset()

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            throw NSError(domain: "CastKit", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "No display to capture"])
        }

        // Keep the display's aspect ratio inside the quality box.
        let (boxWidth, boxHeight) = quality.size
        let scale = min(Double(boxWidth) / Double(display.width),
                        Double(boxHeight) / Double(display.height))
        let width = Int((Double(display.width) * scale / 2).rounded()) * 2   // even dimensions
        let height = Int((Double(display.height) * scale / 2).rounded()) * 2

        let segmenter = try HLSSegmenter(
            width: width, height: height, bitrate: quality.bitrate,
            includeAudio: includeAudio, store: store
        )
        self.segmenter = segmenter

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.capturesAudio = includeAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if includeAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        self.stream = stream
        isRunning = true
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        try? await stream?.stopCapture()
        stream = nil
        await segmenter?.finish()
        segmenter = nil
    }

    /// Waits until the first playable segment exists, so we never hand the
    /// TV a playlist it would choke on.
    public func waitForFirstSegment(timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if store.hasContent { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    // MARK: SCStreamOutput

    public func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            // Only complete frames carry pixels; skip idle/blank updates.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer, createIfNecessary: false
                  ) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete else { return }
            segmenter?.append(video: sampleBuffer)
        case .audio:
            segmenter?.append(audio: sampleBuffer)
        default:
            break
        }
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
        onStopped?(error.localizedDescription)
    }
}
