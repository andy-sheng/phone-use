import Foundation
import XCTest
import PhoneUseKit
@testable import PhoneUseMCP

final class MCPWebPreviewTests: XCTestCase {
    private func device(_ id: String = "simulator:web-test") throws -> DeviceSummary {
        try JSONDecoder().decode(DeviceSummary.self, from: JSONSerialization.data(withJSONObject: [
            "udid": id, "name": "Web Test", "platform": "ios", "connection": "simulator", "state": "ready", "session": "open",
        ]))
    }

    private func request(_ arguments: [String: Any] = [:]) -> [String: Any] {
        ["id": 1, "method": "tools/call", "params": ["name": "get_web_preview", "arguments": arguments]]
    }

    func testInitializationDirectsAgentToItsOwnPreviewAtConnection() throws {
        let reply = try XCTUnwrap(MCPServer.localReply(to: ["id": 1, "method": "initialize"]))
        let instructions = try XCTUnwrap((reply["result"] as? [String: Any])?["instructions"] as? String)
        XCTAssertTrue(instructions.contains("Read the connect_device result before continuing"))
        XCTAssertTrue(instructions.contains("once at connection"))
        XCTAssertTrue(instructions.contains("Use only your agent's built-in web preview"))
    }

    func testVerifiedPreviewDoesNotOpenDeviceSession() async throws {
        let device = try device()
        let access = MCPDeviceAccess(devices: { [device] }, session: { _ in
            XCTFail("Web discovery must not open another device session")
            throw DeviceHubError.connectionClosed
        }, webPreview: { id, port in
            XCTAssertEqual(id, device.udid)
            XCTAssertEqual(port, 9001)
            return URL(string: "http://127.0.0.1:9001/")!
        })
        let reply = await MCPServer.handle(request(["device": device.udid, "port": 9001]), access: access)
        let result = try XCTUnwrap(reply?["result"] as? [String: Any])
        let output = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(output["url"] as? String, "http://127.0.0.1:9001/")
        XCTAssertEqual(output["available"] as? Bool, true)
        XCTAssertEqual(output["browser_opened"] as? Bool, false)
        XCTAssertEqual(output["same_host_required"] as? Bool, true)
        let text = (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(text?.contains("http://127.0.0.1:9001/") == true)
        XCTAssertFalse(text?.contains("preview_open") == true)
        XCTAssertNil(output["next_required_action"])
        XCTAssertNil(output["next_action_target"])
    }

    func testUnavailablePreviewReturnsErrorWithoutReadyURL() async throws {
        let device = try device()
        let access = MCPDeviceAccess(devices: { [device] }, session: { _ in throw DeviceHubError.connectionClosed },
            webPreview: { _, port in
                XCTAssertEqual(port, 8765)
                throw ToolFailure(message: "Web service is unavailable")
            })
        let reply = await MCPServer.handle(request(), access: access)
        let result = try XCTUnwrap(reply?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertNil(result["structuredContent"])
    }

    func testPortValidation() throws {
        if case .webPreview(let port) = try MCPCommand(name: "get_web_preview", arguments: [:]).action {
            XCTAssertEqual(port, 8765)
        } else { XCTFail("Expected web preview") }
        for port: Any in [0, -1, 65536, 1.5, true, "8765"] {
            XCTAssertThrowsError(try MCPCommand(name: "get_web_preview", arguments: ["port": port]))
        }
        XCTAssertThrowsError(try MCPCommand(name: "get_web_preview", arguments: ["url": "https://example.com"]))
    }

    func testHealthRequiresMatchingDeviceAndAnActualFrame() throws {
        let good = Data(#"{"service":"phone-use-web","device_id":"device-one","frames":1}"#.utf8)
        XCTAssertNoThrow(try MCPWebPreview.validate(good, deviceID: "device-one"))
        XCTAssertThrowsError(try MCPWebPreview.validate(good, deviceID: "device-two"))
        for json in [#"{"service":"other","device_id":"device-one","frames":1}"#,
                     #"{"service":"phone-use-web","device_id":"device-one","frames":0}"#,
                     #"{"device":"device-one","frames":1}"#] {
            XCTAssertThrowsError(try MCPWebPreview.validate(Data(json.utf8), deviceID: "device-one"))
        }
    }

    func testLiveLocalWebPreview() async throws {
        guard let id = ProcessInfo.processInfo.environment["PHONEUSE_WEB_PREVIEW_DEVICE"] else {
            throw XCTSkip("Set PHONEUSE_WEB_PREVIEW_DEVICE to check a running local web preview without device input")
        }
        let device = try device(id)
        let access = MCPDeviceAccess(devices: { [device] }, session: { _ in
            XCTFail("Must not open a session")
            throw DeviceHubError.connectionClosed
        }, webPreview: { try await MCPWebPreview.url(deviceID: $0, port: $1) })
        let reply = await MCPServer.handle(request(["device": id]), access: access)
        let result = try XCTUnwrap(reply?["result"] as? [String: Any])
        XCTAssertNil(result["isError"], "\(result)")
        let output = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(output["url"] as? String, "http://127.0.0.1:8765/")
        XCTAssertEqual(output["device"] as? String, id)
    }
}
