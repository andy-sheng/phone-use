import CoreGraphics
import Foundation

/// A shared device facade backed by exactly one platform-specific control adapter.
///
/// Coordinates are normalized to the opened framebuffer (native portrait on iOS): (0, 0) is the
/// top-left corner and (1, 1) the bottom-right corner.
public final class DeviceSession: @unchecked Sendable {
    public let device: DeviceSummary
    public let display: DisplayInfo
    public let services: Set<String>

    private let daemon: DaemonClient
    private let connection: any DeviceConnection
    private let touches: TouchEventQueue
    private let touchErrors: TouchErrorHandlerBox
    private let touchTask: Task<Void, Never>

    /// Interactive queued touch failures. Called off the main actor; UI owners should hop to it.
    /// Automation's awaited `sendTouch` continues to propagate its errors directly.
    public var onTouchError: (@Sendable (String) -> Void)? {
        get { touchErrors.handler }
        set { touchErrors.handler = newValue }
    }

    static func open(_ initialDevice: DeviceSummary, daemon: DaemonClient) async throws -> DeviceSession {
        let opened = try await daemon.openDevice(initialDevice.udid)
        let device = initialDevice.withProductVersion(opened.productVersion)
        let connection: any DeviceConnection
        let display: DisplayInfo
        switch device.platform {
        case .android:
            guard let reportedDisplay = opened.display else {
                throw DeviceHubError.serviceFailed("Android did not report a display size")
            }
            display = reportedDisplay
            connection = try AndroidDeviceConnection(display: display) { action, params in
                try await daemon.androidCommand(device.udid, action: action, params: params)
            }
        case .ios:
            (connection, display) = try await IOSDeviceConnection.open(device, daemon: daemon)
        }
        return DeviceSession(device: device, display: display, services: Set(opened.services),
                             daemon: daemon, connection: connection)
    }

    private init(device: DeviceSummary, display: DisplayInfo, services: Set<String>,
                 daemon: DaemonClient, connection: any DeviceConnection) {
        self.device = device
        self.display = display
        self.services = services
        self.daemon = daemon
        self.connection = connection
        let policy = connection.touchPolicy
        let touches = TouchEventQueue(coalesceMoves: policy.coalescesMoves)
        self.touches = touches
        let touchErrors = TouchErrorHandlerBox()
        self.touchErrors = touchErrors
        touchTask = Task {
            var delivery = QueuedTouchDelivery(suppressFailedGestures: policy.suppressesFailedGestures) { event in
                try await connection.sendTouch(event.phase, x: event.x, y: event.y)
            } reportError: { message in
                FileHandle.standardError.write(Data("touch failed: \(message)\n".utf8))
                touchErrors.report(message)
            }
            for await _ in touches.notifications {
                while !Task.isCancelled, let event = touches.next() {
                    await delivery.deliver(event)
                }
            }
        }
    }

    deinit {
        touches.finish()
        touchTask.cancel()
    }

    // MARK: Touch

    /// Queues one touch event. Events are delivered in order.
    public func touch(_ phase: TouchPhase, x: Double, y: Double) {
        touches.enqueue(phase, x: x, y: y)
    }

    /// Sends a touch and waits for delivery. Automation callers need failures to propagate,
    /// rather than enqueueing events through the interactive preview's fire-and-forget API.
    public func sendTouch(_ phase: TouchPhase, x: Double, y: Double) async throws {
        try await connection.sendTouch(phase, x: x, y: y)
    }

    public func tap(x: Double, y: Double) async throws {
        try await connection.tap(x: x, y: y)
    }

    public func longPress(x: Double, y: Double, duration: Duration = .milliseconds(800)) async throws {
        try await connection.longPress(x: x, y: y, duration: duration)
    }

    public func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double,
                      duration: Duration = .milliseconds(300)) async throws {
        try await connection.swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY, duration: duration)
    }

    public func press(_ button: HardwareButton, duration: Duration? = nil) async throws {
        try await connection.press(button, duration: duration)
    }

    public func screenshot() async throws -> CGImage {
        try await connection.screenshot()
    }

    public func launchApp(bundleID: String) async throws {
        try await connection.launchApp(bundleID: bundleID)
    }

    /// Mirror stream URL (iOS 27+). On those systems the stream is also what authenticates touches.
    public func mirrorURL() async throws -> URL {
        guard !device.isAndroid else { throw DeviceHubError.capabilityUnavailable("Apple screen mirroring on Android") }
        return try await daemon.startMirror(device.udid)
    }

    /// Android preview has its own lifetime; stopping it never releases automation input.
    public func startAndroidVideo() async throws -> AndroidVideoEndpoint {
        guard device.isAndroid else { throw DeviceHubError.capabilityUnavailable("Android video on iOS") }
        return try await daemon.startAndroidVideo(device.udid)
    }

    public func stopAndroidVideo(token: String) async {
        guard device.isAndroid else { return }
        try? await daemon.stopAndroidVideo(device.udid, token: token)
    }

    public func close() async {
        if connection.touchPolicy.dropsPendingOnClose {
            touches.finish()
            touchTask.cancel()
        }
        await connection.close()
    }
}
