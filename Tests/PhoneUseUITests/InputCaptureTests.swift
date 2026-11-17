import AppKit
import PhoneUseKit
import XCTest
@testable import PhoneUseUI

@MainActor
final class InputCaptureTests: XCTestCase {
    func testMouseWheelsDoNotSendDeviceTouches() throws {
        let surface = ScreenSurface.SurfaceNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        var touches: [TouchPhase] = []
        surface.onTouch = { phase, _ in touches.append(phase) }

        for unit in [CGScrollEventUnit.line, .pixel] {
            for delta: Int32 in [-10, 10] {
                surface.scrollWheel(with: try wheel(unit: unit, delta: delta))
            }
        }

        XCTAssertTrue(touches.isEmpty)
    }

    func testWheelDoesNotInterruptMouseDrag() throws {
        let surface = ScreenSurface.SurfaceNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        var touches: [TouchPhase] = []
        surface.onTouch = { phase, _ in touches.append(phase) }

        surface.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50)))
        surface.scrollWheel(with: try wheel(unit: .line, delta: 10))
        surface.scrollWheel(with: try wheel(unit: .pixel, delta: -10))
        XCTAssertEqual(touches, [.began])
        surface.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 80, y: 80)))
        surface.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 80, y: 80)))

        XCTAssertEqual(touches, [.began, .moved, .ended])
    }

    private func wheel(unit: CGScrollEventUnit, delta: Int32) throws -> NSEvent {
        let cgEvent = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: unit,
                                          wheelCount: 2, wheel1: delta, wheel2: delta, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        XCTAssertTrue(event.phase.isEmpty)
        XCTAssertEqual(event.hasPreciseScrollingDeltas, unit == .pixel)
        return event
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1))
    }
}
