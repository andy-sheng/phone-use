import DeviceHubKit
import Foundation
import XCTest
@testable import DeviceHubApp

@MainActor
final class ScreenConnectionTests: XCTestCase {
    private enum Failure: Error { case unavailable }

    private func device(_ id: String = "first", state: String = "ready", connection: String = "network") throws -> DeviceSummary {
        let data = try JSONSerialization.data(withJSONObject: [
            "udid": id, "connection": connection, "name": "Test Device",
            "productVersion": "27.2", "state": state, "session": "closed",
        ])
        return try JSONDecoder().decode(DeviceSummary.self, from: data)
    }

    func testSelectionAndDiscoveryUpdatesNeverPrepareOrOpenAnUnrequestedDevice() async throws {
        var preparations = 0
        var opens = 0
        let model = ScreenModel(prepareSession: { _ in preparations += 1 }, openSession: { _ in
            opens += 1
            throw Failure.unavailable
        }, connectionAttempts: 1)

        await model.run(device: try device())
        await model.run(device: try device(connection: "usb"))
        model.selectionChanged(to: "second")
        await model.run(device: try device("second"))
        await model.run(device: nil)

        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(opens, 0)
        XCTAssertFalse(model.isConnecting)
        XCTAssertNil(model.status)
        XCTAssertNil(model.stream)
    }

    func testConnectButtonOnlyRequestsReadyDevicesAndDoesNotOpenUntilItsViewTaskRuns() throws {
        let model = ScreenModel(openSession: { _ in XCTFail("A button request alone must not open a session"); throw Failure.unavailable })
        model.requestConnection(to: try device(state: "untrusted"))
        XCTAssertNil(model.requestedDeviceID)
        XCTAssertEqual(model.reconnectGeneration, 0)

        model.requestConnection(to: try device())
        XCTAssertEqual(model.requestedDeviceID, "first")
        XCTAssertEqual(model.reconnectGeneration, 1)
    }

    func testAlreadyCancelledViewTaskNeverPreparesOrOpensTheRequestedDevice() async throws {
        var preparations = 0
        var opens = 0
        let model = ScreenModel(prepareSession: { _ in preparations += 1 }, openSession: { _ in
            opens += 1
            throw Failure.unavailable
        }, connectionAttempts: 1)
        let target = try device()
        model.requestConnection(to: target)
        let task = Task { await model.run(device: target) }
        task.cancel()
        await task.value
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(opens, 0)
        XCTAssertFalse(model.isConnecting)
        XCTAssertNil(model.status)
    }

    func testFailedConnectionStopsLoadingAndAnExplicitRetryStartsANewAttempt() async throws {
        var preparations = 0
        var opens = 0
        let model = ScreenModel(prepareSession: { _ in preparations += 1 }, openSession: { _ in
            opens += 1
            throw Failure.unavailable
        }, connectionAttempts: 1)
        let target = try device()
        model.requestConnection(to: target)
        let firstGeneration = model.reconnectGeneration
        await model.run(device: target)
        XCTAssertFalse(model.isConnecting)
        XCTAssertNil(model.status)
        XCTAssertNotNil(model.connectionError)
        XCTAssertEqual(opens, 1)

        model.requestConnection(to: target)
        XCTAssertGreaterThan(model.reconnectGeneration, firstGeneration)
        await model.run(device: target)
        XCTAssertEqual(opens, 2)
        XCTAssertEqual(preparations, 2)
        XCTAssertFalse(model.isConnecting)
    }

    func testSwitchingAwayAndBackRequiresAnotherConnectClick() async throws {
        var opens = 0
        let model = ScreenModel(prepareSession: { _ in }, openSession: { _ in
            opens += 1
            throw Failure.unavailable
        }, connectionAttempts: 1)
        let first = try device()
        let second = try device("second")
        model.requestConnection(to: first)
        model.selectionChanged(to: second.id)
        await model.run(device: second)
        model.selectionChanged(to: first.id)
        await model.run(device: first)
        XCTAssertNil(model.requestedDeviceID)
        XCTAssertEqual(opens, 0)

        model.requestConnection(to: second)
        model.selectionChanged(to: nil)
        await model.run(device: nil)
        XCTAssertNil(model.requestedDeviceID)
        XCTAssertEqual(opens, 0)
    }

