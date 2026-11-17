import CoreImage
import Foundation
import ImageIO
import PhoneUseKit

enum WebVideoProfile: String, CaseIterable, Sendable {
    case balanced, detail

    var maximumDimension: Int {
        switch self { case .balanced: 1920; case .detail: 4096 }
    }
    var quality: Double {
        switch self { case .balanced: 0.86; case .detail: 0.94 }
    }

    func size(width: Int, height: Int) -> (width: Int, height: Int) {
        let scale = min(1, Double(maximumDimension) / Double(max(width, height, 1)))
        return (max(1, Int(Double(width) * scale)), max(1, Int(Double(height) * scale)))
    }

    /// Encoding time counts toward the frame budget; never sleep an additional full interval
    /// or queue catch-up frames after a slow encode.
    static func delay(framesPerSecond: Int, elapsed: TimeInterval) -> TimeInterval {
        max(0, 1 / Double(max(1, framesPerSecond)) - max(0, elapsed))
    }
}

enum WebVideoFrame: @unchecked Sendable {
    case pixels(CVPixelBuffer)
    case image(CGImage)

    @MainActor static func latest(from stream: any ScreenStream) -> WebVideoFrame? {
        if let pixels = stream.copyPixelBuffer() { return .pixels(pixels) }
        return stream.copyFrame().map { .image($0) }
    }
}

struct WebEncodedFrame: Sendable {
    let jpeg: Data
    let width: Int
    let height: Int
    let milliseconds: Double
}

/// One serial encoder and reusable GPU context. USB/decoded video travels directly from a
/// retained CVPixelBuffer through scaling and JPEG, without CGImage + CGContext copies.
actor WebVideoEncoder {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func encode(_ frame: WebVideoFrame, profile: WebVideoProfile) -> WebEncodedFrame? {
        autoreleasepool {
            let start = ProcessInfo.processInfo.systemUptime
            let source: CIImage
            switch frame {
            case .pixels(let pixels): source = CIImage(cvPixelBuffer: pixels)
            case .image(let image): source = CIImage(cgImage: image)
            }
            let size = profile.size(width: Int(source.extent.width), height: Int(source.extent.height))
            let scale = Double(size.width) / source.extent.width
            let image = scale < 1 ? source.applyingFilter("CILanczosScaleTransform",
                parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0]) : source
            let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            guard let jpeg = context.jpegRepresentation(of: image.cropped(to: rect), colorSpace: colorSpace,
                                                        options: [quality: profile.quality]) else { return nil }
            return WebEncodedFrame(jpeg: jpeg, width: size.width, height: size.height,
                milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
    }
}
