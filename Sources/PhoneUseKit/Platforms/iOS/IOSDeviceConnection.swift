import CoreGraphics
import Foundation

/// Apple device services, HID, screenshot and application control live entirely in this adapter.
/// The shared session never constructs or sends an Apple protocol message.
final class IOSDeviceConnection: DeviceConnection, Sendable {
    // Pending events survive close to preserve Apple channel-reopen behavior, including an
    // already queued final release.
    let touchPolicy = TouchQueuePolicy(coalescesMoves: false, suppressesFailedGestures: false,
                                       dropsPendingOnClose: false)
    private let channels: ServiceChannels

    init(channels: ServiceChannels) {
        self.channels = channels
    }

    static func open(_ device: DeviceSummary, daemon: DaemonClient) async throws -> (IOSDeviceConnection, DisplayInfo) {
        let channels = ServiceChannels(udid: device.udid, daemon: daemon, needsTouchAuth: device.osMajorVersion >= 27)
        let reply = try await channels.request(DeviceService.deviceInfo, DisplayQuery.request())
        let display = try DisplayQuery.primaryDisplay(from: reply)
        return (IOSDeviceConnection(channels: channels), display)
    }

    func sendTouch(_ phase: TouchPhase, x: Double, y: Double) async throws {
        try await channels.sendTouch(phase, x: x, y: y)
    }

    func tap(x: Double, y: Double) async throws {
        try await channels.sendTouch(.began, x: x, y: y)
        try await Task.sleep(for: .milliseconds(50))
        try await channels.sendTouch(.ended, x: x, y: y)
    }

    func longPress(x: Double, y: Double, duration: Duration) async throws {
        try await channels.sendTouch(.began, x: x, y: y)
        try await Task.sleep(for: duration)
        try await channels.sendTouch(.ended, x: x, y: y)
    }

    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Duration) async throws {
        let steps = max(Int(duration.timeInterval * 60), 2)
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

    func press(_ button: HardwareButton, duration: Duration?) async throws {
        guard let usage = button.usage else {
            throw DeviceHubError.capabilityUnavailable("\(button.rawValue) on iOS")
        }
        try await channels.send(DeviceService.indigoHID, HIDReports.buttonMessage(page: usage.page, code: usage.code, down: true))
        do { try await Task.sleep(for: duration ?? button.defaultHold) }
        catch {
            try? await channels.send(DeviceService.indigoHID, HIDReports.buttonMessage(page: usage.page, code: usage.code, down: false))
            throw error
        }
        try await channels.send(DeviceService.indigoHID, HIDReports.buttonMessage(page: usage.page, code: usage.code, down: false))
        // The device dispatches HID asynchronously; keep the channel alive through the release.
        try await Task.sleep(for: .milliseconds(100))
    }

    // MARK: Screen and apps

    func screenshot() async throws -> CGImage {
        return try ScreenCapture.image(from: try await channels.request(DeviceService.screenCapture, ScreenCapture.request()))
    }

    func launchApp(bundleID: String) async throws {
        let reply = try await channels.request(DeviceService.appService, AppLaunch.request(bundleID: bundleID))
        _ = try CoreDeviceInvocation.output(of: reply, feature: AppLaunch.feature)
    }

    func uiTree() async throws -> UITree { try await channels.uiTree() }

    func activate(_ selector: UISelector) async throws { try await channels.uiAction(selector: selector) }

    func typeText(_ text: String, target: UISelector?) async throws {
        _ = try SimulatorKeyboard.keys(for: text)
        try await channels.uiAction(selector: target, text: text)
    }

    func close() async {
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
        try await Diagnostics.operation("ios.request", ["service": service, "device": Diagnostics.deviceID(udid), "attempt_timeout_ms": "20000", "max_attempts": "2"]) {
            try await withConnection(service) { try await $0.request(message) }
        }
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

    func uiTree() async throws -> UITree { try await daemon.iosUITree(udid) }

    func uiAction(selector: UISelector?, text: String? = nil) async throws {
        try await daemon.iosUIAction(udid, selector: selector, text: text)
    }

    func closeAll() async {
        for connection in connections.values { await connection.close() }
        connections.removeAll()
    }

    private func withConnection<T>(_ service: String, _ body: (RemoteXPCConnection) async throws -> T) async throws -> T {
        do {
            return try await body(try await connection(for: service))
        } catch {
            Diagnostics.record("ios.channel.retry", ["device": Diagnostics.deviceID(udid), "service": service, "error": String(describing: error)])
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
        try await Diagnostics.operation("ios.channel.connect", ["device": Diagnostics.deviceID(udid), "service": service, "port": String(port)]) {
            try await connection.connect()
        }
        connections[service] = connection
        return connection
    }
}
