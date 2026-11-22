import CoreGraphics
import Vision

/// Reads the system numeric keypad in memory. Require the passcode prompt as well as the
/// complete keypad. The emergency dialler and the SIM PIN screen are different surfaces.
struct PasscodeKeypad {
    let keys: [Character: CGPoint]
    let isEmpty: Bool
    var progress: PasscodeDotRow? = nil

    static func read(_ image: CGImage) throws -> Self? {
        let progress = PasscodeDotRow.read(image)
        func detect(_ frame: CGImage) throws -> Self? {
            try parse(recognize(frame), progress: progress) { candidate, dx, dy in
                hasZeroGlyph(image, at: candidate, column: dx, row: dy)
            }
        }
        if let pad = try detect(image) { return pad }
        // At native Retina resolution Vision sometimes drops isolated digits such as 1.
        // Use a second scale of the same frame; all observations and taps are normalized.
        let width = 768
        guard image.width > width,
              let smaller = ImageEncoding.resized(image, width: width, height: image.height * width / image.width)
        else { return nil }
        return try detect(smaller)
    }

    private static func recognize(_ image: CGImage) throws -> [(String, CGPoint)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.minimumTextHeight = 0.008
        request.usesLanguageCorrection = false
        // Vision chooses its recognition model from the leading language. The Chinese model
        // also reads Latin labels; the English model can turn 输入密码 and 取消 into gibberish.
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { match in
            guard let text = match.topCandidates(1).first?.string else { return nil }
            return (text, CGPoint(x: match.boundingBox.midX, y: 1 - match.boundingBox.midY))
        }
    }

    // Vision sometimes drops an isolated 0. Inspect its actual glyph below the validated
    // 1–9 grid: a tall oval with one centred hole. Reject empty space or a round key border.
    private static func hasZeroGlyph(_ image: CGImage, at point: CGPoint, column: CGFloat, row: CGFloat) -> Bool {
        let size = CGSize(width: CGFloat(image.width) * column * 0.7, height: CGFloat(image.height) * row * 0.65)
        let region = CGRect(x: point.x * CGFloat(image.width) - size.width / 2,
                            y: point.y * CGFloat(image.height) - size.height / 2,
                            width: size.width, height: size.height)
        guard let crop = image.cropping(to: region) else { return false }
        for dark in [false, true] {
            let request = VNDetectContoursRequest()
            request.detectsDarkOnLight = dark
            guard (try? VNImageRequestHandler(cgImage: crop).perform([request])) != nil,
                  let result = request.results?.first else { continue }
            for index in 0..<result.contourCount {
                guard let contour = try? result.contour(at: index), contour.childContourCount == 1,
                      let hole = contour.childContours.first?.normalizedPath.boundingBoxOfPath else { continue }
                let outer = contour.normalizedPath.boundingBoxOfPath
                let aspect = outer.width * size.width / (outer.height * size.height)
                if (0.38...0.88).contains(aspect), (0.2...0.85).contains(outer.height),
                   abs(outer.midX - 0.5) < 0.15, abs(outer.midY - 0.5) < 0.18,
                   abs(hole.midY - outer.midY) < outer.height * 0.12,
                   abs(hole.midX - outer.midX) < outer.width * 0.12,
                   hole.height > outer.height * 0.45 { return true }
            }
        }
        return false
    }

