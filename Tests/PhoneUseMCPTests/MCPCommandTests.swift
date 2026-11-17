import CoreGraphics
import Foundation
import XCTest
@testable import PhoneUseMCP
import PhoneUseKit

private func testDevice(_ id: String = "simulator:one", name: String = "iPhone", platform: String = "ios", connection: String = "simulator") throws -> DeviceSummary {
    try JSONDecoder().decode(DeviceSummary.self, from: JSONSerialization.data(withJSONObject: [
        "udid": id, "name": name, "platform": platform, "connection": connection, "state": "ready", "session": "open",
    ]))
}

private final class TestSession: MCPDeviceSession, @unchecked Sendable {
    let device: DeviceSummary
    let display: DisplayInfo
    let lock = NSLock()
    private var events: [String] = []
    var calls: [String] { lock.withLock { events } }
    var failCapture = false

    init(device: DeviceSummary? = nil, width: Double = 400, height: Double = 800, scale: Double = 1) throws {
        self.device = try device ?? testDevice()
        display = try JSONDecoder().decode(DisplayInfo.self, from: JSONSerialization.data(withJSONObject: [
            "pixelWidth": width, "pixelHeight": height, "pointScale": scale,
        ]))
    }
    private func append(_ value: String) { lock.withLock { events.append(value) } }
    func screenshot() async throws -> CGImage {
        append("screenshot")
        if failCapture { throw DeviceHubError.serviceFailed("capture failed") }
        return CGContext(data: nil, width: 4, height: 8, bitsPerComponent: 8, bytesPerRow: 16,
                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
    func tap(x: Double, y: Double) async throws { append("tap \(x),\(y)") }
    func longPress(x: Double, y: Double, duration: Duration) async throws { append("hold \(x),\(y) \(duration)") }
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Duration) async throws {
        append("swipe \(fromX),\(fromY) \(toX),\(toY) \(duration)")
    }
    func press(_ button: HardwareButton, duration: Duration?) async throws { append("button \(button.rawValue)") }
    func launchApp(bundleID: String) async throws { append("launch \(bundleID)") }
    func uiTree() async throws -> UITree {
        append("tree")
        return try JSONDecoder().decode(UITree.self, from: Data(#"{"elements":[],"truncated":false,"coordinateSpace":"accessibility-ui-points"}"#.utf8))
    }
    func activate(_ selector: UISelector) async throws { append("activate \(selector.id ?? selector.label ?? "substring")") }
    func typeText(_ text: String, target: UISelector?) async throws { append("type \(text) \(target?.id ?? "focused")") }
}

final class MCPCommandTests: XCTestCase {
    private func access(_ session: TestSession) -> MCPDeviceAccess {
        MCPDeviceAccess(devices: { [session.device] }, session: { _ in session })
    }
    private func request(_ tool: String, _ arguments: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": arguments]]
    }
    private func result(_ tool: String, _ arguments: [String: Any], session: TestSession) async throws -> [String: Any] {
        let reply = await MCPServer.handle(request(tool, arguments), access: access(session))
        return try XCTUnwrap(reply?["result"] as? [String: Any])
    }

    func testCatalogAndLegacyAliases() throws {
        let reply = MCPServer.localReply(to: ["id": 1, "method": "tools/list"])!
        let tools = (reply["result"] as! [String: Any])["tools"] as! [[String: Any]]
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertEqual(names, ["list_devices", "screenshot", "describe_ui", "tap", "long_press", "swipe", "gesture", "button", "launch_app", "type_text"])
        XCTAssertNotNil(MCPServer.encode(reply), "every schema must remain JSON serializable")
        for name in ["get_screen", "press_button", "ui", "snapshot_ui"] {
            XCTAssertNoThrow(try MCPCommand(name: name, arguments: name == "press_button" ? ["button": "home"] : [:]))
        }
    }

    func testInvalidArgumentsAreRejectedBeforePreparingOrOpeningDevices() async throws {
        let session = try TestSession()
        let invalid: [(String, [String: Any])] = [
            ("tap", ["x": true, "y": 20]), ("tap", ["x": Double.nan, "y": 20]),
            ("tap", ["x": "2", "y": 20]), ("tap", ["x": 2, "y": 20, "device": 7]),
            ("tap", ["x": 2, "y": 20, "return_screen": 1]),
            ("tap", ["x": 2, "y": 20, "post_delay": -1]),
            ("tap", ["x": 2, "y": 20, "duraton": 1]),
            ("tap", ["x": 2, "y": 20, "id": "save"]),
            ("tap", ["label": "Save", "id": "save"]),
            ("long_press", ["x": 2, "y": 20, "duration": 0]),
            ("long_press", ["x": 2, "y": 20, "duration": 0.8, "duration_ms": 800]),
            ("long_press", ["x": 2, "y": 20, "duration_ms": "bad"]),
            ("long_press", ["x": 2, "y": 20, "duration_ms": 1.5]),
            ("gesture", ["preset": "pinch-in"]),
            ("swipe", ["start_x": 2, "start_y": 20, "to_x": 10, "to_y": 100]),
            ("type_text", ["text": "abc中文"]), ("type_text", ["text": ""]),
        ]
        for (tool, args) in invalid {
            let reply = await MCPServer.handle(request(tool, args), prepare: { XCTFail("must validate first") }, access: access(session))
            XCTAssertEqual((reply?["result"] as? [String: Any])?["isError"] as? Bool, true, "\(tool) \(args)")
        }
        XCTAssertTrue(session.calls.isEmpty)
    }

    func testCoordinateConversionsAndLegacyDurations() async throws {
        let session = try TestSession(width: 1200, height: 2400, scale: 3)
        _ = try await result("tap", ["x": 200, "y": 400], session: session)
        _ = try await result("long_press", ["x": 100, "y": 200, "duration_ms": 800], session: session)
        _ = try await result("swipe", ["from_x": 200, "from_y": 640, "to_x": 200, "to_y": 160, "duration_ms": 300], session: session)
        _ = try await result("swipe", ["start_x": 200, "start_y": 640, "end_x": 200, "end_y": 160, "duration": 0.3], session: session)
        XCTAssertEqual(session.calls[0], "tap 0.5,0.5")
        XCTAssertEqual(session.calls[1], "hold 0.25,0.25 0.8 seconds")
        XCTAssertEqual(session.calls[2], session.calls[3])
        let bad = try await result("swipe", ["start_x": 200, "start_y": 640, "end_x": 401, "end_y": 160], session: session)
        XCTAssertEqual(bad["isError"] as? Bool, true)
        XCTAssertEqual(session.calls.count, 4, "reject both endpoints before sending any touch")
    }

    func testAndroidCoordinatesArePixelsAndPlatformButtonsAreChecked() async throws {
        let session = try TestSession(device: testDevice("android:one", platform: "android", connection: "usb"), width: 1000, height: 2000, scale: 2)
        _ = try await result("tap", ["x": 500, "y": 1000], session: session)
        let shot = try await result("get_screen", [:], session: session)
        let metadata = try XCTUnwrap(shot["structuredContent"] as? [String: Any])
        XCTAssertEqual(metadata["unit"] as? String, "pixels")
        XCTAssertEqual(metadata["width"] as? Double, 1000)
        XCTAssertEqual(session.calls.first, "tap 0.5,0.5")
        _ = try await result("button", ["button": "recents"], session: session)
        XCTAssertEqual(session.calls.last, "button app_switch")
        let bad = try await result("button", ["button": "siri"], session: session)
        XCTAssertEqual(bad["isError"] as? Bool, true)
        let ui = try await result("describe_ui", [:], session: session)
        XCTAssertEqual(ui["isError"] as? Bool, true)
    }

    func testGesturesSelectorsAndTextReachTheSharedSession() async throws {
        let session = try TestSession()
        _ = try await result("gesture", ["preset": "scroll-up"], session: session)
        _ = try await result("gesture", ["preset": "swipe-from-bottom-edge"], session: session)
        _ = try await result("tap", ["id": "save"], session: session)
        _ = try await result("type_text", ["text": "Hello!", "id": "name"], session: session)
        _ = try await result("snapshot_ui", [:], session: session)
        XCTAssertEqual(session.calls, ["swipe 0.5,0.8 0.5,0.2 0.5 seconds", "swipe 0.5,1.0 0.5,0.3 0.3 seconds", "activate save", "type Hello! name", "tree"])
    }

    func testAmbiguousDeviceSelectionNeverOpensASession() async throws {
        let devices = [try testDevice("one", name: "iPhone A"), try testDevice("two", name: "iPhone B")]
        XCTAssertThrowsError(try MCPCommand.resolve(nil, in: devices))
        XCTAssertThrowsError(try MCPCommand.resolve("iPhone", in: devices))
        XCTAssertEqual(try MCPCommand.resolve("two", in: devices).udid, "two")
        let access = MCPDeviceAccess(devices: { devices }, session: { _ in XCTFail("must resolve first"); throw DeviceHubError.connectionClosed })
        let reply = await MCPServer.handle(request("screenshot", [:]), access: access)
        XCTAssertEqual((reply?["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    func testFailedFollowupCaptureDoesNotTurnDeliveredActionIntoAToolFailure() async throws {
        let session = try TestSession()
        session.failCapture = true
        let output = try await result("tap", ["x": 20, "y": 30, "return_screen": true], session: session)
        XCTAssertNil(output["isError"])
        XCTAssertEqual((output["structuredContent"] as? [String: Any])?["input_sent"] as? Bool, true)
        XCTAssertNotNil((output["structuredContent"] as? [String: Any])?["screenshot_error"])
        XCTAssertEqual(session.calls, ["tap 0.05,0.0375", "screenshot"])
    }
}
