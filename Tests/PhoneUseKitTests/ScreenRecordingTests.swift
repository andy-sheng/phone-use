import AVFoundation
import XCTest
@testable import PhoneUseKit

final class ScreenRecordingTests: XCTestCase {
    func testCancelledStopWaitsForPlatformToolToFinishWriting() async throws {
        let url = try destination()
        let ready = url.deletingLastPathComponent().appendingPathComponent("ready")
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Ignore the interrupt so stdin can deterministically control when the
        // fake recording tool finishes saving its file.
        process.arguments = ["-c", "trap '' INT; touch \"$2\"; read line; printf complete > \"$1\"",
                             "recording-test", url.path, ready.path]
        process.standardInput = input
        let recording = try ScreenRecording(process: process, destination: url)
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let entered = expectation(description: "Stopping recording")
        let prematureStop = expectation(description: "Must finish saving before returning")
        prematureStop.isInverted = true
        let stop = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            entered.fulfill()
            defer { if process.isRunning { prematureStop.fulfill() } }
            return try await recording.stop()
        }
        await fulfillment(of: [entered], timeout: 2)
        await fulfillment(of: [prematureStop], timeout: 0.1)
        try input.fileHandleForWriting.close()
        let saved = try await stop.value
        XCTAssertEqual(saved, url)
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "complete")
        XCTAssertFalse(recording.isRunning)
    }

    private func destination() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("recording.mp4")
    }

    private func frame(width: Int = 64, height: Int = 96) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                         nil, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 128, CVPixelBufferGetBytesPerRow(buffer) * height)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
            sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    func testUSBFramesProducePlayableMovieAndSinkCanRecordAgain() async throws {
        let sink = ScreenRecordingSink()
        let url = try destination()
        let recording = try sink.start(to: url)
        XCTAssertThrowsError(try sink.start(to: destination()))
        for _ in 0..<5 {
            sink.append(try frame())
            try await Task.sleep(for: .milliseconds(40))
        }
        let saved = try await recording.stop()
        XCTAssertEqual(saved, url)
        XCTAssertFalse(recording.isRunning)
        sink.append(try frame()) // A late capture callback cannot append to the finished writer.
        let asset = AVURLAsset(url: saved)
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.1)
        let image = try await AVAssetImageGenerator(asset: asset).image(at: .zero).image
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 96)
        let second = try sink.start(to: destination())
        sink.append(try frame())
        _ = try await second.stop()
    }

    func testStoppingWithoutFramesFailsAndRemovesEmptyFile() async throws {
        let url = try destination()
        let recording = try StreamRecording(destination: url)
        do { _ = try await recording.stop(); XCTFail("Empty recording must not report success") }
        catch { XCTAssertTrue(String(describing: error).contains("No video frames")) }
        XCTAssertFalse(recording.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCompressedVideoWaitsForKeyframeAndRemuxesPlayableMovie() async throws {
        let source = try StreamRecording(destination: destination())
        for _ in 0..<6 {
            source.append(try frame())
            try await Task.sleep(for: .milliseconds(40))
        }
        let sourceURL = try await source.stop()
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() { samples.append(sample) }
        XCTAssertEqual(reader.status, .completed)
        let delta = try XCTUnwrap(samples.first {
            let attachments = CMSampleBufferGetSampleAttachmentsArray($0, createIfNecessary: false) as? [[CFString: Any]]
            return attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool == true
        })
        let incomplete = try StreamRecording(destination: destination())
        incomplete.append(delta)
        do { _ = try await incomplete.stop(); XCTFail("Delta frames cannot start a movie") }
        catch { XCTAssertTrue(String(describing: error).contains("No video frames")) }

        let recording = try StreamRecording(destination: destination())
        recording.append(delta) // Joining mid-stream must wait for the next keyframe.
        for sample in samples {
            recording.append(sample)
            try await Task.sleep(for: .milliseconds(40))
        }
        let saved = try await recording.stop()
        let image = try await AVAssetImageGenerator(asset: AVURLAsset(url: saved)).image(at: .zero).image
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 96)
    }

    func testRotationStopsRecordingAndKeepsPlayablePrefix() async throws {
        let recording = try StreamRecording(destination: destination())
        recording.append(try frame())
        try await Task.sleep(for: .milliseconds(50))
        recording.append(try frame(width: 96, height: 64))
        XCTAssertFalse(recording.isRunning)
        do { _ = try await recording.stop(); XCTFail("Rotation should report why recording ended") }
        catch { XCTAssertTrue(String(describing: error).contains("format changed")) }
        _ = try await AVAssetImageGenerator(asset: AVURLAsset(url: recording.destination)).image(at: .zero)
    }

    func testStreamFailureFinishesInsteadOfLeavingRecordingActive() async throws {
        let sink = ScreenRecordingSink()
        let recording = try sink.start(to: destination())
        sink.append(try frame())
        sink.fail("Disconnected")
        XCTAssertFalse(recording.isRunning)
        do { _ = try await recording.stop(); XCTFail("Stream failure should be reported") }
        catch { XCTAssertEqual(String(describing: error), "Disconnected") }
    }

    func testDeviceSettingsSupportDoesNotClaimPhysicalScreenRecording() throws {
        let settings = DeviceSettings(backend: DeviceCtlSettings(identifier: "physical-device"))
        XCTAssertFalse(settings.canRecord)
        XCTAssertThrowsError(try settings.startRecording(to: destination()))
        let simulator = DeviceSettings(backend: DeviceCtlSettings(identifier: "simulator"),
            recordingBackend: SimctlSettings(identifier: "simulator"))
        XCTAssertEqual(simulator.canRecord, SimulatorTools.developerDirectory() != nil)
        XCTAssertTrue(simulator.recordingBackend is SimctlSettings)
    }

    func testNativeRecordingRequiresTheReportedCapability() {
        XCTAssertFalse(DeviceCtlSettings.supportsRecording([:]))
        XCTAssertFalse(DeviceCtlSettings.supportsRecording(["capabilities": [
            ["featureIdentifier": "com.apple.coredevice.feature.customizeappearancesettings"],
        ]]))
        let supported = DeviceCtlSettings.supportsRecording(["capabilities": [
            ["featureIdentifier": "com.apple.coredevice.feature.screenrecording", "name": "Screen Recording"],
        ]])
        XCTAssertTrue(supported)
        let settings = DeviceSettings(backend: DeviceCtlSettings(identifier: "supported-device", canRecord: supported))
        XCTAssertTrue(settings.canRecord)
    }

    func testLockUsesShortPowerPressInsteadOfSiriHold() throws {
        let usage = try XCTUnwrap(HardwareButton.lock.usage)
        let down = HIDReports.buttonMessage(page: usage.page, code: usage.code, down: true)
        XCTAssertEqual(down["payload"]?["usagePage"], .uint64(0x0C))
        XCTAssertEqual(down["payload"]?["usageCode"], .uint64(0x30))
        XCTAssertEqual(down["payload"]?["state"], .uint64(1))
        XCTAssertEqual(HardwareButton.lock.usage?.code, 0x30)
        XCTAssertEqual(HardwareButton.lock.defaultHold, .milliseconds(100))
        XCTAssertEqual(HardwareButton.siri.defaultHold, .seconds(1))
        XCTAssertEqual(SimulatorInput.button(.lock), .source(1))
    }
}
