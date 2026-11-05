import AVFoundation
import Foundation
import XCTest
@testable import DeviceHubKit

@MainActor
final class AndroidVideoTests: XCTestCase {
    // Synthetic single-frame H.264 generated with FFmpeg/libx264; no device screenshots.
    private let portrait = Data(base64Encoded: "AAAAAWdCwArZBBGwEQAAAwABAAADAAKPEiZIAAAAAWjLg8sgAAABZYiEBK8RigACovHAAEo2OAAL60nJyddddddddddddeAAAAFlCIiEBK8RigACovHAAEo2OAAL60nJyddddddddddddeA=")!
    private let landscape = Data(base64Encoded: "AAAAAWdCwArZAgmwEQAAAwABAAADAAKPEiZIAAAAAWjLg8sgAAABZYiEBLxGKAAMxMcAAX1o4AAiQycnJycnJyddddddddddddddddddddddddeA")!
    private let display = DisplayInfo(pixelWidth: 64, pixelHeight: 128, pointScale: 1)

    func testCodecMetadataAndPacketFlagsAreStrictlyParsed() throws {
        let metadata = try ScrcpyVideoMetadata(metadata())
        XCTAssertEqual(metadata.width, 64)
        XCTAssertEqual(metadata.height, 128)
        XCTAssertThrowsError(try ScrcpyVideoMetadata(Data("av01".utf8) + Data(repeating: 0, count: 8)))
        XCTAssertThrowsError(try ScrcpyVideoMetadata(Data("h264".utf8) + Data(repeating: 0, count: 8)))
        XCTAssertThrowsError(try ScrcpyVideoMetadata(Data([0])))
        let parsed = try ScrcpyPacketHeader(header(flags: (1 << 63) | (1 << 62) | 123_456, length: 20))
        XCTAssertTrue(parsed.isConfiguration)
        XCTAssertTrue(parsed.isKeyframe)
        XCTAssertEqual(parsed.presentationTime, 123_456)
        XCTAssertEqual(parsed.payloadSize, 20)
        XCTAssertThrowsError(try ScrcpyPacketHeader(header(flags: 0, length: 0)))
        XCTAssertThrowsError(try ScrcpyPacketHeader(header(flags: 0, length: UInt32.max)))
        XCTAssertThrowsError(try ScrcpyPacketHeader(Data(repeating: 0, count: 11)))
    }

    func testAnnexBSupportsBothStartCodesAndRejectsMalformedUnits() throws {
        let units = try H264AnnexB.nalUnits(Data([0, 0, 0, 1, 0x67, 0x80, 0, 0, 1, 0x68, 0x90, 0, 0]))
        XCTAssertEqual(units, [Data([0x67, 0x80]), Data([0x68, 0x90])])
        XCTAssertEqual(H264AnnexB.avcc(units), Data([0, 0, 0, 2, 0x67, 0x80, 0, 0, 0, 2, 0x68, 0x90]))
        for bytes: [UInt8] in [[0x67, 0x80], [0, 0, 1], [0, 0, 1, 0xE7, 1], [1, 0, 0, 1, 0x67, 1]] {
            XCTAssertThrowsError(try H264AnnexB.nalUnits(Data(bytes)))
        }
    }

