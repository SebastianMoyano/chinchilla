import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import VirtualDisplayKit

public enum MirrorQuality: String, Sendable, CaseIterable {
    /// 480p exists for latency, not looks: H.264 starved of bits shatters on
    /// fast motion, so the way down from "720p is stuttering" is fewer
    /// pixels with bitrate headroom — not the same pixels with less.
    case p480, p720, p1080

    var size: (width: Int, height: Int) {
        switch self {
        case .p480: (854, 480)
        case .p720: (1280, 720)
        case .p1080: (1920, 1080)
        }
    }

    var bitrate: Int {
        switch self {
        case .p480: 3_500_000
        case .p720: 4_000_000
        case .p1080: 8_000_000
        }
    }

    public var heightLabel: String {
        switch self {
        case .p480: "480p"
        case .p720: "720p"
        case .p1080: "1080p"
        }
    }
}

/// What gets sent to the TV: the desk you already have, a new one, or one
/// window parked over there.
/// Which side of the real screen the extra desktop sits on. macOS drops a new
/// display wherever it likes, and then the mouse leaves the wrong edge — which
/// feels broken even though nothing is.
public enum ExtendedSide: String, Sendable, Hashable, CaseIterable, Identifiable {
    case left, right
    public var id: String { rawValue }
    /// Plain string: CastKit has no SwiftUI, and the app localises it.
    public var labelKey: String {
        switch self {
        case .left: "To the left"
        case .right: "To the right"
        }
    }
}

public enum MirrorSource: Sendable, Hashable {
    case wholeScreen
    /// A genuine second desktop, created in software and sent to the TV —
    /// macOS arranges windows onto it exactly like a plugged-in monitor.
    case extendedDisplay
    case window(id: CGWindowID, title: String, app: String)

    public var label: String {
        switch self {
        case .wholeScreen: String(localized: "Whole screen")
        case .extendedDisplay: String(localized: "Extended display (second desktop)")
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
    /// Kept so adaptive quality can rescale the running capture.
    private var configuration: SCStreamConfiguration?
    private var segmenter: HLSSegmenter?
    public private(set) var isRunning = false
    /// Set when the stream dies on its own (display disconnected, etc.).
    public var onStopped: (@Sendable (String?) -> Void)?

    /// Held for the life of the stream: releasing it unplugs the display.
    private var virtualDisplay: ChinchillaVirtualDisplay?

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
        case .extendedDisplay:
            // The virtual display is a fixed 1080p desktop; the stream is
            // the quality's box, scaled down from it by the capture.
            return quality.size
        case .window:
            // The stream is the full quality box and the window is fitted
            // inside it (letterboxed). Sizing the stream to the window's
            // shape instead meant the first resize changed the aspect and
            // the capture started cropping — a bar of the window gone off
            // the top or the side, depending on which way it was resized.
            return quality.size
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

    /// The extra desktop's fixed size — a standard mode, independent of the
    /// stream quality (see the creation comment in `start`).
    static let virtualDisplaySize = (width: 1920, height: 1080)

    /// Moves an already-running extra desktop to the other side.
    public func repositionVirtualDisplay(on side: ExtendedSide, quality: MirrorQuality) {
        guard let display = virtualDisplay, display.isActive else { return }
        Self.place(display: display.displayID, on: side, size: Self.virtualDisplaySize)
    }

    /// Puts the virtual display beside the real one. `kCGConfigureForSession`
    /// rather than permanently: this display is temporary, and there's no
    /// reason for it to leave a mark on the user's saved arrangement.
    static func place(display: CGDirectDisplayID, on side: ExtendedSide, size: (Int, Int)) {
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let x: Int32 = side == .left
            ? -Int32(size.0)
            : Int32(mainBounds.width)
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success,
              let configuration else { return }
        CGConfigureDisplayOrigin(configuration, display, x, 0)
        CGCompleteDisplayConfiguration(configuration, .forSession)
    }

    public func start(
        quality: MirrorQuality, includeAudio: Bool, frameRate: Int = 30,
        source: MirrorSource = .wholeScreen,
        extendedSide: ExtendedSide = .right
    ) async throws {
        guard !isRunning else { return }
        store.reset()

        // Resolve the main display only when the source actually captures it.
        // Every SCShareableContent lookup is a slow XPC query that can hang
        // (hence the timeouts), and the other sources compute their own size
        // below: the extra query here was pure overhead — and for the extended
        // display it can't even be shared, because its lookup has to run after
        // the virtual display exists.
        var width = 0
        var height = 0
        var chosenDisplay: SCDisplay?
        if case .wholeScreen = source {
            let display = try await Self.mainDisplay()
            (width, height) = Self.captureSize(for: quality, display: display)
            chosenDisplay = display
        }

        // A second desktop: bring the display up first, then capture it like
        // any other. macOS moves windows onto it the moment it appears.
        //
        // Always created at 1080p, whatever quality the *stream* runs at.
        // Creating it at the level's box (720p for the responsive levels)
        // gave the user a chunky desktop with oversized apps, and handed
        // Mission Control a non-standard display mode it visibly choked on
        // (black screen on the swipe-up gesture). The desktop stays a normal
        // 1080p; SCStream scales the capture down to whatever the ladder
        // asks for.
        if case .extendedDisplay = source {
            let (w, h) = Self.virtualDisplaySize
            let virtual = ChinchillaVirtualDisplay(
                name: "Chinchilla TV", width: UInt32(w), height: UInt32(h), refreshRate: 60
            )
            guard virtual.isActive else {
                throw NSError(domain: "CastKit", code: 12, userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "macOS wouldn't create the extra display."
                    ),
                ])
            }
            self.virtualDisplay = virtual
            Self.place(display: virtual.displayID, on: extendedSide, size: (w, h))
            let content = try await withTimeout(.seconds(8), "Screen capture") {
                Unchecked(try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false
                ))
            }.value
            guard let scDisplay = content.displays.first(where: {
                $0.displayID == virtual.displayID
            }) else {
                self.virtualDisplay = nil
                throw NSError(domain: "CastKit", code: 13, userInfo: [
                    NSLocalizedDescriptionKey: String(
                        localized: "The extra display came up but couldn't be captured."
                    ),
                ])
            }
            chosenDisplay = scDisplay
            // The stream is the level's box; the desktop stays 1080p.
            (width, height) = quality.size
        }

