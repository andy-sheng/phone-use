import CoreVideo
import XCTest
@testable import PhoneUseKit

final class VideoFrameImageTests: XCTestCase {
    private let gray: (UInt8, UInt8, UInt8) = (128, 128, 128)

    /// BGRA pixels: `content` fills the top-left `contentShare` of each side, gray padding the rest.
    private func frame(width: Int, height: Int, contentShare: Double = 1) throws -> CVPixelBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), noErr)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let contentWidth = Int(Double(width) * contentShare), contentHeight = Int(Double(height) * contentShare)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * rowBytes + x * 4
                if x < contentWidth && y < contentHeight {
                    // Busy content: a colored checkerboard, never mistaken for padding.
                    let on = (x / 4 + y / 4) % 2 == 0
                    p[0] = on ? 200 : 20; p[1] = on ? 40 : 180; p[2] = on ? 10 : 230
                } else {
                    p[0] = gray.2; p[1] = gray.1; p[2] = gray.0
                }
                p[3] = 255
            }
        }
        return buffer
    }

    func testFullFrameIsScaledToNativePixels() throws {
        let result = VideoFrameImage().nativeImage(try frame(width: 316, height: 688), width: 295, height: 640)
        let image = try result.get()
        XCTAssertEqual(image.width, 295)
        XCTAssertEqual(image.height, 640)
    }

    func testCollapsedFrameIsRejected() throws {
        let result = VideoFrameImage().nativeImage(try frame(width: 316, height: 688, contentShare: 0.55),
                                                   width: 295, height: 640)
        guard case .failure(let error) = result else { return XCTFail("collapsed frame accepted") }
        XCTAssertEqual(error.reason, .collapsed)
    }

    func testRotatedFrameIsRejected() throws {
        let result = VideoFrameImage().nativeImage(try frame(width: 688, height: 316), width: 295, height: 640)
        guard case .failure(let error) = result else { return XCTFail("rotated frame accepted") }
        XCTAssertEqual(error.reason, .aspect)
    }

    func testUniformGrayScreenIsNotTreatedAsCollapse() {
        let width = 16, height = 32
        let rgba = [UInt8](repeating: 128, count: width * height * 4)
        XCTAssertFalse(VideoFrameImage.isCollapsed(rgba, width: width, height: height))
    }
}
