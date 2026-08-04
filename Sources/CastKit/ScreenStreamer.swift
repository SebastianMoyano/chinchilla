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

/// What gets sent to the TV.
///
/// macOS won't let an app add a real second desktop — that needs a DriverKit
/// display extension and an entitlement Apple grants case by case (the old
/// `CGVirtualDisplay` route accepts the settings and then never brings the
/// display up). So the useful version of "extend my screen" here is picking
/// *what* to send: a single window can sit on the TV while you carry on
/// working, which is what people actually want it for.
public enum MirrorSource: Sendable, Hashable {
    case wholeScreen
    case window(id: CGWindowID, title: String, app: String)

    public var label: String {
        switch self {
        case .wholeScreen: String(localized: "Whole screen")
        case .window(_, let title, let app): title.isEmpty ? app : "\(app) — \(title)"
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

    /// Set to bypass the HLS segmenter and receive raw frames — the
    /// low-latency path encodes them itself.
    public var onVideoSample: (@Sendable (CMSampleBuffer) -> Void)?
    /// Same idea for system audio.
    public var onAudioSample: (@Sendable (CMSampleBuffer) -> Void)?

    public override init() { super.init() }

    /// The capture size for a quality box, keeping the display's aspect ratio.
    public static func captureSize(
        for quality: MirrorQuality, display: SCDisplay
    ) -> (width: Int, height: Int) {
        let (boxWidth, boxHeight) = quality.size
        let scale = min(Double(boxWidth) / Double(display.width),
                        Double(boxHeight) / Double(display.height))
        return (Int((Double(display.width) * scale / 2).rounded()) * 2,   // even dimensions
                Int((Double(display.height) * scale / 2).rounded()) * 2)
    }

    /// ScreenCaptureKit's content query can hang indefinitely when its daemon
    /// is wedged — it neither returns nor throws. Anything waiting on it needs
    /// its own clock.
    /// The stream size for a source. Callers that must describe the stream
    /// before it starts — the Cast offer, for one — need this up front.
    public static func captureSize(
        for quality: MirrorQuality, source: MirrorSource
    ) async throws -> (width: Int, height: Int) {
        switch source {
        case .wholeScreen:
            return captureSize(for: quality, display: try await mainDisplay())
        case .window(let windowID, _, _):
            let content = try await withTimeout(.seconds(8), "Screen capture") {
                Unchecked(try await SCShareableContent.excludingDesktopWindows(
                    true, onScreenWindowsOnly: true
                ))
            }.value
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw NSError(domain: "CastKit", code: 11, userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "That window isn't open any more."
                    ),
                ])
            }
            let (boxWidth, boxHeight) = quality.size
            let scale = min(Double(boxWidth) / window.frame.width,
                            Double(boxHeight) / window.frame.height, 1)
            return (max(2, Int((window.frame.width * scale / 2).rounded()) * 2),
                    max(2, Int((window.frame.height * scale / 2).rounded()) * 2))
        }
    }

    public static func mainDisplay(timeout: Duration = .seconds(8)) async throws -> SCDisplay {
        let content = try await withTimeout(timeout, "Screen capture") {
            Unchecked(try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            ))
        }.value
        guard let display = content.displays.first else {
            throw NSError(domain: "CastKit", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "No display to capture"])
        }
        return display
    }

    /// Windows that are worth offering as a mirroring source: on screen, big
    /// enough to be a real window, and not our own.
    public static func mirrorableWindows() async throws -> [MirrorSource] {
        let content = try await withTimeout(.seconds(8), "Screen capture") {
            Unchecked(try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            ))
        }.value
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows
            .filter { $0.owningApplication?.processID != ownPID }
            .filter { $0.frame.width > 200 && $0.frame.height > 150 }
            .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
            .map {
                .window(
                    id: $0.windowID,
                    title: $0.title ?? "",
                    app: $0.owningApplication?.applicationName ?? "?"
                )
            }
    }

    public func start(
        quality: MirrorQuality, includeAudio: Bool, frameRate: Int = 30,
        source: MirrorSource = .wholeScreen
    ) async throws {
        guard !isRunning else { return }
        store.reset()

        let display = try await Self.mainDisplay()
        var (width, height) = Self.captureSize(for: quality, display: display)

        // A single window: size the stream to the window, so the TV shows it
        // filling the screen instead of a small rectangle on a big desktop.
        var windowFilter: SCContentFilter?
        if case .window(let windowID, _, _) = source {
            let content = try await withTimeout(.seconds(8), "Screen capture") {
                Unchecked(try await SCShareableContent.excludingDesktopWindows(
                    true, onScreenWindowsOnly: true
                ))
            }.value
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw NSError(domain: "CastKit", code: 11, userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "That window isn't open any more."
                    ),
                ])
            }
            let (box, boxHeight) = quality.size
            let scale = min(Double(box) / window.frame.width,
                            Double(boxHeight) / window.frame.height, 1)
            width = max(2, Int((window.frame.width * scale / 2).rounded()) * 2)
            height = max(2, Int((window.frame.height * scale / 2).rounded()) * 2)
            windowFilter = SCContentFilter(desktopIndependentWindow: window)
        }

        // The low-latency path owns its own encoder, so no segmenter.
        if onVideoSample == nil {
            self.segmenter = try HLSSegmenter(
                width: width, height: height, bitrate: quality.bitrate,
                includeAudio: includeAudio, store: store
            )
        }

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.capturesAudio = includeAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let filter = windowFilter
            ?? SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if includeAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        let boxed = Unchecked(stream)
        try await withTimeout(.seconds(10), "Screen capture") {
            try await boxed.value.startCapture()
        }
        self.stream = stream
        isRunning = true
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        // Stop delivering frames before tearing anything down, so a callback
        // can't land on a half-released encoder.
        onVideoSample = nil
        onAudioSample = nil
        if let stream {
            let boxed = Unchecked(stream)
            try? await withTimeout(.seconds(5), "Screen capture") {
                try await boxed.value.stopCapture()
            }
        }
        stream = nil
        await segmenter?.finish()
        segmenter = nil
    }

    /// Waits until the first playable segment exists, so we never hand the
    /// TV a playlist it would choke on.
    public func waitForFirstSegment(
        minimumSegments: Int = 4, timeout: Duration = .seconds(15)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if store.hasAtLeast(minimumSegments) { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return store.hasContent
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
            if let sink = onVideoSample {
                sink(sampleBuffer)
            } else {
                segmenter?.append(video: sampleBuffer)
            }
        case .audio:
            if let sink = onAudioSample {
                sink(sampleBuffer)
            } else {
                segmenter?.append(audio: sampleBuffer)
            }
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
