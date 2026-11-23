import Foundation
import PhoneUseKit
import XCTest
@testable import PhoneUseUI

final class AndroidSidebarStatusTests: XCTestCase {
    private func device(state: String = "ready", session: String = "closed",
                        connection: String = "usb") throws -> DeviceSummary {
        let data = try JSONEncoder().encode(["udid": "android:test", "platform": "android", "name": "Test",
                                             "connection": connection, "state": state, "session": session])
        return try JSONDecoder().decode(DeviceSummary.self, from: data)
    }

    func testDiscoveryOverridesPreviousSessionAndPreview() throws {
        for (state, expected) in [("offline", AndroidSidebarStatus.offline), ("unauthorized", .unauthorized),
                                  ("disconnected", .disconnected), ("probing", .probing)] {
            let device = try device(state: state, session: "open")
            let status = AndroidSidebarStatus(device: device, connecting: true, failed: true)
            XCTAssertEqual(status, expected)
            XCTAssertEqual(status.needsAttention, state == "offline" || state == "unauthorized")
            if state == "disconnected" { XCTAssertEqual(status.subtitle(for: device), "已断开连接") }
        }
    }

    func testSessionAndPreviewProgressAreScopedToReadyDevices() throws {
        for (session, expected) in [("closed", AndroidSidebarStatus.ready), ("opening", .connecting),
                                    ("open", .connected), ("failed", .failed)] {
            let device = try device(session: session, connection: "network")
            let status = AndroidSidebarStatus(device: device, connecting: false, failed: false)
            XCTAssertEqual(status, expected)
            XCTAssertEqual(status.subtitle(for: device), "Wi-Fi · " + expected.rawValue)
        }
        let device = try device(session: "failed")
        XCTAssertEqual(AndroidSidebarStatus(device: device, connecting: true, failed: false), .connecting)
        let openDevice = try self.device(session: "open")
        XCTAssertEqual(AndroidSidebarStatus(device: openDevice, connecting: false, failed: true), .failed)
    }
}
