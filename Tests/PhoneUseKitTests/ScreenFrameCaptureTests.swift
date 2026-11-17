import CoreMedia
import CoreVideo
import XCTest
@testable import PhoneUseKit

final class ScreenFrameCaptureTests: XCTestCase {
    func testFrameCaptureIsOptInAndResetClearsPixels() throws {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 16, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), noErr)
        let buffer = try XCTUnwrap(pixels)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
            sampleBufferOut: &sample), noErr)
        let capture = ScreenFrameCapture()
        capture.append(try XCTUnwrap(sample))
        XCTAssertNil(capture.copyFrame())
        capture.append(try XCTUnwrap(sample))
        let image = try XCTUnwrap(capture.copyFrame())
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 16)
        capture.reset()
        XCTAssertNil(capture.copyFrame())
    }
}
