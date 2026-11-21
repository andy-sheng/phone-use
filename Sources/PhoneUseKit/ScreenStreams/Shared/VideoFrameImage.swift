import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// Turns a decoded video frame into a native-size recognition image, or rejects it.
///
/// Under bandwidth pressure the iOS Mirror encoder keeps its buffer size but renders a smaller
/// capture into the top-left corner and fills the rest with flat mid-gray (Y = Cb = Cr = 128).
/// Such a frame would misplace every recognized element, so it is rejected rather than stretched;
/// the next full-resolution keyframe replaces it.
final class VideoFrameImage: @unchecked Sendable {
    /// Unmanaged conversion: the check compares raw decoded levels against the padding value.
    private let raw = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                          .cacheIntermediates: false])
    private let output = CIContext(options: [.cacheIntermediates: false])
    private static let sampleWidth = 64

    enum Rejection: Equatable {
        case aspect, collapsed, conversion
    }

    func nativeImage(_ pixels: CVPixelBuffer, width: Int, height: Int) -> Result<CGImage, RejectionError> {
        let frameWidth = CVPixelBufferGetWidth(pixels), frameHeight = CVPixelBufferGetHeight(pixels)
        guard width > 0, height > 0, frameWidth > 0, frameHeight > 0 else { return .failure(.init(.conversion)) }
        // The encoder alternates between a few rows of height, so only a real aspect change fails.
        let aspect = Double(frameWidth) / Double(frameHeight), native = Double(width) / Double(height)
        guard abs(aspect / native - 1) < 0.03 else { return .failure(.init(.aspect)) }
        let source = CIImage(cvPixelBuffer: pixels)
        guard let sample = samplePixels(source) else { return .failure(.init(.conversion)) }
        if Self.isCollapsed(sample, width: Self.sampleWidth, height: sample.count / 4 / Self.sampleWidth) {
            return .failure(.init(.collapsed))
        }
        let scaled = source.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / CGFloat(frameWidth),
                                                              y: CGFloat(height) / CGFloat(frameHeight)))
        guard let image = output.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
            return .failure(.init(.conversion))
        }
        return .success(image)
    }

    struct RejectionError: Error, CustomStringConvertible {
        let reason: Rejection
        init(_ reason: Rejection) { self.reason = reason }
        var description: String { "video frame rejected: \(reason)" }
    }

    /// RGBA8 bytes of a small rendering of the frame.
    private func samplePixels(_ image: CIImage) -> [UInt8]? {
        let width = Self.sampleWidth
        let height = max(8, Int((Double(width) * image.extent.height / image.extent.width).rounded()))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / image.extent.width,
                                                             y: CGFloat(height) / image.extent.height))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        // Row 0 of the bitmap is the top of the screen.
        raw.render(scaled, toBitmap: &bytes, rowBytes: width * 4,
                   bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: nil)
        return bytes
    }

    /// Both the right and the bottom edge strips are padding while the top-left still has content.
    static func isCollapsed(_ rgba: [UInt8], width: Int, height: Int) -> Bool {
        guard width >= 8, height >= 8, rgba.count >= width * height * 4 else { return false }
        func paddingShare(_ xs: Range<Int>, _ ys: Range<Int>) -> Double {
            var padding = 0, total = 0
            for y in ys {
                for x in xs {
                    let i = (y * width + x) * 4
                    let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
                    total += 1
                    if (114...146).contains(r), (114...146).contains(g), (114...146).contains(b),
                       max(r, g, b) - min(r, g, b) <= 8 {
                        padding += 1
                    }
                }
            }
            return total == 0 ? 0 : Double(padding) / Double(total)
        }
        let strip = max(1, width / 20), band = max(1, height / 20)
        let right = paddingShare(width - strip ..< width, 0 ..< height)
        let bottom = paddingShare(0 ..< width, height - band ..< height)
        let corner = paddingShare(0 ..< width / 3, 0 ..< height / 3)
        return right >= 0.9 && bottom >= 0.9 && corner < 0.9
    }
}
