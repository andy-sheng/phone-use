import Foundation
import XCTest
@testable import PhoneUseKit

final class DeviceAppInstallationTests: XCTestCase {
    private func device(_ platform: String, _ connection: String) throws -> DeviceSummary {
        let data = try JSONSerialization.data(withJSONObject: [
            "udid": UUID().uuidString, "name": "Test", "platform": platform, "connection": connection,
            "state": "ready", "session": "closed",
        ])
        return try JSONDecoder().decode(DeviceSummary.self, from: data)
    }

    func testFormatFollowsPlatformAndConnection() throws {
        XCTAssertEqual(try device("ios", "network").appPackageExtension, "ipa")
        XCTAssertEqual(try device("ios", "simulator").appPackageExtension, "app")
        XCTAssertEqual(try device("android", "usb").appPackageExtension, "apk")
        XCTAssertEqual(try device("android", "emulator").appPackageExtension, "apk")
    }

    func testDownloadedSimulatorZipResolvesBundleAndRejectsExternalLinks() async throws {
        let files = FileManager.default
        let base = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: base) }
        let app = base.appendingPathComponent("My Simulator.app")
        try files.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: app.appendingPathComponent("Info.plist"))
        let archive = base.appendingPathComponent("build.zip")
        for externalLink in [false, true] {
            if externalLink {
                try files.createSymbolicLink(atPath: app.appendingPathComponent("outside").path,
                                             withDestinationPath: "/etc/hosts")
            }
            _ = try await HostCommand.run("/usr/bin/tar", ["-caf", archive.path, "-C", base.path, app.lastPathComponent])
            let work = base.appendingPathComponent(UUID().uuidString)
            try files.createDirectory(at: work, withIntermediateDirectories: false)
            do {
                let result = try await AppPackageDownload.simulatorApp(in: archive, directory: work)
                XCTAssertFalse(externalLink)
                XCTAssertEqual(try Data(contentsOf: result.appendingPathComponent("Info.plist")), Data("fixture".utf8))
            } catch {
                XCTAssertTrue(externalLink, "\(error)")
                XCTAssertTrue(String(describing: error).contains("outside its bundle"), "\(error)")
            }
        }
    }

    func testSimulatorRejectsDevicePackagesBeforeInvokingSimctl() async throws {
        let simulator = try device("ios", "simulator")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = directory.appendingPathComponent("Game.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let info: [String: Any] = ["CFBundleSupportedPlatforms": ["iPhoneOS"], "CFBundleIdentifier": "test.game"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        for file in [app, directory.appendingPathComponent("Game.ipa")] {
            do {
                try await DeviceHub.shared.installApp(from: file, on: simulator)
                XCTFail("Accepted a physical-device package")
            } catch {
                XCTAssertTrue(String(describing: error).contains("iOS Simulator"), "\(error)")
            }
        }
    }
}
