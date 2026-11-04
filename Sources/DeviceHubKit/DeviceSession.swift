import CoreGraphics
import Foundation

/// An open device plus lazily connected service channels to it.
///
/// Coordinates are normalized to the device's native portrait framebuffer: (0, 0) is the
/// top-left corner and (1, 1) the bottom-right corner.
public final class DeviceSession: @unchecked Sendable {
    public let device: DeviceSummary
    public let display: DisplayInfo
    public let services: Set<String>

    private let daemon: DaemonClient
    private let channels: ServiceChannels
    private let touches: AsyncStream<(TouchPhase, Double, Double)>.Continuation
    private let touchTask: Task<Void, Never>

    static func open(_ device: DeviceSummary, daemon: DaemonClient) async throws -> DeviceSession {
        let opened = try await daemon.openDevice(device.udid)
        let channels = ServiceChannels(udid: device.udid, daemon: daemon, needsTouchAuth: device.osMajorVersion >= 27)
        let reply = try await channels.request(DeviceService.deviceInfo, DisplayQuery.request())
        let display = try DisplayQuery.primaryDisplay(from: reply)
        return DeviceSession(device: device, display: display, services: Set(opened.services),
                             daemon: daemon, channels: channels)
    }

    private init(device: DeviceSummary, display: DisplayInfo, services: Set<String>,
                 daemon: DaemonClient, channels: ServiceChannels) {
        self.device = device
        self.display = display
        self.services = services
        self.daemon = daemon
        self.channels = channels
        let (stream, continuation) = AsyncStream<(TouchPhase, Double, Double)>.makeStream()
        touches = continuation
        touchTask = Task {
            for await (phase, x, y) in stream {
                do {
                    try await channels.sendTouch(phase, x: x, y: y)
                } catch {
                    FileHandle.standardError.write(Data("touch failed: \(error)\n".utf8))
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
        touches.yield((phase, x, y))
    }

    public func tap(x: Double, y: Double) async throws {
        try await channels.sendTouch(.began, x: x, y: y)
        try await Task.sleep(for: .milliseconds(50))
        try await channels.sendTouch(.ended, x: x, y: y)
    }

    public func longPress(x: Double, y: Double, duration: Duration = .milliseconds(800)) async throws {
        try await channels.sendTouch(.began, x: x, y: y)
        try await Task.sleep(for: duration)
        try await channels.sendTouch(.ended, x: x, y: y)
    }

    public func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double,
                      duration: Duration = .milliseconds(300)) async throws {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let steps = max(Int(seconds * 60), 2)
        let interval = duration / steps
        try await channels.sendTouch(.began, x: fromX, y: fromY)
        for step in 1...steps {
            try await Task.sleep(for: interval)
            let t = Double(step) / Double(steps)
            try await channels.sendTouch(.moved, x: fromX + (toX - fromX) * t, y: fromY + (toY - fromY) * t)
        }
        try await channels.sendTouch(.ended, x: toX, y: toY)
    }

    // MARK: Buttons

    public func press(_ button: HardwareButton, duration: Duration? = nil) async throws {
        let usage = button.usage
        try await channels.send(DeviceService.indigoHID, HIDReports.buttonMessage(page: usage.page, code: usage.code, down: true))
        try await Task.sleep(for: duration ?? button.defaultHold)
        try await channels.send(DeviceService.indigoHID, HIDReports.buttonMessage(page: usage.page, code: usage.code, down: false))
    }

    // MARK: Screen and apps

    public func screenshot() async throws -> CGImage {
        try ScreenCapture.image(from: try await channels.request(DeviceService.screenCapture, ScreenCapture.request()))
    }

    public func launchApp(bundleID: String) async throws {
        let reply = try await channels.request(DeviceService.appService, AppLaunch.request(bundleID: bundleID))
        _ = try CoreDeviceInvocation.output(of: reply, feature: AppLaunch.feature)
    }

    /// Mirror stream URL (iOS 27+). On those systems the stream is also what authenticates touches.
    public func mirrorURL() async throws -> URL {
        try await daemon.startMirror(device.udid)
    }

    public func close() async {
        await channels.closeAll()
    }
}

/// One RemoteXPC connection per device service, reopened through the daemon when it drops
/// (for example after the device re-enumerates on USB and its tunnel is rebuilt).
actor ServiceChannels {
    private let udid: String
    private let daemon: DaemonClient
    private var connections: [String: RemoteXPCConnection] = [:]
    private var touchAuthenticated = false
    private let needsTouchAuth: Bool

    init(udid: String, daemon: DaemonClient, needsTouchAuth: Bool = false) {
        self.udid = udid
        self.daemon = daemon
        self.needsTouchAuth = needsTouchAuth
    }

    func send(_ service: String, _ message: XPCDictionary) async throws {
        try await withConnection(service) { try await $0.send(message) }
    }

    func request(_ service: String, _ message: XPCDictionary) async throws -> XPCDictionary {
        try await withConnection(service) { try await $0.request(message) }
    }

    func sendTouch(_ phase: TouchPhase, x: Double, y: Double) async throws {
        if needsTouchAuth && !touchAuthenticated {
            // iOS 27 drops host touches unless a media stream is running; the daemon keeps one.
            _ = try await daemon.startMirror(udid)
            try await Task.sleep(for: .milliseconds(500))
            touchAuthenticated = true
        }
        let state = phase == .ended ? HIDReports.release : HIDReports.contact
        try await send(DeviceService.universalHID, HIDReports.touchMessage(HIDReports.touchscreen(state: state, x: x, y: y)))
    }

    func closeAll() async {
        for connection in connections.values { await connection.close() }
        connections.removeAll()
    }

    private func withConnection<T>(_ service: String, _ body: (RemoteXPCConnection) async throws -> T) async throws -> T {
        do {
            return try await body(try await connection(for: service))
        } catch {
            // A dead channel fails its first use; open a fresh one once before giving up.
            await connections.removeValue(forKey: service)?.close()
            touchAuthenticated = false
            return try await body(try await connection(for: service))
        }
    }

    private func connection(for service: String) async throws -> RemoteXPCConnection {
        if let existing = connections[service], await existing.isOpen {
            return existing
        }
        connections[service] = nil
        let port: UInt16
        do {
            port = try await daemon.openService(udid, service: service)
        } catch {
            // The worker may have exited; reopening the device restarts it.
            _ = try await daemon.openDevice(udid)
            port = try await daemon.openService(udid, service: service)
        }
        let connection = RemoteXPCConnection(port: port)
        try await connection.connect()
        connections[service] = connection
        return connection
    }
}
