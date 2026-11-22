import AppKit
import CoreGraphics
import ImageIO
import XCTest
@testable import PhoneUseKit

final class PasscodeKeypadTests: XCTestCase {
    private var keypad: [(String, CGPoint)] {
        "1234567890".enumerated().map { i, ch in
            (String(ch), CGPoint(x: 0.3 + Double(ch == "0" ? 1 : i % 3) * 0.2,
                                 y: 0.3 + Double(i / 3) * 0.12))
        }
    }

    func testPhysicalLockStatusPreservesPartialCoreDeviceEvidence() {
        let noPIN = DeviceLockStatus(physicalInfo: ["passcodeRequired": false, "unlockedSinceBoot": true])
        XCTAssertEqual(noPIN.state, .unknown)
        XCTAssertEqual(noPIN.passcodeRequired, false)
        XCTAssertEqual(noPIN.unlockedSinceBoot, true)
        XCTAssertEqual(DeviceLockStatus(physicalInfo: ["passcodeRequired": true]).state, .locked)
        XCTAssertEqual(DeviceLockStatus(physicalInfo: ["unlockedSinceBoot": false]).state, .locked)
        XCTAssertEqual(DeviceLockStatus(physicalInfo: [:]).state, .unknown)
    }

    func testVisionReadsSyntheticPasscodeScreen() throws {
        let size = CGSize(width: 780, height: 1688)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.black.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        let labels = keypad + [("Enter Passcode", CGPoint(x: 0.5, y: 0.16)),
                               ("Cancel", CGPoint(x: 0.8, y: 0.85))]
        for (label, point) in labels {
            let text = NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: label.count == 1 ? 66 : 38),
                .foregroundColor: NSColor.white])
            text.draw(at: CGPoint(x: point.x * size.width - text.size().width / 2,
                                  y: (1 - point.y) * size.height - text.size().height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = try XCTUnwrap(bitmap.cgImage)
        XCTAssertTrue(try XCTUnwrap(PasscodeKeypad.read(image)).isEmpty)
    }

    func testIPhone16NativeAndUSBPasscodeFrames() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/DeviceUnlock")
        func read(_ name: String) throws -> PasscodeKeypad? {
            let url = fixtures.appendingPathComponent(name)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try PasscodeKeypad.read(XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        }
        let pad = try XCTUnwrap(read("iphone16-native.jpg"))
        XCTAssertTrue(pad.isEmpty)
        XCTAssertEqual(Set(pad.keys.keys), Set("0123456789"))
        for (index, digit) in "1234567890".enumerated() {
            let center = try XCTUnwrap(pad.keys[digit])
            let column = digit == "0" ? 1 : index % 3
            XCTAssertEqual(center.x, 0.24 + Double(column) * 0.26, accuracy: 0.03)
            XCTAssertEqual(center.y, 0.38 + Double(index / 3) * 0.11, accuracy: 0.025)
        }
        let faceIDPrompt = try XCTUnwrap(read("iphone16-faceid.jpg"))
        XCTAssertTrue(faceIDPrompt.isEmpty)
        XCTAssertEqual(faceIDPrompt.progress?.count, 6)
        XCTAssertEqual(faceIDPrompt.progress?.filled, 0)
        XCTAssertEqual(Set(faceIDPrompt.keys.keys), Set(pad.keys.keys))
        XCTAssertNil(try read("iphone16-usb.jpg"))
    }

    func testCountsOnlyConsecutiveFilledDotsOnIPhone16Frame() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/DeviceUnlock/iphone16-faceid.jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let original = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: original.width, height: original.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let bounds = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        func draw(_ slots: [Int]) throws -> CGImage {
            context.draw(original, in: bounds)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            for slot in slots {
                let x = 311 + slot * 111
                context.fillEllipse(in: CGRect(x: x - 17, y: original.height - 609 - 17, width: 34, height: 34))
            }
            return try XCTUnwrap(context.makeImage())
        }
        for filled in 0...6 {
            XCTAssertEqual(PasscodeDotRow.read(try draw(Array(0..<filled)))?.filled, filled)
        }
        XCTAssertNil(PasscodeDotRow.read(try draw([1])))
        XCTAssertEqual(try PasscodeKeypad.read(draw([0]))?.isEmpty, false)
        func obscureTitle() {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: bounds.height * 0.79, width: bounds.width, height: bounds.height * 0.05))
        }
        _ = try draw([])
        obscureTitle()
        XCTAssertNil(try PasscodeKeypad.read(XCTUnwrap(context.makeImage())))
        _ = try draw([0])
        obscureTitle()
        XCTAssertEqual(try PasscodeKeypad.read(XCTUnwrap(context.makeImage()))?.progress?.filled, 1)
        context.fill(CGRect(x: 0, y: bounds.height * 0.20, width: bounds.width, height: bounds.height * 0.50))
        XCTAssertNil(try PasscodeKeypad.read(XCTUnwrap(context.makeImage())))
    }

    func testRequiresBothPasscodePromptAndCompleteKeypadGeometry() throws {
        let title = ("输入密码", CGPoint(x: 0.5, y: 0.16))
        let cancel = ("取消", CGPoint(x: 0.8, y: 0.85))
        XCTAssertNil(PasscodeKeypad.parse(keypad + [("Emergency call", title.1), cancel]))
        XCTAssertNil(PasscodeKeypad.parse(Array(keypad.dropLast()) + [title, cancel]))
        XCTAssertNil(PasscodeKeypad.parse(keypad + [keypad[0], title, cancel]))
        var misplaced = keypad
        misplaced[4].1 = .zero
        XCTAssertNil(PasscodeKeypad.parse(misplaced + [title, cancel]))
        XCTAssertTrue(try XCTUnwrap(PasscodeKeypad.parse(keypad + [title, cancel])).isEmpty)
        XCTAssertFalse(try XCTUnwrap(PasscodeKeypad.parse(keypad + [title, ("Delete", cancel.1)])).isEmpty)
        XCTAssertFalse(DeviceSession.validUnlockPIN("１２３４"))
        XCTAssertTrue(DeviceSession.validUnlockPIN("0012"))
    }
}

