import Foundation
import PhoneUseKit
import XCTest
@testable import PhoneUseUI

@MainActor
final class UIOutlineTests: XCTestCase {
    private func tree(_ label: String) throws -> UITree {
        let data = try JSONSerialization.data(withJSONObject: [
            "elements": [["type": "Button", "label": label, "enabled": true, "depth": 0,
                          "frame": ["x": 0, "y": 0, "width": 100, "height": 44]]],
            "truncated": false, "coordinateSpace": "accessibility-ui-points",
        ])
        return try JSONDecoder().decode(UITree.self, from: data)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for outline state")
    }

    func testPollingIsSequentialAndCancellationStopsFurtherReads() async throws {
        let model = UIOutlineModel(interval: .milliseconds(5))
        let snapshot = try tree("Current")
        var calls = 0, inFlight = 0, maximumInFlight = 0
        let task = Task {
            await model.run(deviceID: "one") {
                calls += 1
                inFlight += 1
                maximumInFlight = max(maximumInFlight, inFlight)
                defer { inFlight -= 1 }
                try await Task.sleep(for: .milliseconds(10))
                return snapshot
            }
        }
        try await waitUntil { calls >= 3 && model.updatedAt != nil }
        task.cancel()
        await task.value
        let finalCalls = calls
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(calls, finalCalls)
        XCTAssertEqual(maximumInFlight, 1)
        XCTAssertTrue(model.outline.contains("Current"))
        XCTAssertFalse(model.isRefreshing)
    }

    func testLateResultFromPreviousDeviceCannotReplaceTheCurrentOutline() async throws {
        let model = UIOutlineModel(interval: .milliseconds(5))
        let oldTree = try tree("Old device"), newTree = try tree("New device")
        var oldReply: CheckedContinuation<UITree?, Never>?
        let old = Task {
            await model.run(deviceID: "old") {
                await withCheckedContinuation { oldReply = $0 }
            }
        }
        try await waitUntil { oldReply != nil }
        let current = Task { await model.run(deviceID: "new") { newTree } }
        try await waitUntil { model.outline.contains("New device") }
        oldReply?.resume(returning: oldTree)
        await old.value
        XCTAssertTrue(model.outline.contains("New device"))
        XCTAssertFalse(model.outline.contains("Old device"))
        current.cancel()
        await current.value
    }

    func testHidingPanelClearsStateAndDiscardsAnUncancellableRead() async throws {
        let model = UIOutlineModel()
        let snapshot = try tree("Late")
        var reply: CheckedContinuation<UITree?, Never>?
        let task = Task {
            await model.run(deviceID: "one") { await withCheckedContinuation { reply = $0 } }
        }
        try await waitUntil { reply != nil }
        model.stop(clear: true)
        reply?.resume(returning: snapshot)
        await task.value
        XCTAssertTrue(model.outline.isEmpty)
        XCTAssertNil(model.updatedAt)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isRefreshing)
    }

    func testTransientFailureIsVisibleAndTheNextSuccessfulReadRecovers() async throws {
        struct Failure: Error {}
        let model = UIOutlineModel(interval: .milliseconds(5))
        let snapshot = try tree("Recovered")
        var recover = false
        let task = Task {
            await model.run(deviceID: "one") {
                if !recover { throw Failure() }
                return snapshot
            }
        }
        try await waitUntil { model.error != nil }
        recover = true
        try await waitUntil { model.outline.contains("Recovered") && model.error == nil }
        task.cancel()
        await task.value
        XCTAssertNotNil(model.updatedAt)
    }

    func testReadingAnUnconnectedPreviewNeverOpensADeviceSession() async throws {
        struct UnexpectedOpen: Error {}
        var opens = 0
        let model = ScreenModel(openSession: { _ in opens += 1; throw UnexpectedOpen() })
        let result = try await model.uiTree(for: "one")
        XCTAssertNil(result)
        XCTAssertEqual(opens, 0)
    }
}
