import CoreGraphics
import Foundation
import ImageIO

/// How a shared control maps onto Simulator's Indigo HID messages. Pure, so tests can check it.
enum SimulatorInput {
    static func requiresModernHID(version: String?) -> Bool {
        version.map { $0.compare("1155.4", options: .numeric) != .orderedAscending } ?? false
    }
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
/// Apple device services or ADB. Coordinates follow the displayed screen orientation.
actor SimulatorDeviceConnection: DeviceConnection {
    nonisolated let touchPolicy = TouchQueuePolicy(coalescesMoves: true, suppressesFailedGestures: false,
                                                   dropsPendingOnClose: true)
    nonisolated let display: SimulatorDisplay
    nonisolated let canRotate: Bool
    private let bridge: CoreSimulatorBridge
    private let identifier: String
    private var hid: AnyObject?
    private var modernInput: SimulatorHIDChannel?
    private var vendorInput: SimulatorHIDChannel?
    private var isChangingGeometry = false
    private var heldPoint: CGPoint?
    private var lastMove = ContinuousClock.now

    static func open(_ device: DeviceSummary) async throws -> (SimulatorDeviceConnection, DisplayInfo) {
        let bridge = try CoreSimulatorBridge.shared()
        let simulator = try bridge.bootedDevice(device.deviceIdentifier)
        let modernInput = try await bridge.modernInput(for: simulator)
        let hid = try modernInput == nil ? bridge.hidClient(for: simulator) : nil
        let display = SimulatorDisplay(panels: try bridge.mainDisplays(of: simulator))
        let orientation = try? await DeviceCtl.run(["device", "orientation", "get", "--device", device.deviceIdentifier])
        let parsedOrientation = orientation.flatMap(SimulatorOrientation.parse)
        if let parsedOrientation { display.setOrientation(parsedOrientation) }
        let size = try display.pixelSize()
        let info = DisplayInfo(pixelWidth: Double(size.width), pixelHeight: Double(size.height),
                               pointScale: bridge.pointScale(of: simulator))
        let connection = SimulatorDeviceConnection(bridge: bridge, identifier: device.deviceIdentifier,
                                                   hid: hid, modernInput: modernInput, display: display,
                                                   canRotate: parsedOrientation != nil)
        return (connection, info)
    }

    private init(bridge: CoreSimulatorBridge, identifier: String, hid: AnyObject?, modernInput: SimulatorHIDChannel?, display: SimulatorDisplay, canRotate: Bool) {
        self.bridge = bridge
        self.identifier = identifier
        self.hid = hid
        self.modernInput = modernInput
        self.display = display
        self.canRotate = canRotate
    }

    nonisolated var canFold: Bool { display.isFoldable }

    func rotate(_ direction: DeviceRotationDirection) async throws {
        guard canRotate else { throw DeviceHubError.capabilityUnavailable("rotation on this simulator") }
        guard !isChangingGeometry else { throw DeviceHubError.deviceNotReady("The simulator is moving") }
        isChangingGeometry = true
        defer { isChangingGeometry = false }
        if let held = heldPoint {
            heldPoint = nil
            try await sendTouchMessage(.ended, at: held)
        }
        let orientation: SimulatorOrientation
        if canFold {
            orientation = display.orientation.rotated(direction)
            if vendorInput == nil {
                vendorInput = try await SimulatorHIDChannel.open(bridge.bootedDevice(identifier),
                                                                service: SimulatorHIDChannel.vendorService)
            }
            try await vendorInput?.setOrientation(orientation)
        } else {
            let result = try await DeviceCtl.run(["device", "orientation", "rotate", "--device", identifier, direction.rawValue])
            guard let parsed = SimulatorOrientation.parse(result) else {
                throw DeviceHubError.serviceFailed("The simulator did not report its new orientation")
            }
            orientation = parsed
        }
        display.setOrientation(orientation)
        // Let the guest finish relayout before accepting the next gesture.
        try await Task.sleep(for: .milliseconds(500))
    }

    func setPosture(_ posture: SimulatorPosture) async throws {
        guard canFold else { throw DeviceHubError.capabilityUnavailable("folding on this simulator") }
        guard !isChangingGeometry else { throw DeviceHubError.deviceNotReady("The simulator is moving") }
        isChangingGeometry = true
        defer { isChangingGeometry = false }
        if let held = heldPoint {
            heldPoint = nil
            try await sendTouchMessage(.ended, at: held)
        }
        if vendorInput == nil {
            vendorInput = try await SimulatorHIDChannel.open(bridge.bootedDevice(identifier),
                                                            service: SimulatorHIDChannel.vendorService)
        }
        try await vendorInput?.setPosture(posture)
        // SpringBoard suppresses interaction until the hinge settles and moves the scene to its panel.
        try await Task.sleep(for: .milliseconds(1200))
        display.select(posture)
    }

    // MARK: Touch

    func sendTouch(_ phase: TouchPhase, x: Double, y: Double) async throws {
        guard !isChangingGeometry else { throw DeviceHubError.deviceNotReady("The simulator is moving") }
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
        var point = display.framebufferOrientation.nativePoint(point)
        if let modernInput {
            try await modernInput.touch(phase, x: point.x, y: point.y, target: display.digitizerTarget)
            if phase == .ended { try await modernInput.drain() }
            return
        }
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
        if let modernInput {
            guard let usage = button.usage else { throw DeviceHubError.capabilityUnavailable("\(button.rawValue) on iOS") }
            try await modernInput.button(page: usage.page, code: usage.code, down: true)
            do { try await Task.sleep(for: duration ?? SimulatorInput.defaultHold(button)) }
            catch { try? await modernInput.button(page: usage.page, code: usage.code, down: false); throw error }
            try await modernInput.button(page: usage.page, code: usage.code, down: false)
            try await modernInput.drain()
            return
        }
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

    func uiTree() async throws -> UITree { try await bridge.accessibility(identifier) }

    func activate(_ selector: UISelector) async throws {
        _ = try await bridge.accessibility(identifier, target: selector)
    }

    func typeText(_ text: String, target: UISelector?) async throws {
        let keys = try SimulatorKeyboard.keys(for: text)
        guard !keys.isEmpty else { return }
        guard modernInput != nil || bridge.keyboardMessage != nil else { throw DeviceHubError.capabilityUnavailable("Simulator keyboard input in this Xcode") }
        if let target {
            _ = try await bridge.accessibility(identifier, target: target, focus: true)
            try await Task.sleep(for: .milliseconds(150))
        }
        func key(_ code: UInt32, down: Bool) async throws {
            if let modernInput { try await modernInput.key(code, down: down); return }
            guard let message = bridge.keyboardMessage?(code, down ? 1 : 2) else { throw DeviceHubError.serviceFailed("SimulatorKit could not create a keyboard event") }
            try await send(message)
        }
        for keyStroke in keys {
            do {
                try Task.checkCancellation()
                if keyStroke.shift { try await key(225, down: true) }
                try await key(keyStroke.code, down: true)
                try await key(keyStroke.code, down: false)
                if keyStroke.shift { try await key(225, down: false) }
            } catch {
                // Release modifiers on partial failures, and never replay partially typed text.
                try? await key(keyStroke.code, down: false)
                if keyStroke.shift { try? await key(225, down: false) }
                throw DeviceHubError.serviceFailed("Text input may have been partially delivered. Inspect describe_ui before retrying. \(error)")
            }
        }
        try await modernInput?.drain()
    }

    func screenshot() async throws -> CGImage {
        if let image = display.liveImage() { return image }
        // Pixels from before this session's registration may be stale; ask simctl for a fresh capture.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("phoneusekit-simulator-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try await SimulatorTools.simctl(["io", identifier, "screenshot", "--type=png", "--display", display.identifier, file.path],
                                        developerDirectory: bridge.developerDirectory)
        // Decode now: an image source reads lazily, and the file is removed on return.
        guard let data = try? Data(contentsOf: file),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw DeviceHubError.serviceFailed("simctl returned an unreadable screenshot")
        }
        return try display.framebufferOrientation.image(image)
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
        vendorInput?.close()
        vendorInput = nil
        hid = nil
        modernInput?.close()
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
