import Foundation
import XCTest
import PhoneUseKit
@testable import PhoneUseMCP

private struct SandboxProbe: DeviceFileAccess {
    var fails = false
    func apps() async throws -> [SandboxApp] {
        if fails { throw DeviceHubError.serviceFailed("Container access denied") }
        return try JSONDecoder().decode([SandboxApp].self, from: Data(#"[{"bundleIdentifier":"example.app","name":"Example","containerAccessible":true}]"#.utf8))
    }
    func list(bundleID: String, path: String) async throws -> [SandboxFile] {
        if fails { throw DeviceHubError.serviceFailed("Container access denied") }
        return try JSONDecoder().decode([SandboxFile].self, from: Data(#"[{"name":"a.txt","path":"Library/a.txt","kind":"file","size":5},{"name":"b.txt","path":"Library/b.txt","kind":"file","size":5}]"#.utf8))
    }
    func readText(bundleID: String, path: String) async throws -> String { "hello 世界" }
    func download(bundleID: String, path: String, to destination: URL) async throws {}
}

final class MCPSandboxTests: XCTestCase {
    private func device(platform: String = "ios", id: String = "one") throws -> DeviceSummary {
        try JSONDecoder().decode(DeviceSummary.self, from: JSONSerialization.data(withJSONObject: [
            "udid": id, "name": "Test", "platform": platform, "connection": "usb", "state": "ready", "session": "closed",
        ]))
    }
    private func access(platform: String = "ios", fails: Bool = false) throws -> MCPDeviceAccess {
        let device = try device(platform: platform)
        return MCPDeviceAccess(devices: { [device] }, session: { _ in
            XCTFail("File operations must not open a screen/input session")
            throw DeviceHubError.connectionClosed
        }, files: { _ in SandboxProbe(fails: fails) })
    }
    private func request(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
    }
    private func result(_ name: String, _ arguments: [String: Any], access: MCPDeviceAccess) async throws -> [String: Any] {
        let reply = await MCPServer.handle(request(name, arguments), access: access)
        return try XCTUnwrap(reply?["result"] as? [String: Any])
    }

    func testFileToolsReturnStructuredDataWithoutOpeningScreenSession() async throws {
        let access = try access()
        let apps = try await result("list_apps", ["search": "EXAMPLE"], access: access)
        XCTAssertEqual(((apps["structuredContent"] as? [String: Any])?["apps"] as? [[String: Any]])?.count, 1)
        let listing = try await result("list_sandbox_files", ["bundle_id": "example.app", "path": "Library", "limit": 1], access: access)
        let output = try XCTUnwrap(listing["structuredContent"] as? [String: Any])
        XCTAssertEqual(output["total"] as? Int, 2)
        XCTAssertEqual(output["next_offset"] as? Int, 1)
        XCTAssertEqual((output["files"] as? [[String: Any]])?.first?["path"] as? String, "Library/a.txt")
        let second = try await result("list_sandbox_files", ["bundle_id": "example.app", "offset": 1, "limit": 1], access: access)
        XCTAssertNil((second["structuredContent"] as? [String: Any])?["next_offset"])
        let text = try await result("read_sandbox_file", ["bundle_id": "example.app", "path": "Library/a.txt"], access: access)
        XCTAssertEqual((text["structuredContent"] as? [String: Any])?["text"] as? String, "hello 世界")
        let download = try await result("download_sandbox_file", ["bundle_id": "example.app", "path": "Library/a.txt", "destination": "/tmp/export.txt"], access: access)
        XCTAssertEqual((download["structuredContent"] as? [String: Any])?["local_path"] as? String, "/tmp/export.txt")
    }

    func testInvalidFileArgumentsFailBeforePreparingDevices() async throws {
        let invalid: [(String, [String: Any])] = [
            ("list_sandbox_files", [:]), ("list_sandbox_files", ["bundle_id": "app", "path": "../other"]),
            ("list_sandbox_files", ["bundle_id": "app", "path": "/Library"]),
            ("list_sandbox_files", ["bundle_id": "app", "limit": true]),
            ("list_sandbox_files", ["bundle_id": "app", "limit": 501]),
            ("list_sandbox_files", ["bundle_id": "app", "offset": 0.5]),
            ("read_sandbox_file", ["bundle_id": "app", "path": "."]),
            ("download_sandbox_file", ["bundle_id": "app", "path": "file", "destination": "relative.txt"]),
            ("list_apps", ["search": 4]),
        ]
        let access = try access()
        for (name, args) in invalid {
            let reply = await MCPServer.handle(request(name, args), prepare: { XCTFail("Validate before preparing") }, access: access)
            XCTAssertEqual((reply?["result"] as? [String: Any])?["isError"] as? Bool, true)
        }
    }

    func testPermissionAndUnsupportedPlatformErrorsDoNotBecomeEmptyListings() async throws {
        for access in [try access(fails: true), try access(platform: "android")] {
            let result = try await result("list_sandbox_files", ["bundle_id": "example.app"], access: access)
            XCTAssertEqual(result["isError"] as? Bool, true)
            XCTAssertNil(result["structuredContent"])
        }
    }

    func testConnectedDeviceThroughMCPDispatch() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let udid = env["DEVICEHUB_SANDBOX_DEVICE"], let bundle = env["DEVICEHUB_SANDBOX_APP"],
              let path = env["DEVICEHUB_SANDBOX_FILE"] else { throw XCTSkip("Set DEVICEHUB_SANDBOX_DEVICE/APP/FILE") }
        let device = try device(id: udid)
        let access = MCPDeviceAccess(devices: { [device] }, session: { _ in
            XCTFail("Sandbox access must not open a screen"); throw DeviceHubError.connectionClosed
        })
        let apps = try await result("list_apps", ["search": bundle], access: access)
        XCTAssertNil(apps["isError"], "\(apps)")
        let root = try await result("list_sandbox_files", ["bundle_id": bundle], access: access)
        XCTAssertNil(root["isError"], "\(root)")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("download")
        let downloaded = try await result("download_sandbox_file", ["bundle_id": bundle, "path": path, "destination": destination.path], access: access)
        XCTAssertNil(downloaded["isError"], "\(downloaded)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        if let text = try? String(contentsOf: destination, encoding: .utf8), text.utf8.count <= DeviceFiles.maximumTextBytes,
           !text.contains("\0") {
            let preview = try await result("read_sandbox_file", ["bundle_id": bundle, "path": path], access: access)
            XCTAssertNil(preview["isError"])
            XCTAssertEqual((preview["structuredContent"] as? [String: Any])?["text"] as? String, text)
        }
    }
}
