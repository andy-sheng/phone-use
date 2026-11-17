import CoreGraphics
import CoreImage
import Foundation
import ImageIO

public enum DeviceRotationDirection: String, Sendable {
    case left, right
}

/// Physical rotation clockwise from the simulator's native portrait framebuffer.
enum SimulatorOrientation: String, CaseIterable, Sendable {
    case portrait, landscapeRight, portraitUpsideDown, landscapeLeft

    var quarterTurns: Int {
        switch self {
        case .portrait: 0
        case .landscapeRight: 1
        case .portraitUpsideDown: 2
        case .landscapeLeft: 3
        }
    }

    var isLandscape: Bool { quarterTurns % 2 == 1 }
    var radians: CGFloat { CGFloat(quarterTurns) * .pi / 2 }

    func rotated(_ direction: DeviceRotationDirection) -> Self {
        Self.allCases[(quarterTurns + (direction == .right ? 1 : 3)) % 4]
    }

    /// DeviceHub's Pop plugin updates the VM motion sensor, rather than only BackBoard's override.
    var command: [String: Any] {
        let value: String = switch self {
        case .portrait: "portrait"
        case .portraitUpsideDown: "pud"
        case .landscapeLeft: "landscape-left"
        case .landscapeRight: "landscape-right"
        }
        return ["provider": "com.apple.Virtualization.VirtualMachines",
                "source": "orientation-picker-control", "type": "enum", "value": value]
    }

    static func parse(_ result: [String: Any]) -> Self? {
        // Face-up/down preserve the last usable screen orientation.
        (result["deviceOrientationNonFlat"] as? String).flatMap(Self.init(rawValue:))
            ?? (result["deviceOrientation"] as? String).flatMap(Self.init(rawValue:))
    }

    /// Convert a displayed top-left normalized point into the native touchscreen coordinates.
    func nativePoint(_ point: CGPoint) -> CGPoint {
        switch self {
        case .portrait: point
        case .landscapeRight: CGPoint(x: point.y, y: 1 - point.x)
        case .portraitUpsideDown: CGPoint(x: 1 - point.x, y: 1 - point.y)
        case .landscapeLeft: CGPoint(x: 1 - point.y, y: point.x)
        }
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    func image(_ image: CGImage) throws -> CGImage {
        guard self != .portrait else { return image }
        let orientation: CGImagePropertyOrientation = switch self {
        case .portrait: .up
        case .landscapeRight: .right
        case .portraitUpsideDown: .down
        case .landscapeLeft: .left
        }
        let rotated = CIImage(cgImage: image).oriented(orientation)
        guard let result = Self.context.createCGImage(rotated, from: rotated.extent) else {
            throw DeviceHubError.serviceFailed("Could not rotate the simulator screenshot")
        }
        return result
    }
}
