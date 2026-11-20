import Foundation
import XCTest
@testable import PhoneUseKit

final class WirelessPairingTests: XCTestCase {
    func testNearbyPairingStatusDecodesWithoutPersistedDeviceMetadata() throws {
        let status = try JSONDecoder().decode(WirelessPairingStatus.self, from: Data(#"""
        {"sessionID":"test-session","state":"waiting","hostName":"Test Mac",
         "devices":[{"id":"advertised-identity","name":"Test iPhone"}]}
        """#.utf8))
        XCTAssertTrue(status.isActive)
        XCTAssertEqual(status.devices.first?.id, "advertised-identity")
        XCTAssertNil(status.pairedUDID)
        XCTAssertNil(status.pin)
        XCTAssertNil(status.error)
    }

    func testPairedAndFailedStatusesEndPollingAndDoNotRequireAPin() throws {
        for state in ["paired", "failed", "cancelled"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "sessionID": "test-session", "state": state, "hostName": "Test Mac", "devices": [],
                "pin": NSNull(), "pairedUDID": "test-device",
            ])
            let status = try JSONDecoder().decode(WirelessPairingStatus.self, from: data)
            XCTAssertFalse(status.isActive)
            XCTAssertNil(status.pin)
        }
    }

    func testExpiredWifiPairingAndSystemWifiDecode() throws {
        let data = Data(#"""
        {"udid":"test-device","connection":"usb","name":"Test iPhone","state":"wirelessPairingExpired",
         "session":"failed","wireless":false,"systemWifi":true}
        """#.utf8)
        let device = try JSONDecoder().decode(DeviceSummary.self, from: data)
        XCTAssertEqual(device.state, .wirelessPairingExpired)
        XCTAssertFalse(device.isReady)
        XCTAssertTrue(device.isAttached)
        XCTAssertEqual(device.systemWifi, true)
        let older = try JSONDecoder().decode(DeviceSummary.self, from: Data(#"""
        {"udid":"test-device","connection":"network","name":"Test iPhone","state":"ready","session":"closed"}
        """#.utf8))
        XCTAssertNil(older.systemWifi)
    }

    func testFirstWirelessSessionUsesWorkerVersionForMirrorAndHIDPolicy() throws {
        let data = Data(#"""
        {"udid":"test-device","connection":"network","name":"Test iPhone",
         "productType":"iPhone18,1","state":"ready","session":"closed"}
        """#.utf8)
        let discovered = try JSONDecoder().decode(DeviceSummary.self, from: data)
        XCTAssertEqual(discovered.osMajorVersion, 0)
        let opened = discovered.withProductVersion("27.1")
        XCTAssertEqual(opened.osMajorVersion, 27)
        XCTAssertEqual(opened.osDescription, "iOS 27.1")
        XCTAssertEqual(opened.udid, discovered.udid)
        XCTAssertFalse(opened.isWired)
        XCTAssertEqual(opened.withProductVersion(nil).productVersion, "27.1")
        XCTAssertNil(discovered.productVersion)
    }
}
