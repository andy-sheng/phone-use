import Foundation
import XCTest
@testable import PhoneUseKit

final class ConfigurationTests: XCTestCase {
    func testPhoneUseKeepsDeviceHubLocations() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configuration = PhoneUseConfiguration.phoneUse
        XCTAssertEqual(configuration.supportDirectory.path, "\(home)/Library/Application Support/DeviceHub")
        XCTAssertEqual(configuration.logDirectory.path, "\(home)/Library/Logs/DeviceHub")
        XCTAssertEqual(configuration.displayName, "phone-use")
    }

    func testApplicationsGetSeparateDaemonState() {
        let automation = PhoneUseConfiguration.application(identifier: "dev.devicehub.automation", displayName: "automation")
        XCTAssertNotEqual(automation.supportDirectory, PhoneUseConfiguration.phoneUse.supportDirectory)
        XCTAssertTrue(automation.supportDirectory.path.hasSuffix("Application Support/dev.devicehub.automation"))
        XCTAssertTrue(automation.logDirectory.path.hasSuffix("Logs/dev.devicehub.automation"))
    }

    func testHelpersInheritTheParentsIdentity() {
        let parent = PhoneUseConfiguration.application(identifier: "dev.example.parent", displayName: "Parent")
        let inherited = PhoneUseConfiguration.inherited(from: parent.environment)
        XCTAssertEqual(inherited, parent)
        XCTAssertNil(PhoneUseConfiguration.inherited(from: [:]))
    }

    func testInheritedIdentityFillsMissingValues() {
        let inherited = PhoneUseConfiguration.inherited(from: ["DEVICEHUB_HOME": "/tmp/kit-home"])
        XCTAssertEqual(inherited?.logDirectory.path, "/tmp/kit-home/Logs")
        XCTAssertEqual(inherited?.displayName, "kit-home")
    }

    func testSocketLivesInTheSupportDirectory() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["DEVICEHUB_SOCKET"] != nil, "socket overridden")
        let configuration = PhoneUseConfiguration(supportDirectory: URL(fileURLWithPath: "/tmp/kit"),
                                                  logDirectory: URL(fileURLWithPath: "/tmp/kit/Logs"),
                                                  displayName: "Kit")
        XCTAssertEqual(configuration.socketPath, "/tmp/kit/devicehubd.sock")
    }
}