    static func parse(_ labels: [(String, CGPoint)], progress: PasscodeDotRow? = nil,
                      confirmZero: (CGPoint, CGFloat, CGFloat) -> Bool = { _, _, _ in false }) -> Self? {
        let titles = ["enterpasscode", "enteryourpasscode", "输入密码", "輸入密碼", "请输入密码", "請輸入密碼",
                      "向上轻扫使用面容id或输入密码", "向上滑動以使用faceid或輸入密碼",
                      "swipeupforfaceidorenterpasscode"]
        let normalized = labels.map { ($0.0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), $0.1) }
        let title = normalized.first { titles.contains($0.0.filter { !$0.isWhitespace }) }
        // The initial empty pad always needs its title. During entry the title can
        // change; a filled row then also needs a system action below the keypad.
        if let progress, let title, progress.bottom <= title.1.y { return nil }
        guard let keypadTop = progress?.bottom ?? title?.1.y else { return nil }
        if title == nil && (progress?.filled ?? 0) == 0 { return nil }
        var keys = [Character: CGPoint]()
        for (label, point) in normalized where point.y > keypadTop {
            let parts = label.split(whereSeparator: \.isWhitespace)
            guard let first = parts.first, first.count == 1, let digit = first.first,
                  "0123456789".contains(digit) else { continue }
            guard keys.updateValue(point, forKey: digit) == nil else { return nil }
        }
        // A single digit can be missed while the letters on that same key are legible.
        // Measure the digit-to-letter offset on the current frame before using a letter label.
        let keypadLetters: [String: Character] = ["abc": "2", "def": "3", "ghi": "4", "jkl": "5",
            "mno": "6", "pqrs": "7", "tuv": "8", "wxyz": "9"]
        var letters = [Character: CGPoint]()
        for (label, point) in normalized where point.y > keypadTop {
            if let digit = keypadLetters[label.filter { !$0.isWhitespace }] {
                guard letters.updateValue(point, forKey: digit) == nil else { return nil }
            }
        }
        let offsets = letters.compactMap { digit, point -> CGFloat? in
            guard let number = keys[digit], abs(point.x - number.x) < 0.035,
                  (0.005...0.06).contains(point.y - number.y) else { return nil }
            return point.y - number.y
        }.sorted()
        if offsets.count >= 3 {
            let offset = offsets[offsets.count / 2]
            for (digit, point) in letters where keys[digit] == nil {
                keys[digit] = CGPoint(x: point.x, y: point.y - offset)
            }
        }
        guard keys.count >= 9, let one = keys["1"], let three = keys["3"],
              let seven = keys["7"] else { return nil }
        let dx = (three.x - one.x) / 2, dy = (seven.y - one.y) / 2
        guard dx > 0.04, dy > 0.03 else { return nil }
        if keys["0"] == nil {
            let point = CGPoint(x: one.x + dx, y: one.y + 3 * dy)
            guard confirmZero(point, dx, dy) else { return nil }
            keys["0"] = point
        }
        for (index, digit) in "1234567890".enumerated() {
            let column = digit == "0" ? 1 : index % 3
            guard let point = keys[digit],
                  abs(point.x - one.x - Double(column) * dx) < dx * 0.3,
                  abs(point.y - one.y - Double(index / 3) * dy) < dy * 0.3 else { return nil }
        }
        let cancel = normalized.contains { ["cancel", "取消"].contains($0.0) && $0.1.y >= seven.y }
        let delete = normalized.contains { ["delete", "删除", "刪除"].contains($0.0) && $0.1.y >= seven.y }
        if let progress {
            guard title != nil || cancel != delete else { return nil }
            return Self(keys: keys, isEmpty: progress.filled == 0, progress: progress)
        }
        guard cancel != delete else { return nil }
        return Self(keys: keys, isEmpty: cancel)
    }

    static func unlock(isLocked: () async throws -> Bool,
                       locate: () async throws -> Self?,
                       takePIN: @Sendable () async throws -> String?,
                       tap: (CGPoint) async throws -> Void) async throws -> DeviceUnlockResult {
        guard try await isLocked() else { return .unlocked }
        // Keychain approval can take longer than the lock screen stays awake.
        // Finish it before capturing the frame that supplies the tap positions.
        let pin = try await takePIN()
        let pad = try await locate()
        guard try await isLocked() else { return .unlocked }
        guard let pad, pad.isEmpty, pad.keys.count == 10 else { return .needsUserUnlock }
        guard let pin else { return .needsPasscode }
        guard DeviceSession.validUnlockPIN(pin) else { return .needsUserUnlock }
        if let row = pad.progress, row.count != pin.count { return .needsUserUnlock }
        let points = pin.compactMap { pad.keys[$0] }
        guard points.count == pin.count else { return .needsUserUnlock }

        // Use one contact per digit. Give even repeated taps a distinct up phase.
        for (index, point) in points.enumerated() {
            if index > 0 { try await Task.sleep(for: .milliseconds(25)) }
            try Task.checkCancellation()
            try await tap(point)
        }
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(300))
            if try await !isLocked() { return .unlocked }
        }
        return .unconfirmed
    }
}
