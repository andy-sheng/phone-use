import CoreGraphics
import Foundation

public enum SimulatorGeometryChange: Sendable {
    case rotation(DeviceRotationDirection), posture(SimulatorPosture)
}

/// A shared device facade backed by exactly one platform-specific control adapter.
///
/// Coordinates are normalized to the opened framebuffer (native portrait on physical iOS,
/// current displayed orientation on Simulator): (0, 0) is the
/// top-left corner and (1, 1) the bottom-right corner.
public final class DeviceSession: @unchecked Sendable {
    public let device: DeviceSummary
    private let initialDisplay: DisplayInfo
    public var display: DisplayInfo {
        if let android = connection as? AndroidDeviceConnection { return android.display }
        guard let framebuffer = simulatorDisplay, let size = try? framebuffer.pixelSize() else { return initialDisplay }
        return DisplayInfo(pixelWidth: Double(size.width), pixelHeight: Double(size.height),
                           pointScale: initialDisplay.pointScale)
    }

    public var canFold: Bool { (connection as? SimulatorDeviceConnection)?.canFold == true }
    /// Physical iOS streams and input use native coordinates. The UI applies this rotation to both.
    public var previewOrientation: DeviceOrientation {
        (connection as? IOSDeviceConnection)?.previewOrientation ?? .portrait
    }

    /// The bezel follows the selected panel, including a foldable simulator's mounting angle.
    public var frameOrientation: DeviceOrientation? {
        simulatorDisplay?.framebufferOrientation ?? (connection as? IOSDeviceConnection)?.previewOrientation
            ?? (connection as? AndroidDeviceConnection)?.display.androidFrameOrientation
    }

    /// Probe only when opening the interactive preview. Other consumers use native coordinates.
    public func preparePreviewRotation() async {
        await (connection as? IOSDeviceConnection)?.readOrientation(deviceID: device.deviceIdentifier)
    }

    public var canRotate: Bool {
        (connection as? SimulatorDeviceConnection)?.canRotate == true ||
            (connection as? IOSDeviceConnection)?.previewOrientation != nil ||
            (connection as? AndroidDeviceConnection)?.display.geometryID != nil
    }

    public func unlockCredentialID() async throws -> String {
        guard let android = connection as? AndroidDeviceConnection else { return device.id }
        return device.unlockCredentialID(androidUser: try await android.unlockIdentity())
    }

    func unlockAndroid(takePIN: @Sendable (String) async throws -> String?) async throws -> DeviceUnlockResult {
        guard let android = connection as? AndroidDeviceConnection else {
            throw DeviceHubError.capabilityUnavailable("Android keyguard")
        }
        return try await android.unlock { identity in try await takePIN(self.device.unlockCredentialID(androidUser: identity)) }
    }

    func tapPasscodeKey(_ point: CGPoint) async throws {
        if let ios = connection as? IOSDeviceConnection {
            try await ios.tapPasscodeKey(point)
        } else {
            try await connection.tap(x: point.x, y: point.y)
        }
    }

    func physicalScreenLock() async throws -> Bool? {
        guard let ios = connection as? IOSDeviceConnection,
              let version = device.productVersion,
              version.compare("27.2", options: .numeric) != .orderedAscending else { return nil }
        return try await ios.screenLocked()
    }

    public func rotate(_ direction: DeviceRotationDirection) async throws {
        if let android = connection as? AndroidDeviceConnection {
            try await android.rotate(direction)
            return
        }
        if let physical = connection as? IOSDeviceConnection, canRotate {
            try await physical.rotate(direction, deviceID: device.deviceIdentifier)
            return
        }
        guard let simulator = connection as? SimulatorDeviceConnection else {
            throw DeviceHubError.capabilityUnavailable("screen rotation on this connection")
        }
        try await simulator.rotate(direction)
    }

    public func restorePreviewRotation() async throws {
        try await (connection as? AndroidDeviceConnection)?.restoreRotation()
    }

