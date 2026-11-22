import CoreGraphics
import Vision

/// The system displays four or six evenly spaced circles above its numeric keypad.
struct PasscodeDotRow: Equatable {
    let count: Int
    let filled: Int
    let bottom: CGFloat

    static func read(_ image: CGImage) -> Self? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let region = CGRect(x: 0, y: floor(h * 0.10), width: w, height: floor(h * 0.26))
        guard let crop = image.cropping(to: region) else { return nil }
        let request = VNDetectContoursRequest()
        request.maximumImageDimension = 768
        request.detectsDarkOnLight = false
        guard (try? VNImageRequestHandler(cgImage: crop).perform([request])) != nil,
              let result = request.results?.first else { return nil }

        var circles = [(box: CGRect, filled: Bool)]()
        for i in 0..<result.contourCount {
            guard let contour = try? result.contour(at: i) else { continue }
            let path = contour.normalizedPath
            let b = path.boundingBoxOfPath
            let box = CGRect(x: b.minX * w, y: region.minY + (1 - b.maxY) * region.height,
                             width: b.width * w, height: b.height * region.height)
            guard (0.018...0.048).contains(box.width / w), (0.85...1.15).contains(box.width / box.height),
                  contour.childContourCount <= 1 else { continue }
            if let inner = contour.childContours.first?.normalizedPath.boundingBoxOfPath {
                guard (0.45...0.90).contains(inner.width / b.width),
                      abs(inner.midX - b.midX) < b.width * 0.10,
                      abs(inner.midY - b.midY) < b.height * 0.10 else { continue }
            }
            circles.append((box, contour.childContourCount == 0))
        }
        // Drop the inner edge of a hollow circle, which Vision also reports as a contour.
        let outer = circles.filter { c in !circles.contains { $0.box.width > c.box.width && $0.box.contains(c.box) } }
        var candidates = [Self]()
        for first in outer where first.box.midX < w / 2 {
            let row = outer.filter { abs($0.box.midY - first.box.midY) < first.box.height * 0.18 }
                .sorted { $0.box.midX < $1.box.midX }
            guard [4, 6].contains(row.count), row.first?.box == first.box, let last = row.last,
                  abs((first.box.midX + last.box.midX) / 2 - w / 2) < first.box.width * 0.3 else { continue }
            let step = (last.box.midX - first.box.midX) / CGFloat(row.count - 1)
            guard (1.7...4.5).contains(step / first.box.width),
                  row.enumerated().allSatisfy({ i, c in
                      abs(c.box.midX - first.box.midX - CGFloat(i) * step) < first.box.width * 0.16 &&
                      abs(c.box.width - first.box.width) < first.box.width * 0.16
                  }) else { continue }
            let filled = row.prefix { $0.filled }.count
            guard row.dropFirst(filled).allSatisfy({ !$0.filled }) else { continue }
            candidates.append(Self(count: row.count, filled: filled, bottom: first.box.maxY / h))
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}