        // A single window: the stream is the full quality box and the window
        // is fitted inside it, letterboxed. The whole window is always on
        // the TV — resize it and the fit follows; sizing the stream to the
        // window's shape instead meant any later resize changed the aspect
        // and the capture cropped a slice off the top or the side.
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
            (width, height) = quality.size
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
        if case .window = source {
            // Fit, don't fill: the window scales into the box with black
            // bars, whatever shape the user drags it to, and the drop
            // shadow doesn't waste box space.
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            configuration.ignoreShadowsSingleWindow = true
        }

        // Every source case above set one of the two; the guard is belt and
        // braces, not a reachable path.
        let filter: SCContentFilter
        if let windowFilter {
            filter = windowFilter
        } else if let chosenDisplay {
            filter = SCContentFilter(display: chosenDisplay, excludingApplications: [], exceptingWindows: [])
        } else {
            throw NSError(domain: "CastKit", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "No display to capture"])
        }
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
        self.configuration = configuration
        isRunning = true
    }

    /// Rescales the running capture output — SCStream scales the same source
    /// to the new size without restarting, so adaptive quality can move
    /// between resolutions with no gap in frames. The filter, audio and
    /// frame rate stay as negotiated.
    public func updateCaptureSize(width: Int, height: Int) async {
        guard isRunning, let stream, let configuration else { return }
        configuration.width = width
        configuration.height = height
        let boxed = Unchecked((stream, configuration))
        try? await withTimeout(.seconds(5), "Screen capture") {
            try await boxed.value.0.updateConfiguration(boxed.value.1)
        }
    }

    public func stop() async {
        // Not `guard isRunning`: that flag is set on the last line of start(),
        // so a throw anywhere before it left the virtual display and the
        // segmenter allocated and unreachable. On the app-lifetime streamer
        // that meant a phantom monitor until the app quit.
        guard isRunning || stream != nil || virtualDisplay != nil || segmenter != nil else {
            return
        }
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
        configuration = nil
        // Unplug the extra desktop; windows on it move back to the real one.
        virtualDisplay?.invalidate()
        virtualDisplay = nil
        await segmenter?.finish()
        segmenter = nil
        // Viewers wait on `store.hasContent` to know the session is over. Left
        // full, that stayed true after the stop, so every viewer task went on
        // polling once a second forever, each one holding its connection open.
        store.reset()
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
