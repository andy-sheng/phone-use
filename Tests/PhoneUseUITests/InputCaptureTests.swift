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
        try sendHorizontalWheelGesture(to: surface)
        XCTAssertEqual(touches, [.began])
        surface.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 80, y: 80)))
        surface.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 80, y: 80)))

        XCTAssertEqual(touches, [.began, .moved, .ended])
    }

    func testPhasedHorizontalWheelDoesNotSwipeDevice() throws {
        let surface = ScreenSurface.SurfaceNSView()
        surface.onTouch = { phase, _ in XCTFail("Horizontal wheel sent \(phase)") }
        try sendHorizontalWheelGesture(to: surface)
    }

    func testTwoFingerPanIgnoresWheelWhileFingersAreDown() throws {
        let surface = ScreenSurface.SurfaceNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        var phases: [TouchPhase] = []
        var points: [CGPoint] = []
        surface.onTouch = { phase, point in
            phases.append(phase)
            points.append(point)
        }

        let event = TwoFingerEvent()
        surface.touchesBegan(with: event)
        try sendHorizontalWheelGesture(to: surface)
        surface.touchesMoved(with: event)
        XCTAssertTrue(phases.isEmpty)

        event.offset = CGPoint(x: 0.1, y: -0.2)
        surface.touchesMoved(with: event)
        try sendHorizontalWheelGesture(to: surface)
        surface.touchesCancelled(with: event)
        surface.touchesEnded(with: event)
        XCTAssertEqual(phases, [.began, .moved, .ended])
        guard points.count == 3 else { return }
        XCTAssertEqual(points[1].x - points[0].x, 0.1, accuracy: 0.0001)
        XCTAssertEqual(points[1].y - points[0].y, 0.05, accuracy: 0.0001)
        XCTAssertEqual(points[2], points[1])
    }

    private func sendHorizontalWheelGesture(to surface: ScreenSurface.SurfaceNSView) throws {
        for phase in [CGScrollPhase.began, .changed, .ended] {
            let event = try wheel(unit: .pixel, delta: 0, horizontal: -12, phase: phase)
            XCTAssertFalse(event.phase.isEmpty)
            XCTAssertNotEqual(event.scrollingDeltaX, 0)
            XCTAssertEqual(event.scrollingDeltaY, 0)
            surface.scrollWheel(with: event)
        }
    }

    private func wheel(unit: CGScrollEventUnit, delta: Int32, horizontal: Int32? = nil,
                       phase: CGScrollPhase? = nil) throws -> NSEvent {
        let cgEvent = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: unit,
                                          wheelCount: 2, wheel1: delta, wheel2: horizontal ?? delta, wheel3: 0))
        if let phase {
            cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        XCTAssertEqual(event.hasPreciseScrollingDeltas, unit == .pixel)
        return event
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1))
    }
}

private final class TwoFingerEvent: NSEvent, @unchecked Sendable {
    var offset = CGPoint.zero
    override var locationInWindow: NSPoint { CGPoint(x: 100, y: 200) }

    override func touches(matching phase: NSTouch.Phase, in view: NSView?) -> Set<NSTouch> {
        Set([0.25, 0.75].map { x -> NSTouch in
            let touch = TrackpadTouch()
            touch.position = CGPoint(x: x + offset.x, y: 0.5 + offset.y)
            return touch
        })
    }
}

private final class TrackpadTouch: NSTouch, @unchecked Sendable {
    var position = CGPoint.zero
    override var normalizedPosition: NSPoint { position }
    override var deviceSize: NSSize { CGSize(width: 200, height: 100) }
}
