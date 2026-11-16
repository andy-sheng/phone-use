import CoreGraphics
import Foundation
import ImageIO

/// How a shared control maps onto Simulator's Indigo HID messages. Pure, so tests can check it.
enum SimulatorInput {
    enum Button: Equatable {
        /// `IndigoHIDMessageForButton` event source, as Simulator.app sends for Home and the side button.
        case source(UInt32)
        /// Any other consumer-page usage, sent through `IndigoHIDMessageForHIDArbitrary`.
        case usage(page: UInt32, code: UInt32)
    }

    /// The Indigo target of the built-in touchscreen and of hardware buttons.
    static let touchTarget: UInt32 = 0x32
    static let buttonTarget: UInt32 = 0x33
    static let down: UInt32 = 1
    static let up: UInt32 = 2

    /// AppKit mouse event types that SimulatorKit converts into a single-finger touch.
    static func eventType(for phase: TouchPhase) -> UInt {
        switch phase {
        case .began: 1 // NSEvent.EventType.leftMouseDown
        case .moved: 6 // leftMouseDragged
        case .ended: 2 // leftMouseUp
        }
    }

    static func button(_ button: HardwareButton) -> Button? {
        switch button {
        case .home: .source(0)
        case .lock: .source(1)
        case .back, .appSwitch: nil
        case .volumeUp, .volumeDown, .siri:
            button.usage.map { .usage(page: UInt32($0.page), code: UInt32($0.code)) }
        }
    }

    /// A long side-button hold is a different gesture on the simulator; a short press locks.
    static func defaultHold(_ button: HardwareButton) -> Duration {
        button == .siri ? .seconds(1) : .milliseconds(100)
    }

    static func coordinate(_ value: Double) throws -> Double {
        guard value.isFinite, (0...1).contains(value) else {
            throw DeviceHubError.serviceFailed("Touch is outside the device screen")
        }
        return value
    }
}

