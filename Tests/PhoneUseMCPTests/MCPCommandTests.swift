import CoreGraphics
import Foundation
import XCTest
@testable import PhoneUseMCP
import PhoneUseKit

private func testDevice(_ id: String = "simulator:one", name: String = "iPhone", platform: String = "ios", connection: String = "simulator", version: String = "", state: String = "ready") throws -> DeviceSummary {
    try JSONDecoder().decode(DeviceSummary.self, from: JSONSerialization.data(withJSONObject: [
        "productVersion": version, "udid": id, "name": name, "platform": platform, "connection": connection, "state": state, "session": "open",
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
        XCTAssertEqual(names, ["select_device", "connect_device", "get_web_preview", "list_devices", "screenshot", "describe_ui", "tap", "long_press", "swipe", "gesture", "button", "launch_app", "type_text", "list_apps", "list_sandbox_files", "read_sandbox_file", "download_sandbox_file"])
        XCTAssertNotNil(MCPServer.encode(reply), "every schema must remain JSON serializable")
        for name in ["get_screen", "press_button", "ui", "snapshot_ui"] {
            XCTAssertNoThrow(try MCPCommand(name: name, arguments: name == "press_button" ? ["button": "home"] : [:]))
        }
    }

    func testInvalidArgumentsAreRejectedBeforePreparingOrOpeningDevices() async throws {
        let session = try TestSession()
        let invalid: [(String, [String: Any])] = [
            ("select_device", [:]), ("connect_device", ["device": 7]),
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

    func testPhysicalIOSRoutesHierarchyAndSelectorsAndReportsConditionalCapabilities() async throws {
        let session = try TestSession(device: testDevice("physical", connection: "usb"))
        let ui = try await result("describe_ui", [:], session: session)
        XCTAssertNil(ui["isError"])
        _ = try await result("tap", ["id": "save"], session: session)
        XCTAssertEqual(session.calls, ["tree", "activate save"])
        let list = try await result("list_devices", [:], session: session)
        let rows = (list["structuredContent"] as? [String: Any])?["devices"] as? [[String: Any]]
        let capabilities = try XCTUnwrap(rows?.first?["capabilities"] as? [String])
        XCTAssertTrue(capabilities.contains("describe_ui"))
        XCTAssertTrue(capabilities.contains("element_targeting"))
        // The fixture has no known OS version; never promise the iOS 27 HID path.
        XCTAssertFalse(capabilities.contains("type_text"))
        let text = try await result("type_text", ["text": "Hello"], session: session)
        XCTAssertEqual(text["isError"] as? Bool, true)
        XCTAssertEqual(session.calls, ["tree", "activate save"])
    }

    func testPhysicalIOS27TextLimitsAndCapabilityReporting() async throws {
        let session = try TestSession(device: testDevice("physical", connection: "network", version: "27.1"))
        let list = try await result("list_devices", [:], session: session)
        let rows = (list["structuredContent"] as? [String: Any])?["devices"] as? [[String: Any]]
        XCTAssertTrue((rows?.first?["capabilities"] as? [String])?.contains("type_text") == true)
        let invalid = try await result("type_text", ["text": String(repeating: "a", count: 501), "id": "field"], session: session)
        XCTAssertEqual(invalid["isError"] as? Bool, true)
        XCTAssertTrue(session.calls.isEmpty, "Length must fail before selector activation")
        let valid = try await result("type_text", ["text": "42", "id": "field"], session: session)
        XCTAssertNil(valid["isError"])
        XCTAssertEqual(session.calls, ["type 42 field"])
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


private actor WorkspaceProbe {
    var selected: String?
    var events: [String] = []
    let failsConnection: Bool
    init(selected: String? = nil, failsConnection: Bool = false) {
        self.selected = selected
        self.failsConnection = failsConnection
    }
    func select(_ device: DeviceSummary) { selected = device.udid; events.append("select " + device.udid) }
    func connect(_ device: DeviceSummary) throws {
        events.append("connect " + device.udid)
        if failsConnection { throw DeviceHubError.serviceFailed("connection failed") }
        selected = device.udid
    }
    nonisolated var access: MCPWorkspaceAccess {
        MCPWorkspaceAccess(selectedDevice: { await self.selected },
                           select: { await self.select($0) }, connect: { try await self.connect($0) })
    }
}

extension MCPCommandTests {
    func testBatchedConnectLaunchScreenshotEachReturnVerifiedWebHandoff() async throws {
        let session = try TestSession()
        let probe = WebHandoffProbe()
        let access = MCPDeviceAccess(devices: { [session.device] }, session: { _ in session },
                                     webPreview: { try await probe.url($0, port: $1) })
        let workspace = WorkspaceProbe()
        // Reproduce the agent's bug: execute the whole batch without reading intermediate results.
        let connected = await MCPServer.handle(request("connect_device", [:]), access: access, workspace: workspace.access)
        let launched = await MCPServer.handle(request("launch_app", ["bundle_id": "example.app"]), access: access)
        let screenshot = await MCPServer.handle(request("screenshot", [:]), access: access)
        for reply in [connected, launched, screenshot] {
            let result = try XCTUnwrap(reply?["result"] as? [String: Any])
            XCTAssertNil(result["isError"])
            let output = try XCTUnwrap(result["structuredContent"] as? [String: Any])
            let preview = try XCTUnwrap(output["web_preview"] as? [String: Any])
            XCTAssertEqual(preview["url"] as? String, "http://127.0.0.1:8765/")
            XCTAssertEqual(output["next_required_action"] as? String, "open_url")
            XCTAssertEqual(output["web_preview_pending"] as? Bool, false)
            let texts = (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
            XCTAssertTrue(texts.contains { $0.contains("NEXT REQUIRED ACTION") })
        }
        XCTAssertEqual(session.calls, ["launch example.app", "screenshot"])
        let checks = await probe.calls
        XCTAssertEqual(checks.count, 1, "The short batch reuses availability, without hiding later handoff reminders")
        let content = (screenshot?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        XCTAssertTrue(content?.contains { $0["type"] as? String == "image" } == true)
    }

    func testPreviewFailurePreservesConnectionAndDeliveredInput() async throws {
        let session = try TestSession()
        let access = MCPDeviceAccess(devices: { [session.device] }, session: { _ in session }, webPreview: { _, _ in
            throw ToolFailure(message: "Preview stopped")
        })
        let workspace = WorkspaceProbe()
        let connected = await MCPServer.handle(request("connect_device", [:]), access: access, workspace: workspace.access)
        let tapped = await MCPServer.handle(request("tap", ["x": 40, "y": 80]), access: access)
        for reply in [connected, tapped] {
            let result = try XCTUnwrap(reply?["result"] as? [String: Any])
            XCTAssertNil(result["isError"], "Preview errors must not invite replay of successful input")
            let output = try XCTUnwrap(result["structuredContent"] as? [String: Any])
            XCTAssertEqual(output["next_required_action"] as? String, "get_web_preview")
            XCTAssertEqual(output["web_preview_pending"] as? Bool, true)
            let preview = try XCTUnwrap(output["web_preview"] as? [String: Any])
            XCTAssertNil(preview["url"])
            XCTAssertEqual(preview["error"] as? String, "Preview stopped")
        }
        let connection = (connected?["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
        XCTAssertEqual(connection?["session_connected"] as? Bool, true)
        let input = (tapped?["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
        XCTAssertEqual(input?["input_sent"] as? Bool, true)
        XCTAssertEqual(session.calls.count, 1)
    }

    func testCustomPreviewPortIsReusedAndAnotherDeviceDoesNotInheritIt() async throws {
        let first = try TestSession(device: testDevice("one"))
        let second = try TestSession(device: testDevice("two"))
        let probe = WebHandoffProbe()
        let access = MCPDeviceAccess(devices: { [first.device, second.device] }, session: { $0 == "one" ? first : second },
                                     webPreview: { try await probe.url($0, port: $1) })
        _ = await MCPServer.handle(request("get_web_preview", ["device": "one", "port": 9001]), access: access)
        // A lookup by one client must not suppress a subsequent client's browser reminder.
        let firstScreen = await MCPServer.handle(request("screenshot", ["device": "one"]), access: access)
        let secondScreen = await MCPServer.handle(request("screenshot", ["device": "two"]), access: access)
        for (reply, port) in [(firstScreen, 9001), (secondScreen, 8765)] {
            let output = (reply?["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
            XCTAssertEqual(output?["next_required_action"] as? String, "open_url")
            let preview = output?["web_preview"] as? [String: Any]
            XCTAssertEqual(preview?["port"] as? Int, port)
        }
        let checks = await probe.calls
        XCTAssertEqual(checks, ["one:9001", "two:8765"])
    }

    func testReconnectRechecksAvailabilityAndDiscardsStaleURL() async throws {
        let session = try TestSession()
        let probe = WebHandoffProbe()
        let access = MCPDeviceAccess(devices: { [session.device] }, session: { _ in session },
                                     webPreview: { try await probe.url($0, port: $1) })
        let workspace = WorkspaceProbe()
        _ = await MCPServer.handle(request("connect_device", [:]), access: access, workspace: workspace.access)
        await probe.stop()
        let reply = await MCPServer.handle(request("connect_device", [:]), access: access, workspace: workspace.access)
        let output = (reply?["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
        XCTAssertEqual(output?["next_required_action"] as? String, "get_web_preview")
        XCTAssertNil((output?["web_preview"] as? [String: Any])?["url"])
        let checks = await probe.calls
        XCTAssertEqual(checks.count, 2)
    }

    func testSelectThenConnectAndImplicitActionUseSharedSelection() async throws {
        let first = try TestSession(device: testDevice("one"))
        let second = try TestSession(device: testDevice("two"))
        let devices = [first.device, second.device]
        let access = MCPDeviceAccess(devices: { devices }, session: { $0 == "one" ? first : second })
        let workspace = WorkspaceProbe()
        let selected = await MCPServer.handle(request("select_device", ["device": "two"]), access: access, workspace: workspace.access)
        XCTAssertNil((selected?["result"] as? [String: Any])?["isError"])
        XCTAssertTrue(first.calls.isEmpty && second.calls.isEmpty)
        let connected = await MCPServer.handle(request("connect_device", [:]), access: access, workspace: workspace.access)
        let data = (connected?["result"] as? [String: Any])?["structuredContent"] as? [String: Any]
        XCTAssertEqual(data?["session_connected"] as? Bool, true)
        XCTAssertEqual(data?["first_frame_verified"] as? Bool, false)
        let events = await workspace.events
        XCTAssertEqual(events, ["select two", "connect two"])
        _ = await MCPServer.handle(request("tap", ["x": 10, "y": 20]), access: access, workspace: workspace.access)
        XCTAssertTrue(first.calls.isEmpty)
        XCTAssertEqual(second.calls.count, 1)
        _ = await MCPServer.handle(request("tap", ["device": "one", "x": 10, "y": 20]), access: access, workspace: workspace.access)
        XCTAssertEqual(first.calls.count, 1)
        let selection = await workspace.selected
        XCTAssertEqual(selection, "two", "An explicit action target must not change the UI selection")
        let list = await MCPServer.handle(request("list_devices", [:]), access: access, workspace: workspace.access)
        let rows = ((list?["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["devices"] as? [[String: Any]]
        XCTAssertEqual(rows?.map { $0["selected"] as? Bool }, [false, true])
    }

    func testSelectUnreadyDeviceButRejectConnectionAndDoNotFallback() async throws {
        let unavailable = try testDevice("locked", state: "untrusted")
        let ready = try testDevice("ready")
        let access = MCPDeviceAccess(devices: { [unavailable, ready] }, session: { _ in
            XCTFail("Must not open another device"); throw DeviceHubError.connectionClosed
        })
        let workspace = WorkspaceProbe()
        let selection = await MCPServer.handle(request("select_device", ["device": "locked"]), access: access, workspace: workspace.access)
        XCTAssertNil((selection?["result"] as? [String: Any])?["isError"])
        for tool in ["connect_device", "screenshot"] {
            let reply = await MCPServer.handle(request(tool, [:]), access: access, workspace: workspace.access)
            XCTAssertEqual((reply?["result"] as? [String: Any])?["isError"] as? Bool, true)
        }
        let events = await workspace.events
        XCTAssertEqual(events, ["select locked"])
    }

    func testConnectReportsFailureAndAmbiguityWithoutSuccess() async throws {
        let device = try testDevice("one")
        let other = try testDevice("two")
        let access = MCPDeviceAccess(devices: { [device, other] }, session: { _ in
            XCTFail("Explicit connection uses the workspace"); throw DeviceHubError.connectionClosed
        })
        let workspace = WorkspaceProbe(failsConnection: true)
        let ambiguous = await MCPServer.handle(request("connect_device", [:]), access: access, workspace: workspace.access)
        XCTAssertEqual((ambiguous?["result"] as? [String: Any])?["isError"] as? Bool, true)
        let initialEvents = await workspace.events
        XCTAssertTrue(initialEvents.isEmpty)
        let failure = await MCPServer.handle(request("connect_device", ["device": "two"]), access: access, workspace: workspace.access)
        let result = failure?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        XCTAssertNil(result?["structuredContent"])
        let missingHost = await MCPServer.handle(request("select_device", ["device": "one"]), access: access)
        XCTAssertEqual((missingHost?["result"] as? [String: Any])?["isError"] as? Bool, true)
    }
}

private actor WebHandoffProbe {
    private(set) var calls: [String] = []
    private var stopped = false
    func stop() { stopped = true }
    func url(_ device: String, port: UInt16) throws -> URL {
        calls.append("\(device):\(port)")
        if stopped { throw ToolFailure(message: "Preview stopped") }
        return URL(string: "http://127.0.0.1:\(port)/")!
    }
}