    func testTransientReadinessChangeKeepsTheSameExplicitRequest() async throws {
        var opens = 0
        let model = ScreenModel(prepareSession: { _ in }, openSession: { _ in
            opens += 1
            throw Failure.unavailable
        }, connectionAttempts: 1)
        model.requestConnection(to: try device())
        model.selectionChanged(to: "first")
        await model.run(device: try device(state: "disconnected"))
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(model.requestedDeviceID, "first")
        await model.run(device: try device())
        XCTAssertEqual(opens, 1)
    }

    func testRepeatedClickWhileConnectingDoesNotScheduleAnotherSession() async throws {
        var resumeOpen: CheckedContinuation<Void, Never>?
        let started = expectation(description: "Opening requested device")
        var opens = 0
        let model = ScreenModel(prepareSession: { _ in }, openSession: { _ in
            opens += 1
            await withCheckedContinuation { resumeOpen = $0; started.fulfill() }
            throw Failure.unavailable
        }, connectionAttempts: 1)
        let target = try device()
        model.requestConnection(to: target)
        let generation = model.reconnectGeneration
        let task = Task { await model.run(device: target) }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(model.isConnecting)
        model.requestConnection(to: target)
        XCTAssertEqual(model.reconnectGeneration, generation)
        XCTAssertEqual(opens, 1)
        resumeOpen?.resume()
        await task.value
    }

    func testCancelClearsIntentAndLateFailureCannotReplaceTheIdleScreen() async throws {
        var resumeOpen: CheckedContinuation<Void, Never>?
        let started = expectation(description: "Opening requested device")
        let model = ScreenModel(prepareSession: { _ in }, openSession: { _ in
            await withCheckedContinuation { resumeOpen = $0; started.fulfill() }
            throw Failure.unavailable
        }, connectionAttempts: 1)
        let target = try device()
        model.requestConnection(to: target)
        let task = Task { await model.run(device: target) }
        await fulfillment(of: [started], timeout: 1)
        model.cancelConnection()
        task.cancel()
        await model.run(device: target)
        resumeOpen?.resume()
        await task.value
        XCTAssertNil(model.requestedDeviceID)
        XCTAssertNil(model.connectionError)
        XCTAssertNil(model.status)
        XCTAssertFalse(model.isConnecting)
    }

    func testCancelDuringPreparationPreventsOpenBeforeViewTaskCancellationArrives() async throws {
        var resumePreparation: CheckedContinuation<Void, Never>?
        let preparing = expectation(description: "Preparing explicitly requested device")
        var opens = 0
        let model = ScreenModel(prepareSession: { _ in
            await withCheckedContinuation { resumePreparation = $0; preparing.fulfill() }
        }, openSession: { _ in
            opens += 1
            throw Failure.unavailable
        }, connectionAttempts: 1)
        let target = try device()
        model.requestConnection(to: target)
        let task = Task { await model.run(device: target) }
        await fulfillment(of: [preparing], timeout: 1)
        model.cancelConnection()
        // The model must honor cancellation immediately, even before SwiftUI
        // has reconciled the task's changed identity and cancelled that Task.
        resumePreparation?.resume()
        await task.value
        XCTAssertEqual(opens, 0)
        XCTAssertFalse(model.isConnecting)
        XCTAssertNil(model.connectionError)
    }

    func testLateFailureFromPreviousDeviceDoesNotOverwriteNewDeviceState() async throws {
        var resumeOpen: CheckedContinuation<Void, Never>?
        let started = expectation(description: "Opening first device")
        let model = ScreenModel(prepareSession: { _ in }, openSession: { _ in
            await withCheckedContinuation { resumeOpen = $0; started.fulfill() }
            throw Failure.unavailable
        }, connectionAttempts: 1)
        let first = try device()
        let second = try device("second")
        model.requestConnection(to: first)
        let task = Task { await model.run(device: first) }
        await fulfillment(of: [started], timeout: 1)
        model.selectionChanged(to: second.id)
        await model.run(device: second)
        resumeOpen?.resume()
        await task.value
        XCTAssertTrue(model.isShowingDevice(second.id))
        XCTAssertFalse(model.isConnecting)
        XCTAssertNil(model.connectionError)
        XCTAssertNil(model.status)
    }
}