    public func setPosture(_ posture: SimulatorPosture) async throws {
        guard let simulator = connection as? SimulatorDeviceConnection else {
            throw DeviceHubError.capabilityUnavailable("simulator folding on this connection")
        }
        try await simulator.setPosture(posture)
    }
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
        try await Diagnostics.operation("device.open", ["device": Diagnostics.deviceID(initialDevice.udid),
            "platform": initialDevice.platform.rawValue, "connection": initialDevice.connection,
            "os": initialDevice.productVersion ?? "unknown"]) {
            try await openConnection(initialDevice, daemon: daemon)
        }
    }

    private static func openConnection(_ initialDevice: DeviceSummary, daemon: DaemonClient) async throws -> DeviceSession {
        if initialDevice.isSimulator {
            // The daemon only lists simulators; control and display stay in this process.
            let (connection, display) = try await SimulatorDeviceConnection.open(initialDevice)
            return DeviceSession(device: initialDevice, display: display, services: [],
                                 daemon: daemon, connection: connection)
        }
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
        self.initialDisplay = display
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
                Diagnostics.record("touch.failed", ["error": message])
                touchErrors.report(message)
            }
            for await _ in touches.notifications {
                while !Task.isCancelled, let event = touches.next() {
                    switch event {
                    case .touch(let touch):
                        await delivery.deliver(touch)
                    case .keyboard(let keys):
                        do { try await connection.sendKeystrokes(keys) }
                        catch {
                            touches.discardKeystrokes()
                            touchErrors.report(String(describing: error))
                        }
                    }
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

    /// Keyboard and touch share a queue so a click that focuses a field precedes typing.
    public func enqueueKeystroke(_ key: DeviceKeystroke) {
        touches.enqueue(key)
    }

    public func discardPendingKeystrokes() {
        touches.discardKeystrokes()
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
        try await Diagnostics.operation("screenshot", ["device": Diagnostics.deviceID(device.udid), "connection": device.connection]) {
            try await connection.screenshot()
        }
    }

    /// A physical iOS screenshot whose reply wait is bounded and not retried after a timeout.
    /// Other platforms take their usual screenshot.
    func screenshot(replyTimeout: Duration) async throws -> CGImage {
        guard let ios = connection as? IOSDeviceConnection else { return try await screenshot() }
        return try await Diagnostics.operation("screenshot", ["device": Diagnostics.deviceID(device.udid),
            "connection": device.connection, "reply_timeout_ms": String(Int(replyTimeout.timeInterval * 1000))]) {
            try await ios.screenshot(replyTimeout: replyTimeout)
        }
    }

    public func launchApp(bundleID: String) async throws {
        try await connection.launchApp(bundleID: bundleID)
    }

    public func uiTree() async throws -> UITree { try await connection.uiTree() }
    public func activate(_ selector: UISelector) async throws { try await connection.activate(selector) }
    public func typeText(_ text: String, target: UISelector? = nil) async throws {
        try await connection.typeText(text, target: target)
    }

    /// The simulator's framebuffer, shared by its preview stream and screenshots.
    var simulatorDisplay: SimulatorDisplay? {
        (connection as? SimulatorDeviceConnection)?.display
    }

    /// Mirror stream URL (iOS 27+). On those systems the stream is also what authenticates touches.
    public func mirrorURL() async throws -> URL {
        guard !device.isAndroid else { throw DeviceHubError.capabilityUnavailable("Apple screen mirroring on Android") }
        guard !device.isSimulator else { throw DeviceHubError.capabilityUnavailable("Apple screen mirroring on a simulator") }
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
        Diagnostics.record("device.close", ["device": Diagnostics.deviceID(device.udid)])
        touches.discardKeystrokes()
        if connection.touchPolicy.dropsPendingOnClose {
            touches.finish()
            touchTask.cancel()
        }
        await connection.close()
    }
}
