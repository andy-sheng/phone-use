import Foundation
import CoreGraphics
import CoreVideo
import QuartzCore

public enum ScreenStreamKind: String, Sendable {
    case mirror = "Mirror"
    case usb = "USB video"
    case scrcpy = "Android video"
    case simulator = "Simulator display"
    case screenshots = "Screenshots"
}

public enum ScreenStreamRecoveryPolicy: Equatable, Sendable {
    case none
    case retryVideo
}

/// Platform-neutral display surface and lifecycle. Platform providers own transport selection.
@MainActor
public protocol ScreenStream: AnyObject {
    var kind: ScreenStreamKind { get }
    var layer: CALayer { get }
    var recoveryPolicy: ScreenStreamRecoveryPolicy { get }
    var statusMessage: String? { get }
    var onFrame: ((Double) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var canRecord: Bool { get }
    func startRecording(to destination: URL) throws -> any ScreenRecordingSession
    func start() async throws
    func stop()
    /// Copies the latest video frame without issuing a device screenshot request.
    /// Returns nil until a frame is available. Callers should limit their sampling rate.
    func copyFrame() -> CGImage?
    /// Retains the latest decoded pixels, avoiding a CPU image copy for video encoders.
    /// Never modify the returned buffer. Streams without pixel-buffer output return nil.
    func copyPixelBuffer() -> CVPixelBuffer?
}

public extension ScreenStream {
    func copyFrame() -> CGImage? { nil }
    func copyPixelBuffer() -> CVPixelBuffer? { nil }
    var recoveryPolicy: ScreenStreamRecoveryPolicy { .none }
    var statusMessage: String? { nil }
    var canRecord: Bool { false }
    func startRecording(to destination: URL) throws -> any ScreenRecordingSession {
        throw DeviceHubError.capabilityUnavailable("Recording this screen stream")
    }
}

@MainActor
public func prepareScreenSession(for device: DeviceSummary) async {
    if device.isAndroid {
        await AndroidScreenStreamProvider.prepare(device)
    } else if device.isSimulator {
        // No USB capture to settle; an existing in-process session can be reused.
    } else {
        await IOSScreenStreamProvider.prepare(device)
    }
}

@MainActor
public func makeScreenStream(for session: DeviceSession) async -> any ScreenStream {
    if session.device.isAndroid { return await AndroidScreenStreamProvider.makeStream(session) }
    if session.device.isSimulator { return await SimulatorScreenStreamProvider.makeStream(session) }
    return await IOSScreenStreamProvider.makeStream(session)
}

@MainActor
public func makeVideoScreenStream(for session: DeviceSession, captureFrames: Bool = false) async -> (any ScreenStream)? {
    if session.device.isAndroid { return await AndroidScreenStreamProvider.makeVideo(session, captureFrames: captureFrames) }
    if session.device.isSimulator { return await SimulatorScreenStreamProvider.makeVideo(session) }
    return await IOSScreenStreamProvider.makeVideo(session, captureFrames: captureFrames)
}
