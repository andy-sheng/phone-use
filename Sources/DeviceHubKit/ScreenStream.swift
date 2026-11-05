import Foundation
import QuartzCore

public enum ScreenStreamKind: String, Sendable {
    case mirror = "Mirror"
    case usb = "USB video"
    case scrcpy = "Android video"
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
    func start() async throws
    func stop()
}

public extension ScreenStream {
    var recoveryPolicy: ScreenStreamRecoveryPolicy { .none }
    var statusMessage: String? { nil }
}

@MainActor
public func prepareScreenSession(for device: DeviceSummary) async {
    if device.isAndroid {
        await AndroidScreenStreamProvider.prepare(device)
    } else {
        await IOSScreenStreamProvider.prepare(device)
    }
}

@MainActor
public func makeScreenStream(for session: DeviceSession) async -> any ScreenStream {
    if session.device.isAndroid { return await AndroidScreenStreamProvider.makeStream(session) }
    return await IOSScreenStreamProvider.makeStream(session)
}

@MainActor
public func makeVideoScreenStream(for session: DeviceSession) async -> (any ScreenStream)? {
    if session.device.isAndroid { return await AndroidScreenStreamProvider.makeVideo(session) }
    return await IOSScreenStreamProvider.makeVideo(session)
}
