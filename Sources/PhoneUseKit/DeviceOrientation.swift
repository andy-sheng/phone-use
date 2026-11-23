import CoreGraphics
import CoreImage
import Foundation
import ImageIO

public enum DeviceRotationDirection: String, Sendable {
    case left, right
}

/// Clockwise rotation from the native portrait framebuffer.
public enum DeviceOrientation: String, CaseIterable, Sendable {
    case portrait, landscapeRight, portraitUpsideDown, landscapeLeft

    var quarterTurns: Int {
        switch self {
        case .portrait: 0
        case .landscapeRight: 1
        case .portraitUpsideDown: 2
        case .landscapeLeft: 3
        }
    }

    public var isLandscape: Bool { quarterTurns % 2 == 1 }
    public var radians: CGFloat { CGFloat(quarterTurns) * .pi / 2 }

    func rotated(_ direction: DeviceRotationDirection) -> Self {
        Self.allCases[(quarterTurns + (direction == .right ? 1 : 3)) % 4]
    }

    static func parse(_ result: [String: Any]) -> Self? {
        // Face-up/down preserve the last usable screen orientation.
        (result["deviceOrientationNonFlat"] as? String).flatMap(Self.init(rawValue:))
            ?? (result["deviceOrientation"] as? String).flatMap(Self.init(rawValue:))
    }

    /// The preview and its inspector use oriented dimensions, while device input keeps its native coordinates.
    public func display(_ native: DisplayInfo) -> DisplayInfo {
        guard isLandscape else { return native }
        return DisplayInfo(pixelWidth: native.pixelHeight, pixelHeight: native.pixelWidth, pointScale: native.pointScale)
    }

    static func read(deviceID: String) async throws -> Self {
        try await query(["get"], deviceID: deviceID)
    }

    static func rotate(_ direction: DeviceRotationDirection, deviceID: String) async throws -> Self {
        try await query(["rotate", direction.rawValue], deviceID: deviceID)
    }

    private static func query(_ command: [String], deviceID: String) async throws -> Self {
        let result = try await DeviceCtl.run(["device", "orientation"] + command + ["--device", deviceID], timeout: 5)
        guard let orientation = parse(result) else {
            throw DeviceHubError.serviceFailed("The device did not report its screen orientation")
        }
        return orientation
    }

    /// Convert a displayed top-left normalized point into the native touchscreen coordinates.
    public func nativePoint(_ point: CGPoint) -> CGPoint {
        switch self {
        case .portrait: point
        case .landscapeRight: CGPoint(x: point.y, y: 1 - point.x)
        case .portraitUpsideDown: CGPoint(x: 1 - point.x, y: 1 - point.y)
        case .landscapeLeft: CGPoint(x: 1 - point.y, y: point.x)
        }
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    public func image(_ image: CGImage) throws -> CGImage {
        guard self != .portrait else { return image }
        let orientation: CGImagePropertyOrientation = switch self {
        case .portrait: .up
        case .landscapeRight: .right
        case .portraitUpsideDown: .down
        case .landscapeLeft: .left
        }
        let rotated = CIImage(cgImage: image).oriented(orientation)
        guard let result = Self.context.createCGImage(rotated, from: rotated.extent) else {
            throw DeviceHubError.serviceFailed("Could not rotate the screenshot")
        }
        return result
    }
}
