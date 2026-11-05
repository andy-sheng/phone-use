import CoreGraphics
import Foundation
import XCTest
@testable import DeviceHubKit

final class AndroidDeviceTests: XCTestCase {
    func testOlderDaemonDefaultsToIOS() throws {
        let device = try decodeDevice()
        XCTAssertEqual(device.platform, .ios)
        XCTAssertEqual(device.platformName, "iPhone")
        XCTAssertEqual(device.deviceIcon, "iphone")
        XCTAssertEqual(device.deviceIdentifier, "example-udid")
        XCTAssertEqual(device.osDescription, "iOS 27.0")
        XCTAssertEqual(device.modelName, "iPhone 17 Pro")
        let opened = try JSONDecoder().decode(DaemonClient.OpenedDevice.self,
            from: Data(#"{"udid":"example-udid","services":[]}"#.utf8))
        XCTAssertNil(opened.display)
    }

    func testAndroidSummaryPreservesPlatformAndAuthorizationStates() throws {
        for state in ["unauthorized", "offline", "ready"] {
            let device = try decodeDevice(["platform": "android", "udid": "android:emulator-5554",
                "productType": "Pixel 9", "productVersion": "16", "state": state])
            XCTAssertTrue(device.isAndroid)
            XCTAssertTrue(device.isAttached)
            XCTAssertEqual(device.isReady, state == "ready")
            XCTAssertEqual(device.deviceIdentifier, "emulator-5554")
            XCTAssertEqual(device.platformName, "Android")
            XCTAssertEqual(device.deviceIcon, "candybarphone")
            XCTAssertEqual(device.osDescription, "Android 16")
            XCTAssertEqual(device.modelName, "Pixel 9")
            XCTAssertEqual(try JSONDecoder().decode(DeviceSummary.self, from: JSONEncoder().encode(device)), device)
        }
        let ipad = try decodeDevice(["productType": "iPad14,5"])
        XCTAssertEqual(ipad.platformName, "iPad")
        XCTAssertEqual(ipad.deviceIcon, "ipad")
    }

    func testAndroidOnlyButtonsHaveNoIOSHIDUsage() {
        XCTAssertNil(HardwareButton.back.usage)
        XCTAssertNil(HardwareButton.appSwitch.usage)
        XCTAssertNotNil(HardwareButton.home.usage)
    }

    func testQueuedMovesPreserveTouchBoundaries() {
        let queue = TouchEventQueue(coalesceMoves: true)
        for (phase, x) in [(TouchPhase.began, 0), (.moved, 0.2), (.moved, 0.4), (.ended, 0.4),
                            (.began, 0.5), (.moved, 0.6), (.ended, 0.6)] {
            queue.enqueue(phase, x: x, y: x)
        }
        var events: [QueuedTouch] = []
        while let event = queue.next() { events.append(event) }
        XCTAssertEqual(events.map(\.phase), [.began, .moved, .ended, .began, .moved, .ended])
        XCTAssertEqual(events[1].x, 0.4)
        queue.finish()
        queue.enqueue(.began, x: 0, y: 0)
        XCTAssertNil(queue.next())
    }

    func testIOSQueueDoesNotCoalesceMoves() {
        let queue = TouchEventQueue(coalesceMoves: false)
        queue.enqueue(.moved, x: 0.2, y: 0.2)
        queue.enqueue(.moved, x: 0.4, y: 0.4)
        XCTAssertEqual(queue.next()?.x, 0.2)
        XCTAssertEqual(queue.next()?.x, 0.4)
    }

    func testTouchErrorCallbackCanBeReboundDuringDelivery() {
        let handlers = TouchErrorHandlerBox()
        let first = expectation(description: "original preview receives failure")
        let second = expectation(description: "replacement preview receives failure")
        handlers.handler = { message in
            XCTAssertEqual(message, "inputNotAllowed")
            handlers.handler = { next in
                XCTAssertEqual(next, "disconnected")
                second.fulfill()
            }
            first.fulfill()
        }
        DispatchQueue.global().async {
            handlers.report("inputNotAllowed")
            handlers.report("disconnected")
        }
        wait(for: [first, second], timeout: 2)
        handlers.handler = nil
        XCTAssertNil(handlers.handler)
    }

    func testFailedAndroidGesturePreservesPermissionErrorAndNextGestureCanRetry() async {
        let queue = TouchEventQueue(coalesceMoves: true)
        for phase in [TouchPhase.began, .moved, .moved, .ended, .began, .moved, .ended] {
            queue.enqueue(phase, x: 0.5, y: 0.5)
        }
        let sender = FailingGestureSender()
        let errors = CollectedTouchErrors()
        var delivery = QueuedTouchDelivery(suppressFailedGestures: true) { event in
            try await sender.send(event)
        } reportError: { message in
            errors.append(message)
        }
        while let event = queue.next() { await delivery.deliver(event) }
        let sent = await sender.phases
        XCTAssertEqual(sent, [.began, .ended, .began, .moved, .ended])
        XCTAssertEqual(errors.values, ["Enable USB debugging security settings"])
    }

    func testIOSTouchDeliveryStillReportsEachFailureAndSendsMoves() async {
        let sender = FailingGestureSender()
        let errors = CollectedTouchErrors()
        var delivery = QueuedTouchDelivery(suppressFailedGestures: false) { event in
            try await sender.send(event)
        } reportError: { message in
            errors.append(message)
        }
        for phase in [TouchPhase.began, .moved, .ended] {
            await delivery.deliver(QueuedTouch(phase: phase, x: 0.5, y: 0.5))
        }
        let sent = await sender.phases
        XCTAssertEqual(sent, [.began, .moved, .ended])
        XCTAssertEqual(errors.values, ["Enable USB debugging security settings", "No touch is held"])
    }

    func testInvalidCoordinatesNeverReachDevice() async throws {
        let backend = FakeAndroidBackend()
        let connection = try makeConnection(backend)
        for x in [-0.01, 1.01, Double.nan, Double.infinity] {
            do { try await connection.tap(x: x, y: 0.5); XCTFail("Invalid coordinate accepted") } catch {}
        }
        for y in [-1.0, Double.nan] {
            do { try await connection.sendTouch(.began, x: 0.5, y: y); XCTFail("Invalid coordinate accepted") } catch {}
        }
        let calls = await backend.calls
        XCTAssertTrue(calls.isEmpty)
        try await connection.tap(x: 0, y: 1)
        let boundary = await backend.calls
        XCTAssertEqual(boundary.last?.params, ["x": "0.0", "y": "1.0", "owner": "preview"])
    }

    func testTouchRequestsCarryTheSessionOwner() async throws {
        let backend = FakeAndroidBackend()
        let connection = try makeConnection(backend)
        try await connection.sendTouch(.began, x: 0.5, y: 0.5)
        try await connection.sendTouch(.ended, x: 0.5, y: 0.5)
        try await connection.swipe(fromX: 0, fromY: 0, toX: 1, toY: 1, duration: .milliseconds(100))
        try await connection.press(.home, duration: nil)
        await connection.close()
        let calls = await backend.calls
        XCTAssertEqual(calls.map(\.action), ["touch", "touch", "swipe", "press", "release"])
        XCTAssertEqual(calls.map { $0.params["owner"] }, ["preview", "preview", "preview", nil, "preview"])
    }

    func testGestureIsNotRetriedAfterFailure() async throws {
        let backend = FakeAndroidBackend(fail: true)
        let connection = try makeConnection(backend)
        do {
            try await connection.swipe(fromX: 0, fromY: 0, toX: 1, toY: 1, duration: .milliseconds(250))
            XCTFail("Failure did not propagate")
        } catch {}
        let calls = await backend.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.action, "swipe")
        XCTAssertEqual(calls.first?.params["durationMs"], "250")
    }

    func testInvalidDurationAndSiriDoNotReachAndroid() async throws {
        let backend = FakeAndroidBackend()
        let connection = try makeConnection(backend)
        for duration in [Duration.zero, .milliseconds(-1), .seconds(31)] {
            do {
                try await connection.swipe(fromX: 0, fromY: 0, toX: 1, toY: 1, duration: duration)
                XCTFail("Invalid duration accepted")
            } catch {}
        }
        do { try await connection.press(.siri, duration: nil); XCTFail("Siri accepted on Android") } catch {}
        let calls = await backend.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testDefaultButtonPressDoesNotRequireKeyDownSupport() async throws {
        let backend = FakeAndroidBackend()
        let connection = try makeConnection(backend)
        try await connection.press(.back, duration: nil)
        try await connection.press(.home, duration: .milliseconds(500))
        let calls = await backend.calls
        XCTAssertEqual(calls[0].params, ["button": "back"])
        XCTAssertEqual(calls[1].params, ["button": "home", "durationMs": "500"])
    }

    func testRotationStopsInputButStillAllowsRelease() async throws {
        let backend = try imageBackend(width: 3, height: 2)
        let connection = try makeConnection(backend)
        do { _ = try await connection.screenshot(); XCTFail("Rotated screenshot accepted") } catch {}
        do { try await connection.tap(x: 0.5, y: 0.5); XCTFail("Input after rotation accepted") } catch {}
        try await connection.sendTouch(.ended, x: .nan, y: .nan)
        await connection.close()
        let calls = await backend.calls
        XCTAssertEqual(calls.map(\.action), ["screenshot", "touch", "release"])
        XCTAssertEqual(calls[1].params["phase"], "ended")
    }

    func testScreenshotKeepsNativeDimensions() async throws {
        let connection = try makeConnection(imageBackend(width: 2, height: 3))
        let image = try await connection.screenshot()
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 3)
    }

    private func decodeDevice(_ overrides: [String: Any] = [:]) throws -> DeviceSummary {
        var values: [String: Any] = ["udid": "example-udid", "connection": "usb", "name": "Test phone",
            "productType": "iPhone18,1", "productVersion": "27.0", "state": "ready", "session": "closed"]
        values.merge(overrides) { _, new in new }
        return try JSONDecoder().decode(DeviceSummary.self, from: JSONSerialization.data(withJSONObject: values))
    }

    private func makeConnection(_ backend: FakeAndroidBackend) throws -> AndroidDeviceConnection {
        try AndroidDeviceConnection(display: DisplayInfo(pixelWidth: 2, pixelHeight: 3, pointScale: 1),
                                    owner: "preview") { action, params in
            try await backend.request(action: action, params: params)
        }
    }

    private func imageBackend(width: Int, height: Int) throws -> FakeAndroidBackend {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let png = try XCTUnwrap(ImageEncoding.png(image))
        let response = try JSONSerialization.data(withJSONObject: ["png": png.base64EncodedString(), "width": width, "height": height])
        return FakeAndroidBackend(response: response)
    }
}

private actor FakeAndroidBackend {
    struct Call: Sendable { let action: String; let params: [String: String] }
    enum Failure: Error { case disconnected }
    private(set) var calls: [Call] = []
    private let fail: Bool
    private let response: Data

    init(fail: Bool = false, response: Data = Data("{}".utf8)) {
        self.fail = fail
        self.response = response
    }

    func request(action: String, params: [String: String]) throws -> Data {
        calls.append(Call(action: action, params: params))
        if fail { throw Failure.disconnected }
        return response
    }
}

private actor FailingGestureSender {
    private(set) var phases: [TouchPhase] = []
    private var rejectedBegin = false
    private var rejectedEnd = false

    func send(_ event: QueuedTouch) throws {
        phases.append(event.phase)
        if event.phase == .began && !rejectedBegin {
            rejectedBegin = true
            throw DeviceHubError.daemon(code: "inputNotAllowed", message: "Enable USB debugging security settings")
        }
        if event.phase == .ended && !rejectedEnd {
            rejectedEnd = true
            throw DeviceHubError.daemon(code: "invalidState", message: "No touch is held")
        }
    }
}

private final class CollectedTouchErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}
