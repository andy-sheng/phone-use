import CoreGraphics
import Foundation
import QuartzCore
import XCTest
@testable import PhoneUseKit

final class SimulatorOrientationTests: XCTestCase {
    func testQuarterTurnsCycleInBothDirectionsAndUseDuoSensorCommands() {
        var orientation = SimulatorOrientation.portrait
        for expected in [SimulatorOrientation.landscapeRight, .portraitUpsideDown, .landscapeLeft, .portrait] {
            orientation = orientation.rotated(.right)
            XCTAssertEqual(orientation, expected)
        }
        for expected in [SimulatorOrientation.landscapeLeft, .portraitUpsideDown, .landscapeRight, .portrait] {
            orientation = orientation.rotated(.left)
            XCTAssertEqual(orientation, expected)
        }
        for (orientation, value) in [(SimulatorOrientation.portrait, "portrait"), (.portraitUpsideDown, "pud"),
                                     (.landscapeLeft, "landscape-left"), (.landscapeRight, "landscape-right")] {
            XCTAssertEqual(orientation.command as? [String: String], [
                "provider": "com.apple.Virtualization.VirtualMachines", "source": "orientation-picker-control",
                "type": "enum", "value": value,
            ])
        }
    }

    func testDisplayedTouchMapsBackToNativeFramebuffer() {
        let point = CGPoint(x: 0.2, y: 0.3)
        let expected: [(SimulatorOrientation, CGPoint)] = [
            (.portrait, point), (.landscapeRight, CGPoint(x: 0.3, y: 0.8)),
            (.portraitUpsideDown, CGPoint(x: 0.8, y: 0.7)),
            (.landscapeLeft, CGPoint(x: 0.7, y: 0.2)),
        ]
        for (orientation, native) in expected {
            let mapped = orientation.nativePoint(point)
            XCTAssertEqual(mapped.x, native.x, accuracy: 0.0001)
            XCTAssertEqual(mapped.y, native.y, accuracy: 0.0001)
        }
    }

    func testFaceUpPreservesLastNonFlatOrientationAndUnknownDoesNotDefaultToPortrait() {
        XCTAssertEqual(SimulatorOrientation.parse(["deviceOrientation": "faceUp",
            "deviceOrientationNonFlat": "landscapeLeft"]), .landscapeLeft)
        XCTAssertEqual(SimulatorOrientation.parse(["deviceOrientation": "portrait"]), .portrait)
        XCTAssertNil(SimulatorOrientation.parse(["deviceOrientation": "unknown"]))
        XCTAssertNil(SimulatorOrientation.parse([:]))
    }

    /// The video layer and screenshots must rotate identically, without mirroring or stretching.
    @MainActor
    func testPreviewAndScreenshotKeepTheSameFourCornersAtEveryOrientation() async throws {
        let original = try colorQuadrants()
        for orientation in SimulatorOrientation.allCases {
            let expected = try orientation.image(original)
            XCTAssertEqual(expected.width, orientation.isLandscape ? 96 : 64)
            XCTAssertEqual(expected.height, orientation.isLandscape ? 64 : 96)
            let layer = SimulatorPreviewLayer()
            layer.bounds = CGRect(x: 0, y: 0, width: expected.width, height: expected.height)
            layer.orientation = orientation
            layer.surfaceLayer.contents = original
            layer.layoutIfNeeded()
            let context = try bitmap(width: expected.width, height: expected.height)
            layer.render(in: context)
            let actual = try XCTUnwrap(context.makeImage())
            for (x, y) in [(0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8)] {
                XCTAssertEqual(try pixel(actual, x: x, y: y), try pixel(expected, x: x, y: y),
                               "Preview differs from screenshot at \(orientation): \(x),\(y)")
                let native = orientation.nativePoint(CGPoint(x: x, y: y))
                XCTAssertEqual(try pixel(expected, x: x, y: y), try pixel(original, x: native.x, y: native.y),
                               "Touch differs from screenshot at \(orientation): \(x),\(y)")
            }
        }
    }

    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func colorQuadrants() throws -> CGImage {
        let context = try bitmap(width: 64, height: 96)
        for (rect, color) in [
            (CGRect(x: 0, y: 48, width: 32, height: 48), CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
            (CGRect(x: 32, y: 48, width: 32, height: 48), CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
            (CGRect(x: 0, y: 0, width: 32, height: 48), CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
            (CGRect(x: 32, y: 0, width: 32, height: 48), CGColor(red: 1, green: 1, blue: 0, alpha: 1)),
        ] {
            context.setFillColor(color)
            context.fill(rect)
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func pixel(_ image: CGImage, x: Double, y: Double) throws -> [UInt8] {
        let context = try bitmap(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = Int(y * Double(image.height)) * context.bytesPerRow + Int(x * Double(image.width)) * 4
        return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
    }
}