    func testH264ConfigurationBuildsNativeSamplesAndRequiresKeyframeAfterFlush() throws {
        let parts = try split(portrait)
        var decoder = H264SampleBuilder(display: display)
        let configured = try decoder.packet(parts.config, header: parsedHeader(config: true, length: parts.config.count))
        XCTAssertTrue(configured.formatChanged)
        XCTAssertNil(configured.sample)
        XCTAssertFalse(try decoder.packet(parts.config, header: parsedHeader(config: true, length: parts.config.count)).formatChanged)
        let frame = try decoder.packet(parts.frame, header: parsedHeader(key: true, length: parts.frame.count))
        let sample = try XCTUnwrap(frame.sample)
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_H264)
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(format).width, 64)
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(format).height, 128)
        decoder.requireKeyframe()
        let delta = Data([0, 0, 1, 0x41, 0x80])
        XCTAssertNil(try decoder.packet(delta, header: parsedHeader(length: delta.count)).sample)
        XCTAssertNotNil(try decoder.packet(parts.frame, header: parsedHeader(key: true, length: parts.frame.count)).sample)
        var unconfigured = H264SampleBuilder(display: display)
        XCTAssertThrowsError(try unconfigured.packet(parts.frame, header: parsedHeader(key: true, length: parts.frame.count)))
    }

    func testAlignmentScalingIsAllowedButRotationAndSPSGeometryChangesFail() throws {
        let phone = DisplayInfo(pixelWidth: 1080, pixelHeight: 2340, pointScale: 1)
        XCTAssertNoThrow(try AndroidVideoGeometry.validate(width: 880, height: 1920, display: phone))
        XCTAssertThrowsError(try AndroidVideoGeometry.validate(width: 1920, height: 880, display: phone))
        XCTAssertThrowsError(try AndroidVideoGeometry.validate(width: 1000, height: 1000, display: phone))
        var decoder = H264SampleBuilder(display: display)
        let first = try split(portrait).config
        _ = try decoder.packet(first, header: parsedHeader(config: true, length: first.count))
        let rotated = try split(landscape).config
        XCTAssertThrowsError(try decoder.packet(rotated, header: parsedHeader(config: true, length: rotated.count)))
    }

    func testStartWaitsForAnActuallyDecodedFrameAndStopReleasesOnlyItsToken() async throws {
        let transport = FakeVideoTransport(data: try framedVideo())
        let endpoints = EndpointRecorder()
        let stream = AndroidScrcpyScreenStream(display: display, startupTimeout: .seconds(3),
            startEndpoint: { AndroidVideoEndpoint(port: 12345, token: "video-one") },
            stopEndpoint: { await endpoints.stop($0) }, transportFactory: { _ in transport })
        try await stream.start()
        XCTAssertEqual(stream.kind, .scrcpy)
        XCTAssertTrue(stream.hasDecodedFrame)
        XCTAssertEqual(transport.writes, [Data("video-one\n".utf8)])
        stream.stop()
        stream.stop()
        try await waitUntil { await endpoints.tokens == ["video-one"] }
        XCTAssertTrue(transport.isClosed)
    }

    func testStalledFirstFrameTimesOutAndClosesTransport() async throws {
        let transport = FakeVideoTransport(data: metadata())
        let endpoints = EndpointRecorder()
        let stream = AndroidScrcpyScreenStream(display: display, startupTimeout: .milliseconds(100),
            startEndpoint: { AndroidVideoEndpoint(port: 12345, token: "stalled") },
            stopEndpoint: { await endpoints.stop($0) }, transportFactory: { _ in transport })
        do { try await stream.start(); XCTFail("A header without a decoded frame cannot start video") }
        catch { XCTAssertTrue(String(describing: error).contains("first decoded")) }
        try await waitUntil { await endpoints.tokens == ["stalled"] }
        XCTAssertTrue(transport.isClosed)
    }

    func testFailureBeforeCallbackAttachmentIsDeliveredWhenViewAttaches() async throws {
        let transport = FakeVideoTransport(data: try framedVideo())
        let endpoints = EndpointRecorder()
        let stream = AndroidScrcpyScreenStream(display: display, startupTimeout: .seconds(3),
            startEndpoint: { AndroidVideoEndpoint(port: 12345, token: "late-callback") },
            stopEndpoint: { await endpoints.stop($0) }, transportFactory: { _ in transport })
        defer { stream.stop() }
        try await stream.start()
        transport.close()
        try await waitUntil { await endpoints.tokens == ["late-callback"] }
        var errors: [String] = []
        stream.onError = { errors.append($0) }
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("closed"))
    }

    func testMalformedKeyframeCannotSatisfyStartup() async throws {
        let config = try split(portrait).config
        let malformed = Data([0, 0, 1, 0x65, 0x01])
        let data = metadata() + header(flags: 1 << 63, length: UInt32(config.count)) + config
            + header(flags: 1 << 62, length: UInt32(malformed.count)) + malformed
        let transport = FakeVideoTransport(data: data)
        let endpoints = EndpointRecorder()
        let stream = AndroidScrcpyScreenStream(display: display, startupTimeout: .seconds(3),
            startEndpoint: { AndroidVideoEndpoint(port: 12345, token: "malformed") },
            stopEndpoint: { await endpoints.stop($0) }, transportFactory: { _ in transport })
        do { try await stream.start(); XCTFail("An undecodable IDR cannot start video") }
        catch { XCTAssertTrue(String(describing: error).contains("decoder")) }
        XCTAssertFalse(stream.hasDecodedFrame)
        try await waitUntil { await endpoints.tokens == ["malformed"] }
    }

    func testScreenshotTerminalErrorIsReplayedAfterCallbackAttachmentAndClearedOnStop() async throws {
        let stream = ScreenshotScreenStream(recoveryPolicy: .none, stopOnError: true) {
            throw DeviceHubError.serviceFailed("geometry_changed: reconnect the device")
        }
        try await stream.start()
        try await waitUntil { stream.terminalError != nil }
        var errors: [String] = []
        stream.onError = { errors.append($0) }
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("geometry_changed"))
        stream.stop()
        stream.onError = { errors.append($0) }
        XCTAssertEqual(errors.count, 1)
        XCTAssertNil(stream.terminalError)
    }

    func testRecordedScrcpyVideoWhenExplicitlyEnabled() async throws {
        guard let path = ProcessInfo.processInfo.environment["DEVICEHUB_TEST_SCRCPY_CAPTURE"] else {
            throw XCTSkip("Set DEVICEHUB_TEST_SCRCPY_CAPTURE to validate a local recorded scrcpy stream")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let metadata = try ScrcpyVideoMetadata(Data(data.prefix(12)))
        let native = DisplayInfo(pixelWidth: Double(metadata.width), pixelHeight: Double(metadata.height), pointScale: 1)
        let transport = FakeVideoTransport(data: data)
        let stream = AndroidScrcpyScreenStream(display: native, startupTimeout: .seconds(5),
            startEndpoint: { AndroidVideoEndpoint(port: 12345, token: "recorded") },
            stopEndpoint: { _ in }, transportFactory: { _ in transport })
        defer { stream.stop() }
        try await stream.start()
        XCTAssertTrue(stream.hasDecodedFrame)
    }

    func testLateCancelledEndpointCannotStopNewStream() async throws {
        let endpoints = DelayedEndpoints()
        let transport = FakeVideoTransport(data: try framedVideo())
        let stream = AndroidScrcpyScreenStream(display: display, startupTimeout: .seconds(3),
            startEndpoint: { try await endpoints.start() }, stopEndpoint: { await endpoints.stop($0) },
            transportFactory: { _ in transport })
        let oldStart = Task { try await stream.start() }
        try await waitUntil { await endpoints.hasPendingStart }
        stream.stop()
        try await stream.start()
        await endpoints.releaseOldStart()
        do { try await oldStart.value; XCTFail("Cancelled startup must not succeed") } catch {}
        try await waitUntil { await endpoints.stopped == ["old"] }
        XCTAssertFalse(transport.isClosed)
        XCTAssertTrue(stream.hasDecodedFrame)
        stream.stop()
        try await waitUntil { await endpoints.stopped == ["old", "new"] }
    }

    func testLiveAndroidVideoWhenExplicitlyEnabled() async throws {
        guard let device = ProcessInfo.processInfo.environment["DEVICEHUB_TEST_ANDROID_VIDEO_UDID"], !device.isEmpty else {
            throw XCTSkip("Set DEVICEHUB_TEST_ANDROID_VIDEO_UDID to run read-only live video verification")
        }
        let session = try await DeviceHub.shared.session(for: device)
        let stream = AndroidScrcpyScreenStream(session: session)
        defer { stream.stop() }
        try await stream.start()
        XCTAssertEqual(stream.kind, .scrcpy)
        XCTAssertTrue(stream.hasDecodedFrame)
    }

    private func metadata() -> Data {
        var data = Data("h264".utf8)
        data.appendBE(UInt32(64)); data.appendBE(UInt32(128))
        return data
    }

    private func header(flags: UInt64, length: UInt32) -> Data {
        var data = Data(); data.appendBE(flags); data.appendBE(length); return data
    }

    private func parsedHeader(config: Bool = false, key: Bool = false, length: Int) throws -> ScrcpyPacketHeader {
        try ScrcpyPacketHeader(header(flags: (config ? 1 << 63 : 0) | (key ? 1 << 62 : 0), length: UInt32(length)))
    }

    private func split(_ data: Data) throws -> (config: Data, frame: Data) {
        var config = Data(), frame = Data()
        for nal in try H264AnnexB.nalUnits(data) {
            let encoded = Data([0, 0, 0, 1]) + nal
            if [7, 8].contains(nal.first! & 0x1F) { config.append(encoded) } else { frame.append(encoded) }
        }
        return (config, frame)
    }

    private func framedVideo() throws -> Data {
        let parts = try split(portrait)
        return metadata() + header(flags: 1 << 63, length: UInt32(parts.config.count)) + parts.config
            + header(flags: 1 << 62, length: UInt32(parts.frame.count)) + parts.frame
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting for video lifecycle event"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class FakeVideoTransport: ScrcpyVideoTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: Data
    private var closed = false
    private var output: [Data] = []
    private var pending: CheckedContinuation<Data, Error>?
    init(data: Data) { buffer = data }
    var writes: [Data] { lock.withLock { output } }
    var isClosed: Bool { lock.withLock { closed } }
    func open() async throws {}
    func write(_ data: Data) async throws { lock.withLock { output.append(data) } }
    func read(exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed { lock.unlock(); continuation.resume(throwing: DeviceHubError.connectionClosed) }
            else if buffer.count >= count {
                let data = Data(buffer.prefix(count)); buffer.removeFirst(count)
                lock.unlock(); continuation.resume(returning: data)
            } else { pending = continuation; lock.unlock() }
        }
    }
    func close() {
        lock.lock(); closed = true; let waiting = pending; pending = nil; lock.unlock()
        waiting?.resume(throwing: DeviceHubError.connectionClosed)
    }
}

private actor EndpointRecorder {
    private(set) var tokens: [String] = []
    func stop(_ token: String) { tokens.append(token) }
}

private actor DelayedEndpoints {
    private var pending: CheckedContinuation<AndroidVideoEndpoint, Error>?
    private var starts = 0
    private(set) var stopped: [String] = []
    var hasPendingStart: Bool { pending != nil }
    func start() async throws -> AndroidVideoEndpoint {
        starts += 1
        if starts > 1 { return AndroidVideoEndpoint(port: 12345, token: "new") }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func releaseOldStart() { pending?.resume(returning: AndroidVideoEndpoint(port: 12345, token: "old")); pending = nil }
    func stop(_ token: String) { stopped.append(token) }
}
