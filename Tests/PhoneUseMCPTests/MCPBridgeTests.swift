import Foundation
import XCTest
@testable import PhoneUseMCP
import PhoneUseKit

/// Messages written by a bridge, in order.
private final class Transcript: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [[String: Any]] = []

    func append(_ data: Data) {
        guard let message = MCPServer.decode(data) else { return XCTFail("bridge wrote invalid JSON") }
        lock.withLock { lines.append(message) }
    }

    var messages: [[String: Any]] { lock.withLock { lines } }

    /// Waits until `count` messages arrived.
    func wait(for count: Int, timeout: TimeInterval = 5) async throws -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if messages.count >= count { return messages }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("expected \(count) messages, got \(messages)")
        return messages
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

final class MCPBridgeTests: XCTestCase {
    private var socketPath = ""
    private var servers: [MCPSocketServer] = []

    override func setUp() {
        // Unix socket paths are limited to 104 bytes, so keep the name short.
        socketPath = NSTemporaryDirectory() + "mcp-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        servers.forEach { $0.stop() }
        unlink(socketPath)
    }

    private func line(_ message: [String: Any]) -> Data {
        MCPServer.encode(message)!
    }

    private func call(_ id: Int, _ tool: String = "tap") -> Data {
        line(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": [String: Any]()]])
    }

    /// A stand-in for the app that answers every call with the tool name it was asked for.
    private func makeApp(reply: Bool = true) -> MCPSocketServer {
        let server = MCPSocketServer(path: socketPath, handler: { data in
            guard reply, let message = MCPServer.decode(data) else { return nil }
            let name = (message["params"] as? [String: Any])?["name"] as? String ?? ""
            return MCPServer.encode(["jsonrpc": "2.0", "id": message["id"]!,
                                     "result": ["content": [["type": "text", "text": "ran \(name)"]]]])
        })
        servers.append(server)
        return server
    }

    private func text(_ message: [String: Any]) -> String? {
        let content = (message["result"] as? [String: Any])?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String
    }

    private func isError(_ message: [String: Any]) -> Bool {
        (message["result"] as? [String: Any])?["isError"] as? Bool == true
    }

    func testInitializeAndToolListNeverLaunchTheApp() async throws {
        let transcript = Transcript(), launches = Counter()
        let bridge = MCPBridge(socketPath: socketPath, launchApp: { launches.increment() }, output: transcript.append)
        await bridge.receive(line(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                   "params": ["protocolVersion": "2025-06-18"]]))
        await bridge.receive(line(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        await bridge.receive(line(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        await bridge.receive(line(["jsonrpc": "2.0", "id": 3, "method": "ping"]))

        let messages = try await transcript.wait(for: 3)
        XCTAssertEqual(messages.count, 3, "notifications get no reply")
        let info = (messages[0]["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "phone-use")
        let tools = (messages[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertTrue(tools?.contains { $0["name"] as? String == "get_screen" } == true)
        XCTAssertEqual(messages[2]["id"] as? Int, 3)
        XCTAssertEqual(launches.count, 0)
    }

    func testToolCallsRunInTheRunningApp() async throws {
        try await makeApp().start()
        let transcript = Transcript(), launches = Counter()
        let bridge = MCPBridge(socketPath: socketPath, launchApp: { launches.increment() }, output: transcript.append)
        await bridge.receive(call(7, "tap"))
        await bridge.receive(call(8, "swipe"))

        let messages = try await transcript.wait(for: 2)
        XCTAssertEqual(messages.map { $0["id"] as? Int }, [7, 8])
        XCTAssertEqual(messages.map(text), ["ran tap", "ran swipe"])
        XCTAssertEqual(launches.count, 0)
    }

    func testFirstToolCallLaunchesTheAppAndWaitsForIt() async throws {
        let app = makeApp()
        let transcript = Transcript(), launches = Counter()
        let bridge = MCPBridge(socketPath: socketPath, launchApp: {
            launches.increment()
            // The app starts serving a little after it launches.
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                do { try await app.start() } catch { XCTFail("\(error)") }
            }
        }, output: transcript.append)
        await bridge.receive(call(1))
        await bridge.receive(call(2))

        let messages = try await transcript.wait(for: 2)
        XCTAssertEqual(messages.map(text), ["ran tap", "ran tap"])
        XCTAssertEqual(launches.count, 1, "the second call reuses the connection")
    }

    func testCallsInFlightFailWhenTheAppQuitsAndTheNextCallReconnects() async throws {
        let silent = makeApp(reply: false)
        try await silent.start()
        let transcript = Transcript()
        let bridge = MCPBridge(socketPath: socketPath, launchApp: {}, output: transcript.append)
        await bridge.receive(call(1))
        try await Task.sleep(for: .milliseconds(200))
        silent.stop()

        let failed = try await transcript.wait(for: 1)
        XCTAssertEqual(failed[0]["id"] as? Int, 1)
        XCTAssertTrue(isError(failed[0]))

        try await makeApp().start()
        await bridge.receive(call(2))
        let messages = try await transcript.wait(for: 2)
        XCTAssertEqual(messages[1]["id"] as? Int, 2)
        XCTAssertEqual(text(messages[1]), "ran tap")
    }

    func testAppThatNeverServesReportsAToolError() async throws {
        let transcript = Transcript()
        let bridge = MCPBridge(socketPath: socketPath, launchTimeout: .milliseconds(500),
                               launchApp: {}, output: transcript.append)
        await bridge.receive(call(4))
        let messages = try await transcript.wait(for: 1)
        XCTAssertEqual(messages[0]["id"] as? Int, 4)
        XCTAssertTrue(isError(messages[0]))
    }

    func testFailedLaunchReportsAToolError() async throws {
        struct Missing: Error {}
        let transcript = Transcript()
        let bridge = MCPBridge(socketPath: socketPath, launchApp: { throw Missing() }, output: transcript.append)
        await bridge.receive(call(5))
        let messages = try await transcript.wait(for: 1)
        XCTAssertTrue(isError(messages[0]))
        XCTAssertTrue(text(messages[0])?.contains("not available") == true)
    }

    func testServerReplacesAStaleSocketButNotALiveOne() async throws {
        // A socket file nobody listens on, as left behind by a crash.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            _ = socketPath.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        try await makeApp().start()
        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        do {
            try await makeApp().start()
            XCTFail("a second server must not take over a live socket")
        } catch MCPSocketServer.StartError.alreadyServing {
        }
    }

    func testServerRejectsUnknownToolsBeforePreparing() async throws {
        let prepared = Counter()
        let reply = await MCPServer.handle(
            ["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": ["name": "format_disk"]],
            prepare: { prepared.increment() })
        XCTAssertNotNil(reply)
        XCTAssertTrue(isError(reply!))
        XCTAssertEqual(prepared.count, 0)
    }

    func testServerReportsPrepareFailureAsAToolError() async throws {
        struct DaemonDown: Error, CustomStringConvertible { var description: String { "daemon down" } }
        let reply = await MCPServer.handle(
            ["jsonrpc": "2.0", "id": 10, "method": "tools/call", "params": ["name": "get_screen"]],
            prepare: { throw DaemonDown() })
        XCTAssertTrue(isError(reply!))
        XCTAssertEqual(text(reply!), "daemon down")
    }

    func testDeviceErrorsTellTheAgentWhatToAskTheUser() {
        let notReady = MCPServer.guidance(for: DeviceHubError.deviceNotReady("Andy's iPhone is not ready (pairing)"))
        XCTAssertTrue(notReady.hasPrefix("Andy's iPhone is not ready (pairing)."))
        XCTAssertTrue(notReady.contains("Ask the user to open PhoneUse"))
        let missing = MCPServer.guidance(for: DeviceHubError.deviceNotFound("Pixel"))
        XCTAssertTrue(missing.contains("list_devices"))
        let daemon = MCPServer.guidance(for: DeviceHubError.daemonUnavailable("connection refused"))
        XCTAssertTrue(daemon.contains("(connection refused)"))
        XCTAssertFalse(daemon.contains("Open PhoneUse.app first"), "the app-side message must not repeat the CLI advice")
        XCTAssertEqual(MCPServer.guidance(for: DeviceHubError.connectionClosed), DeviceHubError.connectionClosed.description)
    }
}