extension PasscodeKeypadTests {
    private var keys: [Character: CGPoint] {
        Dictionary(uniqueKeysWithValues: keypad.map { (Character($0.0), $0.1) })
    }

    func testSingleFrameForWholePINIncludingRepeatedAndLeadingZeroes() async throws {
        let pad = PasscodeKeypad(keys: keys, isEmpty: true)
        var pressed = [CGPoint](), frames = 0
        let result = try await PasscodeKeypad.unlock(isLocked: {
            XCTAssertTrue(pressed.isEmpty || pressed.count == 6, "No lock queries between digits")
            return pressed.count < 6
        }, locate: {
            frames += 1
            return pad
        }, takePIN: { "001220" }, tap: { pressed.append($0) })
        XCTAssertEqual(frames, 1)
        XCTAssertEqual(pressed, "001220".compactMap { keys[$0] })
        XCTAssertEqual(result, .unlocked)
    }

    func testRefusesPartialPadOrWrongSlotCountBeforeFirstTap() async throws {
        for pad in [PasscodeKeypad(keys: keys, isEmpty: false), PasscodeKeypad(keys: keys, isEmpty: true,
                progress: PasscodeDotRow(count: 6, filled: 0, bottom: 0.23))] {
            let result = try await PasscodeKeypad.unlock(isLocked: { true }, locate: { pad },
                takePIN: { "0123" }, tap: { _ in XCTFail("Unexpected tap") })
            XCTAssertEqual(result, .needsUserUnlock)
        }
    }

    func testInterruptedBurstDoesNotRepeatOrFinishRemainingDigits() async {
        let pad = PasscodeKeypad(keys: keys, isEmpty: true)
        var pressed = [CGPoint]()
        do {
            _ = try await PasscodeKeypad.unlock(isLocked: { true }, locate: { pad },
                takePIN: { "0123" }, tap: { point in
                    pressed.append(point)
                    if pressed.count == 2 { throw CancellationError() }
                })
            XCTFail("Expected interrupted delivery")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(pressed, "01".compactMap { keys[$0] })
    }
}
