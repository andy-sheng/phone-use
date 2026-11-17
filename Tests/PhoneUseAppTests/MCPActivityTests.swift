import XCTest
import PhoneUseMCP
@testable import PhoneUseApp

@MainActor
final class MCPActivityTests: XCTestCase {
    private func request(_ name: String = "tap", arguments: [String: Any] = ["x": 10, "y": 20]) -> Data {
        MCPServer.encode(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                          "params": ["name": name, "arguments": arguments]])!
    }
    private func reply(_ text: String, failed: Bool = false) -> Data {
        MCPServer.encode(["jsonrpc": "2.0", "id": 1, "result": ["isError": failed,
            "content": [["type": "text", "text": text]]]])!
    }

    func testRecordsRunningAndCompletedWithoutChangingWireResponse() async {
        let store = MCPActivityStore()
        let input = request(arguments: ["device": "test-device", "x": 10, "y": 20])
        let output = reply("Input sent; verify UI")
        let actual = await store.handle(line: input) { line in
            XCTAssertEqual(line, input)
            await MainActor.run {
                XCTAssertEqual(store.calls.count, 1)
                XCTAssertEqual(store.calls[0].state, .running)
                XCTAssertEqual(store.calls[0].device, "test-device")
                XCTAssertTrue(store.calls[0].arguments.contains("10"))
            }
            return output
        }
        XCTAssertEqual(actual, output)
        XCTAssertEqual(store.calls[0].state, .succeeded)
        XCTAssertEqual(store.calls[0].result, "Input sent; verify UI")
        XCTAssertNotNil(store.calls[0].elapsed)
    }

    func testOverlappingClientsWithSameRequestIDFinishTheirOwnRows() async {
        let store = MCPActivityStore()
        let input = request()
        let outerReply = reply("first")
        let innerReply = reply("second", failed: true)
        _ = await store.handle(line: input) { _ in
            _ = await store.handle(line: input) { _ in innerReply }
            return outerReply
        }
        XCTAssertEqual(store.calls.map(\.result), ["second", "first"])
        XCTAssertEqual(store.calls.map(\.state), [.failed, .succeeded])
        XCTAssertNotEqual(store.calls[0].id, store.calls[1].id)
    }

    func testClearDoesNotRestoreInFlightCallsAndCapacityEvictsOldest() async {
        let store = MCPActivityStore(capacity: 2)
        let output = reply("done")
        _ = await store.handle(line: request()) { _ in
            await MainActor.run { store.clear() }
            return output
        }
        XCTAssertTrue(store.calls.isEmpty)
        for name in ["tap", "screenshot", "describe_ui"] {
            _ = await store.handle(line: request(name)) { _ in output }
        }
        XCTAssertEqual(store.calls.map(\.name), ["describe_ui", "screenshot"])
    }

    func testErrorsAndInvalidArgumentsAreRecordedButLifecycleIsIgnored() async {
        let store = MCPActivityStore()
        let protocolError = MCPServer.encode(["id": 1, "error": ["code": -32602, "message": "Bad arguments"]])!
        let invalid = MCPServer.encode(["id": 1, "method": "tools/call",
                                       "params": ["name": "tap", "arguments": "invalid"]])!
        _ = await store.handle(line: invalid) { _ in protocolError }
        XCTAssertEqual(store.calls[0].state, .failed)
        XCTAssertTrue(store.calls[0].arguments.contains("invalid"))
        XCTAssertTrue(store.calls[0].result.contains("Bad arguments"))
        _ = await store.handle(line: request()) { _ in nil }
        XCTAssertEqual(store.calls[0].state, .failed)
        let ping = MCPServer.encode(["id": 2, "method": "ping"])!
        let result = await store.handle(line: ping) { _ in protocolError }
        XCTAssertEqual(result, protocolError)
        XCTAssertEqual(store.calls.count, 2)
    }

    func testImagesAreSummarizedAndLargeTextIsBounded() async {
        let store = MCPActivityStore()
        let output = MCPServer.encode(["id": 1, "result": ["content": [
            ["type": "image", "mimeType": "image/jpeg", "data": "PRIVATE_BASE64_PAYLOAD"],
            ["type": "text", "text": String(repeating: "x", count: 30_000)]
        ]]])!
        _ = await store.handle(line: request("type_text", arguments: ["text": String(repeating: "a", count: 10_000)])) { _ in output }
        let call = store.calls[0]
        XCTAssertTrue(call.result.contains("image/jpeg"))
        XCTAssertFalse(call.result.contains("PRIVATE_BASE64_PAYLOAD"))
        XCTAssertLessThan(call.result.count, 12_100)
        XCTAssertLessThan(call.arguments.count, 8_100)
        XCTAssertTrue(call.result.contains("截断"))
        XCTAssertTrue(call.arguments.contains("截断"))
    }
}
