import XCTest
@testable import PhoneUseKit

final class IOSDeviceManagementTests: XCTestCase {
    private let id = "00000000-0123456789ABCDEF"

    func testActionsRequireBothTheCommandAndSelectedDeviceCapability() {
        let device: [String: Any] = [
            "properties": ["hardware": ["udid": id.lowercased()]],
            "capabilities": ["rebootdevice", "renamedevice", "filesystemoperation", "unpairdevice"].map {
                ["featureIdentifier": "com.apple.coredevice.feature.\($0)"]
            },
        ]
        let inventory = ["devices": [device]]
        let deviceHelp = "SUBCOMMANDS:\n  reboot  Reboot a device.\n  sysdiagnose  Gather a sysdiagnose."
        let infoHelp = "SUBCOMMANDS:\n  mountpoint  Get the mount point.\n  apps  List apps.\n  files  List files."
        let manageHelp = "SUBCOMMANDS:\n  unpair  Unpair a device."

        XCTAssertEqual(IOSDeviceManagement.actions(for: id, isReady: true, inventory: inventory,
            deviceHelp: deviceHelp, infoHelp: infoHelp, manageHelp: manageHelp),
            [.restart, .showInFinder, .browseSandbox, .unpair])
        XCTAssertEqual(IOSDeviceManagement.actions(for: id, isReady: false, inventory: inventory,
            deviceHelp: deviceHelp, infoHelp: infoHelp, manageHelp: manageHelp), [.unpair])
        XCTAssertEqual(IOSDeviceManagement.actions(for: id, isReady: true, inventory: inventory,
            deviceHelp: deviceHelp, infoHelp: "SUBCOMMANDS:\n  apps  List apps.", manageHelp: ""), [.restart])
        XCTAssertTrue(IOSDeviceManagement.actions(for: id, isReady: true, inventory: inventory,
            deviceHelp: "", infoHelp: "", manageHelp: "").isEmpty)
        XCTAssertTrue(IOSDeviceManagement.actions(for: "unknown-device", isReady: true, inventory: inventory,
            deviceHelp: deviceHelp, infoHelp: infoHelp, manageHelp: manageHelp).isEmpty)
    }
}
