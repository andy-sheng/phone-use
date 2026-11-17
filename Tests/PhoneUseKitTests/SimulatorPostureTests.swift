import Foundation
import IOSurface
import XCTest
@testable import PhoneUseKit

final class SimulatorPostureTests: XCTestCase {
    func testPreviewFollowsBacklightWhenBothPortsRemainPowered() throws {
        let inner = try TestPanel(width: 200, height: 280)
        let cover = try TestPanel(width: 140, height: 200)
        cover.screenProperties.backlight.state = 2
        let display = SimulatorDisplay(panels: [
            .init(descriptor: inner, identifier: "inner"),
            .init(descriptor: cover, identifier: "cover"),
        ])
        defer { display.close() }
        XCTAssertTrue(display.isFoldable)
        XCTAssertEqual(display.identifier, "cover")
        XCTAssertEqual(try display.pixelSize().width, 140)

        cover.screenProperties.backlight.state = -101
        inner.screenProperties.backlight.state = 2
        XCTAssertEqual(display.identifier, "inner")
        XCTAssertEqual(try display.pixelSize().width, 280)

        // Locking the screen must retain the last panel, not jump back to the cover.
        inner.screenProperties.backlight.state = -101
        XCTAssertEqual(display.identifier, "inner")

        // A commanded fold takes precedence over the stale backlight values seen on Duo.
        cover.screenProperties.backlight.state = 2
        display.select(.openFlat)
        XCTAssertEqual(display.identifier, "inner")
        XCTAssertFalse(display.isLive, "Selecting a panel is not evidence of a fresh frame")
        display.select(.closed)
        XCTAssertEqual(display.identifier, "cover")
        display.setOrientation(.landscapeRight)
        XCTAssertEqual(try display.pixelSize().width, 200)
        XCTAssertEqual(try display.pixelSize().height, 140)
        display.select(.openFlat)
        XCTAssertEqual(try display.pixelSize().width, 200)
        XCTAssertEqual(try display.pixelSize().height, 280)
        XCTAssertEqual(display.framebufferOrientation, .portraitUpsideDown)
        XCTAssertEqual(display.orientation, .landscapeRight, "Folding must preserve physical orientation")
    }

    func testSingleScreenDoesNotOfferFolding() throws {
        let panel = try TestPanel(width: 100, height: 200)
        let display = SimulatorDisplay(panels: [.init(descriptor: panel, identifier: "main")])
        defer { display.close() }
        XCTAssertFalse(display.isFoldable)
        XCTAssertEqual(try display.pixelSize().height, 200)
    }

    /// Opt-in integration check. Changes all three hinge states, then restores the original panel.
    func testBootedDuoSwitchesActiveFramebuffers() async throws {
        guard let id = ProcessInfo.processInfo.environment["DEVICEHUB_FOLDABLE_SIMULATOR_UDID"] else {
            throw XCTSkip("Set DEVICEHUB_FOLDABLE_SIMULATOR_UDID to exercise folding")
        }
        let values = ["udid": "simulator:\(id)", "platform": "ios", "connection": "simulator",
                      "name": "Duo", "productType": "iPhone Duo", "state": "ready", "session": "closed"]
        let device = try JSONDecoder().decode(DeviceSummary.self, from: JSONSerialization.data(withJSONObject: values))
        let (connection, original) = try await SimulatorDeviceConnection.open(device)
        XCTAssertTrue(connection.canFold)
        do {
            try await connection.setPosture(.closed)
            let cover = try connection.display.pixelSize()
            let coverID = connection.display.identifier
            try await connection.setPosture(.openFlat)
            let inner = try connection.display.pixelSize()
            XCTAssertNotEqual(connection.display.identifier, coverID)
            XCTAssertGreaterThan(inner.width * inner.height, cover.width * cover.height)
            try await connection.setPosture(.partiallyOpen)
            XCTAssertEqual(try connection.display.pixelSize().width, inner.width)
            let screenshot = try await connection.screenshot()
            XCTAssertEqual(screenshot.width, inner.width)
            XCTAssertEqual(screenshot.height, inner.height)
            try await connection.setPosture(original.pixelWidth == Double(cover.width) ? .closed : .openFlat)
        } catch {
            await connection.close()
            throw error
        }
        await connection.close()
    }
}

private final class TestBacklight: NSObject {
    @objc var state: Int32 = -101
}
private final class TestScreenProperties: NSObject {
    @objc let backlight = TestBacklight()
}
private final class TestPanel: NSObject {
    @objc let screenProperties = TestScreenProperties()
    @objc let framebufferSurface: IOSurface

    init(width: Int, height: Int) throws {
        framebufferSurface = try XCTUnwrap(IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4, .bytesPerRow: width * 4,
            .allocSize: width * height * 4, .pixelFormat: 0x4247_5241,
        ]))
    }
}
