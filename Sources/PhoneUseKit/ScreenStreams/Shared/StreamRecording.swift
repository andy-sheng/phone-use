import AVFoundation
import Foundation

/// Receives samples on the stream's existing delivery queue. No second device connection is opened.
final class ScreenRecordingSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let frameCapture = ScreenFrameCapture()
    private let lock = NSLock()
    private var recording: StreamRecording?

    func start(to destination: URL) throws -> StreamRecording {
        try lock.withLock {
            guard recording?.isRunning != true else { throw DeviceHubError.serviceFailed("Already recording") }
            let next = try StreamRecording(destination: destination)
            recording = next
            return next
        }
    }

    func append(_ sample: CMSampleBuffer) {
        frameCapture.append(sample)
        lock.withLock { recording }?.append(sample)
    }

    func fail(_ message: String) {
        lock.withLock { recording }?.fail(message)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        append(sampleBuffer)
    }
}

/// Writes USB pixel buffers as H.264, or remuxes Mirror's HEVC samples without re-encoding.
/// All appends and the transition to finishing are serialized; back pressure drops frames.
final class StreamRecording: ScreenRecordingSession, @unchecked Sendable {
    let destination: URL
    private let lock = NSLock()
    private let writer: AVAssetWriter
    private var input: AVAssetWriterInput?
    private var format: CMFormatDescription?
    private var startedAt: TimeInterval?
    private var lastTime = CMTime.invalid
    private var stopping = false
    private var failure: Error?

    init(destination: URL) throws {
        self.destination = destination
        writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
    }

    var isRunning: Bool { lock.withLock { !stopping && failure == nil && writer.status != .failed } }

    func fail(_ message: String) {
        lock.withLock {
            if !stopping && failure == nil { failure = DeviceHubError.serviceFailed(message) }
        }
    }

    func append(_ sample: CMSampleBuffer) {
        lock.withLock {
            guard !stopping, failure == nil, let description = CMSampleBufferGetFormatDescription(sample) else { return }
            do {
                let compressed = CMSampleBufferGetImageBuffer(sample) == nil
                if input == nil {
                    // A delta frame cannot begin a standalone movie.
                    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
                    if compressed && attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool == true { return }
                    let size = CMVideoFormatDescriptionGetDimensions(description)
                    let settings: [String: Any]? = compressed ? nil : [
                        AVVideoCodecKey: AVVideoCodecType.h264,
                        AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                    ]
                    let track = AVAssetWriterInput(mediaType: .video, outputSettings: settings, sourceFormatHint: description)
                    track.expectsMediaDataInRealTime = true
                    guard writer.canAdd(track) else { throw DeviceHubError.serviceFailed("Unsupported recording video format") }
                    writer.add(track)
                    guard writer.startWriting() else { throw writer.error ?? DeviceHubError.serviceFailed("Cannot start recording") }
                    writer.startSession(atSourceTime: .zero)
                    input = track
                    format = description
                    startedAt = ProcessInfo.processInfo.systemUptime
                }
                // A rotated stream needs a new movie track. Finalize the playable part and report it.
                guard let format, CMFormatDescriptionEqual(format, otherFormatDescription: description) else {
                    throw DeviceHubError.serviceFailed("The video format changed. Start a new recording after rotation.")
                }
                guard let input else { return }
                guard input.isReadyForMoreMediaData else {
                    if compressed { throw DeviceHubError.serviceFailed("Recording could not keep up with the video stream") }
                    return
                }
                var time = CMTime(seconds: ProcessInfo.processInfo.systemUptime - (startedAt ?? 0), preferredTimescale: 60000)
                if lastTime.isValid && time <= lastTime { time = lastTime + CMTime(value: 1, timescale: 60000) }
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                                               presentationTimeStamp: time, decodeTimeStamp: .invalid)
                var copy: CMSampleBuffer?
                guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                    sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
                    let copy, input.append(copy) else {
                    throw writer.error ?? DeviceHubError.serviceFailed("Cannot write recording frame")
                }
                lastTime = time
            } catch { failure = error }
        }
    }

    func stop() async throws -> URL {
        let recordingFailure = try lock.withLock {
            guard !stopping else { throw DeviceHubError.serviceFailed("Recording is already stopping") }
            stopping = true
            guard input != nil, lastTime.isValid, writer.status == .writing else {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: destination)
                throw failure ?? writer.error ?? DeviceHubError.serviceFailed("No video frames were recorded")
            }
            writer.endSession(atSourceTime: max(lastTime + CMTime(value: 1, timescale: 60),
                CMTime(seconds: ProcessInfo.processInfo.systemUptime - (startedAt ?? 0), preferredTimescale: 60000)))
            input?.markAsFinished()
            return failure
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? DeviceHubError.serviceFailed("The screen recording was not saved")
        }
        if let recordingFailure { throw recordingFailure }
        return destination
    }

    deinit {
        if writer.status == .writing { writer.cancelWriting() }
    }
}