/// Simulator control runs in this process through CoreSimulator; it never uses a daemon worker,
/// Apple device services or ADB. Coordinates are normalized to the portrait framebuffer.
actor SimulatorDeviceConnection: DeviceConnection {
    nonisolated let touchPolicy = TouchQueuePolicy(coalescesMoves: true, suppressesFailedGestures: false,
                                                   dropsPendingOnClose: true)
    nonisolated let display: SimulatorDisplay
    private let bridge: CoreSimulatorBridge
    private let identifier: String
    private var hid: AnyObject?
    private var heldPoint: CGPoint?
    private var lastMove = ContinuousClock.now

    static func open(_ device: DeviceSummary) async throws -> (SimulatorDeviceConnection, DisplayInfo) {
        let bridge = try CoreSimulatorBridge.shared()
        let simulator = try bridge.bootedDevice(device.deviceIdentifier)
        let hid = try bridge.hidClient(for: simulator)
        let display = SimulatorDisplay(descriptor: try bridge.mainDisplay(of: simulator))
        let size = try display.pixelSize()
        let info = DisplayInfo(pixelWidth: Double(size.width), pixelHeight: Double(size.height),
                               pointScale: bridge.pointScale(of: simulator))
        let connection = SimulatorDeviceConnection(bridge: bridge, identifier: device.deviceIdentifier,
                                                   hid: hid, display: display)
        return (connection, info)
    }

    private init(bridge: CoreSimulatorBridge, identifier: String, hid: AnyObject, display: SimulatorDisplay) {
        self.bridge = bridge
        self.identifier = identifier
        self.hid = hid
        self.display = display
    }

    // MARK: Touch

    func sendTouch(_ phase: TouchPhase, x: Double, y: Double) async throws {
        let point = CGPoint(x: try SimulatorInput.coordinate(x), y: try SimulatorInput.coordinate(y))
        if phase == .moved {
            guard heldPoint != nil else { return }
            // SimulatorKit drops drags less than a frame apart; wait instead of losing the position.
            let elapsed = ContinuousClock.now - lastMove
            if elapsed < .milliseconds(17) { try await Task.sleep(for: .milliseconds(17) - elapsed) }
            lastMove = .now
        }
        if phase == .began, let held = heldPoint {
            // A new gesture starts from a lifted finger, as on the device.
            try await sendTouchMessage(.ended, at: held)
        }
        try await sendTouchMessage(phase, at: point)
        heldPoint = phase == .ended ? nil : point
    }

    func tap(x: Double, y: Double) async throws {
        try await sendTouch(.began, x: x, y: y)
        try await Task.sleep(for: .milliseconds(50))
        try await sendTouch(.ended, x: x, y: y)
    }

    func longPress(x: Double, y: Double, duration: Duration) async throws {
        try await sendTouch(.began, x: x, y: y)
        try await Task.sleep(for: duration)
        try await sendTouch(.ended, x: x, y: y)
    }

    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Duration) async throws {
        _ = try SimulatorInput.coordinate(toX)
        _ = try SimulatorInput.coordinate(toY)
        let steps = max(Int(duration.timeInterval * 60), 2)
        try await sendTouch(.began, x: fromX, y: fromY)
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            try await sendTouch(.moved, x: fromX + (toX - fromX) * t, y: fromY + (toY - fromY) * t)
        }
        try await sendTouch(.ended, x: toX, y: toY)
    }

    private func sendTouchMessage(_ phase: TouchPhase, at point: CGPoint) async throws {
        var point = point
        // With a unit size, SimulatorKit's ratio is the normalized coordinate itself.
        guard let message = bridge.mouseMessage(&point, nil, SimulatorInput.touchTarget,
                                                SimulatorInput.eventType(for: phase),
                                                CGSize(width: 1, height: 1), 0) else {
            if phase == .moved { return }
            throw DeviceHubError.serviceFailed("SimulatorKit could not create a touch event")
        }
        try await send(message)
    }

    // MARK: Buttons

    func press(_ button: HardwareButton, duration: Duration?) async throws {
        guard let route = SimulatorInput.button(button) else {
            throw DeviceHubError.capabilityUnavailable("\(button.rawValue) on iOS")
        }
        try await sendButton(route, direction: SimulatorInput.down)
        do {
            try await Task.sleep(for: duration ?? SimulatorInput.defaultHold(button))
        } catch {
            try? await sendButton(route, direction: SimulatorInput.up)
            throw error
        }
        try await sendButton(route, direction: SimulatorInput.up)
    }

    private func sendButton(_ route: SimulatorInput.Button, direction: UInt32) async throws {
        let message = switch route {
        case .source(let source):
            bridge.buttonMessage(source, direction, SimulatorInput.buttonTarget)
        case .usage(let page, let code):
            bridge.arbitraryMessage(SimulatorInput.buttonTarget, page, code, direction)
        }
        guard let message else { throw DeviceHubError.serviceFailed("SimulatorKit could not create a button event") }
        try await send(message)
    }

    // MARK: Screen and apps

    func screenshot() async throws -> CGImage {
        if let image = display.liveImage() { return image }
        // Pixels from before this session's registration may be stale; ask simctl for a fresh capture.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("phoneusekit-simulator-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try await SimulatorTools.simctl(["io", identifier, "screenshot", "--type=png", file.path],
                                        developerDirectory: bridge.developerDirectory)
        // Decode now: an image source reads lazily, and the file is removed on return.
        guard let data = try? Data(contentsOf: file),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw DeviceHubError.serviceFailed("simctl returned an unreadable screenshot")
        }
        return image
    }

    func launchApp(bundleID: String) async throws {
        guard !bundleID.isEmpty, !bundleID.hasPrefix("-") else {
            throw DeviceHubError.serviceFailed("Missing bundle identifier")
        }
        try await SimulatorTools.simctl(["launch", "--terminate-running-process", identifier, bundleID],
                                        developerDirectory: bridge.developerDirectory)
    }

    func close() async {
        if let held = heldPoint {
            heldPoint = nil
            try? await sendTouchMessage(.ended, at: held)
        }
        hid = nil
        display.close()
    }

    private func send(_ message: UnsafeMutableRawPointer) async throws {
        guard let hid else {
            free(message)
            throw DeviceHubError.connectionClosed
        }
        try await bridge.send(message, through: hid)
    }
}
