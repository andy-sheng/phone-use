import CoreMedia
import Foundation
import VideoToolbox

/// Proves the first access unit is decodable before exposing the stream to the UI.
/// A display layer is not attached to a window until start returns, so its readyForDisplay
/// property cannot serve as the startup handshake for a detached/headless preview.
enum H264FirstFrameDecoder {
    static func verify(_ sample: CMSampleBuffer) throws {
        guard let format = CMSampleBufferGetFormatDescription(sample) else {
            throw ScrcpyVideoError.decoder("first frame has no codec description")
        }
        var session: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil,
            decompressionSessionOut: &session)
        guard created == noErr, let session else {
            throw ScrcpyVideoError.decoder("could not create decoder (\(created))")
        }
        defer { VTDecompressionSessionInvalidate(session) }
        let result = FirstFrameResult()
        // With neither asynchronous nor temporal flags, VideoToolbox invokes the output handler
        // before returning. No dependent frames or display-layer attachment are needed.
        let decoded = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, image, _, _ in result.record(status: status, hasImage: image != nil)
        }
        guard decoded == noErr, result.succeeded else {
            throw ScrcpyVideoError.decoder("first H.264 frame was not decoded (\(decoded), \(result.status))")
        }
    }
}

private final class FirstFrameResult: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStatus: OSStatus = -1
    private var hasImage = false
    var status: OSStatus { lock.withLock { recordedStatus } }
    var succeeded: Bool { lock.withLock { recordedStatus == noErr && hasImage } }
    func record(status: OSStatus, hasImage: Bool) {
        lock.withLock { recordedStatus = status; self.hasImage = hasImage }
    }
}
