import CoreGraphics
import Foundation
import os

/// Apple device services, HID, screenshot and application control live entirely in this adapter.
/// The shared session never constructs or sends an Apple protocol message.
final class IOSDeviceConnection: DeviceConnection, Sendable {
    // Pending events survive close to preserve Apple channel-reopen behavior, including an
    // already queued final release.
    let touchPolicy = TouchQueuePolicy(coalescesMoves: false, suppressesFailedGestures: false,
                                       dropsPendingOnClose: false)
    private let channels: ServiceChannels

    private let orientation = OSAllocatedUnfairLock<DeviceOrientation?>(initialState: nil)
    var previewOrientation: DeviceOrientation? { orientation.withLock { $0 } }

    func readOrientation(deviceID: String) async {
        let value = try? await DeviceOrientation.read(deviceID: deviceID)
        orientation.withLock { $0 = value }
    }

    func rotate(_ direction: DeviceRotationDirection, deviceID: String) async throws {
        let value = try await DeviceOrientation.rotate(direction, deviceID: deviceID)
        orientation.withLock { $0 = value }
    }

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

    func tapPasscodeKey(_ point: CGPoint) async throws {
        // A write failure may occur after the device received the contact. Never replay a digit.
        do {
            try await channels.sendTouch(.began, x: point.x, y: point.y, replayOnDisconnect: false)
            try await Task.sleep(for: .milliseconds(50))
        } catch {
            try? await channels.sendTouch(.ended, x: point.x, y: point.y, replayOnDisconnect: false)
            throw error
        }
        try await channels.sendTouch(.ended, x: point.x, y: point.y, replayOnDisconnect: false)
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

    func screenLocked() async throws -> Bool {
        let name = "com.apple.springboard.lockstate"
        let reply = try await channels.request("com.apple.mobile.notification_proxy.remote",
                                               ["Command": "GetNotificationState", "Name": .string(name)],
                                               timeout: .seconds(3), retriesTimeout: false)
        guard reply["Command"]?.stringValue == "RelayNotificationState", reply["Name"]?.stringValue == name,
              (reply["Status"]?.intValue ?? 0) == 0, let state = reply["State"]?.intValue else {
            throw DeviceHubError.serviceFailed("Cannot read the SpringBoard lock state")
        }
        return state != 0
    }

    func screenshot() async throws -> CGImage {
        return try ScreenCapture.image(from: try await channels.request(DeviceService.screenCapture, ScreenCapture.request()))
    }

    /// One reply wait of at most `replyTimeout`; a timeout is reported rather than retried.
    func screenshot(replyTimeout: Duration) async throws -> CGImage {
        try ScreenCapture.image(from: try await channels.request(
            DeviceService.screenCapture, ScreenCapture.request(), timeout: replyTimeout, retriesTimeout: false))
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

    func sendKeystrokes(_ keys: [DeviceKeystroke]) async throws {
        try await channels.sendKeystrokes(keys)
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

    /// `retriesTimeout: false` still reopens a dead channel once, but returns a reply timeout to the
    /// caller instead of waiting a second full `timeout`.
    func request(_ service: String, _ message: XPCDictionary, timeout: Duration = .seconds(20),
                 retriesTimeout: Bool = true) async throws -> XPCDictionary {
        try await Diagnostics.operation("ios.request", ["service": service, "device": Diagnostics.deviceID(udid),
            "attempt_timeout_ms": String(Int(timeout.timeInterval * 1000)), "max_attempts": "2",
            "retries_timeout": String(retriesTimeout)]) {
            try await withConnection(service, retriesTimeout: retriesTimeout) { try await $0.request(message, timeout: timeout) }
        }
    }

    func sendTouch(_ phase: TouchPhase, x: Double, y: Double, replayOnDisconnect: Bool = true) async throws {
        if needsTouchAuth && !touchAuthenticated {
            // iOS 27 drops host touches unless a media stream is running; the daemon keeps one.
            _ = try await daemon.startMirror(udid)
            try await Task.sleep(for: .milliseconds(500))
            touchAuthenticated = true
        }
        let state = phase == .ended ? HIDReports.release : HIDReports.contact
        let message = HIDReports.touchMessage(HIDReports.touchscreen(state: state, x: x, y: y))
        if replayOnDisconnect {
            try await send(DeviceService.universalHID, message)
        } else {
            try await connection(for: DeviceService.universalHID).send(message)
        }
    }

    func uiTree() async throws -> UITree { try await daemon.iosUITree(udid) }

    func uiAction(selector: UISelector?, text: String? = nil) async throws {
        try await daemon.iosUIAction(udid, selector: selector, text: text)
    }

    func sendKeystrokes(_ keys: [DeviceKeystroke]) async throws {
        try await daemon.iosKeystrokes(udid, keys: keys)
    }

    func closeAll() async {
        for connection in connections.values { await connection.close() }
        connections.removeAll()
    }

    private func withConnection<T>(_ service: String, retriesTimeout: Bool = true,
                                   _ body: (RemoteXPCConnection) async throws -> T) async throws -> T {
        do {
            return try await body(try await connection(for: service))
        } catch {
            // A timed-out request has already failed its channel; the next use reopens it.
            if !retriesTimeout, case DeviceHubError.timeout = error {
                Diagnostics.record("ios.channel.timeout", ["device": Diagnostics.deviceID(udid), "service": service])
                await connections.removeValue(forKey: service)?.close()
                touchAuthenticated = false
                throw error
            }
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
