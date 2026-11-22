import Foundation
import XCTest
@testable import PhoneUseKit

final class SimulatorTests: XCTestCase {
    func testCreationOptionsKeepCompatibleModelsGroupedByAvailableIOSRuntime() throws {
        let phone = ["identifier": "phone", "name": "Phone", "productFamily": "iPhone"]
        let pad = ["identifier": "pad", "name": "Pad", "productFamily": "iPad"]
        let watch = ["identifier": "watch", "name": "Watch", "productFamily": "Apple Watch"]
        func entry(_ version: String, _ models: [[String: String]], available: Bool = true, platform: String = "iOS") -> [String: Any] {
            ["identifier": "com.apple.CoreSimulator.SimRuntime.\(platform)-\(version)", "name": platform + " " + version,
             "version": version, "isAvailable": available, "supportedDeviceTypes": models]
        }
        let data = try JSONSerialization.data(withJSONObject: ["runtimes": [
            entry("18.9", [phone, pad]), entry("18.10", [pad]), entry("19", [phone], available: false),
            entry("20", [watch]), entry("21", [phone], platform: "watchOS"),
        ]])
        let runtimes = try SimulatorLifecycle.decodeCreationOptions(data)
        XCTAssertEqual(runtimes.map(\.version), ["18.10", "18.9"])
        XCTAssertEqual(runtimes.map { $0.supportedDeviceTypes.map(\.identifier) }, [["pad"], ["phone", "pad"]])
    }

    func testShutdownSimulatorIsAvailableButRequiresAnExplicitStart() throws {
        let shutdown = try decodeDevice(["state": "disconnected", "simulatorState": "Shutdown"])
        XCTAssertFalse(shutdown.isReady)
        XCTAssertFalse(shutdown.isAttached)
        XCTAssertTrue(shutdown.isAvailable)
        XCTAssertTrue(shutdown.canStartSimulator)
        XCTAssertTrue(try decodeDevice(["state": "disconnected", "simulatorState": "Booting"]).canStartSimulator)
        XCTAssertFalse(try decodeDevice(["state": "disconnected", "simulatorState": "Shutting Down"]).canStartSimulator)
        let missing = try decodeDevice(["state": "disconnected"])
        XCTAssertFalse(missing.isAvailable)
        XCTAssertFalse(missing.canStartSimulator)
        XCTAssertFalse(try decodeDevice(["connection": "usb", "state": "disconnected", "simulatorState": "Shutdown"]).canStartSimulator)
    }

    func testStartRejectsPhysicalDevicesAndInvalidIdentifiers() async throws {
        for device in [try decodeDevice(["connection": "usb"]), try decodeDevice(["udid": "simulator:booted"])] {
            do {
                try await SimulatorLifecycle.start(device)
                XCTFail("Must reject invalid targets before running simctl")
            } catch DeviceHubError.capabilityUnavailable { }
        }
    }

    func testSimulatorSummaryIsAppleButNotAPhysicalLink() throws {
        let device = try decodeDevice()
        XCTAssertEqual(device.platform, .ios)
        XCTAssertTrue(device.isSimulator)
        XCTAssertFalse(device.isAndroid)
        XCTAssertFalse(device.isWired)
        XCTAssertEqual(device.deviceIdentifier, "9FE432F2-3B05-481E-843F-CA17089E78E7")
        XCTAssertEqual(device.connectionDescription, "Simulator")
        XCTAssertEqual(device.osDescription, "iOS 27.0")
        XCTAssertEqual(device.modelName, "iPhone 17 Pro")
        XCTAssertEqual(device.platformName, "iPhone")

        let ipad = try decodeDevice(["productType": "iPad Air 11 inch M3"])
        XCTAssertTrue(ipad.isPad)
        XCTAssertEqual(ipad.osDescription, "iPadOS 27.0")

        let physical = try decodeDevice(["udid": "00008150-0014544036F2401C", "connection": "usb"])
        XCTAssertFalse(physical.isSimulator)
        XCTAssertEqual(physical.deviceIdentifier, "00008150-0014544036F2401C")
    }

    func testTouchPhasesUseSimulatorKitMouseEvents() {
        XCTAssertEqual(SimulatorInput.eventType(for: .began), 1)
        XCTAssertEqual(SimulatorInput.eventType(for: .moved), 6)
        XCTAssertEqual(SimulatorInput.eventType(for: .ended), 2)
    }

    func testButtonsFollowSimulatorAppRouting() {
        XCTAssertEqual(SimulatorInput.button(.home), .source(0))
        XCTAssertEqual(SimulatorInput.button(.lock), .source(1))
        XCTAssertEqual(SimulatorInput.button(.volumeUp), .usage(page: 0x0C, code: 0xE9))
        XCTAssertEqual(SimulatorInput.button(.volumeDown), .usage(page: 0x0C, code: 0xEA))
        XCTAssertEqual(SimulatorInput.button(.siri), .usage(page: 0x0C, code: 0xCF))
        XCTAssertNil(SimulatorInput.button(.back))
        XCTAssertNil(SimulatorInput.button(.appSwitch))
        // A long side-button hold does not lock the simulator.
        XCTAssertEqual(SimulatorInput.defaultHold(.lock), .milliseconds(100))
        XCTAssertEqual(SimulatorInput.defaultHold(.siri), .seconds(1))
    }

    func testCoordinatesOutsideTheScreenAreRejected() {
        XCTAssertEqual(try SimulatorInput.coordinate(0), 0)
        XCTAssertEqual(try SimulatorInput.coordinate(1), 1)
        for value in [-0.01, 1.01, .nan, .infinity] {
            XCTAssertThrowsError(try SimulatorInput.coordinate(value))
        }
    }

    /// Read-only check against a booted simulator; set DEVICEHUB_SIMULATOR_UDID to run it.
    func testBootedSimulatorDisplayAndScreenshot() async throws {
        guard let udid = ProcessInfo.processInfo.environment["DEVICEHUB_SIMULATOR_UDID"], !udid.isEmpty else {
            throw XCTSkip("Set DEVICEHUB_SIMULATOR_UDID to a booted simulator to run this check")
        }
        let device = try decodeDevice(["udid": "simulator:\(udid)"])
        let (connection, display) = try await SimulatorDeviceConnection.open(device)
        XCTAssertGreaterThan(display.pixelWidth, 0)
        XCTAssertGreaterThan(display.pointScale, 0)
        let image = try await connection.screenshot()
        XCTAssertEqual(Double(image.width), display.pixelWidth)
        XCTAssertEqual(Double(image.height), display.pixelHeight)
        await connection.close()
    }

    private func decodeDevice(_ overrides: [String: Any] = [:]) throws -> DeviceSummary {
        var values: [String: Any] = [
            "udid": "simulator:9FE432F2-3B05-481E-843F-CA17089E78E7", "platform": "ios", "connection": "simulator",
            "name": "iPhone 17 Pro", "productType": "iPhone 17 Pro", "productVersion": "27.0",
            "state": "ready", "session": "closed",
        ]
        values.merge(overrides) { _, new in new }
        return try JSONDecoder().decode(DeviceSummary.self, from: JSONSerialization.data(withJSONObject: values))
    }
}
