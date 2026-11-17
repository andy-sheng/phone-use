import CoreVideo
import XCTest
@testable import PhoneUseCLI

final class WebVideoTests: XCTestCase {
    func testHandshakeValidatesOriginTokenAndRFCExample() throws {
        let headers = ["host":"localhost:8765", "origin":"http://localhost:8765", "upgrade":"websocket",
                       "connection":"keep-alive, Upgrade", "sec-websocket-version":"13", "sec-websocket-key":"dGhlIHNhbXBsZSBub25jZQ=="]
        let request = WebPreviewHTTP.Request(method: "GET", path: "/video?token=secret", headers: headers, body: Data())
        let data = try XCTUnwrap(WebSocketVideo.handshake(request, token: "secret"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
        XCTAssertNil(WebSocketVideo.handshake(request, token: "wrong"))
        for (name,value) in [("origin","https://evil.example"),("sec-websocket-version","12"),("sec-websocket-key","bad"),("connection","close")] {
            var invalid = headers; invalid[name] = value
            XCTAssertNil(WebSocketVideo.handshake(.init(method:"GET",path:request.path,headers:invalid,body:Data()), token:"secret"))
        }
    }

    func testMaskedSplitMessagesAndMalformedFrames() throws {
        let payload = Array("keyframe".utf8), mask: [UInt8] = [1,2,3,4]
        let message = Data([0x81,0x88] + mask + payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        var partial = Data(message.prefix(7))
        XCTAssertNil(try WebSocketVideo.read(&partial))
        partial.append(message.dropFirst(7)); partial.append(message)
        XCTAssertEqual(try WebSocketVideo.read(&partial)?.payload,Data(payload))
        XCTAssertEqual(try WebSocketVideo.read(&partial)?.payload,Data(payload))
        XCTAssertTrue(partial.isEmpty)
        for bad in [Data([0x81,1,0]),Data([0x01,0x80]),Data([0xc1,0x80]),Data([0x89,0xfe,0,126]),Data(repeating:0,count:8193)] {
            var buffer = bad; XCTAssertThrowsError(try WebSocketVideo.read(&buffer))
        }
        XCTAssertEqual(Array(WebSocketVideo.frame(Data(repeating:7,count:65536)).prefix(10)),[0x82,127,0,0,0,0,0,1,0,0])
    }

    func testHardwareEncoderProducesAnnexBKeyAndDeltaFrames() async throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 320, 640, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 80, CVPixelBufferGetBytesPerRow(pixels) * 640)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let encoder = WebH264Encoder()
        let encoded = try await encoder.encode(.pixels(pixels), forceKey: true)
        let key = try XCTUnwrap(encoded)
        XCTAssertTrue(key.key); XCTAssertEqual(key.width,320); XCTAssertEqual(key.height,640)
        XCTAssertTrue(key.codec.hasPrefix("avc1."))
        XCTAssertEqual(Array(key.bytes.prefix(4)),[0,0,0,1]); XCTAssertEqual(key.bytes[4] & 31,7)
        let deltaResult = try await encoder.encode(.pixels(pixels))
        let delta = try XCTUnwrap(deltaResult)
        XCTAssertFalse(delta.key); XCTAssertGreaterThanOrEqual(delta.timestamp,key.timestamp)
        let forcedResult = try await encoder.encode(.pixels(pixels), forceKey: true)
        XCTAssertTrue(try XCTUnwrap(forcedResult).key)
    }
}
