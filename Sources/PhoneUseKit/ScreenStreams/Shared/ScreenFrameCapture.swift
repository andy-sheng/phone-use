import CoreImage
import Foundation
import VideoToolbox

/// Opt-in frame access for consumers outside Core Animation. Keeps only the latest pixels;
/// compressed streams must decode every access unit even when the consumer samples slowly.
final class ScreenFrameCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var enabled = false
    private var pixels: CVPixelBuffer?
    private var decoder: VTDecompressionSession?
    private var format: CMFormatDescription?

    func append(_ sample: CMSampleBuffer) {
        lock.withLock {
            guard enabled else { return }
            if let image = CMSampleBufferGetImageBuffer(sample) {
                pixels = image
                return
            }
            guard let description = CMSampleBufferGetFormatDescription(sample) else { return }
            if format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: description) }) ?? true {
                resetDecoder()
            }
            if decoder == nil {
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
                guard attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true else { return }
                guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
                    decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil,
                    decompressionSessionOut: &decoder) == noErr else { return }
                format = description
            }
            guard let decoder else { return }
            let output = DecodedPixels()
            // Synchronous decoding: the output handler completes before this call returns.
            let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
                status, _, image, _, _ in
                if status == noErr { output.set(image) }
            }
            if status == noErr, let image = output.get() { pixels = image }
            else { resetDecoder() }
        }
    }

    func copyFrame() -> CGImage? {
        guard let buffer = copyPixelBuffer() else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(image, from: image.extent)
    }

    func copyPixelBuffer() -> CVPixelBuffer? {
        lock.withLock { enabled = true; return pixels }
    }

    func reset() { lock.withLock { resetDecoder() } }

    private func resetDecoder() {
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        decoder = nil
        format = nil
        pixels = nil
    }

    deinit { if let decoder { VTDecompressionSessionInvalidate(decoder) } }
}

private final class DecodedPixels: @unchecked Sendable {
    private let lock = NSLock()
    private var pixels: CVPixelBuffer?
    func set(_ value: CVPixelBuffer?) { lock.withLock { pixels = value } }
    func get() -> CVPixelBuffer? { lock.withLock { pixels } }
}
