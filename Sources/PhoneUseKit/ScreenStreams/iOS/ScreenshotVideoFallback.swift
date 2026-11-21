import CoreGraphics
import CoreVideo
import Foundation

/// Device screenshots first, with the live Mirror video as their fallback.
///
/// Screenshots stay the primary source: they are lossless and native size. On iOS 27 the
/// daemon keeps a Mirror stream running to authenticate touches, so subscribing to it locally
/// costs no extra device or network work. While that stream is up a screenshot gets a shorter
/// reply wait; when it fails or times out, this asks for a keyframe and returns the first
/// full-resolution frame decoded after the failure, scaled to native pixels. Earlier frames and
/// frames with the encoder's collapsed resolution are never returned.
///
/// Other devices take ordinary screenshots with a single bounded reply wait.
@MainActor
public final class ScreenshotVideoFallback {
    public enum Source: String, Sendable {
        case screenshot, video
    }

    /// Reply wait while a video fallback is running; most Wi-Fi screenshots answer well within it.
    public static let screenshotTimeoutWithVideo: Duration = .seconds(8)
    /// Reply wait without a fallback. One attempt, so callers can bound the whole request.
    public static let screenshotTimeout: Duration = .seconds(20)
    static let frameWait: Duration = .seconds(3)
    static let restartInterval: TimeInterval = 10

    private let session: DeviceSession
    private let frames = VideoFrameImage()
    private var stream: MirrorScreenStream?
    private var starting: Task<Void, Never>?
    private var lastStart: TimeInterval = -.infinity
    private var stopped = false

    public init(session: DeviceSession) {
        self.session = session
    }

    private var supportsVideo: Bool {
        session.device.platform == .ios && !session.device.isSimulator && session.device.osMajorVersion >= 27
    }

    /// Starts the video in the background. Also restarts it, at most every few seconds, after it ended.
    public func prepare() {
        guard supportsVideo, !stopped, stream == nil, starting == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastStart >= Self.restartInterval else { return }
        lastStart = now
        starting = Task { [weak self] in await self?.startVideo() }
    }

    public func screenshot() async throws -> (image: CGImage, source: Source) {
        prepare()
        let timeout = stream == nil ? Self.screenshotTimeout : Self.screenshotTimeoutWithVideo
        do {
            return (try await session.screenshot(replyTimeout: timeout), .screenshot)
        } catch {
            guard let video = stream else { throw error }
            let started = ProcessInfo.processInfo.systemUptime
            guard let image = await freshFrame(from: video) else {
                Diagnostics.record("screenshot.video.unavailable", ["device": Diagnostics.deviceID(session.device.udid),
                    "error": String(describing: error), "elapsed_ms": Diagnostics.elapsed(since: started)])
                throw error
            }
            Diagnostics.record("screenshot.video.used", ["device": Diagnostics.deviceID(session.device.udid),
                "error": String(describing: error), "elapsed_ms": Diagnostics.elapsed(since: started)])
            return (image, .video)
        }
    }

    public func stop() {
        stopped = true
        starting?.cancel()
        starting = nil
        stream?.stop()
        stream = nil
    }

    private func startVideo() async {
        defer { starting = nil }
        let candidate = MirrorScreenStream(session: session)
        _ = candidate.copyLatestFrame() // opt in to decoding before the first frame arrives
        candidate.onError = { [weak self, weak candidate] message in
            guard let self, let candidate, self.stream === candidate else { return }
            Diagnostics.record("screenshot.video.ended", ["device": Diagnostics.deviceID(self.session.device.udid), "error": message])
            candidate.stop()
            self.stream = nil
        }
        do {
            try await Diagnostics.operation("screenshot.video.start", ["device": Diagnostics.deviceID(session.device.udid)]) {
                try await candidate.start()
            }
            guard !stopped, !Task.isCancelled else { candidate.stop(); return }
            stream = candidate
        } catch {
            candidate.stop()
        }
    }

    /// The first acceptable frame decoded after this call, within `frameWait`.
    private func freshFrame(from video: MirrorScreenStream) async -> CGImage? {
        let since = ProcessInfo.processInfo.systemUptime
        await video.requestKeyFrame()
        let width = Int(session.display.pixelWidth), height = Int(session.display.pixelHeight)
        let deadline = since + Self.frameWait.timeInterval
        var checked = since
        while ProcessInfo.processInfo.systemUptime < deadline, stream === video {
            if let frame = video.copyLatestFrame(), frame.uptime > checked {
                checked = frame.uptime
                switch frames.nativeImage(frame.pixels, width: width, height: height) {
                case .success(let image): return image
                case .failure(let rejection):
                    Diagnostics.record("screenshot.video.rejected", ["device": Diagnostics.deviceID(session.device.udid),
                        "reason": "\(rejection.reason)", "frame": "\(CVPixelBufferGetWidth(frame.pixels))x\(CVPixelBufferGetHeight(frame.pixels))"])
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
}
