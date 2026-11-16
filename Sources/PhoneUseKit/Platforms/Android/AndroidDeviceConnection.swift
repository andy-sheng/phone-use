import CoreGraphics
import Foundation
import ImageIO

/// High-level Android commands share the daemon connection but never use Apple device services.
/// The injectable request function also lets tests exercise failures without a physical device.
///
/// The preview and automation open separate sessions on one daemon worker. Touch requests carry
/// this session's `owner`, so releasing or closing one session never lifts another's held touch.
actor AndroidDeviceConnection: DeviceConnection {
    nonisolated let touchPolicy = TouchQueuePolicy(coalescesMoves: true, suppressesFailedGestures: true,
                                                   dropsPendingOnClose: true)
    typealias Request = @Sendable (String, [String: String]) async throws -> Data

    private struct Screenshot: Decodable {
        let png: String
        let width: Int
        let height: Int
    }

    private let display: DisplayInfo
    private let owner: String
    private let request: Request
    private var displayChanged = false
    private var closed = false

    init(display: DisplayInfo, owner: String = UUID().uuidString, request: @escaping Request) throws {
        guard let width = Int(exactly: display.pixelWidth), let height = Int(exactly: display.pixelHeight),
              width > 0, height > 0, display.pointScale.isFinite, display.pointScale > 0 else {
            throw DeviceHubError.serviceFailed("Android returned an invalid display size")
        }
        self.display = display
        self.owner = owner
        self.request = request
    }

    static func coordinate(_ value: Double) throws -> String {
        guard value.isFinite, (0...1).contains(value) else {
            throw DeviceHubError.serviceFailed("Touch is outside the device screen")
        }
        return String(value)
    }

    static func milliseconds(_ duration: Duration) throws -> String {
        let ms = duration.timeInterval * 1000
        guard ms.isFinite, ms > 0, ms <= 30_000 else {
            throw DeviceHubError.serviceFailed("Gesture duration must be greater than zero and at most 30 seconds")
        }
        return String(Int(ms.rounded(.up)))
    }

    func sendTouch(_ phase: TouchPhase, x: Double, y: Double) async throws {
        if phase == .ended {
            // Release must remain possible after rotation or a failed screenshot.
            try await touchRequest("touch", ["phase": "ended", "x": "0", "y": "0"])
            return
        }
        try requireUsableDisplay()
        try await touchRequest("touch", ["phase": phase == .began ? "began" : "moved",
                                         "x": Self.coordinate(x), "y": Self.coordinate(y)])
    }

    func tap(x: Double, y: Double) async throws {
        try requireUsableDisplay()
        try await touchRequest("tap", ["x": Self.coordinate(x), "y": Self.coordinate(y)])
    }

    func longPress(x: Double, y: Double, duration: Duration) async throws {
        try await swipe(fromX: x, fromY: y, toX: x, toY: y, duration: duration)
    }

    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Duration) async throws {
        try requireUsableDisplay()
        try await touchRequest("swipe", ["fromX": Self.coordinate(fromX), "fromY": Self.coordinate(fromY),
                                         "toX": Self.coordinate(toX), "toY": Self.coordinate(toY),
                                         "durationMs": Self.milliseconds(duration)])
    }

    func press(_ button: HardwareButton, duration: Duration?) async throws {
        guard button != .siri else { throw DeviceHubError.capabilityUnavailable("Siri on Android") }
        try requireOpen()
        var params = ["button": button.rawValue]
        if let duration { params["durationMs"] = try Self.milliseconds(duration) }
        _ = try await request("press", params)
    }

    func screenshot() async throws -> CGImage {
        try requireUsableDisplay()
        let data = try await request("screenshot", [:])
        let screenshot = try JSONDecoder().decode(Screenshot.self, from: data)
        guard let png = Data(base64Encoded: screenshot.png),
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == screenshot.width, image.height == screenshot.height else {
            throw DeviceHubError.serviceFailed("Android returned an invalid screenshot")
        }
        guard Double(image.width) == display.pixelWidth, Double(image.height) == display.pixelHeight else {
            displayChanged = true
            throw orientationError()
        }
        return image
    }

    func launchApp(bundleID: String) async throws {
        try requireOpen()
        guard !bundleID.isEmpty else { throw DeviceHubError.serviceFailed("Missing Android package name") }
        _ = try await request("launch", ["bundleID": bundleID])
    }

    func close() async {
        guard !closed else { return }
        closed = true
        try? await touchRequest("release", [:])
    }

    private func touchRequest(_ action: String, _ params: [String: String]) async throws {
        var params = params
        params["owner"] = owner
        _ = try await request(action, params)
    }

    private func requireOpen() throws {
        if closed { throw DeviceHubError.connectionClosed }
    }

    private func requireUsableDisplay() throws {
        try requireOpen()
        if displayChanged { throw orientationError() }
    }

    private func orientationError() -> DeviceHubError {
        .serviceFailed("Android screen orientation or size changed; reconnect the device session before sending input")
    }
}
