import CoreImage
import Foundation
import PhoneUseKit
import VideoToolbox

struct WebH264Frame: Sendable {
    let bytes: Data
    let codec: String
    let width: Int
    let height: Int
    let timestamp: UInt64
    let key: Bool

    var packet: Data {
        var payload = Data([key ? 1 : 0])
        WebSocketVideo.append(timestamp, bytes: 8, to: &payload)
        payload.append(bytes)
        return WebSocketVideo.frame(payload)
    }

    static func copy(_ sample: CMSampleBuffer) -> WebH264Frame? {
        guard let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var parameter: UnsafePointer<UInt8>?, size = 0, count = 0, header: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
            parameterSetPointerOut: &parameter, parameterSetSizeOut: &size,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &header) == noErr,
            let sps = parameter, size >= 4, header == 4 else { return nil }
        let codec = String(format: "avc1.%02X%02X%02X", sps[1], sps[2], sps[3])
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
        let key = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true
        var annex = Data()
        if key {
            for index in 0..<count {
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &parameter, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let parameter else { return nil }
                annex.append(contentsOf: [0, 0, 0, 1]); annex.append(parameter, count: size)
            }
        }
        var avcc = Data(count: CMBlockBufferGetDataLength(block))
        let status = avcc.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        guard status == noErr else { return nil }
        var offset = 0
        while offset + 4 <= avcc.count {
            let length = (0..<4).reduce(0) { ($0 << 8) | Int(avcc[offset + $1]) }
            offset += 4
            guard length > 0, length <= avcc.count - offset else { return nil }
            annex.append(contentsOf: [0, 0, 0, 1]); annex.append(avcc[offset..<offset + length]); offset += length
        }
        guard offset == avcc.count, !annex.isEmpty else { return nil }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        return .init(bytes: annex, codec: codec, width: Int(dimensions.width), height: Int(dimensions.height),
                     timestamp: UInt64(max(0, CMTimeGetSeconds(time) * 1_000_000)), key: key)
    }
}

/// Serial hardware encoder; no B frames, no software fallback, one frame in flight.
actor WebH264Encoder {
    private var session: VTCompressionSession?
    private var width = 0, height = 0
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    deinit { if let session { VTCompressionSessionInvalidate(session) } }

    func encode(_ frame: WebVideoFrame, forceKey: Bool = false) async throws -> WebH264Frame? {
        let image: CIImage
        let direct: CVPixelBuffer?
        switch frame {
        case .pixels(let pixels): image = CIImage(cvPixelBuffer: pixels); direct = pixels
        case .image(let cgImage): image = CIImage(cgImage: cgImage); direct = nil
        }
        let scale = min(1, 4096 / max(image.extent.width, image.extent.height))
        let w = max(2, Int(image.extent.width * scale) / 2 * 2), h = max(2, Int(image.extent.height * scale) / 2 * 2)
        if session == nil || w != width || h != height { try setup(width: w, height: h) }
        guard let session else { return nil }
        let pixels: CVPixelBuffer
        if let direct, CVPixelBufferGetWidth(direct) == w, CVPixelBufferGetHeight(direct) == h { pixels = direct }
        else {
            var rendered: CVPixelBuffer?
            guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &rendered) == kCVReturnSuccess, let rendered else {
                throw DeviceHubError.serviceFailed("Cannot allocate web video frame")
            }
            context.render(image.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / image.extent.width,
                y: CGFloat(h) / image.extent.height)), to: rendered)
            pixels = rendered
        }
        let timestamp = CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 1_000_000)
        return try await withCheckedThrowingContinuation { continuation in
            let result = EncodingResult(continuation)
            let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: timestamp,
                duration: CMTime(value: 1, timescale: 60), frameProperties: forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil,
                infoFlagsOut: nil) { status, flags, sample in
                    if status != noErr { result.finish(.failure(DeviceHubError.serviceFailed("H.264 encode failed: \(status)"))) }
                    else { result.finish(.success(sample.flatMap(WebH264Frame.copy))) }
                }
            if status != noErr { result.finish(.failure(DeviceHubError.serviceFailed("H.264 submission failed: \(status)"))) }
        }
    }

    private func setup(width: Int, height: Int) throws {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw DeviceHubError.serviceFailed("Hardware H.264 unavailable: \(status)") }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_MaxFrameDelayCount: 0,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 60,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1,
            kVTCompressionPropertyKey_AverageBitRate: min(60_000_000, max(12_000_000, width * height * 8)),
        ]
        let configured = VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
        guard configured == noErr else { VTCompressionSessionInvalidate(session); self.session = nil; throw DeviceHubError.serviceFailed("H.264 configuration failed: \(configured)") }
        var newPool: CVPixelBufferPool?
        let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool) == kCVReturnSuccess else {
            VTCompressionSessionInvalidate(session); self.session = nil
            throw DeviceHubError.serviceFailed("Cannot create web video buffer pool")
        }
        pool = newPool; self.width = width; self.height = height
    }
}

private final class EncodingResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WebH264Frame?, Error>?
    init(_ continuation: CheckedContinuation<WebH264Frame?, Error>) { self.continuation = continuation }
    func finish(_ result: Result<WebH264Frame?, Error>) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}
