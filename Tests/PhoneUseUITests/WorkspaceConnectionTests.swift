import Foundation
import XCTest
import PhoneUseKit
@testable import PhoneUseUI

@MainActor
final class WorkspaceConnectionTests: XCTestCase {
    private func device(_ id: String, state: String = "ready") throws -> DeviceSummary {
        try JSONDecoder().decode(DeviceSummary.self, from: JSONSerialization.data(withJSONObject: [
            "udid": id, "name": id, "connection": "usb", "state": state, "session": "closed"
        ]))
    }

    func testSelectionDoesNotConnectAndSuccessfulConnectionQueuesOnePreview() async throws {
        var opened: [String] = []
        let model = DeviceListModel(connectSession: { opened.append($0.id) })
        let target = try device("one")
        model.selectDevice(target)
        XCTAssertEqual(model.selectedDevice?.id, "one")
        XCTAssertTrue(opened.isEmpty)
        XCTAssertNil(model.previewRequest)
        try await model.connectDevice(target)
        XCTAssertEqual(opened, ["one"])
        XCTAssertEqual(model.previewRequest, "one", "Retain while no view exists")
        XCTAssertEqual(model.consumePreviewRequest()?.id, "one")
        XCTAssertNil(model.consumePreviewRequest())
    }

    func testDiscoveryDoesNotReplaceMissingSelectedDevice() throws {
        let model = DeviceListModel(connectSession: { _ in XCTFail("Discovery must not connect") })
        let first = try device("one")
        let second = try device("two")
        model.selectDevice(first)
        model.apply([second])
        XCTAssertEqual(model.selection, "one")
        XCTAssertNil(model.selectedDevice)
        model.apply([second, first])
        XCTAssertEqual(model.selectedDevice?.id, "one")
    }

    func testUnreadyAndFailedConnectionsNeverQueuePreview() async throws {
        var opens = 0
        let model = DeviceListModel(connectSession: { _ in opens += 1; throw DeviceHubError.connectionClosed })
        do { try await model.connectDevice(device("untrusted", state: "untrusted")); XCTFail("must reject") }
        catch {}
        XCTAssertEqual(opens, 0)
        do { try await model.connectDevice(device("ready")); XCTFail("must fail") }
        catch {}
        XCTAssertEqual(opens, 1)
        XCTAssertNil(model.previewRequest)
    }

    func testChangingSelectionDuringConnectDoesNotRevertUIOrStartOldPreview() async throws {
        let started = expectation(description: "connection started")
        var resume: CheckedContinuation<Void, Never>?
        let model = DeviceListModel(connectSession: { _ in
            await withCheckedContinuation { continuation in resume = continuation; started.fulfill() }
        })
        let first = try device("one")
        let second = try device("two")
        let task = Task { try await model.connectDevice(first) }
        await fulfillment(of: [started], timeout: 2)
        model.selectDevice(second)
        resume?.resume()
        do { try await task.value; XCTFail("superseded selection must fail") } catch {}
        XCTAssertEqual(model.selection, "two")
        XCTAssertNil(model.previewRequest)
    }

    func testConcurrentConnectsToSameDeviceShareAnOpen() async throws {
        let started = expectation(description: "connection started")
        var resume: CheckedContinuation<Void, Never>?
        var opens = 0
        let model = DeviceListModel(connectSession: { _ in
            opens += 1
            guard opens == 1 else { XCTFail("Must reuse in-flight connection"); return }
            await withCheckedContinuation { continuation in resume = continuation; started.fulfill() }
        })
        let target = try device("one")
        let first = Task { try await model.connectDevice(target) }
        await fulfillment(of: [started], timeout: 2)
        let joined = expectation(description: "second caller joined")
        let second = Task {
            joined.fulfill()
            try await model.connectDevice(target)
        }
        await fulfillment(of: [joined], timeout: 2)
        resume?.resume()
        try await first.value
        try await second.value
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(model.previewRequest, "one")
    }
}
